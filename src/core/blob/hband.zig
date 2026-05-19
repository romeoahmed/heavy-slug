//! CPU helpers for reading a blob's horizontal-band candidate index.

const std = @import("std");
const decode = @import("decode.zig");

pub const Band = struct {
    id_start: u32,
    id_count: u32,
};

pub fn count(view: decode.BlobView) u32 {
    return view.header.bandCount();
}

pub fn minBand(view: decode.BlobView) i32 {
    return view.header.bandMin();
}

pub fn heightInBlobUnits(view: decode.BlobView) i32 {
    return view.header.band_height_q;
}

pub fn bandIndex(y_q: i32, band_height_q: i32) i32 {
    std.debug.assert(band_height_q > 0);
    return @divFloor(y_q, band_height_q);
}

pub fn anchoredBandIndex(anchor_q: i32, delta_q: i32, band_height_q: i32) i32 {
    const k = bandIndex(anchor_q, band_height_q);
    const r64 = @as(i64, anchor_q) - @as(i64, k) * @as(i64, band_height_q);
    const r: i32 = @intCast(r64);
    return saturatingAddI32(k, bandIndex(saturatingAddI32(r, delta_q), band_height_q));
}

pub fn readBand(view: decode.BlobView, band_index: u32) ?Band {
    if (band_index >= count(view)) return null;
    const band = view.band(band_index);
    return .{ .id_start = band.id_start, .id_count = band.id_count };
}

pub fn readCurveId(view: decode.BlobView, id_index: u32) u32 {
    return view.curveId(id_index);
}

pub fn candidateIds(
    allocator: std.mem.Allocator,
    view: decode.BlobView,
    band_index: u32,
) ![]u32 {
    const band = readBand(view, band_index) orelse return &.{};
    const ids = try allocator.alloc(u32, band.id_count);
    errdefer allocator.free(ids);
    for (ids, 0..) |*id, i| {
        id.* = readCurveId(view, band.id_start + @as(u32, @intCast(i)));
    }
    return ids;
}

fn saturatingAddI32(a: i32, b: i32) i32 {
    const sum = @as(i64, a) + @as(i64, b);
    if (sum <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (sum >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(sum);
}

test "hband: anchored band lookup matches absolute floor division" {
    const h = 16;
    const anchors = [_]i32{ -33, -16, -1, 0, 1, 15, 16, 33 };
    const deltas = [_]i32{ -40, -17, -1, 0, 1, 17, 40 };
    for (anchors) |anchor| {
        for (deltas) |delta| {
            try std.testing.expectEqual(
                bandIndex(anchor + delta, h),
                anchoredBandIndex(anchor, delta, h),
            );
        }
    }
}

test "hband: reads candidate ids" {
    const format = @import("format.zig");
    const curve_count = 10;
    const layout = try format.Layout.init(curve_count, 1, 2);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = format.Header{
        .protocol_magic = format.protocol_magic,
        .protocol_version = format.protocol_version_word,
        .fraction_bits = format.default_fraction_bits,
        .flags = 0,
        .fill_sign = 1,
        .curve_count = curve_count,
        .band_min = 0,
        .band_count = 1,
        .band_height_q = format.hbandHeightQ(format.default_fraction_bits),
        .id_count = 2,
        .word_count = layout.word_count,
        .bounds_min_x_q = 0,
        .bounds_min_y_q = 0,
        .bounds_max_x_q = 9,
        .bounds_max_y_q = 9,
        .curve_base_words = layout.curve_base_words,
        .band_base_words = layout.band_base_words,
        .id_base_words = layout.id_base_words,
    };
    format.writeHeader(words, header);

    var curve_index: u32 = 0;
    while (curve_index < curve_count) : (curve_index += 1) {
        format.writeCurve(words, header.curve_base_words + curve_index * format.curve_word_len, .{
            .p0_x_q = @intCast(curve_index),
            .p0_y_q = 0,
            .p1_x_q = @intCast(curve_index),
            .p1_y_q = 1,
            .p2_x_q = @intCast(curve_index),
            .p2_y_q = 2,
            .p3_x_q = @intCast(curve_index),
            .p3_y_q = 3,
            .bbox_min_x_q = @intCast(curve_index),
            .bbox_min_y_q = 0,
            .bbox_max_x_q = @intCast(curve_index),
            .bbox_max_y_q = 3,
        });
    }

    const band = format.Band{ .id_start = 0, .id_count = 2 };
    format.writeBand(words, header.band_base_words, band);
    words[header.id_base_words] = 7;
    words[header.id_base_words + 1] = 9;

    const view = try decode.BlobView.init(std.mem.sliceAsBytes(words));
    const ids = try candidateIds(std.testing.allocator, view, 0);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, ids);
}
