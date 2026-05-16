const std = @import("std");
const format = @import("format.zig");
const decode = @import("decode.zig");
const regularize = @import("../outline/regularize.zig");

pub const Cubic = regularize.RegularizedCubicSpan;

pub const Error = error{
    GlyphTooLarge,
    GlyphOffsetOverflow,
    OutOfMemory,
};

const Texel = format.Texel;
const CoverageBlob = format.CoverageBlob;
const header_len = format.header_len;
const curve_texel_len = format.curve_texel_len;
const curve_ids_per_texel = format.curve_ids_per_texel;
const hband_height_q = format.hband_height_units;
const blob_units_per_pixel = format.units_per_pixel;

pub fn curves(allocator: std.mem.Allocator, source_curves: []const Cubic) Error!CoverageBlob {
    if (source_curves.len == 0) return CoverageBlob.empty(allocator);
    if (source_curves.len > std.math.maxInt(i16)) return error.GlyphOffsetOverflow;

    var min_x_f: f64 = std.math.inf(f64);
    var min_y_f: f64 = std.math.inf(f64);
    var max_x_f: f64 = -std.math.inf(f64);
    var max_y_f: f64 = -std.math.inf(f64);

    const quantized_curves = try allocator.alloc(Cubic, source_curves.len);
    defer allocator.free(quantized_curves);

    for (source_curves, 0..) |source_curve, i| {
        const curve = try quantizedCubic(source_curve);
        quantized_curves[i] = curve;
        min_x_f = @min(min_x_f, curve.minX());
        min_y_f = @min(min_y_f, curve.minY());
        max_x_f = @max(max_x_f, curve.maxX());
        max_y_f = @max(max_y_f, curve.maxY());
    }

    const min_x_q = try quantizeDown(min_x_f);
    const min_y_q = try quantizeDown(min_y_f);
    const max_x_q = try quantizeUp(max_x_f);
    const max_y_q = try quantizeUp(max_y_f);

    var hbands = try HBandIndex.init(allocator, quantized_curves, min_y_q, max_y_q);
    defer hbands.deinit(allocator);

    const curve_base: u32 = header_len;
    const band_base = try addU32(curve_base, try mulU32(@intCast(quantized_curves.len), curve_texel_len));
    const id_base = try addU32(band_base, hbands.band_count);
    const id_texel_count = divCeilU32(hbands.id_count, curve_ids_per_texel);
    const total_len = try addU32(id_base, id_texel_count);

    const texels = try allocator.alloc(Texel, total_len);
    errdefer allocator.free(texels);
    @memset(texels, .{ .r = 0, .g = 0, .b = 0, .a = 0 });

    texels[0] = .{ .r = min_x_q, .g = min_y_q, .b = max_x_q, .a = max_y_q };
    texels[1] = .{
        .r = @intCast(quantized_curves.len),
        .g = fillSignCubics(quantized_curves),
        .b = @intCast(hbands.band_min),
        .a = @intCast(hbands.band_count),
    };

    var data_texel: u32 = curve_base;
    for (quantized_curves) |curve| {
        texels[data_texel] = .{
            .r = try quantize(curve.p0.x),
            .g = try quantize(curve.p0.y),
            .b = try quantize(curve.p1.x),
            .a = try quantize(curve.p1.y),
        };
        data_texel += 1;
        texels[data_texel] = .{
            .r = try quantize(curve.p2.x),
            .g = try quantize(curve.p2.y),
            .b = try quantize(curve.p3.x),
            .a = try quantize(curve.p3.y),
        };
        data_texel += 1;
        texels[data_texel] = .{
            .r = try quantizeDown(curve.minX()),
            .g = try quantizeUp(curve.maxX()),
            .b = try quantizeDown(curve.minY()),
            .a = try quantizeUp(curve.maxY()),
        };
        data_texel += 1;
    }

    std.debug.assert(data_texel == band_base);

    for (0..@intCast(hbands.band_count)) |band_i| {
        const start = hbands.band_starts[band_i];
        const count = hbands.band_counts[band_i];
        if (start > std.math.maxInt(i16) or count > std.math.maxInt(i16)) {
            return error.GlyphOffsetOverflow;
        }
        texels[data_texel] = .{
            .r = @intCast(start),
            .g = @intCast(count),
            .b = 0,
            .a = 0,
        };
        data_texel += 1;
    }

    std.debug.assert(data_texel == id_base);

    for (0..@intCast(id_texel_count)) |texel_i| {
        const id_i = texel_i * curve_ids_per_texel;
        texels[data_texel] = .{
            .r = idAtOrZero(hbands.ids, id_i),
            .g = idAtOrZero(hbands.ids, id_i + 1),
            .b = idAtOrZero(hbands.ids, id_i + 2),
            .a = idAtOrZero(hbands.ids, id_i + 3),
        };
        data_texel += 1;
    }

    std.debug.assert(data_texel == total_len);
    return CoverageBlob.init(allocator, texels);
}

const HBandIndex = struct {
    band_min: i32,
    band_count: u32,
    id_count: u32,
    band_starts: []u32,
    band_counts: []u32,
    ids: []i16,

    fn init(
        allocator: std.mem.Allocator,
        curve_spans: []const Cubic,
        min_y_q: i16,
        max_y_q: i16,
    ) Error!HBandIndex {
        const band_min = bandIndex(min_y_q);
        const band_max = bandIndex(max_y_q);
        const band_count_i32 = band_max - band_min + 1;
        if (band_count_i32 <= 0 or band_count_i32 > std.math.maxInt(i16)) {
            return error.GlyphOffsetOverflow;
        }
        const band_count: u32 = @intCast(band_count_i32);

        const band_counts = try allocator.alloc(u32, band_count);
        errdefer allocator.free(band_counts);
        @memset(band_counts, 0);

        for (curve_spans) |curve| {
            const range = try curveBandRange(curve, band_min);
            for (range.lo..range.hi + 1) |band_i| {
                band_counts[band_i] += 1;
            }
        }

        const band_starts = try allocator.alloc(u32, band_count);
        errdefer allocator.free(band_starts);

        var id_count: u32 = 0;
        for (band_counts, 0..) |count, i| {
            band_starts[i] = id_count;
            id_count = try addU32(id_count, count);
        }
        if (id_count > std.math.maxInt(i16)) return error.GlyphOffsetOverflow;

        const ids = try allocator.alloc(i16, id_count);
        errdefer allocator.free(ids);

        const cursors = try allocator.dupe(u32, band_starts);
        defer allocator.free(cursors);

        for (curve_spans, 0..) |curve, curve_i| {
            const range = try curveBandRange(curve, band_min);
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

fn curveBandRange(curve: Cubic, band_min: i32) Error!struct { lo: usize, hi: usize } {
    const min_y = try quantizeDown(curve.minY());
    const max_y = try quantizeUp(curve.maxY());
    const lo_i32 = bandIndex(min_y) - band_min;
    const hi_i32 = bandIndex(max_y) - band_min;
    if (lo_i32 < 0 or hi_i32 < lo_i32) return error.GlyphOffsetOverflow;
    return .{ .lo = @intCast(lo_i32), .hi = @intCast(hi_i32) };
}

fn bandIndex(y_q: i16) i32 {
    return @divFloor(@as(i32, y_q), @as(i32, hband_height_q));
}

fn divCeilU32(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

fn idAtOrZero(ids: []const i16, index: usize) i16 {
    return if (index < ids.len) ids[index] else 0;
}

fn quantizedCubic(curve: Cubic) Error!Cubic {
    return .{
        .p0 = try quantizedPoint(curve.p0),
        .p1 = try quantizedPoint(curve.p1),
        .p2 = try quantizedPoint(curve.p2),
        .p3 = try quantizedPoint(curve.p3),
    };
}

fn quantizedPoint(point: regularize.Point) Error!regularize.Point {
    return .{
        .x = dequantize(try quantize(point.x)),
        .y = dequantize(try quantize(point.y)),
    };
}

fn quantize(v: f64) Error!i16 {
    return quantized(std.math.round(v * blob_units_per_pixel));
}

fn quantizeDown(v: f64) Error!i16 {
    return quantized(@floor(v * blob_units_per_pixel));
}

fn quantizeUp(v: f64) Error!i16 {
    return quantized(@ceil(v * blob_units_per_pixel));
}

fn quantized(v: f64) Error!i16 {
    if (!std.math.isFinite(v) or v < std.math.minInt(i16) or v > std.math.maxInt(i16)) {
        return error.GlyphTooLarge;
    }
    return @intFromFloat(v);
}

fn dequantize(v: i16) f64 {
    return @as(f64, @floatFromInt(v)) / blob_units_per_pixel;
}

fn fillSignCubics(curve_spans: []const Cubic) i16 {
    const area = signedAreaCubics(curve_spans);
    return if (area < 0) -1 else 1;
}

fn signedAreaCubics(curve_spans: []const Cubic) f64 {
    var area: f64 = 0;
    for (curve_spans) |curve| area += cubicSignedArea(curve);
    return area;
}

fn cubicSignedArea(curve: Cubic) f64 {
    const mid: f64 = 0.5;
    const half: f64 = 0.5;
    const root: f64 = 0.7745966692414834;
    return half * (5.0 / 9.0 * greenIntegrand(curve, mid - half * root) +
        8.0 / 9.0 * greenIntegrand(curve, mid) +
        5.0 / 9.0 * greenIntegrand(curve, mid + half * root));
}

fn greenIntegrand(curve: Cubic, t: f64) f64 {
    const p = cubicPoint(curve, t);
    const d = cubicDerivative(curve, t);
    return 0.5 * (p.x * d.y - p.y * d.x);
}

fn cubicPoint(curve: Cubic, t: f64) regularize.Point {
    const a = lerpPoint(curve.p0, curve.p1, t);
    const b = lerpPoint(curve.p1, curve.p2, t);
    const c = lerpPoint(curve.p2, curve.p3, t);
    const d = lerpPoint(a, b, t);
    const e = lerpPoint(b, c, t);
    return lerpPoint(d, e, t);
}

fn cubicDerivative(curve: Cubic, t: f64) regularize.Point {
    const u = 1.0 - t;
    return .{
        .x = 3.0 * (u * u * (curve.p1.x - curve.p0.x) +
            2.0 * u * t * (curve.p2.x - curve.p1.x) +
            t * t * (curve.p3.x - curve.p2.x)),
        .y = 3.0 * (u * u * (curve.p1.y - curve.p0.y) +
            2.0 * u * t * (curve.p2.y - curve.p1.y) +
            t * t * (curve.p3.y - curve.p2.y)),
    };
}

fn lerpPoint(a: regularize.Point, b: regularize.Point, t: f64) regularize.Point {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
    };
}

fn addU32(a: u32, b: u32) Error!u32 {
    return std.math.add(u32, a, b) catch error.GlyphOffsetOverflow;
}

fn mulU32(a: u32, b: u32) Error!u32 {
    return std.math.mul(u32, a, b) catch error.GlyphOffsetOverflow;
}

test "blob encode: curves round trip through CoverageBlob decoder" {
    const source = [_]Cubic{
        .{
            .p0 = .{ .x = 0, .y = 0 },
            .p1 = .{ .x = 1, .y = 2 },
            .p2 = .{ .x = 3, .y = 2 },
            .p3 = .{ .x = 4, .y = 0 },
        },
    };

    var blob = try curves(std.testing.allocator, &source);
    defer blob.deinit();

    const view = try decode.BlobView.initCoverageBlob(blob);
    try std.testing.expectEqual(@as(u32, 1), view.header.curveCount());
    try std.testing.expectEqual(@as(usize, format.curve_texel_len), view.curveTexels(0).len);
}

test "blob encode: writes h-band candidate index after curves" {
    const source = [_]Cubic{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }),
        regularize.lineAsCubic(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }),
    };

    var blob = try curves(std.testing.allocator, &source);
    defer blob.deinit();

    const texels = blob.texels;
    const curve_count: usize = @intCast(texels[1].r);
    const curve_base: usize = header_len;
    const band_min = texels[1].b;
    const band_count: usize = @intCast(texels[1].a);
    const band_base = curve_base + curve_count * curve_texel_len;
    const id_base = band_base + band_count;

    try std.testing.expectEqual(@as(i16, 0), band_min);
    try std.testing.expectEqual(@as(usize, 1), band_count);
    try std.testing.expectEqual(curve_base + source.len * curve_texel_len, band_base);

    const band = texels[band_base];
    try std.testing.expectEqual(@as(i16, 0), band.r);
    try std.testing.expectEqual(@as(i16, 2), band.g);

    const ids = texels[id_base];
    try std.testing.expectEqual(@as(i16, 0), ids.r);
    try std.testing.expectEqual(@as(i16, 1), ids.g);
}

test "blob encode: stores glyph fill direction in header" {
    const ccw = [_]Cubic{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 0, .y = 2 }, .{ .x = 0, .y = 0 }),
    };
    const cw = [_]Cubic{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 }),
        regularize.lineAsCubic(.{ .x = 2, .y = 0 }, .{ .x = 0, .y = 0 }),
    };

    var ccw_blob = try curves(std.testing.allocator, &ccw);
    defer ccw_blob.deinit();
    var cw_blob = try curves(std.testing.allocator, &cw);
    defer cw_blob.deinit();

    try std.testing.expectEqual(@as(i16, 1), ccw_blob.texels[1].g);
    try std.testing.expectEqual(@as(i16, -1), cw_blob.texels[1].g);
}
