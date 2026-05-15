const std = @import("std");
const stream = @import("stream.zig");

pub const Point = stream.Point;

pub const CubicSpan = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
};

pub fn lineAsCubic(p0: Point, p1: Point) CubicSpan {
    return .{
        .p0 = p0,
        .p1 = lerpPoint(p0, p1, 1.0 / 3.0),
        .p2 = lerpPoint(p0, p1, 2.0 / 3.0),
        .p3 = p1,
    };
}

pub fn quadAsCubic(p0: Point, control: Point, p1: Point) CubicSpan {
    return .{
        .p0 = p0,
        .p1 = .{
            .x = p0.x + (2.0 / 3.0) * (control.x - p0.x),
            .y = p0.y + (2.0 / 3.0) * (control.y - p0.y),
        },
        .p2 = .{
            .x = p1.x + (2.0 / 3.0) * (control.x - p1.x),
            .y = p1.y + (2.0 / 3.0) * (control.y - p1.y),
        },
        .p3 = p1,
    };
}

pub fn appendRegularized(out: *std.ArrayList(CubicSpan), allocator: std.mem.Allocator, outline: []const stream.Segment) !void {
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var open = false;

    for (outline) |segment| {
        switch (segment) {
            .move_to => |p| {
                if (open and !samePoint(current, start)) {
                    try out.append(allocator, lineAsCubic(current, start));
                }
                current = p;
                start = p;
                open = true;
            },
            .line_to => |p| {
                if (!open) {
                    start = current;
                    open = true;
                }
                if (!samePoint(current, p)) try out.append(allocator, lineAsCubic(current, p));
                current = p;
            },
            .quad_to => |q| {
                if (!open) {
                    start = current;
                    open = true;
                }
                if (!samePoint(current, q.to)) try out.append(allocator, quadAsCubic(current, q.control, q.to));
                current = q.to;
            },
            .cubic_to => |c| {
                if (!open) {
                    start = current;
                    open = true;
                }
                if (!samePoint(current, c.to)) {
                    try out.append(allocator, .{ .p0 = current, .p1 = c.control1, .p2 = c.control2, .p3 = c.to });
                }
                current = c.to;
            },
            .close => {
                if (open and !samePoint(current, start)) {
                    try out.append(allocator, lineAsCubic(current, start));
                }
                open = false;
            },
        }
    }

    if (open and !samePoint(current, start)) {
        try out.append(allocator, lineAsCubic(current, start));
    }
}

fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn lerpPoint(a: Point, b: Point, t: f64) Point {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
    };
}

test "regularize raises lines and quadratics into cubic spans" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.lineTo(.{ .x = 3, .y = 0 });
    try outline.quadTo(.{ .x = 6, .y = 3 }, .{ .x = 9, .y = 0 });

    var spans: std.ArrayList(CubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items);

    try std.testing.expectEqual(@as(usize, 3), spans.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), spans.items[0].p1.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5), spans.items[1].p1.x, 1.0e-9);
}
