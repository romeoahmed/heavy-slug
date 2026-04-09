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

test "integration: multiple texts through same FontContext" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    var ctx = try glyph.FontContext.init(ft_lib, test_font_path, 24);
    defer ctx.deinit();

    const texts = [_][]const u8{ "Hello", "World", "Zig" };

    for (texts) |text| {
        const buf = try ctx.shapeText(text, null, null);
        defer buf.destroy();

        try std.testing.expect(buf.getLength() > 0);

        // Encode first glyph from each pass to verify gpu_draw reset
        const infos = buf.getGlyphInfos();
        const encoded = try ctx.encodeGlyph(infos[0].codepoint);
        defer encoded.destroy();
        try std.testing.expect(encoded.data.len > 0);
    }
}

test "integration: cache eviction reclaims pool space" {
    var pa = pool.PoolAllocator.init(std.testing.allocator, 1024, 256);
    defer pa.deinit();

    // cold_capacity=2, no hot slots
    var gc = try cache.GlyphCache.init(std.testing.allocator, 0, 2, 3);
    defer gc.deinit();

    const dummy_box = cache.EmBox{ .x_min = 0, .y_min = 0, .x_max = 64, .y_max = 64 };

    // Fill cold cache with pool-backed allocations
    const alloc_a = pa.alloc(100).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 1 }, 0, alloc_a, dummy_box);

    const alloc_b = pa.alloc(100).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 2 }, 1, alloc_b, dummy_box);

    // Cold is full -- evict LRU (alloc_a was inserted first)
    const evicted = gc.evictLru().?;
    try std.testing.expectEqual(alloc_a.offset, evicted.pool_alloc.offset);
    pa.free(evicted.pool_alloc);

    // Pool space is reusable -- new alloc should reclaim the freed offset
    const recycled = pa.alloc(100).?;
    try std.testing.expectEqual(alloc_a.offset, recycled.offset);
}

test "integration: cold-to-hot promotion preserves pool allocation" {
    var pa = pool.PoolAllocator.init(std.testing.allocator, 4096, 256);
    defer pa.deinit();

    var gc = try cache.GlyphCache.init(std.testing.allocator, 4, 4, 2);
    defer gc.deinit();

    const dummy_box = cache.EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const alloc = pa.alloc(200).?;
    const key = cache.CacheKey{ .font_id = 1, .glyph_id = 42 };
    try gc.insertCold(key, 0, alloc, dummy_box);

    // Use for 2 consecutive frames to trigger promotion (promote_frames=2)
    gc.advanceFrame();
    _ = gc.lookup(key);
    gc.advanceFrame();
    _ = gc.lookup(key);
    gc.advanceFrame(); // promotion happens here

    // Verify promoted: no cold entries left to evict
    try std.testing.expectEqual(@as(?cache.EvictedEntry, null), gc.evictLru());
    try std.testing.expectEqual(@as(u32, 1), gc.hot_count);
    try std.testing.expectEqual(@as(u32, 0), gc.cold_count);

    // Pool allocation is unchanged after promotion
    const entry = gc.lookup(key).?;
    try std.testing.expectEqual(alloc.offset, entry.pool_alloc.offset);
    try std.testing.expectEqual(alloc.size, entry.pool_alloc.size);
}

test "integration: removeFont reclaims all pool and cache resources" {
    var pa = pool.PoolAllocator.init(std.testing.allocator, 4096, 256);
    defer pa.deinit();

    var gc = try cache.GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer gc.deinit();

    const dummy_box = cache.EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };

    // Font 1: one hot + two cold entries
    const alloc_1a = pa.alloc(128).?;
    try gc.insertHot(.{ .font_id = 1, .glyph_id = 65 }, 0, alloc_1a, dummy_box);
    const alloc_1b = pa.alloc(128).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 66 }, 1, alloc_1b, dummy_box);
    const alloc_1c = pa.alloc(128).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 67 }, 2, alloc_1c, dummy_box);

    // Font 2: one cold entry
    const alloc_2 = pa.alloc(128).?;
    try gc.insertCold(.{ .font_id = 2, .glyph_id = 65 }, 3, alloc_2, dummy_box);

    try std.testing.expectEqual(@as(u32, 4), gc.count());

    // Remove font 1 -- returns 3 evicted entries
    const evicted = try gc.removeFont(std.testing.allocator, 1);
    defer std.testing.allocator.free(evicted);

    try std.testing.expectEqual(@as(usize, 3), evicted.len);
    for (evicted) |e| pa.free(e.pool_alloc);

    // Only font 2 remains
    try std.testing.expectEqual(@as(u32, 1), gc.count());
    try std.testing.expect(gc.lookup(.{ .font_id = 2, .glyph_id = 65 }) != null);

    // Pool space from font 1 is reusable
    const recycled = pa.alloc(128).?;
    const recycled_matches = for (evicted) |e| {
        if (recycled.offset == e.pool_alloc.offset) break true;
    } else false;
    try std.testing.expect(recycled_matches);
}

test "integration: motor positions shaped glyphs monotonically" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    var ctx = try glyph.FontContext.init(ft_lib, test_font_path, 24);
    defer ctx.deinit();

    const buf = try ctx.shapeText("Hello World", null, null);
    defer buf.destroy();

    const positions = buf.getGlyphPositions();

    // Position glyphs using motors (mirrors renderer's drawText logic)
    const base = pga.Motor.fromTranslation(100.0, 200.0);
    var pen_x: f32 = 0;
    var prev_x: f32 = -std.math.inf(f32);

    for (positions) |pos| {
        const gx = pen_x + @as(f32, @floatFromInt(pos.x_offset));
        const gy: f32 = @floatFromInt(pos.y_offset);
        const glyph_motor = base.composeTranslation(gx, gy);

        const origin = glyph_motor.apply(.{ 0, 0 });

        // Each glyph should be to the right of the previous (LTR)
        try std.testing.expect(origin[0] > prev_x);
        prev_x = origin[0];

        pen_x += @as(f32, @floatFromInt(pos.x_advance));
    }
}
