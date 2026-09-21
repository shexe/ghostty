//! CAMetalLayer drawable helper. The renderer keeps its IOSurface targets and
//! copies final pixels 1:1 into an exact-size drawable. Submission admission
//! retires after GPU completion plus the main present/discard decision.
const Self = @This();
const std = @import("std");
const objc = @import("objc");

pub const Extent = struct {
    width: usize,
    height: usize,

    pub fn eql(a: Extent, b: Extent) bool {
        return a.width == b.width and a.height == b.height;
    }
};

const Size = extern struct { width: f64, height: f64 };
const Origin = extern struct { x: c_ulong, y: c_ulong, z: c_ulong };
const CopySize = extern struct { width: c_ulong, height: c_ulong, depth: c_ulong };

drawable: objc.Object,
/// Borrowed from drawable; valid until this lease is released.
texture: objc.Object,
extent: Extent,
pixel_format: c_ulong,
presented: bool = false,

/// Configure a CAMetalLayer created/owned by the presentation backend.
/// Caller additionally sets colorspace, opacity, bounds, and contentsScale to
/// match its existing output. Do not set CALayer.contents in this backend.
pub fn configure(layer: objc.Object, device: objc.Object, pixel_format: c_ulong) void {
    assertMainThread();
    layer.setProperty("device", device.value);
    layer.setProperty("pixelFormat", pixel_format);
    layer.setProperty("framebufferOnly", false);
    layer.setProperty("maximumDrawableCount", @as(c_ulong, 3));
    // Apple's default can still block for one second. Never disable it.
    layer.setProperty("allowsNextDrawableTimeout", true);
    layer.setProperty("needsDisplayOnBoundsChange", true);
}

/// Acquire outside renderer/model/mailbox locks. This API MAY BLOCK. Keep no
/// lease while waiting for terminal/PTY progress.
pub fn acquire(layer: objc.Object, expected: Extent) !Self {
    assertMainThread();
    const pool = objc.AutoreleasePool.init();
    defer pool.deinit();
    if (expected.width == 0 or expected.height == 0) return error.EmptyExtent;
    const desired: Size = .{
        .width = @floatFromInt(expected.width),
        .height = @floatFromInt(expected.height),
    };
    const current = layer.getProperty(Size, "drawableSize");
    if (current.width != desired.width or current.height != desired.height)
        layer.setProperty("drawableSize", desired);

    const raw = layer.msgSend(?*anyopaque, objc.sel("nextDrawable"), .{}) orelse
        return error.NoDrawable;
    const drawable = objc.Object.fromId(raw).retain();
    errdefer drawable.release();
    const texture = drawable.getProperty(objc.Object, "texture");
    const actual = textureExtent(texture);
    if (!actual.eql(expected)) return error.DrawableExtentMismatch;
    if (texture.msgSend(bool, objc.sel("isFramebufferOnly"), .{})) return error.FramebufferOnly;
    return .{
        .drawable = drawable,
        .texture = texture,
        .extent = actual,
        .pixel_format = texture.getProperty(c_ulong, "pixelFormat"),
    };
}

pub fn release(self: *Self) void {
    self.drawable.release();
    self.* = undefined;
}

/// Encode after all render/custom-shader/edge-extension encoders end and before
/// command-buffer commit. No resizing, filtering, or colorspace conversion.
pub fn encodeCopy(self: *const Self, buffer: objc.Object, source: objc.Object) !void {
    try encodeTextureCopy(buffer, source, self.texture, self.extent);
}

fn encodeTextureCopy(
    buffer: objc.Object,
    source: objc.Object,
    destination: objc.Object,
    expected: Extent,
) !void {
    if (!textureExtent(source).eql(expected) or
        !textureExtent(destination).eql(expected)) return error.CopyExtentMismatch;
    if (source.getProperty(c_ulong, "pixelFormat") !=
        destination.getProperty(c_ulong, "pixelFormat")) return error.CopyFormatMismatch;
    if (destination.msgSend(bool, objc.sel("isFramebufferOnly"), .{})) return error.FramebufferOnly;
    const raw = buffer.msgSend(?*anyopaque, objc.sel("blitCommandEncoder"), .{}) orelse
        return error.NoBlitEncoder;
    const encoder = objc.Object.fromId(raw);
    defer encoder.msgSend(void, objc.sel("endEncoding"), .{});
    const origin: Origin = .{ .x = 0, .y = 0, .z = 0 };
    const size: CopySize = .{
        .width = @intCast(expected.width),
        .height = @intCast(expected.height),
        .depth = 1,
    };
    encoder.msgSend(void, objc.sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"), .{
        source.value,      @as(c_ulong, 0), @as(c_ulong, 0), origin, size,
        destination.value, @as(c_ulong, 0), @as(c_ulong, 0), origin,
    });
}

/// Native transaction path only. The buffer MUST already be committed, contain
/// the drawable write, and have GPU completion/resource retirement registered.
/// Never hold draw_mutex here. Kept separate from presentScheduled so the
/// caller can recheck frame-id/geometry/detach policy after the blocking call.
pub fn waitUntilScheduled(buffer: objc.Object) !void {
    assertMainThread();
    const before = buffer.getProperty(c_ulong, "status");
    if (before < 2) return error.BufferNotCommitted;
    buffer.msgSend(void, objc.sel("waitUntilScheduled"), .{});
    const after = buffer.getProperty(c_ulong, "status");
    if (after != 3 and after != 4) return error.BufferFailed;
}

/// The layer must already use presentsWithTransaction=true. This call does not
/// mean pixels are displayed or GPU resources can retire.
pub fn presentScheduled(self: *Self, buffer: objc.Object) !void {
    assertMainThread();
    if (self.presented) return error.AlreadyPresented;
    const status = buffer.getProperty(c_ulong, "status");
    if (status != 3 and status != 4) return error.BufferNotScheduled;
    self.drawable.msgSend(void, objc.sel("present"), .{});
    self.presented = true;
}

/// Ordinary asynchronous drawable path. Register before commit, with presentsWithTransaction=false. The buffer owns
/// scheduling; this method does NOT retire any renderer resource.
pub fn scheduleAsync(self: *Self, buffer: objc.Object) !void {
    if (self.presented) return error.AlreadyPresented;
    if (buffer.getProperty(c_ulong, "status") >= 2) return error.BufferAlreadyCommitted;
    buffer.msgSend(void, objc.sel("presentDrawable:"), .{self.drawable.value});
    self.presented = true;
}

fn textureExtent(texture: objc.Object) Extent {
    return .{
        .width = @intCast(texture.getProperty(c_ulong, "width")),
        .height = @intCast(texture.getProperty(c_ulong, "height")),
    };
}

fn assertMainThread() void {
    std.debug.assert(objc.getClass("NSThread").?.msgSend(bool, "isMainThread", .{}));
}

/// Embed in a stable heap-owned completion record, never in a copied ObjC
/// block by value. Both sides own that record until arriving. The one true
/// result owns final frame-token retirement/free; a losing side may not access
/// the record after arrive() returns. GPU status is written before .gpu arrives.
pub const CompletionGate = struct {
    bits: std.atomic.Value(u8) = .init(0),
    pub const Party = enum(u8) { gpu = 1, main = 2 };

    pub fn arrive(self: *CompletionGate, party: Party) bool {
        const bit = @intFromEnum(party);
        const old = self.bits.fetchOr(bit, .acq_rel);
        return old & bit == 0 and old | bit == 3;
    }
};
