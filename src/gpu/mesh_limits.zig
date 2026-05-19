//! Mesh shader geometry and memory budgets mirrored by the Slang ABI.

const std = @import("std");

/// One workgroup emits one CPU-authored h-band meshlet.
pub const workgroup_size = [3]u32{ thread_count, 1, 1 };
pub const thread_count: u32 = 32;

/// CPU subdivision cap. Each glyph can contribute at most this many meshlets
/// to a frame stream.
pub const max_subdivisions_per_glyph: u32 = 16;

/// Sutherland-Hodgman clipping of a quad against four NDC half-spaces can emit
/// at most eight vertices. The triangle fan therefore needs at most six
/// triangles.
pub const output_vertices: u32 = 8;
pub const output_primitives: u32 = output_vertices - 2;

/// Mesh-to-fragment payload: a flat meshlet index. Vulkan mesh output resource
/// accounting is location-based, so the scalar payload occupies one four-scalar
/// user location for limit checks even though the shader writes one u32.
pub const user_locations_per_vertex: u32 = 1;
pub const user_scalar_components_per_vertex: u32 = 1;
pub const position_scalar_components_per_vertex: u32 = 4;
pub const scalar_components_written_per_vertex: u32 =
    position_scalar_components_per_vertex +
    user_scalar_components_per_vertex;
pub const scalar_components_reserved_per_vertex: u32 =
    position_scalar_components_per_vertex +
    user_locations_per_vertex * 4;

/// Current mesh shader groupshared state:
/// - clipped vertex array: 8 * float2
/// - vertex count, primitive count, emit flag: 3 * u32
pub const shared_bytes: u32 =
    output_vertices * @sizeOf([2]f32) +
    3 * @sizeOf(u32);
pub const payload_bytes: u32 = 0;
pub const payload_and_shared_bytes: u32 = payload_bytes + shared_bytes;

/// Conservative Vulkan output-memory budget. The EXT mesh shader properties
/// expose implementation granularities, so callers pass the queried values.
pub fn outputMemoryBytes(vertex_granularity: u32, primitive_granularity: u32) u32 {
    _ = primitive_granularity;
    const rounded_vertices = alignForward(output_vertices, @max(vertex_granularity, 1));
    const components = std.math.mul(
        u32,
        rounded_vertices,
        scalar_components_reserved_per_vertex,
    ) catch std.math.maxInt(u32);
    return std.math.mul(u32, components, @sizeOf(u32)) catch std.math.maxInt(u32);
}

pub fn payloadAndOutputMemoryBytes(vertex_granularity: u32, primitive_granularity: u32) u32 {
    return payload_bytes +| outputMemoryBytes(vertex_granularity, primitive_granularity);
}

pub fn maxMeshletsForGlyphCapacity(glyph_capacity: u32) u32 {
    return glyph_capacity *| max_subdivisions_per_glyph;
}

pub fn checkedMaxMeshletsForGlyphCapacity(glyph_capacity: u32) error{FrameCapacityTooLarge}!u32 {
    return std.math.mul(u32, glyph_capacity, max_subdivisions_per_glyph) catch
        error.FrameCapacityTooLarge;
}

fn alignForward(value: u32, alignment: u32) u32 {
    std.debug.assert(alignment != 0);
    const remainder = value % alignment;
    if (remainder == 0) return value;
    return value +| (alignment - remainder);
}

/// Backwards-compatible names for backend code that describes Vulkan
/// properties directly.
pub const mesh_thread_count = thread_count;
pub const mesh_workgroup_size = workgroup_size;
pub const mesh_output_vertices = output_vertices;
pub const mesh_output_primitives = output_primitives;
pub const mesh_output_user_components_per_vertex = user_scalar_components_per_vertex;
pub const mesh_output_components_per_vertex = scalar_components_reserved_per_vertex;
pub const mesh_shared_bytes = shared_bytes;
pub const mesh_payload_and_shared_bytes = payload_and_shared_bytes;

test "mesh-only limits match the Slang meshlet stream budget" {
    try std.testing.expectEqual(@as(u32, 8), output_vertices);
    try std.testing.expectEqual(@as(u32, 6), output_primitives);
    try std.testing.expectEqual([3]u32{ 32, 1, 1 }, workgroup_size);
    try std.testing.expectEqual(@as(u32, 1), user_scalar_components_per_vertex);
    try std.testing.expectEqual(@as(u32, 5), scalar_components_written_per_vertex);
    try std.testing.expectEqual(@as(u32, 8), scalar_components_reserved_per_vertex);
    try std.testing.expectEqual(@as(u32, 16), max_subdivisions_per_glyph);
    try std.testing.expectEqual(payload_and_shared_bytes, shared_bytes);
}

test "mesh output memory budget follows Vulkan granularity inputs" {
    try std.testing.expectEqual(@as(u32, 8 * 8 * 4), outputMemoryBytes(1, 1));
    try std.testing.expectEqual(@as(u32, 32 * 8 * 4), outputMemoryBytes(32, 1));
    try std.testing.expectEqual(outputMemoryBytes(32, 1), payloadAndOutputMemoryBytes(32, 1));
}

test "maxMeshletsForGlyphCapacity uses per-glyph subdivision cap" {
    try std.testing.expectEqual(@as(u32, 0), maxMeshletsForGlyphCapacity(0));
    try std.testing.expectEqual(@as(u32, max_subdivisions_per_glyph), maxMeshletsForGlyphCapacity(1));
    try std.testing.expectEqual(@as(u32, 64), maxMeshletsForGlyphCapacity(4));
    try std.testing.expectEqual(@as(u32, 64), try checkedMaxMeshletsForGlyphCapacity(4));
    try std.testing.expectError(error.FrameCapacityTooLarge, checkedMaxMeshletsForGlyphCapacity(std.math.maxInt(u32)));
}
