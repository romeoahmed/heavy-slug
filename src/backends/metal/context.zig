//! Zig-facing Metal 4 bridge context and host-owned object contract.

const std = @import("std");
const msl_shaders = @import("msl_shaders");
const backend_options = @import("heavy_slug_backend_options");

const ContextHandle = opaque {};
const BufferHandle = opaque {};

pub const diagnostic_capacity = 2048;

const Status = enum(c_int) {
    ok = 0,
    err = 1,
};

const U8 = u8;

pub const ResourceIndices = struct {
    glyph_pool: u32,
    glyphs: u32,
    meshlets: u32,
    frame_params: u32,
    shader_stats: u32,
};

pub const GeometryLimits = struct {
    object_threadgroup_size: u32,
    mesh_threadgroup_size: u32,
    max_mesh_threadgroups_per_draw: u32,
};

pub const frame_slot_count: usize = 3;
pub const buffer_glyph_pool: u32 = 0;
pub const buffer_glyphs: u32 = 1;
pub const buffer_meshlets: u32 = 2;
pub const buffer_shader_stats: u32 = 3;
pub const buffer_frame_params: u32 = if (backend_options.shader_stats) 4 else 3;
pub const object_threadgroup_size: u32 = 0;
pub const mesh_threadgroup_size: u32 = 32;
pub const max_mesh_threadgroups_per_draw: u32 = 1024;

extern fn hs_metal_context_create(
    out_context: *?*ContextHandle,
    device: ?*anyopaque,
    command_queue: ?*anyopaque,
    layer: ?*anyopaque,
    mesh_source_data: ?[*]const U8,
    mesh_source_size: usize,
    fragment_source_data: ?[*]const U8,
    fragment_source_size: usize,
    error_data: ?[*]U8,
    error_size: usize,
) Status;
extern fn hs_metal_context_destroy(context: ?*ContextHandle) void;
extern fn hs_metal_context_wait_frame_slot(
    context: ?*ContextHandle,
    slot_index: u32,
    error_data: ?[*]U8,
    error_size: usize,
) Status;
extern fn hs_metal_context_release_frame_slot(context: ?*ContextHandle, slot_index: u32) void;
extern fn hs_metal_context_wait_submitted(context: ?*ContextHandle) void;
extern fn hs_metal_buffer_create(
    out_buffer: *?*BufferHandle,
    context: ?*ContextHandle,
    size: usize,
    error_data: ?[*]U8,
    error_size: usize,
) Status;
extern fn hs_metal_buffer_destroy(buffer: ?*BufferHandle) void;
extern fn hs_metal_buffer_contents(buffer: ?*BufferHandle) ?*anyopaque;
extern fn hs_metal_context_draw(
    context: ?*ContextHandle,
    width: u32,
    height: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    glyphs: ?*BufferHandle,
    meshlets: ?*BufferHandle,
    frame_params: ?*BufferHandle,
    frame_params_stride: usize,
    glyph_pool: ?*BufferHandle,
    shader_stats: ?*BufferHandle,
    workgroup_count: u32,
    slot_index: u32,
    error_data: ?[*]U8,
    error_size: usize,
) Status;

pub const Host = struct {
    /// Borrowed id<MTLDevice>; Swift Context retains it for the context lifetime.
    device: *anyopaque,
    /// Borrowed id<MTL4CommandQueue>; Swift Context retains it and it must belong to device.
    command_queue: *anyopaque,
    /// Borrowed CAMetalLayer retained by Swift Context with device, pixelFormat, and residencySet configured.
    layer: *anyopaque,
};

pub const Error = error{
    ContextCreateFailed,
    BufferCreateFailed,
    DrawFailed,
};

fn emptyDiagnostic() [diagnostic_capacity]u8 {
    return .{0} ** diagnostic_capacity;
}

fn dataPtr(bytes: []const u8) ?[*]const U8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

fn bufferPtr(bytes: []u8) ?[*]U8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

pub const Context = struct {
    handle: *ContextHandle,

    pub fn init(host: Host) !Context {
        var error_buf = emptyDiagnostic();
        var handle: ?*ContextHandle = null;
        if (hs_metal_context_create(
            &handle,
            host.device,
            host.command_queue,
            host.layer,
            dataPtr(msl_shaders.mesh),
            msl_shaders.mesh.len,
            dataPtr(msl_shaders.fragment),
            msl_shaders.fragment.len,
            bufferPtr(error_buf[0..]),
            error_buf.len,
        ) != .ok) {
            std.log.err("Metal init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.ContextCreateFailed;
        }
        return .{ .handle = handle orelse return Error.ContextCreateFailed };
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
        var error_buf = emptyDiagnostic();
        var handle: ?*BufferHandle = null;
        if (hs_metal_buffer_create(
            &handle,
            ctx.handle,
            size,
            bufferPtr(error_buf[0..]),
            error_buf.len,
        ) != .ok) {
            std.log.err("Metal buffer init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.BufferCreateFailed;
        }
        const owned_handle = handle orelse return Error.BufferCreateFailed;
        errdefer hs_metal_buffer_destroy(owned_handle);

        const contents = hs_metal_buffer_contents(owned_handle) orelse
            return Error.BufferCreateFailed;

        return .{
            .handle = owned_handle,
            .mapped = @ptrCast(contents),
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
        bufferPtr(error_buffer),
        error_buffer.len,
    ) != .ok) return Error.DrawFailed;
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
    meshlets: Buffer,
    frame_params: Buffer,
    frame_params_stride: usize,
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
        info.meshlets.handle,
        info.frame_params.handle,
        info.frame_params_stride,
        info.glyph_pool.handle,
        shader_stats_handle,
        info.workgroup_count,
        info.slot_index,
        bufferPtr(error_buffer),
        error_buffer.len,
    ) != .ok) return Error.DrawFailed;
}

pub fn resourceIndices() ResourceIndices {
    return .{
        .glyph_pool = buffer_glyph_pool,
        .glyphs = buffer_glyphs,
        .meshlets = buffer_meshlets,
        .frame_params = buffer_frame_params,
        .shader_stats = buffer_shader_stats,
    };
}

pub fn geometryLimits() GeometryLimits {
    return .{
        .object_threadgroup_size = object_threadgroup_size,
        .mesh_threadgroup_size = mesh_threadgroup_size,
        .max_mesh_threadgroups_per_draw = max_mesh_threadgroups_per_draw,
    };
}

test "Metal context public API compiles" {
    _ = Context;
    _ = Host;
    _ = Buffer;
    _ = GeometryLimits;
    _ = @TypeOf(Context.init);
}

test "Metal context mirrors Swift bridge ABI constants" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(Status.err));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(U8));
    try std.testing.expectEqual(@as(usize, 3), frame_slot_count);
    try std.testing.expectEqual(@as(u32, 0), buffer_glyph_pool);
    try std.testing.expectEqual(@as(u32, 1), buffer_glyphs);
    try std.testing.expectEqual(@as(u32, 2), buffer_meshlets);
    try std.testing.expectEqual(@as(u32, 3), buffer_shader_stats);
    try std.testing.expectEqual(@as(u32, 0), object_threadgroup_size);
    try std.testing.expectEqual(@as(u32, 32), mesh_threadgroup_size);
    try std.testing.expectEqual(@as(u32, 1024), max_mesh_threadgroups_per_draw);
}
