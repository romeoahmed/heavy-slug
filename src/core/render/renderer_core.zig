const types = @import("../types.zig");

pub const RendererOptions = struct {
    max_glyph_descriptors: u32 = 65_536,
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    min_storage_alignment: u32 = 256,
};

pub const TextRun = struct {
    font: types.FontHandle,
    text: []const u8,
    transform: types.Transform = .identity,
    color: types.Color = .black,
    fill_rule: types.FillRule = .non_zero,
};

test "RendererOptions mirrors current default capacities" {
    const opts = RendererOptions{};
    try @import("std").testing.expectEqual(@as(u32, 65_536), opts.max_glyph_descriptors);
    try @import("std").testing.expectEqual(@as(u32, 16_384), opts.max_glyphs_per_frame);
}
