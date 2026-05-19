//! Cubic Bezier geometry used by outline regularization.

const std = @import("std");
const stream = @import("stream.zig");

pub const Point = stream.Point;

const Vec2 = @Vector(2, f64);
const Vec4 = @Vector(4, f64);

pub const Cubic = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,

    pub fn minX(self: Cubic) f64 {
        return @reduce(.Min, self.xValues());
    }

    pub fn maxX(self: Cubic) f64 {
        return @reduce(.Max, self.xValues());
    }

    pub fn minY(self: Cubic) f64 {
        return @reduce(.Min, self.yValues());
    }

    pub fn maxY(self: Cubic) f64 {
        return @reduce(.Max, self.yValues());
    }

    pub fn isFinite(self: Cubic) bool {
        return pointIsFinite(self.p0) and
            pointIsFinite(self.p1) and
            pointIsFinite(self.p2) and
            pointIsFinite(self.p3);
    }

    fn xValues(self: Cubic) Vec4 {
        return .{ self.p0.x, self.p1.x, self.p2.x, self.p3.x };
    }

    fn yValues(self: Cubic) Vec4 {
        return .{ self.p0.y, self.p1.y, self.p2.y, self.p3.y };
    }
};

pub const SplitCubic = struct {
    left: Cubic,
    right: Cubic,
};

pub const RootList = struct {
    values: [max_roots]f64 = undefined,
    len: usize = 0,

    pub const max_roots = 8;

    pub fn appendCubicCriticalPoints(self: *RootList, cubic: Cubic) void {
        self.appendDerivativeRoots(cubic.p0.x, cubic.p1.x, cubic.p2.x, cubic.p3.x);
        self.appendDerivativeRoots(cubic.p0.y, cubic.p1.y, cubic.p2.y, cubic.p3.y);
        self.appendInflectionRoots(cubic);
    }

    pub fn sorted(self: *RootList) []const f64 {
        std.mem.sort(f64, self.values[0..self.len], {}, lessThan);
        return self.values[0..self.len];
    }

    pub fn hasInteriorDerivativeRoot(self: *RootList, p0: f64, p1: f64, p2: f64, p3: f64) bool {
        self.len = 0;
        self.appendDerivativeRoots(p0, p1, p2, p3);
        return self.len > 0;
    }

    fn appendDerivativeRoots(self: *RootList, p0: f64, p1: f64, p2: f64, p3: f64) void {
        const a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
        const b = 2.0 * (p0 - 2.0 * p1 + p2);
        const c = p1 - p0;
        self.appendQuadraticRoots01(3.0 * a, 3.0 * b, 3.0 * c);
    }

    fn appendInflectionRoots(self: *RootList, cubic: Cubic) void {
        const ax = -cubic.p0.x + 3.0 * cubic.p1.x - 3.0 * cubic.p2.x + cubic.p3.x;
        const ay = -cubic.p0.y + 3.0 * cubic.p1.y - 3.0 * cubic.p2.y + cubic.p3.y;
        const bx = 3.0 * cubic.p0.x - 6.0 * cubic.p1.x + 3.0 * cubic.p2.x;
        const by = 3.0 * cubic.p0.y - 6.0 * cubic.p1.y + 3.0 * cubic.p2.y;
        const cx = -3.0 * cubic.p0.x + 3.0 * cubic.p1.x;
        const cy = -3.0 * cubic.p0.y + 3.0 * cubic.p1.y;

        self.appendQuadraticRoots01(
            -6.0 * cross(.{ .x = ax, .y = ay }, .{ .x = bx, .y = by }),
            6.0 * cross(.{ .x = cx, .y = cy }, .{ .x = ax, .y = ay }),
            2.0 * cross(.{ .x = cx, .y = cy }, .{ .x = bx, .y = by }),
        );
    }

    fn appendQuadraticRoots01(self: *RootList, a: f64, b: f64, c: f64) void {
        const eps = 1.0e-9;
        if (@abs(a) <= eps) {
            if (@abs(b) > eps) self.appendRoot01(-c / b);
            return;
        }

        const disc = b * b - 4.0 * a * c;
        if (disc < 0.0) return;
        const d = @sqrt(@max(disc, 0.0));
        self.appendRoot01((-b - d) / (2.0 * a));
        self.appendRoot01((-b + d) / (2.0 * a));
    }

    fn appendRoot01(self: *RootList, t: f64) void {
        if (!std.math.isFinite(t) or t <= 1.0e-6 or t >= 1.0 - 1.0e-6) return;
        for (self.values[0..self.len]) |existing| {
            if (@abs(existing - t) < 1.0e-5) return;
        }
        if (self.len < self.values.len) {
            self.values[self.len] = t;
            self.len += 1;
        }
    }
};

pub fn pointIsFinite(p: Point) bool {
    return std.math.isFinite(p.x) and std.math.isFinite(p.y);
}

pub fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

pub fn lineAsCubic(p0: Point, p1: Point) Cubic {
    return .{
        .p0 = p0,
        .p1 = lerpPoint(p0, p1, 1.0 / 3.0),
        .p2 = lerpPoint(p0, p1, 2.0 / 3.0),
        .p3 = p1,
    };
}

pub fn quadAsCubic(p0: Point, control: Point, p1: Point) Cubic {
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

pub fn splitCubic(curve: Cubic, t: f64) SplitCubic {
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

fn lerpPoint(a: Point, b: Point, t: f64) Point {
    const av = pointVec(a);
    return pointFromVec(av + (pointVec(b) - av) * @as(Vec2, @splat(t)));
}

fn pointVec(p: Point) Vec2 {
    return .{ p.x, p.y };
}

fn pointFromVec(v: Vec2) Point {
    return .{ .x = v[0], .y = v[1] };
}

fn cross(a: Point, b: Point) f64 {
    return a.x * b.y - a.y * b.x;
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

test "outline geometry: line and quadratic elevation preserve endpoints" {
    const line = lineAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 3, .y = 0 });
    try std.testing.expectEqual(@as(f64, 0), line.p0.x);
    try std.testing.expectEqual(@as(f64, 3), line.p3.x);
    try std.testing.expectApproxEqAbs(@as(f64, 1), line.p1.x, 1.0e-12);

    const quad = quadAsCubic(.{ .x = 0, .y = 0 }, .{ .x = 1.5, .y = 3 }, .{ .x = 3, .y = 0 });
    try std.testing.expectEqual(@as(f64, 0), quad.p0.x);
    try std.testing.expectEqual(@as(f64, 3), quad.p3.x);
    try std.testing.expect(quad.p1.y > 0);
    try std.testing.expect(quad.p2.y > 0);
}

test "outline geometry: critical roots include axis extrema" {
    const cubic = Cubic{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = 100, .y = 200 },
        .p2 = .{ .x = -100, .y = 200 },
        .p3 = .{ .x = 0, .y = 0 },
    };
    var roots = RootList{};
    roots.appendCubicCriticalPoints(cubic);
    try std.testing.expect(roots.len > 0);
}

test "outline geometry: split cubic joins exactly at the split point" {
    const cubic = Cubic{
        .p0 = .{ .x = 0, .y = 0 },
        .p1 = .{ .x = 1, .y = 3 },
        .p2 = .{ .x = 2, .y = 3 },
        .p3 = .{ .x = 3, .y = 0 },
    };
    const split = splitCubic(cubic, 0.5);
    try std.testing.expectApproxEqAbs(split.left.p3.x, split.right.p0.x, 1.0e-12);
    try std.testing.expectApproxEqAbs(split.left.p3.y, split.right.p0.y, 1.0e-12);
}
