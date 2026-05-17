//! Signed area helper for determining contour orientation.

const std = @import("std");
const regularize = @import("regularize.zig");

const RegularizedCubicSpan = regularize.RegularizedCubicSpan;

pub fn signedArea(spans: []const regularize.RegularizedCubicSpan) f64 {
    var area: f64 = 0.0;
    for (spans) |span| {
        area += cubicSignedArea(span);
    }
    return area;
}

pub fn cubicSignedArea(span: RegularizedCubicSpan) f64 {
    // Exact integral of 0.5 * (x dy - y dx) over a cubic Bezier segment.
    return (6.0 * cross(span.p0, span.p1) +
        3.0 * cross(span.p0, span.p2) +
        cross(span.p0, span.p3) +
        3.0 * cross(span.p1, span.p2) +
        3.0 * cross(span.p1, span.p3) +
        6.0 * cross(span.p2, span.p3)) / 20.0;
}

fn cross(a: regularize.Point, b: regularize.Point) f64 {
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
    try std.testing.expectApproxEqAbs(@as(f64, 1), signedArea(&ccw), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, -1), signedArea(&cw), 1.0e-12);
}

test "area: cubicSignedArea uses exact Bezier integral, not control polygon area" {
    const arch = RegularizedCubicSpan{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = 0, .y = 1 },
        .p2 = .{ .x = 1, .y = 1 },
        .p3 = .{ .x = 1, .y = 0 },
    };

    try std.testing.expectApproxEqAbs(@as(f64, -0.6), cubicSignedArea(arch), 1.0e-12);
}
