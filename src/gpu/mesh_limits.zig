//! Mesh/task shader geometry limits mirrored by the Slang ABI.

const std = @import("std");

pub const task_group_size: u32 = 32;
pub const mesh_thread_count: u32 = 32;
pub const max_subdivisions_per_glyph: u32 = 16;
pub const task_max_meshlets: u32 = task_group_size * max_subdivisions_per_glyph;

pub const mesh_output_vertices: u32 = 4;
pub const mesh_output_primitives: u32 = 2;

pub const task_payload_bytes: u32 = task_max_meshlets * 2 * @sizeOf(u32);
pub const mesh_shared_bytes: u32 =
    mesh_thread_count * (@sizeOf(f32) + @sizeOf(f32) + @sizeOf(u32)) +
    @sizeOf([4]f32) +
    @sizeOf(u32);
pub const mesh_payload_and_shared_bytes: u32 = task_payload_bytes + mesh_shared_bytes;

test "mesh/task limits match the Slang payload budget" {
    try std.testing.expectEqual(@as(u32, 512), task_max_meshlets);
    try std.testing.expectEqual(@as(u32, 4096), task_payload_bytes);
    try std.testing.expect(mesh_payload_and_shared_bytes > task_payload_bytes);
    try std.testing.expectEqual(@as(u32, 4), mesh_output_vertices);
    try std.testing.expectEqual(@as(u32, 2), mesh_output_primitives);
}
