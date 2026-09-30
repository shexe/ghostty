//! Graphics API wrapper for Metal.
pub const Metal = @This();

const std = @import("std");
const assert = @import("../quirks.zig").inlineAssert;
const Allocator = std.mem.Allocator;
const builtin = @import("builtin");
const objc = @import("objc");
const macos = @import("macos");
const graphics = macos.graphics;
const apprt = @import("../apprt.zig");
const font = @import("../font/main.zig");
const configpkg = @import("../config.zig");
const rendererpkg = @import("../renderer.zig");
const Renderer = rendererpkg.GenericRenderer(Metal);
const shadertoy = @import("shadertoy.zig");

const mtl = @import("metal/api.zig");
const IOSurfaceLayer = @import("metal/IOSurfaceLayer.zig");
pub const DrawableLease = IOSurfaceLayer.Drawable;

pub const GraphicsAPI = Metal;
pub const Target = @import("metal/Target.zig");
pub const Frame = @import("metal/Frame.zig");
pub const RenderPass = @import("metal/RenderPass.zig");
pub const Pipeline = @import("metal/Pipeline.zig");
const bufferpkg = @import("metal/buffer.zig");
pub const Buffer = bufferpkg.Buffer;
pub const Sampler = @import("metal/Sampler.zig");
pub const Texture = @import("metal/Texture.zig");
pub const shaders = @import("metal/shaders.zig");

pub const custom_shader_target: shadertoy.Target = .msl;
// The fragCoord for Metal shaders is +Y = down.
pub const custom_shader_y_is_down = true;

/// Triple buffering.
pub const swap_chain_count = 3;

const log = std.log.scoped(.metal);

layer: IOSurfaceLayer,

/// MTLDevice
device: objc.Object,
/// MTLCommandQueue
queue: objc.Object,

/// Alpha blending mode
blending: configpkg.Config.AlphaBlending,

/// The default storage mode to use for resources created with our device.
///
/// This is based on whether the device is a discrete GPU or not, since
/// discrete GPUs do not have unified memory and therefore do not support
/// the "shared" storage mode, instead we have to use the "managed" mode.
default_storage_mode: mtl.MTLResourceOptions.StorageMode,

/// The maximum 2D texture width and height supported by the device.
max_texture_size: u32,

/// Pixel format shared by the render targets and the layer's drawables.
pixel_format: mtl.MTLPixelFormat,

/// Monotonically increasing identifier assigned while the generic renderer's
/// draw mutex is held. The layer uses it to reject a late completed frame.
next_frame_id: u64 = 0,

/// We start an AutoreleasePool before `drawFrame` and end it afterwards.
autorelease_pool: ?*objc.AutoreleasePool = null,

pub fn init(alloc: Allocator, opts: rendererpkg.Options) !Metal {
    comptime switch (builtin.os.tag) {
        .macos, .ios => {},
        else => @compileError("unsupported platform for Metal"),
    };

    _ = alloc;

    // Choose our MTLDevice and create a MTLCommandQueue for that device.
    const device = try chooseDevice();
    errdefer device.release();
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    errdefer queue.release();

    // Grab metadata about the device.
    const default_storage_mode: mtl.MTLResourceOptions.StorageMode = switch (comptime builtin.os.tag) {
        // manage mode is not supported by iOS
        .ios => .shared,
        else => if (device.getProperty(bool, "hasUnifiedMemory")) .shared else .managed,
    };
    const max_texture_size = queryMaxTextureSize(device);
    log.debug(
        "device properties default_storage_mode={} max_texture_size={}",
        .{ default_storage_mode, max_texture_size },
    );

    const ViewInfo = struct {
        view: objc.Object,
        scaleFactor: f64,
    };

    // Get the metadata about our underlying view that we'll be rendering to.
    const info: ViewInfo = switch (apprt.runtime) {
        apprt.embedded => .{
            .scaleFactor = @floatCast(opts.rt_surface.content_scale.x),
            .view = switch (opts.rt_surface.platform) {
                .macos => |v| v.nsview,
                .ios => |v| v.uiview,
            },
        },

        else => @compileError("unsupported apprt for metal"),
    };

    const pixel_format: mtl.MTLPixelFormat = if (opts.config.blending.isLinear())
        .bgra8unorm_srgb
    else
        .bgra8unorm;
    // Create an IOSurfaceLayer which we can assign to the view to make
    // it in to a "layer-hosting view", so that we can manually control
    // the layer contents.
    var layer = try IOSurfaceLayer.init(
        max_texture_size,
        device,
        queue,
        @intFromEnum(pixel_format),
    );
    errdefer layer.release();

    // Add our layer to the view.
    //
    // On macOS we do this by making the view "layer-hosting"
    // by assigning it to the view's `layer` property BEFORE
    // setting `wantsLayer` to `true`.
    //
    // On iOS, views are always layer-backed, and `layer`
    // is readonly, so instead we add it as a sublayer.
    switch (comptime builtin.os.tag) {
        .macos => {
            info.view.setProperty("layer", layer.layer.value);
            info.view.setProperty("wantsLayer", true);
        },

        .ios => {
            const view_layer = objc.Object.fromId(info.view.getProperty(?*anyopaque, "layer"));
            view_layer.msgSend(void, objc.sel("addSublayer:"), .{layer.layer.value});
        },

        else => @compileError("unsupported target for Metal"),
    }

    // Ensure that if our layer is oversized it
    // does not overflow the bounds of the view.
    info.view.setProperty("clipsToBounds", true);

    // Ensure that our layer has a content scale set to
    // match the scale factor of the window. This avoids
    // magnification issues leading to blurry rendering.
    layer.layer.setProperty("contentsScale", info.scaleFactor);

    // This makes it so that our display callback will actually be called.
    layer.layer.setProperty("needsDisplayOnBoundsChange", true);

    return .{
        .layer = layer,
        .device = device,
        .queue = queue,
        .blending = opts.config.blending,
        .default_storage_mode = default_storage_mode,
        .max_texture_size = max_texture_size,
        .pixel_format = pixel_format,
    };
}

pub fn deinit(self: *Metal) void {
    self.layer.setDisplayCallback(null, null);
    self.queue.release();
    self.device.release();
    self.layer.release();
}

pub fn loopEnter(self: *Metal) void {
    const renderer: *align(1) Renderer = @fieldParentPtr("api", self);
    self.layer.setDisplayCallback(
        @ptrCast(&displayCallback),
        @ptrCast(renderer),
    );
}

fn displayCallback(renderer: *Renderer) align(8) void {
    // Consume the coalesced native request before any early return so a later
    // completion can request the next transaction.
    const native = renderer.api.layer.beginNativeDisplay();
    switch (renderer.api.layer.drainCompletedFrame()) {
        .accepted => return,
        .deferred => {
            renderer.api.layer.requestNativeRedraw();
            return;
        },
        .empty, .rejected, .superseded => {},
    }

    const size = renderer.api.surfaceSize() catch return;
    var drawable: ?DrawableLease = renderer.api.acquireDrawable(
        size.width,
        size.height,
        native.main_render_serial,
    ) catch |err| {
        if (err == error.DrawableBusy) renderer.api.layer.requestNativeRedraw();
        // If this callback does the drawing for a live resize, the render
        // request waits for a later callback that gets a drawable.
        if (native.main_render_active) return;
        // If not, draw the newest target without a drawable. The frame goes
        // into the one-slot mailbox, and it is presented when a drawable slot
        // is free again.
        var none: ?DrawableLease = null;
        renderer.drawFrameDisplayCallback(false, &none) catch {};
        return;
    };
    defer if (drawable) |*value| renderer.api.discardDrawable(value);
    renderer.drawFrameDisplayCallback(true, &drawable) catch |err| {
        log.warn("Error drawing frame in display callback, err={}", .{err});
    };
}

/// Actions taken before doing anything in `drawFrame`.
///
/// Right now we use this to start an AutoreleasePool.
pub fn drawFrameStart(self: *Metal) void {
    assert(self.autorelease_pool == null);
    self.autorelease_pool = .init();
}

/// Actions taken after `drawFrame` is done.
///
/// Right now we use this to end our AutoreleasePool.
pub fn drawFrameEnd(self: *Metal) void {
    assert(self.autorelease_pool != null);
    self.autorelease_pool.?.deinit();
    self.autorelease_pool = null;
}

pub fn initShaders(
    self: *const Metal,
    alloc: Allocator,
    custom_shaders: []const [:0]const u8,
) !shaders.Shaders {
    return try shaders.Shaders.init(
        alloc,
        self.device,
        custom_shaders,
        // Using an `*_srgb` pixel format makes Metal gamma encode
        // the pixels written to it *after* blending, which means
        // we get linear alpha blending rather than gamma-incorrect
        // blending.
        if (self.blending.isLinear())
            mtl.MTLPixelFormat.bgra8unorm_srgb
        else
            mtl.MTLPixelFormat.bgra8unorm,
    );
}

/// Get the current size of the runtime surface.
pub fn surfaceSize(self: *const Metal) !struct { width: u32, height: u32 } {
    const geometry = try self.surfaceGeometry();

    // We need to clamp our runtime surface size to the maximum
    // possible texture size since we can't create a screen buffer (texture)
    // larger than that.
    return .{
        .width = @min(geometry.size.width, self.max_texture_size),
        .height = @min(geometry.size.height, self.max_texture_size),
    };
}

pub const SurfaceGeometry = struct {
    /// Raw physical backing bounds before GPU texture-size clamping.
    size: rendererpkg.ScreenSize,
    content_scale: apprt.ContentScale,
};

/// Get raw backing geometry and the scale used to derive it.
pub fn surfaceGeometry(self: *const Metal) !SurfaceGeometry {
    const bounds = self.layer.layer.getProperty(graphics.Rect, "bounds");
    const scale = self.layer.layer.getProperty(f64, "contentsScale");

    // Extra pixels beyond the layer bounds, so the drawable, the render target
    // and the size the terminal is asked for all agree on a picture larger than
    // the window. The layer keeps its bounds, so its top-left gravity shows the
    // matching part of that picture and clips the rest.
    const lead = self.geometryLeadPx(scale);
    const base_width: u32 = @intFromFloat(bounds.size.width * scale);
    const base_height: u32 = @intFromFloat(bounds.size.height * scale);
    return .{
        .size = .{
            .width = base_width + lead,
            .height = base_height + lead,
        },
        .content_scale = .{
            .x = @floatCast(scale),
            .y = @floatCast(scale),
        },
    };
}

/// Resize lead, in points: the extra size beyond the layer that the drawable,
/// the render target and the terminal size get during a live resize. The
/// terminal then draws the size that the window is about to have, so the edge
/// that the window grows into is already painted.
const resize_lead_points = 80;

/// Zero outside a live resize, so the terminal size is exact when a drag ends.
/// Only the host can measure how fast the window moves, so the host can ask
/// for a larger lead.
fn geometryLeadPx(self: *const Metal, scale: f64) u32 {
    if (!self.layer.liveResizing()) return 0;
    const host = self.layer.hostResizeLeadPx();
    if (host > 0) return host;
    const px = resize_lead_points * scale;
    return if (px <= 0) 0 else @intFromFloat(px);
}

/// Initialize a new render target which can be presented by this API.
pub fn initTarget(self: *const Metal, width: usize, height: usize) !Target {
    return Target.init(.{
        .device = self.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = self.pixel_format,
        .storage_mode = self.default_storage_mode,
        .width = width,
        .height = height,
    });
}

/// Submit the provided target's contents to the layer. A `motion` frame
/// (it moves the viewport or animates) is presented without a pace wait.
pub inline fn present(
    self: *Metal,
    target: Target,
    frame_id: u64,
    sync: bool,
    motion: bool,
) !void {
    if (sync) {
        self.layer.setTargetSync(target.surface, target.texture, frame_id);
    } else {
        self.layer.setTarget(target.surface, target.texture, frame_id, motion);
    }
}

pub fn acquireDrawable(
    self: *Metal,
    width: usize,
    height: usize,
    main_render_serial: u64,
) !DrawableLease {
    return self.layer.acquireDrawable(width, height, main_render_serial);
}

pub fn discardDrawable(self: *Metal, drawable: *DrawableLease) void {
    self.layer.discardDrawable(drawable);
}

pub fn presentNativeDrawable(
    self: *Metal,
    drawable: *DrawableLease,
    buffer: objc.Object,
    frame_id: u64,
) bool {
    return self.layer.presentNativeDrawable(drawable, buffer, frame_id);
}

pub fn requestNativeRedraw(self: *Metal) void {
    self.layer.requestNativeRedraw();
}

pub fn handoffRendererDrawToNative(self: *Metal) bool {
    return self.layer.handoffRendererDrawToNative();
}

pub fn setBlending(self: *Metal, value: configpkg.Config.AlphaBlending) void {
    self.blending = value;
    self.pixel_format = if (value.isLinear()) .bgra8unorm_srgb else .bgra8unorm;
    self.layer.setPixelFormat(@intFromEnum(self.pixel_format));
}

/// Returns the options to use when constructing buffers.
pub inline fn bufferOptions(self: Metal) bufferpkg.Options {
    return .{
        .device = self.device,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.default_storage_mode,
        },
    };
}

pub const instanceBufferOptions = bufferOptions;
pub const uniformBufferOptions = bufferOptions;
pub const fgBufferOptions = bufferOptions;
pub const bgBufferOptions = bufferOptions;
pub const imageBufferOptions = bufferOptions;
pub const bgImageBufferOptions = bufferOptions;

/// Returns the options to use when constructing textures.
pub inline fn textureOptions(self: Metal) Texture.Options {
    return .{
        .device = self.device,
        // Using an `*_srgb` pixel format makes Metal gamma encode the pixels
        // written to it *after* blending, which means we get linear alpha
        // blending rather than gamma-incorrect blending.
        .pixel_format = if (self.blending.isLinear())
            .bgra8unorm_srgb
        else
            .bgra8unorm,
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.default_storage_mode,
        },
        .usage = .{
            // textureOptions is currently only used for custom shaders,
            // which require both the shader read (for when multiple shaders
            // are chained) and render target (for the final output) usage.
            // Disabling either of these will lead to metal validation
            // errors in Xcode.
            .shader_read = true,
            .render_target = true,
        },
    };
}

pub inline fn samplerOptions(self: Metal) Sampler.Options {
    return .{
        .device = self.device,

        // These parameters match Shadertoy behaviors.
        .min_filter = .linear,
        .mag_filter = .linear,
        .s_address_mode = .clamp_to_edge,
        .t_address_mode = .clamp_to_edge,
    };
}

/// Pixel format for image texture options.
pub const ImageTextureFormat = enum {
    /// 1 byte per pixel grayscale.
    gray,
    /// 4 bytes per pixel RGBA.
    rgba,
    /// 4 bytes per pixel BGRA.
    bgra,

    fn toPixelFormat(
        self: ImageTextureFormat,
        srgb: bool,
    ) mtl.MTLPixelFormat {
        return switch (self) {
            .gray => if (srgb) .r8unorm_srgb else .r8unorm,
            .rgba => if (srgb) .rgba8unorm_srgb else .rgba8unorm,
            .bgra => if (srgb) .bgra8unorm_srgb else .bgra8unorm,
        };
    }
};

/// Returns the options to use when constructing textures for images.
pub inline fn imageTextureOptions(
    self: Metal,
    format: ImageTextureFormat,
    srgb: bool,
) Texture.Options {
    return .{
        .device = self.device,
        .pixel_format = format.toPixelFormat(srgb),
        .resource_options = .{
            // Indicate that the CPU writes to this resource but never reads it.
            .cpu_cache_mode = .write_combined,
            .storage_mode = self.default_storage_mode,
        },
        .usage = .{
            // We only need to read from this texture from a shader.
            .shader_read = true,
        },
    };
}

/// Initializes a Texture suitable for the provided font atlas.
pub fn initAtlasTexture(
    self: *const Metal,
    atlas: *const font.Atlas,
) Texture.Error!Texture {
    const pixel_format: mtl.MTLPixelFormat = switch (atlas.format) {
        .grayscale => .r8unorm,
        .bgra => .bgra8unorm_srgb,
        else => @panic("unsupported atlas format for Metal texture"),
    };

    return try Texture.init(
        .{
            .device = self.device,
            .pixel_format = pixel_format,
            .resource_options = .{
                // Indicate that the CPU writes to this resource but never reads it.
                .cpu_cache_mode = .write_combined,
                .storage_mode = self.default_storage_mode,
            },
            .usage = .{
                // We only need to read from this texture from a shader.
                .shader_read = true,
            },
        },
        atlas.size,
        atlas.size,
        null,
    );
}

/// Begin a frame.
pub inline fn beginFrame(
    self: *Metal,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target's contents are submitted via the renderer's API when completed.
    target: *Target,
    token: Renderer.FrameToken,
    drawable: *?DrawableLease,
    /// The frame moves the viewport or animates (see `present`).
    motion: bool,
) !Frame {
    std.debug.assert(self.next_frame_id < std.math.maxInt(u64));
    self.next_frame_id += 1;
    return try Frame.begin(
        .{ .queue = self.queue },
        renderer,
        target,
        self.next_frame_id,
        token,
        drawable,
        motion,
    );
}

/// Warm up the Metal device machinery. The first Metal device query in
/// a process takes multiple milliseconds; once warm, subsequent queries
/// are effectively free. Calling this early (e.g. on a background
/// thread at app startup; Metal device queries are thread-safe) moves
/// that one-time cost off the critical path of the first surface's
/// renderer initialization.
pub fn warmup() void {
    const device = chooseDevice() catch return;
    defer device.release();

    // Create and release a command queue. The first command queue
    // created for a device pays additional one-time driver setup
    // costs; subsequent creations are much cheaper.
    const queue = device.msgSend(objc.Object, objc.sel("newCommandQueue"), .{});
    queue.release();

    // Build and discard our shader pipelines for both pixel formats we
    // may use (which one is used depends on the blending config). The
    // first pipeline state creation compiles shaders which is slow;
    // once warm, later creations hit driver and OS caches.
    inline for (.{
        mtl.MTLPixelFormat.bgra8unorm_srgb,
        mtl.MTLPixelFormat.bgra8unorm,
    }) |format| {
        if (shaders.Shaders.init(
            std.heap.c_allocator,
            device,
            &.{},
            format,
        )) |s| {
            var s_mut = s;
            s_mut.deinit(std.heap.c_allocator);
        } else |err| {
            log.warn("metal warmup shader init failed err={}", .{err});
        }
    }
}

fn chooseDevice() error{NoMetalDevice}!objc.Object {
    var chosen_device: ?objc.Object = null;

    switch (comptime builtin.os.tag) {
        .macos => {
            const devices = objc.Object.fromId(mtl.MTLCopyAllDevices());
            defer devices.release();

            var iter = devices.iterate();
            while (iter.next()) |device| {
                // We want a GPU that’s connected to a display.
                if (device.getProperty(bool, "isHeadless")) continue;
                chosen_device = device;
                // If the user has an eGPU plugged in, they probably want
                // to use it. Otherwise, integrated GPUs are better for
                // battery life and thermals.
                if (device.getProperty(bool, "isRemovable") or
                    device.getProperty(bool, "isLowPower")) break;
            }
        },
        .ios => {
            chosen_device = objc.Object.fromId(mtl.MTLCreateSystemDefaultDevice());
        },
        else => @compileError("unsupported target for Metal"),
    }

    const device = chosen_device orelse return error.NoMetalDevice;
    return device.retain();
}

/// Determines the maximum 2D texture size supported by the device.
/// We need to clamp our frame size to this if it's larger.
fn queryMaxTextureSize(device: objc.Object) u32 {
    // https://developer.apple.com/metal/Metal-Feature-Set-Tables.pdf

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple10},
    )) return 32768;

    if (device.msgSend(
        bool,
        objc.sel("supportsFamily:"),
        .{mtl.MTLGPUFamily.apple3},
    )) return 16384;

    return 8192;
}
