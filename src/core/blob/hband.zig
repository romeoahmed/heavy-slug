//! CPU helpers for reading a blob's horizontal-band candidate index.

const std = @import("std");
const format = @import("format.zig");
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

pub fn heightInBlobUnits(_: decode.BlobView) i32 {
    return format.hband_height_units;
}

pub fn readBand(view: decode.BlobView, band_index: u32) ?Band {
    if (band_index >= count(view)) return null;
    const base: usize = @intCast(view.header.bandBase());
    const texel = view.texels[base + band_index];
    return .{
        .id_start = @intCast(@max(texel.r, 0)),
        .id_count = @intCast(@max(texel.g, 0)),
    };
}

pub fn readCurveId(view: decode.BlobView, id_index: u32) u32 {
    const id_base: usize = @intCast(view.header.idBase());
    const texel = view.texels[id_base + id_index / format.curve_ids_per_texel];
    const lane = id_index % format.curve_ids_per_texel;
    const value = switch (lane) {
        0 => texel.r,
        1 => texel.g,
        2 => texel.b,
        else => texel.a,
    };
    return @intCast(@max(value, 0));
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

test "hband: reads packed candidate ids" {
    const texels = [_]format.Texel{
        .{ .r = 0, .g = 0, .b = 16, .a = 16 },
        .{ .r = 0, .g = 1, .b = 0, .a = 1 },
        .{ .r = 0, .g = 2, .b = 0, .a = 0 },
        .{ .r = 7, .g = 9, .b = 0, .a = 0 },
    };
    const view = try decode.BlobView.init(std.mem.sliceAsBytes(&texels));
    const ids = try candidateIds(std.testing.allocator, view, 0);
    defer std.testing.allocator.free(ids);
    try std.testing.expectEqualSlices(u32, &.{ 7, 9 }, ids);
}
