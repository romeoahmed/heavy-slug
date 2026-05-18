//! Mesh/task shader geometry limits mirrored by the Slang ABI.

const std = @import("std");

pub const task_group_size: u32 = 32;
pub const mesh_thread_count: u32 = 32;
pub const max_subdivisions_per_glyph: u32 = 16;
pub const task_max_meshlets: u32 = task_group_size * max_subdivisions_per_glyph;

pub const mesh_output_vertices: u32 = 8;
pub const mesh_output_primitives: u32 = 6;
pub const mesh_output_user_components_per_vertex: u32 =
    4 + // color
    1 + // blobRef
    1 + // flags
    2 + // meshAnchorQ
    2 + // screenAnchorPx
    4; // localFromScreen
pub const mesh_output_components_per_vertex: u32 =
    4 + // SV_Position
    mesh_output_user_components_per_vertex;

pub const task_payload_bytes: u32 = task_max_meshlets * 2 * @sizeOf(u32);
pub const mesh_shared_bytes: u32 =
    mesh_thread_count * (@sizeOf(f32) + @sizeOf(u32)) +
    @sizeOf([2]i32) +
    @sizeOf([2]f32) +
    mesh_output_vertices * @sizeOf([2]f32) +
    2 * @sizeOf(u32) +
    @sizeOf(u32);
pub const mesh_payload_and_shared_bytes: u32 = task_payload_bytes + mesh_shared_bytes;

pub fn taskWorkgroupCount(glyph_count: u32) u32 {
    return (glyph_count / task_group_size) + @intFromBool(glyph_count % task_group_size != 0);
}

test "mesh/task limits match the Slang payload budget" {
    try std.testing.expectEqual(@as(u32, 512), task_max_meshlets);
    try std.testing.expectEqual(@as(u32, 4096), task_payload_bytes);
    try std.testing.expect(mesh_payload_and_shared_bytes > task_payload_bytes);
    try std.testing.expectEqual(@as(u32, 8), mesh_output_vertices);
    try std.testing.expectEqual(@as(u32, 6), mesh_output_primitives);
    try std.testing.expectEqual(@as(u32, 14), mesh_output_user_components_per_vertex);
    try std.testing.expectEqual(@as(u32, 18), mesh_output_components_per_vertex);
}

test "taskWorkgroupCount uses task group size" {
    try std.testing.expectEqual(@as(u32, 0), taskWorkgroupCount(0));
    try std.testing.expectEqual(@as(u32, 1), taskWorkgroupCount(1));
    try std.testing.expectEqual(@as(u32, 1), taskWorkgroupCount(task_group_size));
    try std.testing.expectEqual(@as(u32, 2), taskWorkgroupCount(task_group_size + 1));
}
