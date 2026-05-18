//! Encode regularized cubic spans into the GPU coverage blob format.

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
    if (source_curves.len == 0) return CoverageBlob.empty(allocator);
    if (fraction_bits < format.min_fraction_bits or fraction_bits > format.max_fraction_bits) {
        return error.PrecisionUnsupported;
    }
    if (source_curves.len > std.math.maxInt(u32)) return error.GlyphOffsetOverflow;

    const quantized_curves = try allocator.alloc(format.Curve, source_curves.len);
    defer allocator.free(quantized_curves);

    var min_x_q: i32 = std.math.maxInt(i32);
    var min_y_q: i32 = std.math.maxInt(i32);
    var max_x_q: i32 = std.math.minInt(i32);
    var max_y_q: i32 = std.math.minInt(i32);

    for (source_curves, 0..) |source_curve, i| {
        const curve = try quantizedCubic(source_curve, fraction_bits);
        quantized_curves[i] = curve;
        min_x_q = @min(min_x_q, curve.bbox_min_x_q);
        min_y_q = @min(min_y_q, curve.bbox_min_y_q);
        max_x_q = @max(max_x_q, curve.bbox_max_x_q);
        max_y_q = @max(max_y_q, curve.bbox_max_y_q);
    }

    const band_height_q = format.hbandHeightQ(fraction_bits);
    var hbands = try HBandIndex.init(allocator, quantized_curves, min_y_q, max_y_q, band_height_q);
    defer hbands.deinit(allocator);

    const curve_base = format.header_word_len;
    const band_base = try addMulU32(curve_base, @intCast(quantized_curves.len), format.curve_word_len);
    const id_base = try addMulU32(band_base, hbands.band_count, format.band_word_len);
    const total_words = try addU32(id_base, hbands.id_count);

    const words = try allocator.alloc(u32, total_words);
    errdefer allocator.free(words);
    @memset(words, 0);

    const header = format.Header{
        .magic_version = format.magic_version,
        .fraction_bits = fraction_bits,
        .flags = format.flags_none,
        .fill_sign = fillSignCubics(source_curves),
        .curve_count = @intCast(quantized_curves.len),
        .band_min = hbands.band_min,
        .band_count = hbands.band_count,
        .band_height_q = band_height_q,
        .id_count = hbands.id_count,
        .word_count = total_words,
        .bounds_min_x_q = min_x_q,
        .bounds_min_y_q = min_y_q,
        .bounds_max_x_q = max_x_q,
        .bounds_max_y_q = max_y_q,
        .curve_base_words = curve_base,
        .band_base_words = band_base,
        .id_base_words = id_base,
    };
    writeValue(words, 0, header);

    var word_offset = curve_base;
    for (quantized_curves) |curve| {
        writeValue(words, word_offset, curve);
        word_offset += format.curve_word_len;
    }
    std.debug.assert(word_offset == band_base);

    for (0..hbands.band_count) |band_i| {
        writeValue(words, word_offset, format.Band{
            .id_start = hbands.band_starts[band_i],
            .id_count = hbands.band_counts[band_i],
        });
        word_offset += format.band_word_len;
    }
    std.debug.assert(word_offset == id_base);

    for (hbands.ids) |id| {
        words[word_offset] = id;
        word_offset += 1;
    }
    std.debug.assert(word_offset == total_words);

    return CoverageBlob.init(allocator, words);
}

const HBandIndex = struct {
    band_min: i32,
    band_count: u32,
    id_count: u32,
    band_starts: []u32,
    band_counts: []u32,
    ids: []u32,

    fn init(
        allocator: std.mem.Allocator,
        curve_spans: []const format.Curve,
        min_y_q: i32,
        max_y_q: i32,
        band_height_q: i32,
    ) Error!HBandIndex {
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

        for (curve_spans) |curve| {
            const range = try curveBandRange(curve, band_min, band_height_q);
            for (range.lo..range.hi + 1) |band_i| {
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

        for (curve_spans, 0..) |curve, curve_i| {
            if (curve_i > std.math.maxInt(u32)) return error.GlyphOffsetOverflow;
            const range = try curveBandRange(curve, band_min, band_height_q);
            for (range.lo..range.hi + 1) |band_i| {
                const id_i = cursors[band_i];
                ids[id_i] = @intCast(curve_i);
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

    fn deinit(self: *HBandIndex, allocator: std.mem.Allocator) void {
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
    const p0_x = try quantize(curve.p0.x, fraction_bits);
    const p0_y = try quantize(curve.p0.y, fraction_bits);
    const p1_x = try quantize(curve.p1.x, fraction_bits);
    const p1_y = try quantize(curve.p1.y, fraction_bits);
    const p2_x = try quantize(curve.p2.x, fraction_bits);
    const p2_y = try quantize(curve.p2.y, fraction_bits);
    const p3_x = try quantize(curve.p3.x, fraction_bits);
    const p3_y = try quantize(curve.p3.y, fraction_bits);
    return .{
        .p0_x_q = p0_x,
        .p0_y_q = p0_y,
        .p1_x_q = p1_x,
        .p1_y_q = p1_y,
        .p2_x_q = p2_x,
        .p2_y_q = p2_y,
        .p3_x_q = p3_x,
        .p3_y_q = p3_y,
        .bbox_min_x_q = try quantizeDown(curve.minX(), fraction_bits),
        .bbox_min_y_q = try quantizeDown(curve.minY(), fraction_bits),
        .bbox_max_x_q = try quantizeUp(curve.maxX(), fraction_bits),
        .bbox_max_y_q = try quantizeUp(curve.maxY(), fraction_bits),
    };
}

fn quantize(v: f64, fraction_bits: u8) Error!i32 {
    return quantized(std.math.round(v * format.scaleForFractionBits(fraction_bits)));
}

fn quantizeDown(v: f64, fraction_bits: u8) Error!i32 {
    return quantized(@floor(v * format.scaleForFractionBits(fraction_bits)));
}

fn quantizeUp(v: f64, fraction_bits: u8) Error!i32 {
    return quantized(@ceil(v * format.scaleForFractionBits(fraction_bits)));
}

fn quantized(v: f64) Error!i32 {
    if (!std.math.isFinite(v) or v < std.math.minInt(i32) or v > std.math.maxInt(i32)) {
        return error.GlyphTooLarge;
    }
    return @intFromFloat(v);
}

fn fillSignCubics(curve_spans: []const RegularizedCubicSpan) i32 {
    const area = outline_area.signedArea(curve_spans);
    return if (area < 0) -1 else 1;
}

fn writeValue(words: []u32, word_offset: u32, value: anytype) void {
    const start = @as(usize, word_offset) * @sizeOf(u32);
    const bytes = std.mem.sliceAsBytes(words);
    @memcpy(bytes[start..][0..@sizeOf(@TypeOf(value))], std.mem.asBytes(&value));
}

fn addU32(a: u32, b: u32) Error!u32 {
    return std.math.add(u32, a, b) catch error.GlyphOffsetOverflow;
}

fn addMulU32(a: u32, b: u32, c: u32) Error!u32 {
    const product = std.math.mul(u32, b, c) catch return error.GlyphOffsetOverflow;
    return addU32(a, product);
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

test "blob encode: empty curve list produces empty blob" {
    var blob = try curves(std.testing.allocator, &.{}, format.default_fraction_bits);
    defer blob.deinit();

    try std.testing.expectEqual(@as(usize, 0), blob.words.len);
    try std.testing.expectEqual(@as(usize, 0), blob.len());
}

test "blob encode: writes h-band candidate index after curves" {
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
