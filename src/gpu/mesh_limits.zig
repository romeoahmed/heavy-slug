//! Mesh shader geometry limits mirrored by the Slang ABI.

const std = @import("std");

pub const task_group_size: u32 = 32;
pub const mesh_thread_count: u32 = 32;
pub const max_subdivisions_per_glyph: u32 = 16;

pub const mesh_output_vertices: u32 = 8;
pub const mesh_output_primitives: u32 = 6;
pub const mesh_output_user_components_per_vertex: u32 =
    1; // meshlet index
pub const mesh_output_components_per_vertex: u32 =
    4 + // SV_Position
    mesh_output_user_components_per_vertex;

pub const mesh_shared_bytes: u32 =
    mesh_output_vertices * @sizeOf([2]f32) +
    2 * @sizeOf(u32) +
    @sizeOf(u32);
pub const mesh_payload_and_shared_bytes: u32 = mesh_shared_bytes;

pub fn maxMeshletsForGlyphCapacity(glyph_capacity: u32) u32 {
    return glyph_capacity *| max_subdivisions_per_glyph;
}

test "mesh-only limits match the Slang meshlet stream budget" {
    try std.testing.expectEqual(@as(u32, 8), mesh_output_vertices);
    try std.testing.expectEqual(@as(u32, 6), mesh_output_primitives);
    try std.testing.expectEqual(@as(u32, 1), mesh_output_user_components_per_vertex);
    try std.testing.expectEqual(@as(u32, 5), mesh_output_components_per_vertex);
    try std.testing.expectEqual(@as(u32, 16), max_subdivisions_per_glyph);
    try std.testing.expect(mesh_payload_and_shared_bytes == mesh_shared_bytes);
}

test "maxMeshletsForGlyphCapacity uses per-glyph subdivision cap" {
    try std.testing.expectEqual(@as(u32, 0), maxMeshletsForGlyphCapacity(0));
    try std.testing.expectEqual(@as(u32, max_subdivisions_per_glyph), maxMeshletsForGlyphCapacity(1));
    try std.testing.expectEqual(@as(u32, 64), maxMeshletsForGlyphCapacity(4));
}
