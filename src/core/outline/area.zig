//! Signed area helper for determining contour orientation.

const std = @import("std");
const regularize = @import("regularize.zig");

pub fn signedArea(spans: []const regularize.RegularizedCubicSpan) f64 {
    var area: f64 = 0.0;
    for (spans) |span| {
        area += lineIntegral(span.p0, span.p1);
        area += lineIntegral(span.p1, span.p2);
        area += lineIntegral(span.p2, span.p3);
    }
    return area * 0.5;
}

fn lineIntegral(a: regularize.Point, b: regularize.Point) f64 {
    return a.x * b.y - b.x * a.y;
}

test "area: signed area distinguishes contour direction" {
    const ccw = [_]regularize.RegularizedCubicSpan{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 0 }),
        regularize.lineAsCubic(.{ .x = 1, .y = 0 }, .{ .x = 1, .y = 1 }),
        regularize.lineAsCubic(.{ .x = 1, .y = 1 }, .{ .x = 0, .y = 1 }),
        regularize.lineAsCubic(.{ .x = 0, .y = 1 }, .{ .x = 0, .y = 0 }),
    };
    const cw = [_]regularize.RegularizedCubicSpan{
        regularize.lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 1 }),
        regularize.lineAsCubic(.{ .x = 0, .y = 1 }, .{ .x = 1, .y = 1 }),
        regularize.lineAsCubic(.{ .x = 1, .y = 1 }, .{ .x = 1, .y = 0 }),
        regularize.lineAsCubic(.{ .x = 1, .y = 0 }, .{ .x = 0, .y = 0 }),
    };

    try std.testing.expect(signedArea(&ccw) > 0);
    try std.testing.expect(signedArea(&cw) < 0);
}
