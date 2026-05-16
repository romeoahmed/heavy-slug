const std = @import("std");
const stream = @import("stream.zig");
const blob_format = @import("../blob/format.zig");

pub const Error = error{
    GlyphTooLarge,
    OutOfMemory,
};

pub const Point = stream.Point;

pub const RegularizedCubicSpan = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,

    pub fn minX(self: RegularizedCubicSpan) f64 {
        return @min(@min(self.p0.x, self.p1.x), @min(self.p2.x, self.p3.x));
    }

    pub fn maxX(self: RegularizedCubicSpan) f64 {
        return @max(@max(self.p0.x, self.p1.x), @max(self.p2.x, self.p3.x));
    }

    pub fn minY(self: RegularizedCubicSpan) f64 {
        return @min(@min(self.p0.y, self.p1.y), @min(self.p2.y, self.p3.y));
    }

    pub fn maxY(self: RegularizedCubicSpan) f64 {
        return @max(@max(self.p0.y, self.p1.y), @max(self.p2.y, self.p3.y));
    }
};

const max_cubic_prepare_depth = 8;
const blob_units_per_pixel = blob_format.units_per_pixel;

pub fn lineAsCubic(p0: Point, p1: Point) RegularizedCubicSpan {
    return .{
        .p0 = p0,
        .p1 = lerpPoint(p0, p1, 1.0 / 3.0),
        .p2 = lerpPoint(p0, p1, 2.0 / 3.0),
        .p3 = p1,
    };
}

pub fn quadAsCubic(p0: Point, control: Point, p1: Point) RegularizedCubicSpan {
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

pub fn appendRegularized(
    out: *std.ArrayList(RegularizedCubicSpan),
    allocator: std.mem.Allocator,
    outline: []const stream.Segment,
) Error!void {
    var current = Point{ .x = 0, .y = 0 };
    var start = current;
    var open = false;

    for (outline) |segment| {
        switch (segment) {
            .move_to => |p| {
                if (open and !samePoint(current, start)) {
                    try appendPrepared(out, allocator, lineAsCubic(current, start), 0);
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
                if (!samePoint(current, p)) try appendPrepared(out, allocator, lineAsCubic(current, p), 0);
                current = p;
            },
            .quad_to => |q| {
                if (!open) {
                    start = current;
                    open = true;
                }
                if (!samePoint(current, q.to)) try appendSplitCubic(out, allocator, quadAsCubic(current, q.control, q.to));
                current = q.to;
            },
            .cubic_to => |c| {
                if (!open) {
                    start = current;
                    open = true;
                }
                if (!samePoint(current, c.to) or !samePoint(c.control1, c.to) or !samePoint(c.control2, c.to)) {
                    try appendSplitCubic(out, allocator, .{ .p0 = current, .p1 = c.control1, .p2 = c.control2, .p3 = c.to });
                }
                current = c.to;
            },
            .close => {
                if (open and !samePoint(current, start)) {
                    try appendPrepared(out, allocator, lineAsCubic(current, start), 0);
                }
                open = false;
            },
        }
    }

    if (open and !samePoint(current, start)) {
        try appendPrepared(out, allocator, lineAsCubic(current, start), 0);
    }
}

fn appendSplitCubic(
    out: *std.ArrayList(RegularizedCubicSpan),
    allocator: std.mem.Allocator,
    source: RegularizedCubicSpan,
) Error!void {
    var roots: [8]f64 = undefined;
    var root_count: usize = 0;
    appendDerivativeRoots(&roots, &root_count, source.p0.x, source.p1.x, source.p2.x, source.p3.x);
    appendDerivativeRoots(&roots, &root_count, source.p0.y, source.p1.y, source.p2.y, source.p3.y);
    appendInflectionRoots(&roots, &root_count, source.p0, source.p1, source.p2, source.p3);
    std.mem.sort(f64, roots[0..root_count], {}, lessThan);

    var curve = source;
    var previous_t: f64 = 0.0;
    for (roots[0..root_count]) |t| {
        if (t <= previous_t or t >= 1.0) continue;
        const local_t = (t - previous_t) / (1.0 - previous_t);
        const split = splitCubic(curve, local_t);
        try appendPrepared(out, allocator, split.left, 0);
        curve = split.right;
        previous_t = t;
    }
    try appendPrepared(out, allocator, curve, 0);
}

fn appendPrepared(
    out: *std.ArrayList(RegularizedCubicSpan),
    allocator: std.mem.Allocator,
    curve: RegularizedCubicSpan,
    depth: u8,
) Error!void {
    if (depth >= max_cubic_prepare_depth or cubicControlPolygonMonotoneAfterQuantize(curve)) {
        try out.append(allocator, curve);
        return;
    }

    const split = splitCubic(curve, 0.5);
    try appendPrepared(out, allocator, split.left, depth + 1);
    try appendPrepared(out, allocator, split.right, depth + 1);
}

fn splitCubic(curve: RegularizedCubicSpan, t: f64) struct { left: RegularizedCubicSpan, right: RegularizedCubicSpan } {
    const p01 = lerpPoint(curve.p0, curve.p1, t);
    const p12 = lerpPoint(curve.p1, curve.p2, t);
    const p23 = lerpPoint(curve.p2, curve.p3, t);
    const p012 = lerpPoint(p01, p12, t);
    const p123 = lerpPoint(p12, p23, t);
    const p0123 = lerpPoint(p012, p123, t);
    return .{
        .left = .{ .p0 = curve.p0, .p1 = p01, .p2 = p012, .p3 = p0123 },
        .right = .{ .p0 = p0123, .p1 = p123, .p2 = p23, .p3 = curve.p3 },
    };
}

fn appendDerivativeRoots(roots: *[8]f64, count: *usize, p0: f64, p1: f64, p2: f64, p3: f64) void {
    const a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
    const b = 2.0 * (p0 - 2.0 * p1 + p2);
    const c = p1 - p0;
    appendQuadraticRoots01(roots, count, 3.0 * a, 3.0 * b, 3.0 * c);
}

fn appendInflectionRoots(roots: *[8]f64, count: *usize, p0: Point, p1: Point, p2: Point, p3: Point) void {
    const ax = -p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x;
    const ay = -p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y;
    const bx = 3.0 * p0.x - 6.0 * p1.x + 3.0 * p2.x;
    const by = 3.0 * p0.y - 6.0 * p1.y + 3.0 * p2.y;
    const cx = -3.0 * p0.x + 3.0 * p1.x;
    const cy = -3.0 * p0.y + 3.0 * p1.y;

    appendQuadraticRoots01(
        roots,
        count,
        -6.0 * cross(.{ .x = ax, .y = ay }, .{ .x = bx, .y = by }),
        6.0 * cross(.{ .x = cx, .y = cy }, .{ .x = ax, .y = ay }),
        2.0 * cross(.{ .x = cx, .y = cy }, .{ .x = bx, .y = by }),
    );
}

fn appendQuadraticRoots01(roots: *[8]f64, count: *usize, a: f64, b: f64, c: f64) void {
    const eps = 1.0e-9;
    if (@abs(a) <= eps) {
        if (@abs(b) > eps) appendRoot01(roots, count, -c / b);
        return;
    }

    const disc = b * b - 4.0 * a * c;
    if (disc < 0.0) return;
    const d = @sqrt(@max(disc, 0.0));
    appendRoot01(roots, count, (-b - d) / (2.0 * a));
    appendRoot01(roots, count, (-b + d) / (2.0 * a));
}

fn appendRoot01(roots: *[8]f64, count: *usize, t: f64) void {
    if (t <= 1.0e-6 or t >= 1.0 - 1.0e-6) return;
    for (roots[0..count.*]) |existing| {
        if (@abs(existing - t) < 1.0e-5) return;
    }
    if (count.* < roots.len) {
        roots[count.*] = t;
        count.* += 1;
    }
}

fn cubicControlPolygonMonotoneAfterQuantize(curve: RegularizedCubicSpan) bool {
    const x = quantizedAxis4(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x) orelse return false;
    const y = quantizedAxis4(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y) orelse return false;
    return monotone4(x) and monotone4(y);
}

fn quantizedAxis4(a: f64, b: f64, c: f64, d: f64) ?[4]i32 {
    return .{
        quantizedAxis(a) orelse return null,
        quantizedAxis(b) orelse return null,
        quantizedAxis(c) orelse return null,
        quantizedAxis(d) orelse return null,
    };
}

fn quantizedAxis(v: f64) ?i32 {
    const q = std.math.round(v * blob_units_per_pixel);
    if (!std.math.isFinite(q) or q < std.math.minInt(i16) or q > std.math.maxInt(i16)) {
        return null;
    }
    return @intFromFloat(q);
}

fn monotone4(v: [4]i32) bool {
    return (v[0] <= v[1] and v[1] <= v[2] and v[2] <= v[3]) or
        (v[0] >= v[1] and v[1] >= v[2] and v[2] >= v[3]);
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

fn cross(a: Point, b: Point) f64 {
    return a.x * b.y - a.y * b.x;
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn hasInteriorAxisExtremum(p0: f64, p1: f64, p2: f64, p3: f64) bool {
    var roots: [8]f64 = undefined;
    var count: usize = 0;
    appendDerivativeRoots(&roots, &count, p0, p1, p2, p3);
    return count > 0;
}

test "regularize raises lines and quadratics into cubic spans" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.lineTo(.{ .x = 3, .y = 0 });
    try outline.quadTo(.{ .x = 6, .y = 3 }, .{ .x = 9, .y = 0 });

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items);

    try std.testing.expectEqual(@as(usize, 4), spans.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), spans.items[0].p1.x, 1.0e-9);
    try std.testing.expect(spans.items[1].p3.x > spans.items[1].p0.x);
}

test "regularize prepares cubic spans at axis extrema" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.cubicTo(.{ .x = 100, .y = 200 }, .{ .x = -100, .y = 200 }, .{ .x = 0, .y = 0 });

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items);

    try std.testing.expect(spans.items.len > 1);
    for (spans.items) |span| {
        try std.testing.expect(!hasInteriorAxisExtremum(span.p0.x, span.p1.x, span.p2.x, span.p3.x));
        try std.testing.expect(!hasInteriorAxisExtremum(span.p0.y, span.p1.y, span.p2.y, span.p3.y));
    }
}

test "regularize prepared cubic control polygons stay monotone after quantization" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.cubicTo(.{ .x = 300, .y = 20 }, .{ .x = -280, .y = 22 }, .{ .x = 40, .y = 44 });

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items);

    for (spans.items) |span| {
        try std.testing.expect(cubicControlPolygonMonotoneAfterQuantize(span));
    }
}
