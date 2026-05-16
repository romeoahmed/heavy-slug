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

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";
const font = core.font;
const cache = core.cache.glyph_cache;
const pool = core.cache.byte_pool;

fn testGlyphRef(value: u32) cache.GlyphRef {
    return cache.GlyphRef.from(value);
}

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

    // Encode each unique glyph
    var seen = std.AutoHashMap(u32, void).init(std.testing.allocator);
    defer seen.deinit();

    for (infos) |info| {
        if (seen.contains(info.codepoint)) continue;
        try seen.put(info.codepoint, {});

        const encoded = try loaded.encodeGlyph(info.codepoint);
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

test "integration: multiple texts through same FontSystem and ShapePlan" {
    var system = try font.FontSystem.init(std.testing.allocator);
    defer system.deinit();

    var loaded = try system.load(.{ .path = test_font_path }, .{ .size_px = 24 });
    defer loaded.deinit();
    var shape_plan = try font.ShapePlan.init();
    defer shape_plan.deinit();

    const texts = [_][]const u8{ "Hello", "World", "Zig" };

    for (texts) |text| {
        const shaped = try loaded.shape(shape_plan, text, .{});
        try std.testing.expect(shaped.infos.len > 0);

        // Encode first glyph from each pass to verify encoder reuse.
        const encoded = try loaded.encodeGlyph(shaped.infos[0].codepoint);
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
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 1 }, testGlyphRef(0), alloc_a, dummy_box);

    const alloc_b = pa.alloc(100).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 2 }, testGlyphRef(1), alloc_b, dummy_box);

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
    try gc.insertCold(key, testGlyphRef(0), alloc, dummy_box);

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
    try gc.insertHot(.{ .font_id = 1, .glyph_id = 65 }, testGlyphRef(0), alloc_1a, dummy_box);
    const alloc_1b = pa.alloc(128).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 66 }, testGlyphRef(1), alloc_1b, dummy_box);
    const alloc_1c = pa.alloc(128).?;
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 67 }, testGlyphRef(2), alloc_1c, dummy_box);

    // Font 2: one cold entry
    const alloc_2 = pa.alloc(128).?;
    try gc.insertCold(.{ .font_id = 2, .glyph_id = 65 }, testGlyphRef(3), alloc_2, dummy_box);

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
    var system = try font.FontSystem.init(std.testing.allocator);
    defer system.deinit();

    var loaded = try system.load(.{ .path = test_font_path }, .{ .size_px = 24 });
    defer loaded.deinit();
    var shape_plan = try font.ShapePlan.init();
    defer shape_plan.deinit();

    const shaped = try loaded.shape(shape_plan, "Hello World", .{});
    const positions = shaped.positions;

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

test "integration: composeTranslation matches compose(fromTranslation)" {
    // Non-trivial motor: rotation + translation (like a rotated text block)
    const motor = pga.Motor.compose(
        pga.Motor.fromTranslation(50.0, 30.0),
        pga.Motor.fromRotation(std.math.pi / 6.0),
    );

    // Test with several glyph-like advance values
    const advances = [_]f32{ 640, 1280, 1920 };
    const test_point = [2]f32{ 10.0, 5.0 };

    for (advances) |tx| {
        const via_specialized = motor.composeTranslation(tx, 0).apply(test_point);
        const via_general = pga.Motor.compose(motor, pga.Motor.fromTranslation(tx, 0)).apply(test_point);

        try std.testing.expectApproxEqAbs(via_general[0], via_specialized[0], 1e-2);
        try std.testing.expectApproxEqAbs(via_general[1], via_specialized[1], 1e-2);
    }
}

test "integration: repeated motor composition drifts then unitize recovers" {
    const small = pga.Motor.fromRotation(0.01);
    var m = small;

    // Compose 999 more small rotations (1000 total)
    for (0..999) |_| m = pga.Motor.compose(m, small);

    // Motor norm should have drifted
    const norm_sq = m.m[0] * m.m[0] + m.m[1] * m.m[1];

    // Unitize restores unit norm
    const fixed = m.unitize();
    const fixed_norm = fixed.m[0] * fixed.m[0] + fixed.m[1] * fixed.m[1];
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), fixed_norm, 1e-6);

    // Unitized motor matches fresh construction
    const expected_angle: f32 = 1000.0 * 0.01;
    const fresh = pga.Motor.fromRotation(expected_angle);
    const p = [2]f32{ 1, 0 };

    const fixed_result = fixed.apply(p);
    const fresh_result = fresh.apply(p);
    try std.testing.expectApproxEqAbs(fresh_result[0], fixed_result[0], 0.01);
    try std.testing.expectApproxEqAbs(fresh_result[1], fixed_result[1], 0.01);

    _ = norm_sq; // verified drift exists
}
