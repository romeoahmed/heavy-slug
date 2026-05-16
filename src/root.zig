//! heavy_slug core API: font shaping, glyph encoding, and math.

const std = @import("std");
pub const core = @import("core/root.zig");
pub const gpu = @import("gpu/root.zig");

const pga = @import("math/pga.zig");

pub const FontHandle = core.FontHandle;
pub const Color = core.Color;
pub const Transform = core.Transform;
pub const Viewport = core.Viewport;
pub const Projection = core.Projection;
pub const FillRule = core.FillRule;
pub const FontSource = core.FontSource;
pub const FontOptions = core.FontOptions;
pub const GlyphKey = core.GlyphKey;
pub const RendererOptions = core.RendererOptions;
pub const TextRun = core.TextRun;
pub const FrameToken = core.FrameToken;
pub const ShaderStats = gpu.ShaderStats;

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";
const font = core.font;

test {
    _ = core;
    _ = pga;
    _ = gpu;
}

test "integration: shape text and encode all unique glyphs" {
    var system = try font.FontSystem.init(std.testing.allocator);
    defer system.deinit();

    var loaded = try system.load(.{ .path = test_font_path }, .{ .size_px = 32 });
    defer loaded.deinit();

    var shape_plan = try font.ShapePlan.init();
    defer shape_plan.deinit();

    const shaped = try loaded.shape(shape_plan, "Heavy Slug", .{});
    const infos = shaped.infos;
    const positions = shaped.positions;
    try std.testing.expect(infos.len > 0);
    try std.testing.expectEqual(infos.len, positions.len);

    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();

    for (infos) |info| {
        if (seen.contains(info.codepoint)) continue;
        try seen.put(info.codepoint, {});

        const encoded = try loaded.encodeGlyph(info.codepoint);
        defer encoded.destroy();

        if (encoded.data.len > 0) {
            try std.testing.expect(encoded.extents.width != 0);
        }
    }

    var total_advance: i32 = 0;
    for (positions) |pos| total_advance += pos.x_advance;
    try std.testing.expect(total_advance > 0);
}
