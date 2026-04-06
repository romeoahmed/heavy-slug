const std = @import("std");
const vk = @import("vulkan");

/// Per-glyph draw command uploaded to GPU each frame (spec §10.1).
/// 64 bytes, tightly packed for storage buffer access.
pub const GlyphCommand = extern struct {
    motor: [4]f32,           // offset  0: PGA Motor [s, e12, e01, e02]
    color: [4]f32,           // offset 16: RGBA
    em_x_min: f32,           // offset 32
    em_y_min: f32,           // offset 36
    em_x_max: f32,           // offset 40
    em_y_max: f32,           // offset 44
    descriptor_index: u32,   // offset 48: index into glyph_blobs[] descriptor array
    flags: u32,              // offset 52: bit 0 = even-odd fill (0 = nonzero winding)
    _pad: [2]u32 = .{ 0, 0 }, // offset 56: align to 64 bytes
};

comptime {
    std.debug.assert(@sizeOf(GlyphCommand) == 64);
    std.debug.assert(@offsetOf(GlyphCommand, "motor") == 0);
    std.debug.assert(@offsetOf(GlyphCommand, "color") == 16);
    std.debug.assert(@offsetOf(GlyphCommand, "em_x_min") == 32);
    std.debug.assert(@offsetOf(GlyphCommand, "em_y_min") == 36);
    std.debug.assert(@offsetOf(GlyphCommand, "em_x_max") == 40);
    std.debug.assert(@offsetOf(GlyphCommand, "em_y_max") == 44);
    std.debug.assert(@offsetOf(GlyphCommand, "descriptor_index") == 48);
    std.debug.assert(@offsetOf(GlyphCommand, "flags") == 52);
    std.debug.assert(@offsetOf(GlyphCommand, "_pad") == 56);
}

test "GlyphCommand is 64 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(GlyphCommand));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(GlyphCommand, "descriptor_index"));
}

/// Per-frame push constants (spec §6.3). 80 bytes, within Vulkan's
/// guaranteed 128-byte minimum push constant range.
pub const PushConstants = extern struct {
    proj: [4][4]f32,        // offset  0: column-major projection matrix
    viewport_dim: [2]f32,   // offset 64: viewport width, height in pixels
    glyph_count: u32,       // offset 72: number of glyphs this frame
    _pad: u32 = 0,          // offset 76: align to 80 bytes
};

comptime {
    std.debug.assert(@sizeOf(PushConstants) == 80);
    std.debug.assert(@offsetOf(PushConstants, "proj") == 0);
    std.debug.assert(@offsetOf(PushConstants, "viewport_dim") == 64);
    std.debug.assert(@offsetOf(PushConstants, "glyph_count") == 72);
    std.debug.assert(@offsetOf(PushConstants, "_pad") == 76);
}

test "PushConstants is 80 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(PushConstants));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(PushConstants, "glyph_count"));
}
