//! Pure draw planning for Vulkan mesh-shader submissions.

const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const bindings = @import("bindings.zig");

const core_types = heavy_slug.core.types;

pub const Error = error{
    InvalidView,
    MeshWorkgroupLimitExceeded,
};

pub const FrameGeometry = struct {
    view_size: [2]f32,
    viewport: vk.Viewport,
    scissor: vk.Rect2D,
};

pub const DrawChunk = struct {
    meshlet_base: u32,
    workgroup_count: u32,
};

pub const ChunkIterator = struct {
    meshlet_count: u32,
    max_workgroups_per_draw: u32,
    next_meshlet: u32 = 0,

    pub fn init(meshlet_count: u32, max_workgroups_per_draw: u32) ChunkIterator {
        std.debug.assert(max_workgroups_per_draw > 0);
        return .{
            .meshlet_count = meshlet_count,
            .max_workgroups_per_draw = max_workgroups_per_draw,
        };
    }

    pub fn next(self: *ChunkIterator) ?DrawChunk {
        if (self.next_meshlet >= self.meshlet_count) return null;
        const count = @min(
            self.meshlet_count - self.next_meshlet,
            self.max_workgroups_per_draw,
        );
        const chunk = DrawChunk{
            .meshlet_base = self.next_meshlet,
            .workgroup_count = count,
        };
        self.next_meshlet += count;
        return chunk;
    }
};

pub fn frameGeometry(view: core_types.View) Error!FrameGeometry {
    const view_size = viewSizeF32(view) orelse return Error.InvalidView;
    return .{
        .view_size = view_size,
        .viewport = yUpViewport(view_size),
        .scissor = .{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intFromFloat(@round(view_size[0])),
                .height = @intFromFloat(@round(view_size[1])),
            },
        },
    };
}

pub fn maxMeshWorkgroupsPerDraw(props: vk.PhysicalDeviceMeshShaderPropertiesEXT) u32 {
    return @min(props.max_mesh_work_group_count[0], props.max_mesh_work_group_total_count);
}

pub fn chunkCount(workgroup_count: u32, max_workgroups_per_draw: u32) u32 {
    if (workgroup_count == 0) return 0;
    std.debug.assert(max_workgroups_per_draw > 0);
    return (workgroup_count / max_workgroups_per_draw) +
        @intFromBool(workgroup_count % max_workgroups_per_draw != 0);
}

pub fn validateDrawChunk(
    props: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    workgroup_count: u32,
) Error!void {
    if (workgroup_count == 0) return;
    if (workgroup_count > props.max_mesh_work_group_count[0] or
        workgroup_count > props.max_mesh_work_group_total_count)
    {
        return Error.MeshWorkgroupLimitExceeded;
    }
}

pub fn frameParams(geometry: FrameGeometry, chunk: DrawChunk) bindings.FrameParams {
    return .{
        .viewport_size = geometry.view_size,
        .screen_from_framebuffer_2x2 = .{ 1, 0, 0, -1 },
        .screen_from_framebuffer_offset = .{ 0, geometry.view_size[1] },
        .meshlet_count = chunk.workgroup_count,
        .meshlet_base = chunk.meshlet_base,
    };
}

fn viewSizeF32(view: core_types.View) ?[2]f32 {
    if (!view.isFinite()) return null;
    if (view.width > @as(f64, @floatFromInt(std.math.maxInt(u32))) or
        view.height > @as(f64, @floatFromInt(std.math.maxInt(u32))))
    {
        return null;
    }
    return .{
        @floatCast(view.width),
        @floatCast(view.height),
    };
}

// Match the Metal demo's y-up clip-space convention without changing shared scene input math.
fn yUpViewport(viewport: [2]f32) vk.Viewport {
    return .{
        .x = 0,
        .y = viewport[1],
        .width = viewport[0],
        .height = -viewport[1],
        .min_depth = 0,
        .max_depth = 1,
    };
}

fn viewportFramebufferY(viewport: vk.Viewport, ndc_y: f32) f32 {
    return viewport.y + (ndc_y + 1.0) * viewport.height * 0.5;
}

fn framebufferToScreenYUpForCurrentBackends(framebuffer: [2]f32, viewport: [2]f32) [2]f32 {
    return .{ framebuffer[0], viewport[1] - framebuffer[1] };
}

test "mesh workgroup validation follows Vulkan mesh shader draw limits" {
    var props = std.mem.zeroes(vk.PhysicalDeviceMeshShaderPropertiesEXT);
    props.max_mesh_work_group_total_count = 4;
    props.max_mesh_work_group_count = .{ 4, 1, 1 };

    try validateDrawChunk(props, 4);
    try std.testing.expectError(Error.MeshWorkgroupLimitExceeded, validateDrawChunk(props, 5));

    props.max_mesh_work_group_total_count = 3;
    try std.testing.expectError(Error.MeshWorkgroupLimitExceeded, validateDrawChunk(props, 4));
    try std.testing.expectEqual(@as(u32, 3), maxMeshWorkgroupsPerDraw(props));
    try std.testing.expectEqual(@as(u32, 0), chunkCount(0, 3));
    try std.testing.expectEqual(@as(u32, 1), chunkCount(3, 3));
    try std.testing.expectEqual(@as(u32, 2), chunkCount(4, 3));
}

test "ChunkIterator emits bounded contiguous meshlet ranges" {
    var iter = ChunkIterator.init(10, 4);
    try std.testing.expectEqual(DrawChunk{ .meshlet_base = 0, .workgroup_count = 4 }, iter.next().?);
    try std.testing.expectEqual(DrawChunk{ .meshlet_base = 4, .workgroup_count = 4 }, iter.next().?);
    try std.testing.expectEqual(DrawChunk{ .meshlet_base = 8, .workgroup_count = 2 }, iter.next().?);
    try std.testing.expectEqual(@as(?DrawChunk, null), iter.next());
}

test "y-up frame geometry matches the Metal demo clip-space convention" {
    const geometry = try frameGeometry(core_types.View.identity(1280, 720));

    try std.testing.expectEqual(@as(f32, 0), geometry.viewport.x);
    try std.testing.expectEqual(@as(f32, 720), geometry.viewport.y);
    try std.testing.expectEqual(@as(f32, 1280), geometry.viewport.width);
    try std.testing.expectEqual(@as(f32, -720), geometry.viewport.height);
    try std.testing.expectEqual(@as(u32, 1280), geometry.scissor.extent.width);
    try std.testing.expectEqual(@as(u32, 720), geometry.scissor.extent.height);
    try std.testing.expectEqual(@as(f32, 0), viewportFramebufferY(geometry.viewport, 1));
    try std.testing.expectEqual(@as(f32, 720), viewportFramebufferY(geometry.viewport, -1));
}

test "fragment framebuffer conversion restores y-up screen coordinates" {
    const viewport = [2]f32{ 1280, 720 };
    const samples = [_][2]f32{
        .{ 0, 720 },
        .{ 10, 640 },
        .{ 640, 360 },
        .{ 1279.5, 0.5 },
    };
    const expected = [_][2]f32{
        .{ 0, 0 },
        .{ 10, 80 },
        .{ 640, 360 },
        .{ 1279.5, 719.5 },
    };

    for (samples, expected) |framebuffer, screen| {
        const converted = framebufferToScreenYUpForCurrentBackends(framebuffer, viewport);
        try std.testing.expectEqual(screen[0], converted[0]);
        try std.testing.expectEqual(screen[1], converted[1]);
    }
}
