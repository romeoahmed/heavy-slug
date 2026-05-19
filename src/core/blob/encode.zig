//! Encode regularized cubic spans into the explicit GPU coverage blob ABI.

const std = @import("std");
const format = @import("format.zig");
const decode = @import("decode.zig");
const regularize = @import("../outline/regularize.zig");
const outline_area = @import("../outline/area.zig");

const RegularizedCubicSpan = regularize.RegularizedCubicSpan;

pub const Error = error{
    GlyphTooLarge,
    GlyphOffsetOverflow,
    PrecisionUnsupported,
    OutOfMemory,
};

const CoverageBlob = format.CoverageBlob;

/// Quantizes cubics, writes their bounds, and builds the h-band candidate table.
pub fn curves(
    allocator: std.mem.Allocator,
    source_curves: []const RegularizedCubicSpan,
    fraction_bits: u8,
) Error!CoverageBlob {
    try format.validateFractionBits(fraction_bits);
    if (source_curves.len == 0) return CoverageBlob.empty(allocator);
    if (source_curves.len > std.math.maxInt(u32)) return error.GlyphOffsetOverflow;

    const quantized_curves = try allocator.alloc(format.Curve, source_curves.len);
    defer allocator.free(quantized_curves);

    var bounds = QuantizedBounds.empty();
    for (source_curves, 0..) |source_curve, i| {
        const curve = try quantizedCubic(source_curve, fraction_bits);
        quantized_curves[i] = curve;
        bounds.includeCurve(curve);
    }

    const band_height_q = format.hbandHeightQ(fraction_bits);
    var candidates = try CandidateIndex.init(
        allocator,
        quantized_curves,
        bounds.min_y,
        bounds.max_y,
        band_height_q,
    );
    defer candidates.deinit(allocator);

    const layout = format.Layout.init(
        @intCast(quantized_curves.len),
        candidates.band_count,
        candidates.id_count,
    ) catch return error.GlyphOffsetOverflow;

    const words = try allocator.alloc(u32, layout.word_count);
    errdefer allocator.free(words);
    @memset(words, 0);

    format.writeHeader(words, .{
        .magic_version = format.magic_version,
        .fraction_bits = fraction_bits,
        .flags = format.flags_none,
        .fill_sign = fillSignCubics(source_curves),
        .curve_count = @intCast(quantized_curves.len),
        .band_min = candidates.band_min,
        .band_count = candidates.band_count,
        .band_height_q = band_height_q,
        .id_count = candidates.id_count,
        .word_count = layout.word_count,
        .bounds_min_x_q = bounds.min_x,
        .bounds_min_y_q = bounds.min_y,
        .bounds_max_x_q = bounds.max_x,
        .bounds_max_y_q = bounds.max_y,
        .curve_base_words = layout.curve_base_words,
        .band_base_words = layout.band_base_words,
        .id_base_words = layout.id_base_words,
    });

    var word_offset = layout.curve_base_words;
    for (quantized_curves) |curve| {
        format.writeCurve(words, word_offset, curve);
        word_offset += format.curve_word_len;
    }
    std.debug.assert(word_offset == layout.band_base_words);

    for (0..candidates.band_count) |band_i| {
        format.writeBand(words, word_offset, .{
            .id_start = candidates.band_starts[band_i],
            .id_count = candidates.band_counts[band_i],
        });
        word_offset += format.band_word_len;
    }
    std.debug.assert(word_offset == layout.id_base_words);

    for (candidates.ids) |id| {
        words[word_offset] = id;
        word_offset += 1;
    }
    std.debug.assert(word_offset == layout.word_count);

    return CoverageBlob.init(allocator, words);
}

const QuantizedBounds = struct {
    min_x: i32,
    min_y: i32,
    max_x: i32,
    max_y: i32,

    fn empty() QuantizedBounds {
        return .{
            .min_x = std.math.maxInt(i32),
            .min_y = std.math.maxInt(i32),
            .max_x = std.math.minInt(i32),
            .max_y = std.math.minInt(i32),
        };
    }

    fn includeCurve(self: *QuantizedBounds, curve: format.Curve) void {
        self.min_x = @min(self.min_x, curve.bbox_min_x_q);
        self.min_y = @min(self.min_y, curve.bbox_min_y_q);
        self.max_x = @max(self.max_x, curve.bbox_max_x_q);
        self.max_y = @max(self.max_y, curve.bbox_max_y_q);
    }
};

/// A compressed sparse row table from y-band to sorted curve ids.
const CandidateIndex = struct {
    band_min: i32,
    band_count: u32,
    id_count: u32,
    band_starts: []u32,
    band_counts: []u32,
    ids: []u32,

    fn init(
        allocator: std.mem.Allocator,
        curves_q: []const format.Curve,
        min_y_q: i32,
        max_y_q: i32,
        band_height_q: i32,
    ) Error!CandidateIndex {
        std.debug.assert(curves_q.len > 0);
        std.debug.assert(band_height_q > 0);

        const band_min = bandIndex(min_y_q, band_height_q);
        const band_max = bandIndex(max_y_q, band_height_q);
        const band_count_i64 = @as(i64, band_max) - @as(i64, band_min) + 1;
        if (band_count_i64 <= 0 or band_count_i64 > std.math.maxInt(u32)) {
            return error.GlyphOffsetOverflow;
        }
        const band_count: u32 = @intCast(band_count_i64);

        const band_counts = try allocator.alloc(u32, band_count);
        errdefer allocator.free(band_counts);
        @memset(band_counts, 0);

        for (curves_q) |curve| {
            const range = try curveBandRange(curve, band_min, band_height_q);
            var band_i = range.lo;
            while (band_i <= range.hi) : (band_i += 1) {
                band_counts[band_i] = try addU32(band_counts[band_i], 1);
            }
        }

        const band_starts = try allocator.alloc(u32, band_count);
        errdefer allocator.free(band_starts);

        var id_count: u32 = 0;
        for (band_counts, 0..) |count, i| {
            band_starts[i] = id_count;
            id_count = try addU32(id_count, count);
        }

        const ids = try allocator.alloc(u32, id_count);
        errdefer allocator.free(ids);

        const cursors = try allocator.dupe(u32, band_starts);
        defer allocator.free(cursors);

        for (curves_q, 0..) |curve, curve_i| {
            if (curve_i > std.math.maxInt(u32)) return error.GlyphOffsetOverflow;
            const curve_id: u32 = @intCast(curve_i);
            const range = try curveBandRange(curve, band_min, band_height_q);
            var band_i = range.lo;
            while (band_i <= range.hi) : (band_i += 1) {
                const id_i = cursors[band_i];
                ids[id_i] = curve_id;
                cursors[band_i] += 1;
            }
        }

        return .{
            .band_min = band_min,
            .band_count = band_count,
            .id_count = id_count,
            .band_starts = band_starts,
            .band_counts = band_counts,
            .ids = ids,
        };
    }

    fn deinit(self: *CandidateIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.band_starts);
        allocator.free(self.band_counts);
        allocator.free(self.ids);
        self.* = undefined;
    }
};

fn curveBandRange(curve: format.Curve, band_min: i32, band_height_q: i32) Error!struct { lo: usize, hi: usize } {
    const lo_i64 = @as(i64, bandIndex(curve.bbox_min_y_q, band_height_q)) - band_min;
    const hi_i64 = @as(i64, bandIndex(curve.bbox_max_y_q, band_height_q)) - band_min;
    if (lo_i64 < 0 or hi_i64 < lo_i64 or hi_i64 > std.math.maxInt(u32)) {
        return error.GlyphOffsetOverflow;
    }
    return .{ .lo = @intCast(lo_i64), .hi = @intCast(hi_i64) };
}

fn bandIndex(y_q: i32, band_height_q: i32) i32 {
    return @divFloor(y_q, band_height_q);
}

fn quantizedCubic(curve: RegularizedCubicSpan, fraction_bits: u8) Error!format.Curve {
    const p0_x = try quantizeNearest(curve.p0.x, fraction_bits);
    const p0_y = try quantizeNearest(curve.p0.y, fraction_bits);
    const p1_x = try quantizeNearest(curve.p1.x, fraction_bits);
    const p1_y = try quantizeNearest(curve.p1.y, fraction_bits);
    const p2_x = try quantizeNearest(curve.p2.x, fraction_bits);
    const p2_y = try quantizeNearest(curve.p2.y, fraction_bits);
    const p3_x = try quantizeNearest(curve.p3.x, fraction_bits);
    const p3_y = try quantizeNearest(curve.p3.y, fraction_bits);
    return .{
        .p0_x_q = p0_x,
        .p0_y_q = p0_y,
        .p1_x_q = p1_x,
        .p1_y_q = p1_y,
        .p2_x_q = p2_x,
        .p2_y_q = p2_y,
        .p3_x_q = p3_x,
        .p3_y_q = p3_y,
        .bbox_min_x_q = try quantizeOutward(curve.minX(), fraction_bits, .lower),
        .bbox_min_y_q = try quantizeOutward(curve.minY(), fraction_bits, .lower),
        .bbox_max_x_q = try quantizeOutward(curve.maxX(), fraction_bits, .upper),
        .bbox_max_y_q = try quantizeOutward(curve.maxY(), fraction_bits, .upper),
    };
}

const BoundDirection = enum { lower, upper };

fn quantizeNearest(value: f64, fraction_bits: u8) Error!i32 {
    return quantized(std.math.round(value * format.scaleForFractionBits(fraction_bits)));
}

fn quantizeOutward(value: f64, fraction_bits: u8, direction: BoundDirection) Error!i32 {
    const scaled = value * format.scaleForFractionBits(fraction_bits);
    const rounded = switch (direction) {
        .lower => @floor(scaled),
        .upper => @ceil(scaled),
    };
    return quantized(rounded);
}

fn quantized(value: f64) Error!i32 {
    if (!std.math.isFinite(value) or
        value < @as(f64, @floatFromInt(std.math.minInt(i32))) or
        value > @as(f64, @floatFromInt(std.math.maxInt(i32))))
    {
        return error.GlyphTooLarge;
    }
    return @intFromFloat(value);
}

fn fillSignCubics(curve_spans: []const RegularizedCubicSpan) i32 {
    const area = outline_area.signedArea(curve_spans);
    return if (area < 0) -1 else 1;
}

fn addU32(a: u32, b: u32) Error!u32 {
    return std.math.add(u32, a, b) catch error.GlyphOffsetOverflow;
}

test "blob encode: curves round trip through CoverageBlob decoder" {
    const source = [_]RegularizedCubicSpan{
        .{
            .p0 = .{ .x = 0, .y = 0 },
            .p1 = .{ .x = 1, .y = 2 },
            .p2 = .{ .x = 3, .y = 2 },
            .p3 = .{ .x = 4, .y = 0 },
        },
    };

    var blob = try curves(std.testing.allocator, &source, format.default_fraction_bits);
    defer blob.deinit();

    const view = try decode.BlobView.initCoverageBlob(blob);
    try std.testing.expectEqual(@as(u32, 1), view.header.curveCount());
    try std.testing.expectEqual(format.default_fraction_bits, @as(u8, @intCast(view.header.fraction_bits)));
    try std.testing.expectEqual(@as(i32, 0), view.curve(0).p0_x_q);
}

test "blob encode: empty curve list produces empty blob after precision validation" {
    var blob = try curves(std.testing.allocator, &.{}, format.default_fraction_bits);
    defer blob.deinit();

    try std.testing.expectEqual(@as(usize, 0), blob.words.len);
    try std.testing.expectEqual(@as(usize, 0), blob.len());
    try std.testing.expectError(error.PrecisionUnsupported, curves(std.testing.allocator, &.{}, format.max_fraction_bits + 1));
}

test "blob encode: writes CSR h-band candidate index after curves" {
    const source = [_]RegularizedCubicSpan{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }),
        regularize.lineAsCubic(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }),
    };

    var blob = try curves(std.testing.allocator, &source, format.default_fraction_bits);
    defer blob.deinit();

    const view = try decode.BlobView.initCoverageBlob(blob);
    try std.testing.expectEqual(@as(i32, 0), view.header.band_min);
    try std.testing.expectEqual(@as(u32, 1), view.header.band_count);

    const band = view.band(0);
    try std.testing.expectEqual(@as(u32, 0), band.id_start);
    try std.testing.expectEqual(@as(u32, 2), band.id_count);
    try std.testing.expectEqual(@as(u32, 0), view.curveId(0));
    try std.testing.expectEqual(@as(u32, 1), view.curveId(1));
}

test "blob encode: stores glyph fill direction in header" {
    const ccw = [_]RegularizedCubicSpan{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 0, .y = 2 }, .{ .x = 0, .y = 0 }),
    };
    const cw = [_]RegularizedCubicSpan{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 0 }, .{ .x = 0, .y = 0 }),
    };

    var ccw_blob = try curves(std.testing.allocator, &ccw, format.default_fraction_bits);
    defer ccw_blob.deinit();
    var cw_blob = try curves(std.testing.allocator, &cw, format.default_fraction_bits);
    defer cw_blob.deinit();

    const ccw_view = try decode.BlobView.initCoverageBlob(ccw_blob);
    const cw_view = try decode.BlobView.initCoverageBlob(cw_blob);
    try std.testing.expectEqual(@as(i32, 1), ccw_view.header.fill_sign);
    try std.testing.expectEqual(@as(i32, -1), cw_view.header.fill_sign);
}

test "blob encode: rejects unsupported precision and i32 overflow" {
    const source = [_]RegularizedCubicSpan{regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 })};
    try std.testing.expectError(error.PrecisionUnsupported, curves(std.testing.allocator, &source, 30));

    const huge = [_]RegularizedCubicSpan{regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 1.0e12, .y = 1 })};
    try std.testing.expectError(error.GlyphTooLarge, curves(std.testing.allocator, &huge, format.default_fraction_bits));
}

test "blob encode: outward rounding covers source extrema" {
    const source = [_]RegularizedCubicSpan{.{
        .p0 = .{ .x = 0.1, .y = 0.1 },
        .p1 = .{ .x = 1.2, .y = 2.3 },
        .p2 = .{ .x = 3.4, .y = 2.5 },
        .p3 = .{ .x = 4.6, .y = -0.2 },
    }};
    var blob = try curves(std.testing.allocator, &source, 12);
    defer blob.deinit();
    const view = try decode.BlobView.initCoverageBlob(blob);
    const scale = format.scaleForFractionBits(12);
    try std.testing.expect(@as(f64, @floatFromInt(view.header.bounds_min_x_q)) / scale <= 0.1);
    try std.testing.expect(@as(f64, @floatFromInt(view.header.bounds_min_y_q)) / scale <= -0.2);
    try std.testing.expect(@as(f64, @floatFromInt(view.header.bounds_max_x_q)) / scale >= 4.6);
    try std.testing.expect(@as(f64, @floatFromInt(view.header.bounds_max_y_q)) / scale >= 2.5);
}
