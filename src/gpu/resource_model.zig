//! Backend-neutral GPU resource binding contract.

const std = @import("std");

pub const ResourceModel = enum {
    /// One glyph blob storage buffer addressed by byte offsets, plus
    /// per-frame CPU-authored glyph and meshlet streams.
    single_glyph_pool_cpu_meshlets,
};

/// Buffer binding indices shared by both backends. Vulkan uses these as the
/// descriptor `binding` numbers in set 0; Metal uses them directly as
/// `[[buffer(N)]]` argument-table slots. The `frame_params` slot is pinned
/// to 4 on Metal via an explicit `register(b4)` in
/// `shaders/backend_metal/resources.slang`, so the slot is stable whether
/// the optional `shader_stats` RW buffer at slot 3 is compiled in or not.
pub const BufferBinding = enum(u32) {
    glyph_pool = 0,
    glyphs = 1,
    meshlets = 2,
    shader_stats = 3,
    frame_params = 4,
};

pub const required_bindings = [_]BufferBinding{
    .glyph_pool,
    .glyphs,
    .meshlets,
};

pub const optional_bindings = [_]BufferBinding{
    .shader_stats,
};

pub const frame_params_binding: u32 = @intFromEnum(BufferBinding.frame_params);

pub fn descriptorBindingCount(comptime shader_stats: bool) u32 {
    return required_bindings.len + @intFromBool(shader_stats);
}

/// Maximum buffer-binding slot used by the Metal argument table. Stable
/// across `shader_stats` because `frame_params` is pinned at slot 4.
pub const argument_table_bind_count: u32 = @intFromEnum(BufferBinding.frame_params) + 1;

pub const max_descriptor_binding_count = descriptorBindingCount(true);

test "ResourceModel names the current glyph and meshlet resource strategy" {
    try std.testing.expectEqual(
        @as(u1, 0),
        @intFromEnum(ResourceModel.single_glyph_pool_cpu_meshlets),
    );
}

test "buffer bindings are stable across Vulkan and Metal paths" {
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(BufferBinding.glyph_pool));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(BufferBinding.glyphs));
    try std.testing.expectEqual(@as(u32, 2), @intFromEnum(BufferBinding.meshlets));
    try std.testing.expectEqual(@as(u32, 3), @intFromEnum(BufferBinding.shader_stats));
    try std.testing.expectEqual(@as(u32, 4), @intFromEnum(BufferBinding.frame_params));
    try std.testing.expectEqual(@as(u32, 3), descriptorBindingCount(false));
    try std.testing.expectEqual(@as(u32, 4), descriptorBindingCount(true));
    try std.testing.expectEqual(@as(u32, 4), frame_params_binding);
    try std.testing.expectEqual(@as(u32, 5), argument_table_bind_count);
}
