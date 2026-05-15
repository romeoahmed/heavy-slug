const outline_encode = @import("../outline/encode.zig");
const hb = @import("../font/harfbuzz.zig");
const std = @import("std");
const decode = @import("decode.zig");
const format = @import("format.zig");

pub const Cubic = outline_encode.Cubic;
pub const Error = outline_encode.Error;

pub fn curves(allocator: @import("std").mem.Allocator, source_curves: []const Cubic) Error!hb.Blob {
    return outline_encode.encodeCurves(allocator, source_curves);
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

    const blob = try curves(std.testing.allocator, &source);
    defer blob.destroy();

    const view = try decode.BlobView.init(blob.getData());
    try std.testing.expectEqual(@as(u32, 1), view.header.curveCount());
    try std.testing.expectEqual(@as(usize, format.curve_texel_len), view.curveTexels(0).len);
}
