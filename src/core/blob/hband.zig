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
    return @divFloor(y_q, band_height_q);
}

pub fn anchoredBandIndex(anchor_q: i32, delta_q: i32, band_height_q: i32) i32 {
    const k = bandIndex(anchor_q, band_height_q);
    const r = anchor_q - k * band_height_q;
    return k + bandIndex(r + delta_q, band_height_q);
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
    const band_base = format.header_word_len + curve_count * format.curve_word_len;
    const id_base = band_base + format.band_word_len;
    const total_words = id_base + 2;
    const words = try std.testing.allocator.alloc(u32, total_words);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = format.Header{
        .magic_version = format.magic_version,
        .fraction_bits = format.default_fraction_bits,
        .flags = 0,
        .fill_sign = 1,
        .curve_count = curve_count,
        .band_min = 0,
        .band_count = 1,
        .band_height_q = format.hbandHeightQ(format.default_fraction_bits),
        .id_count = 2,
        .word_count = total_words,
        .bounds_min_x_q = 0,
        .bounds_min_y_q = 0,
        .bounds_max_x_q = 0,
        .bounds_max_y_q = 0,
        .curve_base_words = format.header_word_len,
        .band_base_words = band_base,
        .id_base_words = id_base,
    };
    @memcpy(std.mem.sliceAsBytes(words)[0..@sizeOf(format.Header)], std.mem.asBytes(&header));

    const band = format.Band{ .id_start = 0, .id_count = 2 };
    const band_off = @as(usize, band_base) * @sizeOf(u32);
    @memcpy(std.mem.sliceAsBytes(words)[band_off..][0..@sizeOf(format.Band)], std.mem.asBytes(&band));
    words[id_base] = 7;
    words[id_base + 1] = 9;

    const view = try decode.BlobView.init(std.mem.sliceAsBytes(words));
    const ids = try candidateIds(std.testing.allocator, view, 0);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, ids);
}
