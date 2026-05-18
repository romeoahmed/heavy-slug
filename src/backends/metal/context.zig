//! Zig-facing Metal 4 bridge context and host-owned object contract.

const std = @import("std");
const msl_shaders = @import("msl_shaders");

pub const ContextHandle = opaque {};
pub const BufferHandle = opaque {};

pub const Host = extern struct {
    /// Borrowed id<MTLDevice>; must outlive Context.
    device: *anyopaque,
    /// Borrowed id<MTL4CommandQueue>; must belong to device.
    command_queue: *anyopaque,
    /// Borrowed CAMetalLayer with device and pixelFormat already configured.
    layer: *anyopaque,
};

pub const ResourceIndices = extern struct {
    glyph_pool: u32,
    glyphs: u32,
    frame_params: u32,
    shader_stats: u32,
};

pub const GeometryLimits = extern struct {
    task_threadgroup_size: u32,
    mesh_threadgroup_size: u32,
    task_max_meshlets: u32,
    task_payload_bytes: u32,
};

extern fn hs_metal_context_create(
    host: Host,
    task_source: [*]const u8,
    task_source_len: usize,
    mesh_source: [*]const u8,
    mesh_source_len: usize,
    fragment_source: [*]const u8,
    fragment_source_len: usize,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) ?*ContextHandle;

extern fn hs_metal_context_destroy(context: *ContextHandle) void;
extern fn hs_metal_context_wait_frame_slot(
    context: *ContextHandle,
    slot_index: u32,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) c_int;
extern fn hs_metal_context_release_frame_slot(context: *ContextHandle, slot_index: u32) void;
extern fn hs_metal_context_wait_submitted(context: *ContextHandle) void;
extern fn hs_metal_buffer_create(context: *ContextHandle, size: usize) ?*BufferHandle;
extern fn hs_metal_buffer_destroy(buffer: *BufferHandle) void;
extern fn hs_metal_buffer_contents(buffer: *BufferHandle) ?[*]u8;
extern fn hs_metal_context_draw(
    context: *ContextHandle,
    width: u32,
    height: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    glyphs: *BufferHandle,
    frame_params: *BufferHandle,
    glyph_pool: *BufferHandle,
    shader_stats: ?*BufferHandle,
    workgroup_count: u32,
    slot_index: u32,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) c_int;
extern fn hs_metal_get_resource_indices() ResourceIndices;
extern fn hs_metal_get_geometry_limits() GeometryLimits;

pub const Error = error{
    MetalInitFailed,
    MetalBufferCreateFailed,
    MetalDrawFailed,
    InvalidFrameView,
};

pub const Context = struct {
    handle: *ContextHandle,

    pub fn init(host: Host) !Context {
        var error_buf: [2048]u8 = undefined;
        @memset(&error_buf, 0);
        const handle = hs_metal_context_create(
            host,
            msl_shaders.task.ptr,
            msl_shaders.task.len,
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
        hs_metal_context_destroy(self.handle);
        self.* = undefined;
    }
};

pub const Buffer = struct {
    handle: *BufferHandle,
    mapped: [*]u8,

    pub fn init(ctx: Context, size: usize) !Buffer {
        const handle = hs_metal_buffer_create(ctx.handle, size) orelse
            return Error.MetalBufferCreateFailed;
        errdefer hs_metal_buffer_destroy(handle);

        const mapped = hs_metal_buffer_contents(handle) orelse
            return Error.MetalBufferCreateFailed;

        return .{
            .handle = handle,
            .mapped = mapped,
        };
    }

    pub fn deinit(self: Buffer) void {
        hs_metal_buffer_destroy(self.handle);
    }
};

pub fn waitFrameSlot(ctx: Context, slot_index: u32, error_buffer: []u8) Error!void {
    if (hs_metal_context_wait_frame_slot(
        ctx.handle,
        slot_index,
        error_buffer.ptr,
        error_buffer.len,
    ) == 0) return Error.MetalDrawFailed;
}

pub fn releaseFrameSlot(ctx: Context, slot_index: u32) void {
    hs_metal_context_release_frame_slot(ctx.handle, slot_index);
}

pub fn waitSubmitted(ctx: Context) void {
    hs_metal_context_wait_submitted(ctx.handle);
}

pub const DrawInfo = struct {
    viewport: [2]u32,
    clear_color: [4]f32,
    glyphs: Buffer,
    frame_params: Buffer,
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

    if (hs_metal_context_draw(
        ctx.handle,
        info.viewport[0],
        info.viewport[1],
        info.clear_color[0],
        info.clear_color[1],
        info.clear_color[2],
        info.clear_color[3],
        info.glyphs.handle,
        info.frame_params.handle,
        info.glyph_pool.handle,
        shader_stats_handle,
        info.workgroup_count,
        info.slot_index,
        error_buffer.ptr,
        error_buffer.len,
    ) == 0) return Error.MetalDrawFailed;
}

pub fn resourceIndices() ResourceIndices {
    return hs_metal_get_resource_indices();
}

pub fn geometryLimits() GeometryLimits {
    return hs_metal_get_geometry_limits();
}

test "Metal context public API compiles" {
    _ = Context;
    _ = Host;
    _ = Buffer;
    _ = GeometryLimits;
    _ = @TypeOf(Context.init);
}
