//! Zig-facing Metal 4 bridge context and host-owned object contract.

const std = @import("std");
const heavy_slug = @import("heavy_slug");
const msl_shaders = @import("msl_shaders");
const backend_options = @import("heavy_slug_backend_options");

const mesh_limits = heavy_slug.gpu.mesh_limits;
const resource_model = heavy_slug.gpu.resource_model;
const ProtocolVersion = heavy_slug.core.protocol.ProtocolVersion;

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
pub const draw_request_protocol_version = ProtocolVersion.init(1, 0);
pub const draw_request_protocol_version_word: u32 = draw_request_protocol_version.word();
pub const buffer_glyph_pool: u32 = @intFromEnum(resource_model.BufferBinding.glyph_pool);
pub const buffer_glyphs: u32 = @intFromEnum(resource_model.BufferBinding.glyphs);
pub const buffer_meshlets: u32 = @intFromEnum(resource_model.BufferBinding.meshlets);
pub const buffer_shader_stats: u32 = @intFromEnum(resource_model.BufferBinding.shader_stats);
pub const buffer_frame_params: u32 = resource_model.frameParamsBinding(backend_options.shader_stats);
pub const object_threadgroup_size: u32 = 0;
pub const mesh_threadgroup_size: u32 = mesh_limits.mesh_thread_count;
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
    request_data: ?*const DrawRequest,
    request_size: usize,
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
    InvalidBufferSize,
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
    size: usize,

    pub fn init(ctx: Context, size: usize) !Buffer {
        if (size == 0) return Error.InvalidBufferSize;

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
            .size = size,
        };
    }

    pub fn deinit(self: Buffer) void {
        hs_metal_buffer_destroy(self.handle);
    }

    pub fn bytes(self: Buffer) []u8 {
        return self.mapped[0..self.size];
    }

    pub fn constBytes(self: Buffer) []const u8 {
        return self.mapped[0..self.size];
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

pub const DrawRequest = extern struct {
    protocol_version: u32,
    width: u32,
    height: u32,
    slot_index: u32,
    workgroup_count: u32,
    reserved0: u32,
    clear_color: [4]f32,
    frame_params_stride: usize,
    glyphs: ?*BufferHandle,
    meshlets: ?*BufferHandle,
    frame_params: ?*BufferHandle,
    glyph_pool: ?*BufferHandle,
    shader_stats: ?*BufferHandle,

    pub fn init(info: DrawInfo) DrawRequest {
        return .{
            .protocol_version = draw_request_protocol_version_word,
            .width = info.viewport[0],
            .height = info.viewport[1],
            .slot_index = info.slot_index,
            .workgroup_count = info.workgroup_count,
            .reserved0 = 0,
            .clear_color = info.clear_color,
            .frame_params_stride = info.frame_params_stride,
            .glyphs = info.glyphs.handle,
            .meshlets = info.meshlets.handle,
            .frame_params = info.frame_params.handle,
            .glyph_pool = info.glyph_pool.handle,
            .shader_stats = if (info.shader_stats) |shader_stats| shader_stats.handle else null,
        };
    }
};

pub fn draw(ctx: Context, info: DrawInfo, error_buffer: []u8) Error!void {
    const request = DrawRequest.init(info);

    if (hs_metal_context_draw(
        ctx.handle,
        &request,
        @sizeOf(DrawRequest),
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
    try std.testing.expectEqual(ProtocolVersion.init(1, 0).word(), draw_request_protocol_version_word);
    try std.testing.expectEqual(@as(u32, 0), buffer_glyph_pool);
    try std.testing.expectEqual(@as(u32, 1), buffer_glyphs);
    try std.testing.expectEqual(@as(u32, 2), buffer_meshlets);
    try std.testing.expectEqual(@as(u32, 3), buffer_shader_stats);
    try std.testing.expectEqual(@as(u32, 0), object_threadgroup_size);
    try std.testing.expectEqual(@as(u32, 32), mesh_threadgroup_size);
    try std.testing.expectEqual(@as(u32, 1024), max_mesh_threadgroups_per_draw);
}

test "Metal draw request protocol layout is explicit and pointer-sized" {
    try std.testing.expectEqual(@as(usize, 8), @alignOf(DrawRequest));
    try std.testing.expectEqual(@as(usize, 88), @sizeOf(DrawRequest));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(DrawRequest, "protocol_version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(DrawRequest, "width"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(DrawRequest, "height"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(DrawRequest, "slot_index"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(DrawRequest, "workgroup_count"));
    try std.testing.expectEqual(@as(usize, 20), @offsetOf(DrawRequest, "reserved0"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(DrawRequest, "clear_color"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(DrawRequest, "frame_params_stride"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(DrawRequest, "glyphs"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(DrawRequest, "meshlets"));
    try std.testing.expectEqual(@as(usize, 64), @offsetOf(DrawRequest, "frame_params"));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(DrawRequest, "glyph_pool"));
    try std.testing.expectEqual(@as(usize, 80), @offsetOf(DrawRequest, "shader_stats"));
}
