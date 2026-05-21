//! CPU meshlet planning for the backend-neutral renderer hot path.

const std = @import("std");
const cache_mod = @import("../cache/glyph_cache.zig");
const blob_decode = @import("../blob/decode.zig");
const blob_format = @import("../blob/format.zig");
const core_types = @import("../types.zig");
const mesh_limits = @import("../../gpu/mesh_limits.zig");

const target_meshlet_extent_px: f64 = 96.0;
const no_bounds_min_q: i32 = std.math.maxInt(i32);
const no_bounds_max_q: i32 = std.math.minInt(i32);

pub const MeshletPlan = struct {
    mesh_metadata: cache_mod.MeshMetadata,
    bounds: cache_mod.FixedBounds,
    precision_bits: u8,
    viewport_q: [4]i32,
    dilate_q: [2]i32,
    effective_slices: u32,

    pub fn init(
        glyph: anytype,
        mesh_metadata: cache_mod.MeshMetadata,
        bounds: cache_mod.FixedBounds,
        precision_bits: u8,
        local_from_screen: core_types.Transform,
        view: core_types.View,
        screen_bounds: core_types.Rect,
    ) ?MeshletPlan {
        if (mesh_metadata.curve_count == 0 or mesh_metadata.band_count == 0) return null;

        const visible_extent = visiblePixelExtent(screen_bounds, view);
        const requested_slices = subdivisionCount(visible_extent);
        const effective_slices = @min(requested_slices, mesh_metadata.band_count);
        if (effective_slices == 0) return null;

        return .{
            .mesh_metadata = mesh_metadata,
            .bounds = bounds,
            .precision_bits = precision_bits,
            .viewport_q = viewportLocalBoundsQ(glyph, precision_bits, local_from_screen, view),
            .dilate_q = localPixelDilationQ(glyph, precision_bits),
            .effective_slices = effective_slices,
        };
    }

    pub fn append(self: MeshletPlan, batch: anytype, glyph: anytype, glyph_index: u32) !void {
        const Batch = @typeInfo(@TypeOf(batch)).pointer.child;
        const GlyphMeshlet = Batch.Meshlet;

        var slice_index: u32 = 0;
        while (slice_index < self.effective_slices) : (slice_index += 1) {
            const band_start = @as(u32, @intCast((@as(u64, slice_index) * self.mesh_metadata.band_count) / self.effective_slices));
            const band_end = @as(u32, @intCast((@as(u64, slice_index + 1) * self.mesh_metadata.band_count) / self.effective_slices));
            if (band_end <= band_start) continue;

            const slice = self.bandSliceBounds(band_start, band_end) orelse continue;
            const mesh_anchor_q = [2]i32{
                midpointQ(slice.rect_min_q[0], slice.rect_max_q[0]),
                midpointQ(slice.rect_min_q[1], slice.rect_max_q[1]),
            };
            const mesh_screen_anchor = glyphLocalQToScreenF64(glyph, self.precision_bits, mesh_anchor_q);
            const mesh_screen_anchor_px = castPoint2F32(mesh_screen_anchor) orelse continue;

            const meshlet: GlyphMeshlet = .{
                .glyph_index = glyph_index,
                .rect_min_q = slice.rect_min_q,
                .rect_max_q = slice.rect_max_q,
                .mesh_anchor_q = mesh_anchor_q,
                .screen_anchor_px = mesh_screen_anchor_px,
            };
            try batch.appendMeshlet(meshlet);
        }
    }

    fn bandSliceBounds(self: MeshletPlan, band_start: u32, band_end: u32) ?struct {
        rect_min_q: [2]i32,
        rect_max_q: [2]i32,
    } {
        const center_edge_min_y = bandEdgeQ(self.mesh_metadata.band_min, band_start, self.mesh_metadata.band_height_q);
        const center_edge_max_y = bandEdgeQ(self.mesh_metadata.band_min, band_end, self.mesh_metadata.band_height_q);
        const influence_min_y = saturatingSubQ(center_edge_min_y, self.dilate_q[1]);
        const influence_max_y = saturatingAddQ(center_edge_max_y, self.dilate_q[1]);
        const band_range = self.influenceBandRange(influence_min_y, influence_max_y) orelse return null;

        var candidate_count: u32 = 0;
        var min_x_q = no_bounds_min_q;
        var min_y_q = no_bounds_min_q;
        var max_x_q = no_bounds_max_q;
        var max_y_q = no_bounds_max_q;
        var band_index = band_range.start;
        while (band_index < band_range.end) : (band_index += 1) {
            const info = self.mesh_metadata.bands[band_index];
            if (info.candidate_count == 0) continue;
            candidate_count +|= info.candidate_count;
            min_x_q = @min(min_x_q, info.min_x_q);
            min_y_q = @min(min_y_q, info.min_y_q);
            max_x_q = @max(max_x_q, info.max_x_q);
            max_y_q = @max(max_y_q, info.max_y_q);
        }
        if (candidate_count == 0) return null;
        if (min_x_q == no_bounds_min_q or min_y_q == no_bounds_min_q) return null;

        const support_min_y = saturatingSubQ(min_y_q, self.dilate_q[1]);
        const support_max_y = saturatingAddQ(max_y_q, self.dilate_q[1]);
        const center_min_y = if (band_start == 0)
            support_min_y
        else
            @max(center_edge_min_y, support_min_y);
        const center_max_y = if (band_end == self.mesh_metadata.band_count)
            support_max_y
        else
            @min(center_edge_max_y, support_max_y);
        const y_min_q = @max(center_min_y, saturatingSubQ(self.viewport_q[1], self.dilate_q[1]));
        const y_max_q = @min(center_max_y, saturatingAddQ(self.viewport_q[3], self.dilate_q[1]));

        const rect_min_q = [2]i32{
            @max(saturatingSubQ(min_x_q, self.dilate_q[0]), saturatingSubQ(self.viewport_q[0], self.dilate_q[0])),
            y_min_q,
        };
        const rect_max_q = [2]i32{
            @min(saturatingAddQ(max_x_q, self.dilate_q[0]), saturatingAddQ(self.viewport_q[2], self.dilate_q[0])),
            y_max_q,
        };

        if (rect_max_q[0] <= rect_min_q[0] or rect_max_q[1] <= rect_min_q[1]) return null;
        return .{ .rect_min_q = rect_min_q, .rect_max_q = rect_max_q };
    }

    fn influenceBandRange(self: MeshletPlan, min_y_q: i32, max_y_q: i32) ?struct {
        start: u32,
        end: u32,
    } {
        const first_i64 = @as(i64, @divFloor(min_y_q, self.mesh_metadata.band_height_q)) - @as(i64, self.mesh_metadata.band_min);
        const last_i64 = @as(i64, @divFloor(max_y_q, self.mesh_metadata.band_height_q)) - @as(i64, self.mesh_metadata.band_min);
        if (last_i64 < 0 or first_i64 >= self.mesh_metadata.band_count) return null;

        const start_i64 = @max(first_i64, 0);
        const end_i64 = @min(last_i64 + 1, @as(i64, self.mesh_metadata.band_count));
        if (end_i64 <= start_i64) return null;
        return .{ .start = @intCast(start_i64), .end = @intCast(end_i64) };
    }
};

pub fn metadataFromBlobView(allocator: std.mem.Allocator, view: blob_decode.BlobView) !cache_mod.MeshMetadata {
    const header = view.header;
    if (header.band_count == 0) {
        return .{
            .curve_count = header.curve_count,
            .band_min = header.band_min,
            .band_count = 0,
            .band_height_q = header.band_height_q,
            .bands = &.{},
        };
    }

    const bands = try allocator.alloc(cache_mod.BandMeshInfo, header.band_count);
    errdefer allocator.free(bands);

    for (bands, 0..) |*out, band_index| {
        const band = view.band(@intCast(band_index));
        out.* = cache_mod.BandMeshInfo.empty();
        var i: u32 = 0;
        while (i < band.id_count) : (i += 1) {
            const curve_index = view.curveId(band.id_start + i);
            if (curve_index < header.curve_count) {
                const curve = view.curve(curve_index);
                out.candidate_count +|= 1;
                out.min_x_q = @min(out.min_x_q, curve.bbox_min_x_q);
                out.min_y_q = @min(out.min_y_q, curve.bbox_min_y_q);
                out.max_x_q = @max(out.max_x_q, curve.bbox_max_x_q);
                out.max_y_q = @max(out.max_y_q, curve.bbox_max_y_q);
            }
        }
    }

    return .{
        .curve_count = header.curve_count,
        .band_min = header.band_min,
        .band_count = header.band_count,
        .band_height_q = header.band_height_q,
        .bands = bands,
    };
}

pub fn appendGlyphMeshlets(
    batch: anytype,
    glyph: anytype,
    glyph_index: u32,
    mesh_metadata: cache_mod.MeshMetadata,
    bounds: cache_mod.FixedBounds,
    precision_bits: u8,
    local_from_screen: core_types.Transform,
    view: core_types.View,
    screen_bounds: core_types.Rect,
) !void {
    const plan = MeshletPlan.init(
        glyph,
        mesh_metadata,
        bounds,
        precision_bits,
        local_from_screen,
        view,
        screen_bounds,
    ) orelse return;
    try plan.append(batch, glyph, glyph_index);
}

pub fn localRectFromFixed(bounds: cache_mod.FixedBounds, precision_bits: u8) core_types.Rect {
    return .{
        .x_min = blob_format.dequantize(bounds.x_min, precision_bits),
        .y_min = blob_format.dequantize(bounds.y_min, precision_bits),
        .x_max = blob_format.dequantize(bounds.x_max, precision_bits),
        .y_max = blob_format.dequantize(bounds.y_max, precision_bits),
    };
}

pub fn inflatedViewportRect(view: core_types.View, guard_px: f64) core_types.Rect {
    return .{
        .x_min = -guard_px,
        .y_min = -guard_px,
        .x_max = view.width + guard_px,
        .y_max = view.height + guard_px,
    };
}

pub fn chooseGlyphAnchorQ(
    bounds: cache_mod.FixedBounds,
    precision_bits: u8,
    local_from_screen: core_types.Transform,
    screen_point: [2]f64,
) [2]i32 {
    const local = local_from_screen.apply(screen_point);
    const scale = blob_format.scaleForFractionBits(precision_bits);
    const x_q = quantizeClamp(local[0], scale, bounds.x_min, bounds.x_max);
    const y_q = quantizeClamp(local[1], scale, bounds.y_min, bounds.y_max);
    return .{ x_q, y_q };
}

pub fn localPointFromFixed(point_q: [2]i32, precision_bits: u8) [2]f64 {
    return .{
        blob_format.dequantize(point_q[0], precision_bits),
        blob_format.dequantize(point_q[1], precision_bits),
    };
}

pub fn castPoint2F32(point: [2]f64) ?[2]f32 {
    return .{
        castF32Finite(point[0]) orelse return null,
        castF32Finite(point[1]) orelse return null,
    };
}

pub fn castAffineLinear2x2F32(transform: core_types.Transform) ?[4]f32 {
    return .{
        castF32Finite(transform.xx) orelse return null,
        castF32Finite(transform.xy) orelse return null,
        castF32Finite(transform.yx) orelse return null,
        castF32Finite(transform.yy) orelse return null,
    };
}

pub fn viewportLocalBoundsQ(
    glyph: anytype,
    precision_bits: u8,
    local_from_screen: core_types.Transform,
    view: core_types.View,
) [4]i32 {
    const s0 = [2]f64{ 0.0, 0.0 };
    const s1 = [2]f64{ view.width, 0.0 };
    const s2 = [2]f64{ view.width, view.height };
    const s3 = [2]f64{ 0.0, view.height };

    const min_x = @min(
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 0, false), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 0, false)),
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 0, false), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 0, false)),
    );
    const max_x = @max(
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 0, true), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 0, true)),
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 0, true), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 0, true)),
    );
    const min_y = @min(
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 1, false), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 1, false)),
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 1, false), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 1, false)),
    );
    const max_y = @max(
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 1, true), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 1, true)),
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 1, true), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 1, true)),
    );
    return .{ min_x, min_y, max_x, max_y };
}

fn visiblePixelExtent(screen_bounds: core_types.Rect, view: core_types.View) [2]f64 {
    const min_x = @max(screen_bounds.x_min, 0.0);
    const min_y = @max(screen_bounds.y_min, 0.0);
    const max_x = @min(screen_bounds.x_max, view.width);
    const max_y = @min(screen_bounds.y_max, view.height);
    return .{ @max(max_x - min_x, 0.0), @max(max_y - min_y, 0.0) };
}

fn subdivisionCount(visible_extent: [2]f64) u32 {
    const max_extent = @max(visible_extent[0], visible_extent[1]);
    var count: u32 = @intFromFloat(@ceil(max_extent / target_meshlet_extent_px));
    if (max_extent >= 16.0) count = @max(count, 4);
    return std.math.clamp(count, 1, mesh_limits.max_subdivisions_per_glyph);
}

fn localPixelDilationQ(glyph: anytype, precision_bits: u8) [2]i32 {
    const scale = std.math.ldexp(@as(f64, 1.0), precision_bits);
    const m = glyph.local_from_screen_2x2;
    const radius_x = (@abs(@as(f64, m[0])) + @abs(@as(f64, m[2]))) * 0.5;
    const radius_y = (@abs(@as(f64, m[1])) + @abs(@as(f64, m[3]))) * 0.5;
    return .{
        boundedQFromFloat(radius_x * scale, true),
        boundedQFromFloat(radius_y * scale, true),
    };
}

fn localScreenToQ(
    glyph: anytype,
    precision_bits: u8,
    local_from_screen: core_types.Transform,
    screen: [2]f64,
    axis: u1,
    upper: bool,
) i32 {
    const anchor_screen = [2]f64{
        @floatCast(glyph.screen_anchor_px[0]),
        @floatCast(glyph.screen_anchor_px[1]),
    };
    const local_delta = local_from_screen.applyVector(.{
        screen[0] - anchor_screen[0],
        screen[1] - anchor_screen[1],
    });
    const scale = std.math.ldexp(@as(f64, 1.0), precision_bits);
    const anchor = glyph.glyph_anchor_q[axis];
    const delta_q = boundedQFromFloat(local_delta[axis] * scale, upper);
    return saturatingAddQ(anchor, delta_q);
}

fn glyphLocalQToScreenF64(glyph: anytype, precision_bits: u8, local_q: [2]i32) [2]f64 {
    const inv_scale = std.math.ldexp(@as(f64, 1.0), -@as(i32, precision_bits));
    const dx = @as(f64, @floatFromInt(saturatingSubQ(local_q[0], glyph.glyph_anchor_q[0]))) * inv_scale;
    const dy = @as(f64, @floatFromInt(saturatingSubQ(local_q[1], glyph.glyph_anchor_q[1]))) * inv_scale;
    const m = glyph.screen_from_local_2x2;
    return .{
        @as(f64, glyph.screen_anchor_px[0]) + @as(f64, m[0]) * dx + @as(f64, m[2]) * dy,
        @as(f64, glyph.screen_anchor_px[1]) + @as(f64, m[1]) * dx + @as(f64, m[3]) * dy,
    };
}

fn bandEdgeQ(band_min: i32, band_offset: u32, band_height_q: i32) i32 {
    const band = @as(i64, band_min) + @as(i64, band_offset);
    const product = std.math.mul(i64, band, band_height_q) catch {
        if ((band < 0) == (band_height_q > 0)) return std.math.minInt(i32);
        return std.math.maxInt(i32);
    };
    return clampI64ToI32(product);
}

fn midpointQ(lo: i32, hi: i32) i32 {
    if ((lo < 0) != (hi < 0)) return @intCast(@divTrunc(@as(i64, lo) + @as(i64, hi), 2));
    return lo + @divTrunc(hi - lo, 2);
}

fn boundedQFromFloat(value: f64, upper: bool) i32 {
    if (!std.math.isFinite(value)) {
        return if (upper) std.math.maxInt(i32) else std.math.minInt(i32);
    }
    const rounded = if (upper) @ceil(value) else @floor(value);
    if (rounded <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (rounded >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(rounded);
}

fn saturatingAddQ(a: i32, b: i32) i32 {
    return clampI64ToI32(@as(i64, a) + @as(i64, b));
}

fn saturatingSubQ(a: i32, b: i32) i32 {
    return clampI64ToI32(@as(i64, a) - @as(i64, b));
}

fn clampI64ToI32(value: i64) i32 {
    if (value <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (value >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(value);
}

fn quantizeClamp(value: f64, scale: f64, lo: i32, hi: i32) i32 {
    if (!std.math.isFinite(value)) {
        const midpoint = @as(i64, lo) + @divTrunc(@as(i64, hi) - @as(i64, lo), 2);
        return @intCast(midpoint);
    }
    const q_f = std.math.round(value * scale);
    if (q_f <= @as(f64, @floatFromInt(lo))) return lo;
    if (q_f >= @as(f64, @floatFromInt(hi))) return hi;
    return @intFromFloat(q_f);
}

const max_f32_f64: f64 = 3.4028234663852885981170418348451692544e38;

fn castF32Finite(value: f64) ?f32 {
    if (!std.math.isFinite(value) or @abs(value) > max_f32_f64) return null;
    const out: f32 = @floatCast(value);
    return if (std.math.isFinite(out)) out else null;
}

const TestGlyphInstance = extern struct {
    color: [4]f32 = .{ 0, 0, 0, 0 },
    blob_ref: u32 = 0,
    flags: u32 = 0,
    precision_bits: u32 = 0,
    glyph_anchor_q: [2]i32 = .{ 0, 0 },
    screen_anchor_px: [2]f32 = .{ 0, 0 },
    screen_from_local_2x2: [4]f32 = .{ 1, 0, 0, 1 },
    local_from_screen_2x2: [4]f32 = .{ 1, 0, 0, 1 },
};

const TestGlyphMeshlet = extern struct {
    glyph_index: u32,
    _pad0: u32 = 0,
    rect_min_q: [2]i32,
    rect_max_q: [2]i32,
    mesh_anchor_q: [2]i32,
    screen_anchor_px: [2]f32,
};

test "render mesh plan: viewport local bounds invert screen corners without double translation" {
    const screen_from_local = core_types.Transform.init(2, 0, 0, 4, 100, 200);
    const local_from_screen = screen_from_local.inverse().?;
    const glyph_anchor_q = [2]i32{ 8, -12 };
    const screen_anchor = screen_from_local.apply(.{
        @as(f64, @floatFromInt(glyph_anchor_q[0])),
        @as(f64, @floatFromInt(glyph_anchor_q[1])),
    });

    var glyph = std.mem.zeroes(TestGlyphInstance);
    glyph.precision_bits = 0;
    glyph.glyph_anchor_q = glyph_anchor_q;
    glyph.screen_anchor_px = .{
        @floatCast(screen_anchor[0]),
        @floatCast(screen_anchor[1]),
    };

    const bounds = viewportLocalBoundsQ(
        glyph,
        @intCast(glyph.precision_bits),
        local_from_screen,
        core_types.View.identity(1280, 720),
    );

    try std.testing.expectEqual(@as(i32, -50), bounds[0]);
    try std.testing.expectEqual(@as(i32, -50), bounds[1]);
    try std.testing.expectEqual(@as(i32, 590), bounds[2]);
    try std.testing.expectEqual(@as(i32, 130), bounds[3]);
}

test "render mesh plan: emits bounded strips from cached h-band metadata" {
    const FrameBatch = @import("frame_batch.zig").FrameBatch(TestGlyphInstance, TestGlyphMeshlet);
    var glyphs: [1]TestGlyphInstance = undefined;
    var meshlets: [mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = FrameBatch.init(&glyphs, &meshlets);

    var bands = [_]cache_mod.BandMeshInfo{
        testBand(1, 0, 0, 16, 8),
        cache_mod.BandMeshInfo.empty(),
        testBand(2, 8, 16, 32, 24),
        testBand(1, 8, 24, 32, 32),
    };
    const metadata = cache_mod.MeshMetadata{
        .curve_count = 4,
        .band_min = 0,
        .band_count = @intCast(bands.len),
        .band_height_q = 8,
        .bands = &bands,
    };
    const glyph = TestGlyphInstance{
        .precision_bits = 0,
        .glyph_anchor_q = .{ 0, 0 },
        .screen_anchor_px = .{ 0, 0 },
        .screen_from_local_2x2 = .{ 1, 0, 0, 1 },
        .local_from_screen_2x2 = .{ 1, 0, 0, 1 },
    };

    const glyph_index = try batch.appendGlyph(glyph);
    try appendGlyphMeshlets(
        &batch,
        glyph,
        glyph_index,
        metadata,
        .{ .x_min = 0, .y_min = 0, .x_max = 32, .y_max = 32 },
        0,
        core_types.Transform.identity,
        core_types.View.identity(128, 128),
        core_types.Rect.init(0, 0, 32, 32),
    );

    try std.testing.expect(batch.meshletCount() > 0);
    for (batch.meshletSlice()) |meshlet| {
        try std.testing.expect(meshlet.rect_max_q[0] > meshlet.rect_min_q[0]);
        try std.testing.expect(meshlet.rect_max_q[1] > meshlet.rect_min_q[1]);
        try std.testing.expect(meshlet.glyph_index == glyph_index);
    }
}

test "render mesh plan: includes left pixel support outside glyph bounds" {
    const FrameBatch = @import("frame_batch.zig").FrameBatch(TestGlyphInstance, TestGlyphMeshlet);
    var glyphs: [1]TestGlyphInstance = undefined;
    var meshlets: [mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = FrameBatch.init(&glyphs, &meshlets);

    var bands = [_]cache_mod.BandMeshInfo{
        testBand(1, 0, 0, 1, 1),
    };
    const metadata = cache_mod.MeshMetadata{
        .curve_count = 1,
        .band_min = 0,
        .band_count = @intCast(bands.len),
        .band_height_q = 2,
        .bands = &bands,
    };
    const glyph = TestGlyphInstance{
        .precision_bits = 0,
        .glyph_anchor_q = .{ 0, 0 },
        .screen_anchor_px = .{ 0, 0 },
        .screen_from_local_2x2 = .{ 1, 0, 0, 1 },
        .local_from_screen_2x2 = .{ 1, 0, 0, 1 },
    };

    const glyph_index = try batch.appendGlyph(glyph);
    try appendGlyphMeshlets(
        &batch,
        glyph,
        glyph_index,
        metadata,
        .{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 },
        0,
        core_types.Transform.identity,
        core_types.View.identity(16, 16),
        core_types.Rect.init(0, 0, 1, 1),
    );

    try std.testing.expectEqual(@as(u32, 1), batch.meshletCount());
    try std.testing.expectEqual(@as(i32, -1), batch.meshletSlice()[0].rect_min_q[0]);
}

test "render mesh plan: lower center slice is emitted for upper-band influence" {
    const FrameBatch = @import("frame_batch.zig").FrameBatch(TestGlyphInstance, TestGlyphMeshlet);
    var glyphs: [1]TestGlyphInstance = undefined;
    var meshlets: [mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = FrameBatch.init(&glyphs, &meshlets);

    var bands = [_]cache_mod.BandMeshInfo{
        cache_mod.BandMeshInfo.empty(),
        testBand(1, 9, 4, 10, 5),
    };
    const metadata = cache_mod.MeshMetadata{
        .curve_count = 1,
        .band_min = 0,
        .band_count = @intCast(bands.len),
        .band_height_q = 4,
        .bands = &bands,
    };
    const glyph = TestGlyphInstance{
        .precision_bits = 0,
        .glyph_anchor_q = .{ 0, 0 },
        .screen_anchor_px = .{ 0, 0 },
        .screen_from_local_2x2 = .{ 1, 0, 0, 1 },
        .local_from_screen_2x2 = .{ 1, 0, 0, 1 },
    };

    const glyph_index = try batch.appendGlyph(glyph);
    try appendGlyphMeshlets(
        &batch,
        glyph,
        glyph_index,
        metadata,
        .{ .x_min = 9, .y_min = 4, .x_max = 10, .y_max = 5 },
        0,
        core_types.Transform.identity,
        core_types.View.identity(32, 32),
        core_types.Rect.init(0, 0, 16, 16),
    );

    try std.testing.expect(batch.meshletCount() >= 2);
    const lower = batch.meshletSlice()[0];
    try std.testing.expect(lower.rect_min_q[1] <= 3);
    try std.testing.expect(lower.rect_max_q[1] <= 4);
    try std.testing.expect(lower.rect_min_q[0] <= 8);
    try std.testing.expect(lower.rect_max_q[0] >= 11);
}

fn testBand(candidate_count: u32, min_x_q: i32, min_y_q: i32, max_x_q: i32, max_y_q: i32) cache_mod.BandMeshInfo {
    return .{
        .candidate_count = candidate_count,
        .min_x_q = min_x_q,
        .min_y_q = min_y_q,
        .max_x_q = max_x_q,
        .max_y_q = max_y_q,
    };
}
