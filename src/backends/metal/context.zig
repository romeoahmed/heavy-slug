//! Zig-facing Metal 4 bridge context and host-owned object contract.

const std = @import("std");
const c = @import("metal_c");
const msl_shaders = @import("msl_shaders");

pub const ContextHandle = c.hs_metal_context;
pub const BufferHandle = c.hs_metal_buffer;

pub const Host = struct {
    /// Borrowed id<MTLDevice>; must outlive Context.
    device: *anyopaque,
    /// Borrowed id<MTL4CommandQueue>; must belong to device.
    command_queue: *anyopaque,
    /// Borrowed CAMetalLayer with device and pixelFormat already configured.
    layer: *anyopaque,

    fn cValue(self: Host) c.hs_metal_host_objects {
        return .{
            .device = self.device,
            .command_queue = self.command_queue,
            .layer = self.layer,
        };
    }
};

pub const ResourceIndices = c.hs_metal_resource_indices;
pub const GeometryLimits = c.hs_metal_geometry_limits;

pub const Error = error{
    MetalInitFailed,
    MetalBufferCreateFailed,
    MetalDrawFailed,
    InvalidView,
};

pub const Context = struct {
    handle: *ContextHandle,

    pub fn init(host: Host) !Context {
        var error_buf: [2048]u8 = undefined;
        @memset(&error_buf, 0);
        const handle = c.hs_metal_context_create(
            host.cValue(),
            msl_shaders.mesh.ptr,
            msl_shaders.mesh.len,
            msl_shaders.fragment.ptr,
            msl_shaders.fragment.len,
            &error_buf,
            error_buf.len,
        ) orelse {
            std.log.err("Metal init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.MetalInitFailed;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Context) void {
        c.hs_metal_context_destroy(self.handle);
        self.* = undefined;
    }
};

pub const Buffer = struct {
    handle: *BufferHandle,
    mapped: [*]u8,

    pub fn init(ctx: Context, size: usize) !Buffer {
        const handle = c.hs_metal_buffer_create(ctx.handle, size) orelse
            return Error.MetalBufferCreateFailed;
        errdefer c.hs_metal_buffer_destroy(handle);

        const contents = c.hs_metal_buffer_contents(handle) orelse
            return Error.MetalBufferCreateFailed;

        return .{
            .handle = handle,
            .mapped = @ptrCast(contents),
        };
    }

    pub fn deinit(self: Buffer) void {
        c.hs_metal_buffer_destroy(self.handle);
    }
};

pub fn waitFrameSlot(ctx: Context, slot_index: u32, error_buffer: []u8) Error!void {
    if (c.hs_metal_context_wait_frame_slot(
        ctx.handle,
        slot_index,
        error_buffer.ptr,
        error_buffer.len,
    ) == 0) return Error.MetalDrawFailed;
}

pub fn releaseFrameSlot(ctx: Context, slot_index: u32) void {
    c.hs_metal_context_release_frame_slot(ctx.handle, slot_index);
}

pub fn waitSubmitted(ctx: Context) void {
    c.hs_metal_context_wait_submitted(ctx.handle);
}

pub const DrawInfo = struct {
    viewport: [2]u32,
    clear_color: [4]f32,
    glyphs: Buffer,
    meshlets: Buffer,
    frame_params: Buffer,
    frame_params_stride: u32,
    glyph_pool: Buffer,
    shader_stats: ?Buffer,
    workgroup_count: u32,
    slot_index: u32,
};

pub fn draw(ctx: Context, info: DrawInfo, error_buffer: []u8) Error!void {
    const shader_stats_handle: ?*BufferHandle = if (info.shader_stats) |shader_stats|
        shader_stats.handle
    else
        null;

    if (c.hs_metal_context_draw(
        ctx.handle,
        info.viewport[0],
        info.viewport[1],
        info.clear_color[0],
        info.clear_color[1],
        info.clear_color[2],
        info.clear_color[3],
        info.glyphs.handle,
        info.meshlets.handle,
        info.frame_params.handle,
        info.frame_params_stride,
        info.glyph_pool.handle,
        shader_stats_handle,
        info.workgroup_count,
        info.slot_index,
        error_buffer.ptr,
        error_buffer.len,
    ) == 0) return Error.MetalDrawFailed;
}

pub fn resourceIndices() ResourceIndices {
    return c.hs_metal_get_resource_indices();
}

pub fn geometryLimits() GeometryLimits {
    return c.hs_metal_get_geometry_limits();
}

test "Metal context public API compiles" {
    _ = Context;
    _ = Host;
    _ = Buffer;
    _ = GeometryLimits;
    _ = @TypeOf(Context.init);
}

test "Metal context uses translated C bridge ABI" {
    try std.testing.expectEqual(@as(u32, 0), c.HS_METAL_BUFFER_GLYPH_POOL);
    try std.testing.expectEqual(@as(u32, 1), c.HS_METAL_BUFFER_GLYPHS);
    try std.testing.expectEqual(@as(u32, 2), c.HS_METAL_BUFFER_MESHLETS);
    try std.testing.expectEqual(@as(u32, 3), c.HS_METAL_BUFFER_SHADER_STATS);
    try std.testing.expectEqual(@as(u32, 0), c.HS_METAL_OBJECT_THREADGROUP_SIZE);
    try std.testing.expectEqual(@as(u32, 32), c.HS_METAL_MESH_THREADGROUP_SIZE);
    try std.testing.expectEqual(@as(u32, 1024), c.HS_METAL_MAX_MESH_THREADGROUPS_PER_DRAW);
}
