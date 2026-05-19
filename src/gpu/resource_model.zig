//! Backend-neutral GPU resource binding contract.

const std = @import("std");

pub const ResourceModel = enum {
    /// One glyph blob storage buffer addressed by byte offsets, plus
    /// per-frame CPU-authored glyph and meshlet streams.
    single_glyph_pool_cpu_meshlets,
};

pub const BufferBinding = enum(u32) {
    glyph_pool = 0,
    glyphs = 1,
    meshlets = 2,
    shader_stats = 3,
};

pub const required_bindings = [_]BufferBinding{
    .glyph_pool,
    .glyphs,
    .meshlets,
};

pub const optional_bindings = [_]BufferBinding{
    .shader_stats,
};

pub fn descriptorBindingCount(comptime shader_stats: bool) u32 {
    return required_bindings.len + @intFromBool(shader_stats);
}

pub fn frameParamsBinding(comptime shader_stats: bool) u32 {
    return if (shader_stats)
        @intFromEnum(BufferBinding.shader_stats) + 1
    else
        @intFromEnum(BufferBinding.shader_stats);
}

pub fn argumentTableBindingCount(comptime shader_stats: bool) u32 {
    return frameParamsBinding(shader_stats) + 1;
}

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
    try std.testing.expectEqual(@as(u32, 3), descriptorBindingCount(false));
    try std.testing.expectEqual(@as(u32, 4), descriptorBindingCount(true));
    try std.testing.expectEqual(@as(u32, 3), frameParamsBinding(false));
    try std.testing.expectEqual(@as(u32, 4), frameParamsBinding(true));
    try std.testing.expectEqual(@as(u32, 4), argumentTableBindingCount(false));
    try std.testing.expectEqual(@as(u32, 5), argumentTableBindingCount(true));
}
