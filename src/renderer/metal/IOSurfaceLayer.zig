//! A CAMetalLayer that presents completed render targets by copying them 1:1
//! into drawables. During a live resize, AppKit's display callback draws the
//! newest prepared frame itself, so the picture lands in the same transaction
//! as the window's new size.
const IOSurfaceLayer = @This();

const std = @import("std");
const global = @import("../../global.zig");
const objc = @import("objc");
const macos = @import("macos");

const IOSurface = macos.iosurface.IOSurface;
const cf = macos.foundation.c;
const DrawableLease = @import("DrawableLease.zig");
const mtl = @import("api.zig");

const Pending = struct {
    surface: *IOSurface,
    texture: objc.Object,
    frame_id: u64,

    fn init(surface: *IOSurface, texture: objc.Object, frame_id: u64) Pending {
        surface.retain();
        _ = texture.retain();
        return .{ .surface = surface, .texture = texture, .frame_id = frame_id };
    }

    fn release(self: Pending) void {
        self.texture.release();
        self.surface.release();
    }
};

// Presentation ownership and scheduling:
//
// renderer completion                 main run loop (any observed mode)
// retain surface                      persistent source owns state
// replace latest pending slot ------> take slot, accept/reject, release surface
// observe current mode + signal source  state owns layer for callback lifetime
//
// At most one completed frame waits for the main thread. Published images
// are immutable, so an unbounded queue would also be unbounded VRAM. AppKit
// can run private tracking modes during interactive resize. The source is
// registered in common modes once and in whichever mode the main run loop is
// currently running whenever a completion arrives. Teardown detaches the
// state, invalidates the source (removing all mode registrations), then drops
// the source and owner references. The source context keeps both state and
// layer alive until Core Foundation has finished with the callback.
const PresentationState = struct {
    refs: std.atomic.Value(usize) = .init(1),
    mutex: std.Io.Mutex = .init,
    pending: ?Pending = null,
    live_resizing: bool = false,
    /// Resize lead in backing pixels, set by the host before each size it
    /// requests; zero leaves the default lead.
    host_resize_lead_px: std.atomic.Value(u32) = .init(0),
    detached: bool = false,
    source: ?cf.CFRunLoopSourceRef = null,
    layer: objc.Object,
    max_texture_size: u32,
    queue: objc.Object,
    pixel_format: c_ulong,
    active_pixel_format: c_ulong,
    drawables_outstanding: u8 = 0,
    /// Main thread only.
    latest_accepted_id: u64 = 0,
    /// Pixel size of the most recently presented drawable: what is actually on
    /// screen. Main thread only.
    presented_pixel_width: u32 = 0,
    presented_pixel_height: u32 = 0,
    native_redraw_needed: bool = false,
    native_display_requested: bool = false,
    /// During a live resize, renderer-thread draws prepare CPU state and hand
    /// the GPU submission to the AppKit display callback.
    main_render_requested_serial: u64 = 0,
    main_render_serviced_serial: u64 = 0,
    notification_link: ?objc.Object = null,

    fn retain(self: *PresentationState) void {
        _ = self.refs.fetchAdd(1, .monotonic);
    }

    fn release(self: *PresentationState) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        if (self.pending) |p| p.release();
        if (self.notification_link) |link| link.release();
        self.queue.release();
        self.layer.release();
        std.heap.page_allocator.destroy(self);
    }
};

const NotificationLink = struct {
    mutex: std.Io.Mutex = .init,
    state: ?*PresentationState = null,
};

const DrawableSettlement = struct {
    settled: std.atomic.Value(u8) = .init(0),
    link: objc.c.id,
};

/// We subclass CAMetalLayer with a custom display handler, we only need
/// to make the subclass once, and then we can use it as a singleton.
var Subclass: ?objc.Class = null;
var NotificationLinkClass: ?objc.Class = null;
var NotificationLinkOffset: ?usize = null;
var DrawableSettlementClass: ?objc.Class = null;
var DrawableSettlementOffset: ?usize = null;

/// The underlying CAMetalLayer
layer: objc.Object,
state: *PresentationState,
source: cf.CFRunLoopSourceRef,

pub const Drawable = struct {
    lease: DrawableLease,
    settlement: objc.Object,
    /// CPU-preparation request captured by the native callback that acquired
    /// this exact drawable. Zero means no renderer-thread handoff is attached.
    main_render_serial: u64 = 0,

    pub fn encodeCopy(self: *const Drawable, buffer: objc.Object, source_texture: objc.Object) !void {
        try self.lease.encodeCopy(buffer, source_texture);
    }

    pub fn release(self: *Drawable) void {
        self.lease.release();
        self.settlement.release();
        self.* = undefined;
    }
};

pub fn init(
    max_texture_size: u32,
    device: objc.Object,
    queue: objc.Object,
    pixel_format: c_ulong,
) !IOSurfaceLayer {
    // The layer returned by `[CALayer layer]` is autoreleased, which means
    // that at the end of the current autorelease pool it will be deallocated
    // if it isn't retained, so we retain it here manually an extra time.
    const layer = (try getSubclass()).msgSend(
        objc.Object,
        objc.sel("layer"),
        .{},
    ).retain();
    errdefer layer.release();

    // Keep the picture at its native size. A drawable larger than the layer
    // (the resize lead) shows its top-left part instead of being scaled.
    layer.setProperty("contentsGravity", macos.animation.kCAGravityTopLeft);

    DrawableLease.configure(layer, device, pixel_format);
    layer.setProperty("opaque", false);
    const colorspace = try macos.graphics.ColorSpace.createNamed(.displayP3);
    defer colorspace.release();
    layer.setProperty("colorspace", colorspace);

    const state = try std.heap.page_allocator.create(PresentationState);
    state.* = .{
        .layer = layer.retain(),
        .max_texture_size = max_texture_size,
        .queue = queue.retain(),
        .pixel_format = pixel_format,
        .active_pixel_format = pixel_format,
    };
    errdefer state.release();
    state.notification_link = try createNotificationLink(state);

    var context: cf.CFRunLoopSourceContext = .{
        .version = 0,
        .info = state,
        .retain = &presentationStateRetain,
        .release = &presentationStateRelease,
        .copyDescription = null,
        .equal = null,
        .hash = null,
        .schedule = null,
        .cancel = null,
        .perform = &presentationSourcePerform,
    };
    const source = cf.CFRunLoopSourceCreate(null, 0, &context) orelse
        return error.OutOfMemory;
    errdefer cf.CFRelease(source);
    state.source = source;
    cf.CFRunLoopAddSource(cf.CFRunLoopGetMain(), source, cf.kCFRunLoopCommonModes);

    layer.setInstanceVariable("display_cb", .{ .value = null });
    layer.setInstanceVariable("display_ctx", .{ .value = null });

    return .{
        .layer = layer,
        .state = state,
        .source = source,
    };
}

pub fn release(self: *IOSurfaceLayer) void {
    if (self.state.notification_link) |owner| {
        const link = notificationLink(owner);
        link.mutex.lockUncancelable(global.io());
        link.state = null;
        link.mutex.unlock(global.io());
    }
    self.state.mutex.lockUncancelable(global.io());
    self.state.detached = true;
    self.state.native_display_requested = false;
    self.state.native_redraw_needed = false;
    self.state.main_render_requested_serial = 0;
    self.state.main_render_serviced_serial = 0;
    self.state.source = null;
    self.state.mutex.unlock(global.io());
    cf.CFRunLoopSourceInvalidate(self.source);
    cf.CFRelease(self.source);
    self.state.release();
    self.layer.release();
}

pub fn setPixelFormat(self: *IOSurfaceLayer, pixel_format: c_ulong) void {
    self.state.mutex.lockUncancelable(global.io());
    self.state.pixel_format = pixel_format;
    self.state.mutex.unlock(global.io());
}

pub fn acquireDrawable(
    self: *IOSurfaceLayer,
    width: usize,
    height: usize,
    main_render_serial: u64,
) !Drawable {
    var drawable = try acquireDrawableState(self.state, width, height);
    drawable.main_render_serial = main_render_serial;
    return drawable;
}

pub fn discardDrawable(self: *IOSurfaceLayer, drawable: *Drawable) void {
    _ = self;
    settleDrawableOwner(drawable.settlement);
    drawable.release();
}

pub fn requestNativeRedraw(self: *IOSurfaceLayer) void {
    requestNativeRedrawState(self.state);
}

/// Transfer one renderer-thread GPU draw to the AppKit display callback. The
/// CPU frame is already prepared before this call. Retaining the source under
/// the same mutex as the serial publication closes detach and exit races; the
/// Core Foundation calls happen after unlocking.
pub fn handoffRendererDrawToNative(self: *IOSurfaceLayer) bool {
    var source: ?cf.CFRunLoopSourceRef = null;
    self.state.mutex.lockUncancelable(global.io());
    if (mainRenderNativeActiveLocked(self.state) and self.state.source != null) {
        self.state.main_render_requested_serial +%= 1;
        if (self.state.main_render_requested_serial == 0)
            self.state.main_render_requested_serial = 1;
        self.state.native_redraw_needed = true;
        const value = self.state.source.?;
        _ = cf.CFRetain(value);
        source = value;
    }
    self.state.mutex.unlock(global.io());

    const value = source orelse return false;
    signalPresentationSource(value);
    cf.CFRelease(value);
    return true;
}

/// Present a drawable rendered by the display callback. The buffer must
/// already be committed.
pub fn presentNativeDrawable(
    self: *IOSurfaceLayer,
    drawable: *Drawable,
    buffer: objc.Object,
    frame_id: u64,
) bool {
    return presentDrawable(self.state, drawable, buffer, frame_id);
}

/// Pixel size of the frame currently on screen, i.e. the last accepted
/// presentation. This is what the user can see; it is deliberately not the
/// requested surface size, which can run ahead of what has been drawn.
/// Main thread only.
pub fn lastPresentedPixelSize(self: *IOSurfaceLayer) struct { width: u32, height: u32 } {
    std.debug.assert(isMainThread());
    return .{
        .width = self.state.presented_pixel_width,
        .height = self.state.presented_pixel_height,
    };
}

/// Submit a completed target. Off the main thread the frame goes through the
/// one-slot mailbox; on it, the frame is presented directly unless a live
/// resize coalesces presentation into the next display callback.
pub fn setTarget(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    texture: objc.Object,
    frame_id: u64,
) void {
    const pending = Pending.init(surface, texture, frame_id);
    if (!isMainThread()) {
        if (!enqueuePending(self.state, pending)) pending.release();
        signalPresentationSource(self.source);
        return;
    }

    self.state.mutex.lockUncancelable(global.io());
    const coalesce = nativeResizeCoalescingLocked(self.state, false);
    self.state.mutex.unlock(global.io());
    if (coalesce) {
        if (!enqueuePending(self.state, pending)) pending.release();
        requestCoalescedNativeDisplay(self.state);
        return;
    }
    presentOrRestore(self.state, pending, false);
}

/// Present a completed target within the current transaction. Main thread only.
pub fn setTargetSync(
    self: *IOSurfaceLayer,
    surface: *IOSurface,
    texture: objc.Object,
    frame_id: u64,
) void {
    std.debug.assert(isMainThread());
    presentOrRestore(self.state, Pending.init(surface, texture, frame_id), true);
}

/// True while the host is in a live window resize.
pub fn liveResizing(self: *const IOSurfaceLayer) bool {
    self.state.mutex.lockUncancelable(global.io());
    defer self.state.mutex.unlock(global.io());
    return self.state.live_resizing;
}

pub fn setLiveResizing(self: *IOSurfaceLayer, resizing: bool) void {
    std.debug.assert(isMainThread());
    var source: ?cf.CFRunLoopSourceRef = null;
    self.state.mutex.lockUncancelable(global.io());
    self.state.live_resizing = resizing;
    if (!resizing) {
        self.state.native_display_requested = false;
        if (self.state.pending != null or self.state.native_redraw_needed or
            mainRenderWorkPendingLocked(self.state))
        {
            if (self.state.source) |value| {
                _ = cf.CFRetain(value);
                source = value;
            }
        }
    }
    self.state.mutex.unlock(global.io());
    if (source) |value| {
        signalPresentationSource(value);
        cf.CFRelease(value);
    }
}

pub const NativeDisplay = struct {
    /// True while this callback owns live-resize rendering, or while it is
    /// servicing the final CPU request after the live resize ended.
    main_render_active: bool,
    /// Upper bound of CPU-prepared work this callback may service.
    main_render_serial: u64,
};

/// Called at the very start of every AppKit display callback. Consumes a
/// pending native display request.
pub fn beginNativeDisplay(self: *IOSurfaceLayer) NativeDisplay {
    std.debug.assert(isMainThread());
    self.state.mutex.lockUncancelable(global.io());
    defer self.state.mutex.unlock(global.io());
    const work_pending = mainRenderWorkPendingLocked(self.state);
    self.state.native_display_requested = false;
    return .{
        .main_render_active = work_pending or mainRenderNativeActiveLocked(self.state),
        .main_render_serial = if (work_pending) self.state.main_render_requested_serial else 0,
    };
}

/// Consumes an already completed frame from the bounded presentation mailbox.
/// This is called by AppKit's main-thread display callback so a frame that
/// completed before the callback can participate in the current transaction.
/// A producer racing this drain installs and signals a fresh pending slot.
pub fn drainCompletedFrame(self: *IOSurfaceLayer) DrainResult {
    std.debug.assert(isMainThread());
    return drainPresentationState(self.state, true);
}

/// The host measures how fast the window is moving and asks for a lead that
/// covers it, so a fast drag cannot outrun the picture.
pub fn setResizeLeadPx(self: *IOSurfaceLayer, px: u32) void {
    self.state.host_resize_lead_px.store(px, .monotonic);
}

pub fn hostResizeLeadPx(self: *const IOSurfaceLayer) u32 {
    return self.state.host_resize_lead_px.load(.monotonic);
}

/// Outcome from consuming the bounded completed-frame mailbox on the main
/// thread. A rejected frame was consumed and released but did not change the
/// layer contents because the size/order checks failed.
pub const DrainResult = enum { empty, accepted, rejected, deferred, superseded };

const Acceptance = enum { accept, stale, size };

pub const DisplayCallback = ?*align(8) const fn (?*anyopaque) void;

pub fn setDisplayCallback(
    self: *IOSurfaceLayer,
    display_cb: DisplayCallback,
    display_ctx: ?*anyopaque,
) void {
    self.layer.setInstanceVariable(
        "display_cb",
        objc.Object.fromId(@constCast(display_cb)),
    );
    self.layer.setInstanceVariable(
        "display_ctx",
        objc.Object.fromId(display_ctx),
    );
}

fn mainRenderNativeActiveLocked(state: *const PresentationState) bool {
    return state.live_resizing and !state.detached;
}

fn mainRenderWorkPendingLocked(state: *const PresentationState) bool {
    return !state.detached and
        state.main_render_requested_serial != state.main_render_serviced_serial;
}

fn nativeResizeCoalescingLocked(
    state: *const PresentationState,
    native_callback: bool,
) bool {
    return !native_callback and state.live_resizing and !state.detached;
}

fn drawableAdmissionReadyLocked(state: *const PresentationState) bool {
    return !state.detached and state.drawables_outstanding < 2 and
        (state.active_pixel_format == state.pixel_format or state.drawables_outstanding == 0);
}

fn reserveNativeDisplayLocked(state: *PresentationState) bool {
    if (state.native_display_requested or
        (state.pending == null and !state.native_redraw_needed and
            !mainRenderWorkPendingLocked(state)) or
        !drawableAdmissionReadyLocked(state)) return false;
    state.native_display_requested = true;
    return true;
}

fn setNeedsDisplay(state: *PresentationState) void {
    state.layer.msgSend(void, "setNeedsDisplay", .{});
}

fn requestCoalescedNativeDisplay(state: *PresentationState) void {
    std.debug.assert(isMainThread());
    state.mutex.lockUncancelable(global.io());
    const display_now = nativeResizeCoalescingLocked(state, false) and
        reserveNativeDisplayLocked(state);
    state.mutex.unlock(global.io());
    if (display_now) setNeedsDisplay(state);
}

fn requestNativeRedrawState(state: *PresentationState) void {
    var source: ?cf.CFRunLoopSourceRef = null;
    state.mutex.lockUncancelable(global.io());
    state.native_redraw_needed = true;
    if (drawableAdmissionReadyLocked(state)) {
        if (state.source) |value| {
            _ = cf.CFRetain(value);
            source = value;
        }
    }
    state.mutex.unlock(global.io());
    if (source) |value| {
        signalPresentationSource(value);
        cf.CFRelease(value);
    }
}

fn acquireDrawableState(
    state: *PresentationState,
    width: usize,
    height: usize,
) !Drawable {
    std.debug.assert(isMainThread());

    var update_format = false;
    state.mutex.lockUncancelable(global.io());
    if (!drawableAdmissionReadyLocked(state)) {
        state.mutex.unlock(global.io());
        return error.DrawableBusy;
    }
    if (state.active_pixel_format != state.pixel_format) {
        state.active_pixel_format = state.pixel_format;
        update_format = true;
    }
    state.drawables_outstanding += 1;
    state.mutex.unlock(global.io());

    const link = state.notification_link orelse unreachable;
    const settlement = createDrawableSettlement(link) catch |err| {
        state.mutex.lockUncancelable(global.io());
        state.drawables_outstanding -= 1;
        state.mutex.unlock(global.io());
        return err;
    };
    errdefer settlement.release();
    if (update_format)
        state.layer.setProperty("pixelFormat", state.active_pixel_format);
    const lease = try DrawableLease.acquire(state.layer, .{
        .width = width,
        .height = height,
    });
    return .{ .lease = lease, .settlement = settlement };
}

fn drawableAcceptance(
    state: *PresentationState,
    width: usize,
    height: usize,
    frame_id: u64,
) Acceptance {
    const bounds = state.layer.getProperty(macos.graphics.Rect, "bounds");
    const scale = state.layer.getProperty(f64, "contentsScale");
    const layer_width: usize = @intFromFloat(bounds.size.width * scale);
    const layer_height: usize = @intFromFloat(bounds.size.height * scale);
    if (state.live_resizing) {
        // The drawable is deliberately larger than the layer while the resize
        // lead is active: the layer shows its top-left part and clips the rest.
        if (width < layer_width or height < layer_height) return .size;
    } else if (!dimensionsMatch(
        layer_width,
        layer_height,
        width,
        height,
        state.max_texture_size,
    )) return .size;
    if (frame_id <= state.latest_accepted_id) return .stale;
    return .accept;
}

fn noteMainRenderPublished(state: *PresentationState, serial: u64) void {
    if (serial == 0) return;
    var source: ?cf.CFRunLoopSourceRef = null;
    state.mutex.lockUncancelable(global.io());
    if (!state.detached) {
        if (serial > state.main_render_serviced_serial)
            state.main_render_serviced_serial = serial;
        if (state.main_render_requested_serial != state.main_render_serviced_serial) {
            // CPU preparation advanced during this callback. Preserve that
            // newer request and schedule one coalesced native transaction.
            state.native_redraw_needed = true;
            if (drawableAdmissionReadyLocked(state)) if (state.source) |value| {
                _ = cf.CFRetain(value);
                source = value;
            };
        }
    }
    state.mutex.unlock(global.io());
    if (source) |value| {
        signalPresentationSource(value);
        cf.CFRelease(value);
    }
}

fn presentDrawable(
    state: *PresentationState,
    drawable: *Drawable,
    buffer: objc.Object,
    frame_id: u64,
) bool {
    std.debug.assert(isMainThread());
    DrawableLease.waitUntilScheduled(buffer) catch return false;

    state.mutex.lockUncancelable(global.io());
    const detached = state.detached;
    state.mutex.unlock(global.io());
    if (detached) return false;
    if (drawableAcceptance(
        state,
        drawable.lease.extent.width,
        drawable.lease.extent.height,
        frame_id,
    ) != .accept) return false;

    state.layer.setProperty("presentsWithTransaction", true);
    drawable.lease.presentScheduled(buffer) catch return false;
    state.latest_accepted_id = frame_id;
    state.presented_pixel_width = @intCast(drawable.lease.extent.width);
    state.presented_pixel_height = @intCast(drawable.lease.extent.height);
    noteMainRenderPublished(state, drawable.main_render_serial);
    return true;
}

const CopyCompletion = struct {
    gate: DrawableLease.CompletionGate = .{},
    health: std.atomic.Value(u8) = .init(0),
    published: std.atomic.Value(u8) = .init(0),
    state: *PresentationState,
    surface: *IOSurface,
    texture: objc.Object,
    /// Submission admission credit, settled once both GPU completion and the
    /// main-thread present decision have arrived.
    settlement: objc.Object,

    fn arrive(self: *CopyCompletion, party: DrawableLease.CompletionGate.Party) void {
        if (!self.gate.arrive(party)) return;
        const healthy = self.health.load(.acquire) != 0;
        const published = self.published.load(.acquire) != 0;
        if (!healthy and published) requestNativeRedrawState(self.state);
        self.settlement.release();
        self.texture.release();
        self.surface.release();
        self.state.release();
        std.heap.page_allocator.destroy(self);
    }
};

const CopyCompletionBlock = objc.Block(struct {
    completion: *CopyCompletion,
}, .{objc.c.id}, void);

fn drawableCopyCompleted(
    callback: *const CopyCompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const completion = callback.completion;
    const buffer = objc.Object.fromId(buffer_id);
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    completion.health.store(@intFromBool(status != .@"error"), .release);
    completion.arrive(.gpu);
}

/// Copy a completed target into a drawable and present it, either inside the
/// current transaction or asynchronously.
fn presentPending(
    state: *PresentationState,
    pending: Pending,
    transactional: bool,
) DrainResult {
    std.debug.assert(isMainThread());
    if (drawableAcceptance(
        state,
        pending.surface.getWidth(),
        pending.surface.getHeight(),
        pending.frame_id,
    ) != .accept) return .rejected;

    var drawable = acquireDrawableState(
        state,
        pending.surface.getWidth(),
        pending.surface.getHeight(),
    ) catch |err| return if (err == error.DrawableBusy) .deferred else .rejected;
    defer drawable.release();
    if (drawableAcceptance(
        state,
        drawable.lease.extent.width,
        drawable.lease.extent.height,
        pending.frame_id,
    ) != .accept) {
        settleDrawableOwner(drawable.settlement);
        return .rejected;
    }

    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    const buffer = state.queue.msgSend(objc.Object, objc.sel("commandBuffer"), .{});
    drawable.encodeCopy(buffer, pending.texture) catch {
        settleDrawableOwner(drawable.settlement);
        return .rejected;
    };

    if (!transactional) {
        state.layer.setProperty("presentsWithTransaction", false);
        drawable.lease.scheduleAsync(buffer) catch {
            settleDrawableOwner(drawable.settlement);
            return .rejected;
        };
    }

    const completion = std.heap.page_allocator.create(CopyCompletion) catch {
        settleDrawableOwner(drawable.settlement);
        return .rejected;
    };
    state.retain();
    pending.surface.retain();
    _ = pending.texture.retain();
    completion.* = .{
        .state = state,
        .surface = pending.surface,
        .texture = pending.texture,
        .settlement = drawable.settlement.retain(),
    };
    var callback = CopyCompletionBlock.init(.{ .completion = completion }, &drawableCopyCompleted);
    buffer.msgSend(void, objc.sel("addCompletedHandler:"), .{&callback});
    buffer.msgSend(void, objc.sel("commit"), .{});

    const published = if (transactional)
        presentDrawable(state, &drawable, buffer, pending.frame_id)
    else published: {
        state.latest_accepted_id = pending.frame_id;
        state.presented_pixel_width = @intCast(drawable.lease.extent.width);
        state.presented_pixel_height = @intCast(drawable.lease.extent.height);
        break :published true;
    };
    completion.published.store(@intFromBool(published), .release);
    completion.arrive(.main);
    return if (published) .accepted else .rejected;
}

/// Present `pending`, or put it back in the mailbox when no drawable is free.
/// Takes ownership of `pending`.
fn presentOrRestore(state: *PresentationState, pending: Pending, transactional: bool) void {
    if (presentPending(state, pending, transactional) != .deferred) return pending.release();
    state.mutex.lockUncancelable(global.io());
    const restored = restorePendingLocked(state, pending);
    if (restored) signalRestoredIfReadyLocked(state);
    state.mutex.unlock(global.io());
    if (!restored) pending.release();
}

/// Restore a frame whose drawable admission was full. Caller owns the pending
/// retain and holds state.mutex. A newer pending packet wins deterministically.
fn restorePendingLocked(state: *PresentationState, pending: Pending) bool {
    if (state.pending) |existing| {
        if (existing.frame_id >= pending.frame_id) return false;
        state.pending = pending;
        existing.release();
        return true;
    }
    state.pending = pending;
    return true;
}

fn signalRestoredIfReadyLocked(state: *PresentationState) void {
    if (!drawableAdmissionReadyLocked(state)) return;
    const source = state.source orelse return;
    cf.CFRunLoopSourceSignal(source);
    cf.CFRunLoopWakeUp(cf.CFRunLoopGetMain());
}

/// Install the newest completed frame in the one-slot mailbox. Completion
/// handlers may arrive out of order, so an older frame never replaces a newer
/// one. The caller owns `incoming` unless this returns true.
fn enqueuePending(state: *PresentationState, incoming: Pending) bool {
    state.mutex.lockUncancelable(global.io());
    const old = state.pending;
    if (old) |p| if (p.frame_id >= incoming.frame_id) {
        state.mutex.unlock(global.io());
        return false;
    };
    state.pending = incoming;
    state.mutex.unlock(global.io());
    if (old) |p| p.release();
    return true;
}

fn presentationStateRetain(info: ?*const anyopaque) callconv(.c) ?*const anyopaque {
    const state: *PresentationState = @ptrCast(@alignCast(@constCast(info.?)));
    state.retain();
    return info;
}

fn presentationStateRelease(info: ?*const anyopaque) callconv(.c) void {
    const state: *PresentationState = @ptrCast(@alignCast(@constCast(info.?)));
    state.release();
}

fn presentationSourcePerform(info: ?*anyopaque) callconv(.c) void {
    const state: *PresentationState = @ptrCast(@alignCast(info.?));
    _ = drainPresentationState(state, false);
}

/// Takes the latest completed frame under the mailbox mutex, then performs
/// Objective-C layer work after unlocking. The mailbox retain is released
/// exactly once regardless of acceptance. A source callback after a display
/// callback drain safely observes an empty mailbox.
fn drainPresentationState(
    state: *PresentationState,
    native_callback: bool,
) DrainResult {
    std.debug.assert(isMainThread());
    state.mutex.lockUncancelable(global.io());
    if (native_callback and (mainRenderNativeActiveLocked(state) or
        mainRenderWorkPendingLocked(state)))
    {
        // A completed renderer-thread target predates the CPU request claimed
        // by this native callback. Drop it without spending a second drawable;
        // the callback renders the latest prepared state directly below.
        const pending = state.pending;
        state.pending = null;
        // Consume the retry/display latch claimed by this callback. The CPU
        // serial remains authoritative for unserviced prepared work, while a
        // separate retry published during the draw can set the latch again.
        state.native_redraw_needed = false;
        state.mutex.unlock(global.io());
        const p = pending orelse return .empty;
        p.release();
        return .superseded;
    }
    if (nativeResizeCoalescingLocked(state, native_callback) or
        (!native_callback and mainRenderWorkPendingLocked(state)))
    {
        const display_now = reserveNativeDisplayLocked(state);
        state.mutex.unlock(global.io());
        if (display_now) setNeedsDisplay(state);
        return .empty;
    }
    const pending = state.pending;
    state.pending = null;
    const native_redraw = state.native_redraw_needed;
    state.native_redraw_needed = false;
    const detached = state.detached;
    state.mutex.unlock(global.io());

    const p = pending orelse {
        if (native_redraw) serviceNativeRedraw(state, native_callback);
        return .empty;
    };
    if (detached) {
        p.release();
        return .rejected;
    }

    const status = presentPending(state, p, native_callback);
    if (status == .deferred) {
        state.mutex.lockUncancelable(global.io());
        const restored = restorePendingLocked(state, p);
        if (restored) signalRestoredIfReadyLocked(state);
        if (native_redraw) state.native_redraw_needed = true;
        state.mutex.unlock(global.io());
        if (!restored) p.release();
    } else {
        p.release();
        // A native display callback already proceeds to its fallback draw.
        // Only a source callback schedules one display after credit is ready.
        if (native_redraw and status != .accepted)
            serviceNativeRedraw(state, native_callback);
    }
    return status;
}

fn serviceNativeRedraw(state: *PresentationState, native_callback: bool) void {
    std.debug.assert(isMainThread());
    if (native_callback) return;
    state.mutex.lockUncancelable(global.io());
    const ready = drawableAdmissionReadyLocked(state);
    if (!ready and !state.detached) state.native_redraw_needed = true;
    state.mutex.unlock(global.io());
    if (ready) setNeedsDisplay(state);
}

/// Signal the presentation source, first registering it in the main run
/// loop's current mode: AppKit runs private tracking modes during a resize.
fn signalPresentationSource(source: cf.CFRunLoopSourceRef) void {
    const run_loop = cf.CFRunLoopGetMain();
    const mode = cf.CFRunLoopCopyCurrentMode(run_loop);
    defer if (mode) |value| cf.CFRelease(value);
    if (mode) |value| cf.CFRunLoopAddSource(run_loop, source, value);
    cf.CFRunLoopSourceSignal(source);
    cf.CFRunLoopWakeUp(run_loop);
}

fn dimensionsMatch(
    layer_width: usize,
    layer_height: usize,
    surface_width: usize,
    surface_height: usize,
    max_texture_size: u32,
) bool {
    const max_size: usize = max_texture_size;
    return @min(layer_width, max_size) == surface_width and
        @min(layer_height, max_size) == surface_height;
}

fn isMainThread() bool {
    const NSThread = objc.getClass("NSThread").?;
    return NSThread.msgSend(bool, "isMainThread", .{});
}

fn objcBoolResult(value: objc.c.BOOL) bool {
    return switch (@TypeOf(value)) {
        bool => value,
        i8 => value == 1,
        else => @compileError("unexpected Objective-C BOOL type"),
    };
}

fn getSubclass() error{ObjCFailed}!objc.Class {
    if (Subclass) |c| return c;

    const CAMetalLayer =
        objc.getClass("CAMetalLayer") orelse return error.ObjCFailed;

    var subclass =
        objc.allocateClassPair(CAMetalLayer, "GhosttyMetalLayer") orelse return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);

    if (!subclass.addIvar("display_cb")) return error.ObjCFailed;
    if (!subclass.addIvar("display_ctx")) return error.ObjCFailed;

    subclass.replaceMethod("display", struct {
        fn display(target: objc.c.id, sel: objc.c.SEL) callconv(.c) void {
            _ = sel;
            const self = objc.Object.fromId(target);
            const display_cb: DisplayCallback = @ptrFromInt(@intFromPtr(
                self.getInstanceVariable("display_cb").value,
            ));
            if (display_cb) |cb| cb(
                @ptrCast(self.getInstanceVariable("display_ctx").value),
            );
        }
    }.display);

    // Disable all animations for this layer by returning null for all actions.
    subclass.replaceMethod("actionForKey:", struct {
        fn actionForKey(
            target: objc.c.id,
            sel: objc.c.SEL,
            key: objc.c.id,
        ) callconv(.c) objc.c.id {
            _ = target;
            _ = sel;
            _ = key;
            return objc.getClass("NSNull").?.msgSend(objc.c.id, "null", .{});
        }
    }.actionForKey);

    objc.registerClassPair(subclass);

    Subclass = subclass;

    return subclass;
}

fn getNotificationLinkClass() error{ObjCFailed}!objc.Class {
    if (NotificationLinkClass) |value| return value;
    const NSObject = objc.getClass("NSObject") orelse return error.ObjCFailed;
    const subclass = objc.allocateClassPair(NSObject, "GhosttyDrawableNotificationLink") orelse
        return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);
    if (!objcBoolResult(objc.c.class_addIvar(
        subclass.value,
        "notification_link",
        @sizeOf(NotificationLink),
        @intCast(std.math.log2_int(usize, @alignOf(NotificationLink))),
        "^v",
    ))) return error.ObjCFailed;
    objc.registerClassPair(subclass);
    const ivar = objc.c.class_getInstanceVariable(subclass.value, "notification_link") orelse
        return error.ObjCFailed;
    NotificationLinkOffset = @intCast(objc.c.ivar_getOffset(ivar));
    NotificationLinkClass = subclass;
    return subclass;
}

fn notificationLink(owner: objc.Object) *NotificationLink {
    return @ptrFromInt(@intFromPtr(owner.value) + (NotificationLinkOffset orelse unreachable));
}

fn createNotificationLink(state: *PresentationState) !objc.Object {
    const class = try getNotificationLinkClass();
    const owner = class.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    notificationLink(owner).* = .{ .state = state };
    return owner;
}

fn getDrawableSettlementClass() error{ObjCFailed}!objc.Class {
    if (DrawableSettlementClass) |value| return value;
    const NSObject = objc.getClass("NSObject") orelse return error.ObjCFailed;
    const subclass = objc.allocateClassPair(NSObject, "GhosttyDrawableSettlement") orelse
        return error.ObjCFailed;
    errdefer objc.disposeClassPair(subclass);
    if (!objcBoolResult(objc.c.class_addIvar(
        subclass.value,
        "drawable_settlement",
        @sizeOf(DrawableSettlement),
        @intCast(std.math.log2_int(usize, @alignOf(DrawableSettlement))),
        "^v",
    ))) return error.ObjCFailed;
    subclass.replaceMethod("dealloc", struct {
        fn dealloc(target: objc.c.id, _: objc.c.SEL) callconv(.c) void {
            const object = objc.Object.fromId(target);
            settleDrawableOwner(object);
            const value = drawableSettlement(object);
            objc.Object.fromId(value.link).release();
            // NSObject has no owned ivars here; direct runtime disposal avoids
            // the SDK 27 objc_super field-name mismatch in zig-objc.
            _ = objc.c.object_dispose(object.value);
        }
    }.dealloc);
    objc.registerClassPair(subclass);
    const ivar = objc.c.class_getInstanceVariable(subclass.value, "drawable_settlement") orelse
        return error.ObjCFailed;
    DrawableSettlementOffset = @intCast(objc.c.ivar_getOffset(ivar));
    DrawableSettlementClass = subclass;
    return subclass;
}

fn drawableSettlement(owner: objc.Object) *DrawableSettlement {
    return @ptrFromInt(@intFromPtr(owner.value) + (DrawableSettlementOffset orelse unreachable));
}

fn createDrawableSettlement(link: objc.Object) !objc.Object {
    const class = try getDrawableSettlementClass();
    const owner = class.msgSend(objc.Object, "alloc", .{}).msgSend(objc.Object, "init", .{});
    drawableSettlement(owner).* = .{ .link = link.retain().value };
    return owner;
}

/// Return a drawable's admission credit exactly once, from either an explicit
/// settle or the settlement object's dealloc.
fn settleDrawableOwner(owner: objc.Object) void {
    const value = drawableSettlement(owner);
    if (value.settled.swap(1, .acq_rel) != 0) return;
    const link = notificationLink(objc.Object.fromId(value.link));
    link.mutex.lockUncancelable(global.io());
    const state = link.state;
    if (state) |current| current.retain();
    link.mutex.unlock(global.io());
    const current = state orelse return;
    defer current.release();

    var source: ?cf.CFRunLoopSourceRef = null;
    current.mutex.lockUncancelable(global.io());
    if (current.drawables_outstanding > 0) current.drawables_outstanding -= 1;
    if (!current.detached and
        (current.pending != null or current.native_redraw_needed or
            mainRenderWorkPendingLocked(current)))
    {
        if (current.source) |value_source| {
            _ = cf.CFRetain(value_source);
            source = value_source;
        }
    }
    current.mutex.unlock(global.io());
    if (source) |value_source| {
        signalPresentationSource(value_source);
        cf.CFRelease(value_source);
    }
}
