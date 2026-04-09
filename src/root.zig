//! heavy_slug — GPU text rendering library.

const std = @import("std");
const ft = @import("font/ft.zig");
const hb = @import("font/hb.zig");
const glyph = @import("font/glyph.zig");
pub const pga = @import("math/pga.zig");
pub const gpu_context = @import("gpu/context.zig");
const descriptors = @import("gpu/descriptors.zig");
const pool = @import("gpu/pool.zig");
const cache = @import("gpu/cache.zig");
const pipeline = @import("gpu/pipeline.zig");
pub const renderer = @import("gpu/renderer.zig");

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test {
    _ = ft;
    _ = hb;
    _ = glyph;
    _ = pga;
    _ = gpu_context;
    _ = descriptors;
    _ = pool;
    _ = cache;
    _ = pipeline;
    _ = renderer;
}

test "integration: shape text and encode all unique glyphs" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    var ctx = try glyph.FontContext.init(ft_lib, test_font_path, 32);
    defer ctx.deinit();

    const buf = try ctx.shapeText("Heavy Slug", null, null);
    defer buf.destroy();

    const infos = buf.getGlyphInfos();
    const positions = buf.getGlyphPositions();
    try std.testing.expect(infos.len > 0);
    try std.testing.expectEqual(infos.len, positions.len);

    // Encode each unique glyph
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();

    for (infos) |info| {
        if (seen.contains(info.codepoint)) continue;
        try seen.put(info.codepoint, {});

        const encoded = try ctx.encodeGlyph(info.codepoint);
        defer encoded.destroy();

        // Visible glyphs produce non-empty blobs with non-zero extents
        if (encoded.data.len > 0) {
            try std.testing.expect(encoded.extents.width != 0);
        }
    }

    // Total pen advance should be positive (LTR text)
    var total_advance: i32 = 0;
    for (positions) |pos| total_advance += pos.x_advance;
    try std.testing.expect(total_advance > 0);
}
