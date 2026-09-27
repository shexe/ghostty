//! Wrapper for handling render passes.
const Self = @This();

const std = @import("std");
const Allocator = std.mem.Allocator;
const objc = @import("objc");

const mtl = @import("api.zig");
const Renderer = @import("../generic.zig").Renderer(Metal);
const Metal = @import("../Metal.zig");
const Target = @import("Target.zig");
const RenderPass = @import("RenderPass.zig");
const IOSurfaceLayer = @import("IOSurfaceLayer.zig");
const DrawableHelper = @import("DrawableLease.zig");
const Drawable = IOSurfaceLayer.Drawable;

const Health = @import("../../renderer.zig").Health;

const log = std.log.scoped(.metal);

/// Options for beginning a frame.
pub const Options = struct {
    /// MTLCommandQueue
    queue: objc.Object,
};

/// MTLCommandBuffer
buffer: objc.Object,

block: CompletionBlock.Context,

/// Present only through this exact main-thread drawable when non-null.
drawable: ?Drawable = null,

/// Integer pixel rectangle occupied by the completed terminal grid.
pub const GridRect = struct {
    x: usize,
    y: usize,
    width: usize,
    height: usize,

    /// Reject stale geometry and grids that do not leave only the normal
    /// sub-cell remainder around the grid.
    pub fn isFittedWithin(
        self: GridRect,
        target_width: usize,
        target_height: usize,
        cell_width: usize,
        cell_height: usize,
    ) bool {
        if (self.width == 0 or self.height == 0 or cell_width == 0 or cell_height == 0) return false;
        if (self.x > target_width or self.y > target_height) return false;
        if (self.width > target_width - self.x or self.height > target_height - self.y) return false;
        return target_width - self.width < cell_width and target_height - self.height < cell_height;
    }
};

/// Begin encoding a frame.
pub fn begin(
    opts: Options,
    /// Once the frame has been completed, the `frameCompleted` method
    /// on the renderer is called with the health status of the frame.
    renderer: *Renderer,
    /// The target's contents are submitted via the renderer's API when completed.
    target: *Target,
    /// Monotonically increasing ID that prevents a late completion from
    /// replacing newer layer contents.
    frame_id: u64,
    token: Renderer.FrameToken,
    drawable: *?Drawable,
) !Self {
    const buffer = opts.queue.msgSend(
        objc.Object,
        objc.sel("commandBuffer"),
        .{},
    );

    // Create our block to register for completion updates.
    // The block is deallocated by the objC runtime on success.
    const block = CompletionBlock.init(
        .{
            .renderer = renderer,
            .target = target,
            .frame_id = frame_id,
            .token = token,
        },
        &bufferCompleted,
    );

    const owned_drawable = drawable.*;
    drawable.* = null;
    return .{ .buffer = buffer, .block = block, .drawable = owned_drawable };
}

/// Release the frame slot when encoding fails before commit.
pub fn abort(self: *Self) void {
    if (self.drawable) |*drawable| self.block.renderer.api.discardDrawable(drawable);
    self.drawable = null;
    self.block.renderer.abortFrame(self.block.token);
}

/// This is the block type used for the addCompletedHandler callback.
const CompletionBlock = objc.Block(struct {
    renderer: *Renderer,
    target: *Target,
    frame_id: u64,
    token: Renderer.FrameToken,
}, .{
    objc.c.id, // MTLCommandBuffer
}, void);

fn bufferCompleted(
    block: *const CompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const buffer = objc.Object.fromId(buffer_id);
    finishCompleted(block, buffer, false);
}

fn finishCompleted(
    block: *const CompletionBlock.Context,
    buffer: objc.Object,
    sync: bool,
) void {
    // Get our command buffer status to pass back to the generic renderer.
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = switch (status) {
        .@"error" => .unhealthy,
        else => .healthy,
    };

    // If the frame is healthy, submit its contents to the layer.
    if (health == .healthy) {
        block.renderer.api.present(
            block.target.*,
            block.frame_id,
            sync,
        ) catch |err| {
            log.err("Failed to present render target: err={}", .{err});
        };
    }

    block.renderer.frameCompletedMetal(health, block.token, sync);
}

const NativeCompletion = struct {
    gate: DrawableHelper.CompletionGate = .{},
    health: std.atomic.Value(c_int) = .init(@intFromEnum(Health.healthy)),
    published: std.atomic.Value(u8) = .init(0),
    block: CompletionBlock.Context,
    lease: ?Drawable,
    /// Submission admission credit, settled once both GPU completion and the
    /// main-thread present decision have arrived.
    settlement: objc.Object,

    fn arrive(self: *NativeCompletion, party: DrawableHelper.CompletionGate.Party) void {
        if (!self.gate.arrive(party)) return;
        const renderer = self.block.renderer;
        const token = self.block.token;
        const health: Health = @enumFromInt(self.health.load(.acquire));
        const published = self.published.load(.acquire) != 0;
        if (health == .unhealthy and published)
            renderer.api.requestNativeRedraw();
        self.settlement.release();
        std.heap.page_allocator.destroy(self);
        // Releasing the slot is the last renderer access.
        renderer.frameCompletedMetal(health, token, party == .main);
    }
};

const NativeCompletionBlock = objc.Block(struct {
    completion: *NativeCompletion,
}, .{objc.c.id}, void);

fn nativeBufferCompleted(
    callback: *const NativeCompletionBlock.Context,
    buffer_id: objc.c.id,
) callconv(.c) void {
    const completion = callback.completion;
    const buffer = objc.Object.fromId(buffer_id);
    const status = buffer.getProperty(mtl.MTLCommandBufferStatus, "status");
    const health: Health = if (status == .@"error") .unhealthy else .healthy;
    completion.health.store(@intFromEnum(health), .release);
    completion.arrive(.gpu);
}

/// A synchronous frame's remaining work, finished after draw_mutex is
/// released. Owns the frame slot and a command-buffer retain.
pub const SyncContinuation = union(enum) {
    iosurface: struct {
        buffer: objc.Object,
        block: CompletionBlock.Context,
    },
    drawable: struct {
        buffer: objc.Object,
        completion: *NativeCompletion,
    },

    pub fn finish(self: *SyncContinuation) void {
        switch (self.*) {
            .iosurface => |*value| {
                value.buffer.msgSend(void, "waitUntilCompleted", .{});
                finishCompleted(&value.block, value.buffer, true);
                value.buffer.release();
            },
            .drawable => |*value| {
                const completion = value.completion;
                const published = completion.block.renderer.api.presentNativeDrawable(
                    &completion.lease.?,
                    value.buffer,
                    completion.block.frame_id,
                );
                completion.published.store(@intFromBool(published), .release);
                completion.lease.?.release();
                completion.lease = null;
                completion.arrive(.main);
                value.buffer.release();
            },
        }
        self.* = undefined;
    }
};

/// Add a render pass to this frame with the provided attachments.
/// Returns a RenderPass which allows render steps to be added.
pub inline fn renderPass(
    self: *const Self,
    attachments: []const RenderPass.Options.Attachment,
) RenderPass {
    return RenderPass.begin(.{
        .attachments = attachments,
        .command_buffer = self.buffer,
    });
}

/// Extend the completed grid raster into the fitted padding around it.
///
/// Each same-texture blit uses non-overlapping source and destination regions:
/// first the top/bottom rows across the interior width, then the left/right
/// columns across the full target height so the corner pixels are covered too.
pub fn extendRasterEdges(self: *const Self, target: *const Target, rect: GridRect) void {
    const right = target.width - (rect.x + rect.width);
    const bottom = target.height - (rect.y + rect.height);
    if (rect.x == 0 and rect.y == 0 and right == 0 and bottom == 0) return;

    const encoder = self.buffer.msgSend(
        objc.Object,
        objc.sel("blitCommandEncoder"),
        .{},
    );
    defer encoder.msgSend(void, objc.sel("endEncoding"), .{});

    const copy = struct {
        fn run(
            blit: objc.Object,
            texture: objc.Object,
            source_origin: mtl.MTLOrigin,
            size: mtl.MTLSize,
            destination_origin: mtl.MTLOrigin,
        ) void {
            blit.msgSend(
                void,
                objc.sel("copyFromTexture:sourceSlice:sourceLevel:sourceOrigin:sourceSize:toTexture:destinationSlice:destinationLevel:destinationOrigin:"),
                .{
                    texture.value,
                    @as(c_ulong, 0),
                    @as(c_ulong, 0),
                    source_origin,
                    size,
                    texture.value,
                    @as(c_ulong, 0),
                    @as(c_ulong, 0),
                    destination_origin,
                },
            );
        }
    }.run;
    const texture = target.texture;

    for (0..rect.y) |y| copy(encoder, texture, .{ .x = rect.x, .y = rect.y, .z = 0 }, .{ .width = rect.width, .height = 1, .depth = 1 }, .{ .x = rect.x, .y = y, .z = 0 });
    for (0..bottom) |y| copy(encoder, texture, .{ .x = rect.x, .y = rect.y + rect.height - 1, .z = 0 }, .{ .width = rect.width, .height = 1, .depth = 1 }, .{ .x = rect.x, .y = rect.y + rect.height + y, .z = 0 });
    for (0..rect.x) |x| copy(encoder, texture, .{ .x = rect.x, .y = 0, .z = 0 }, .{ .width = 1, .height = target.height, .depth = 1 }, .{ .x = x, .y = 0, .z = 0 });
    for (0..right) |x| copy(encoder, texture, .{ .x = rect.x + rect.width - 1, .y = 0, .z = 0 }, .{ .width = 1, .height = target.height, .depth = 1 }, .{ .x = rect.x + rect.width + x, .y = 0, .z = 0 });
}

/// Commit the frame. Asynchronous frames complete through their callback;
/// synchronous frames return a continuation to finish outside the lock.
pub inline fn complete(self: *Self, sync: bool) !?SyncContinuation {
    if (self.drawable) |owned_lease| {
        if (!sync) return error.DrawableRequiresSynchronousCompletion;
        var lease = owned_lease;
        self.drawable = null;
        errdefer self.block.renderer.api.discardDrawable(&lease);
        try lease.encodeCopy(self.buffer, self.block.target.texture);

        const completion = try std.heap.page_allocator.create(NativeCompletion);
        completion.* = .{
            .block = self.block,
            .lease = lease,
            .settlement = lease.settlement.retain(),
        };
        var callback = NativeCompletionBlock.init(
            .{ .completion = completion },
            &nativeBufferCompleted,
        );
        self.buffer.msgSend(
            void,
            objc.sel("addCompletedHandler:"),
            .{&callback},
        );

        self.buffer.msgSend(void, objc.sel("commit"), .{});
        return .{ .drawable = .{
            .buffer = self.buffer.retain(),
            .completion = completion,
        } };
    }

    // If we don't need to complete synchronously,
    // we add our block as a completion handler.
    //
    // It will be copied when we add the handler, and then the
    // copy will be deallocated by the objc runtime on success.
    if (!sync) {
        self.buffer.msgSend(
            void,
            objc.sel("addCompletedHandler:"),
            .{&self.block},
        );
    }

    self.buffer.msgSend(void, objc.sel("commit"), .{});

    if (!sync) return null;

    // commandBuffer is autoreleased. Keep it alive after the renderer closes
    // its shared autorelease pool and releases draw_mutex.
    return .{ .iosurface = .{
        .buffer = self.buffer.retain(),
        .block = self.block,
    } };
}

