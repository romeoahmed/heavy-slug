const std = @import("std");
const format = @import("format.zig");
const decode = @import("decode.zig");
const hband = @import("hband.zig");

pub const CurveBounds = struct {
    min_x: i32,
    max_x: i32,
    min_y: i32,
    max_y: i32,

    pub fn overlapsYRange(self: CurveBounds, y_min: i32, y_max: i32) bool {
        return self.max_y >= y_min and self.min_y <= y_max;
    }
};

pub const Point = struct {
    x: f64,
    y: f64,
};

const Cubic = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,
};

pub fn curveBounds(view: decode.BlobView, curve_index: u32) CurveBounds {
    const texels = view.curveTexels(curve_index);
    const bbox = texels[2];
    return .{
        .min_x = bbox.r,
        .max_x = bbox.g,
        .min_y = bbox.b,
        .max_y = bbox.a,
    };
}

pub fn curvesOverlappingBand(
    allocator: std.mem.Allocator,
    view: decode.BlobView,
    band_index: u32,
) ![]u32 {
    const band_min = hband.minBand(view) + @as(i32, @intCast(band_index));
    const band_y_min = band_min * hband.heightInBlobUnits(view);
    const band_y_max = band_y_min + hband.heightInBlobUnits(view);
    const curve_count = view.header.curveCount();

    var ids: std.ArrayList(u32) = .empty;
    errdefer ids.deinit(allocator);
    for (0..curve_count) |curve_index| {
        if (curveBounds(view, @intCast(curve_index)).overlapsYRange(band_y_min, band_y_max)) {
            try ids.append(allocator, @intCast(curve_index));
        }
    }
    return try ids.toOwnedSlice(allocator);
}

pub fn containsId(ids: []const u32, needle: u32) bool {
    for (ids) |id| {
        if (id == needle) return true;
    }
    return false;
}

pub fn windingAtPoint(view: decode.BlobView, point: Point) i32 {
    var winding: i32 = 0;
    for (0..view.header.curveCount()) |curve_index| {
        winding += curveWindingAtPoint(readCurve(view, @intCast(curve_index)), point);
    }
    return winding;
}

pub fn coverageAtPoint(view: decode.BlobView, point: Point, even_odd: bool) bool {
    const winding = windingAtPoint(view, point);
    if (even_odd) return @mod(@abs(winding), 2) == 1;
    return winding != 0;
}

fn readCurve(view: decode.BlobView, curve_index: u32) Cubic {
    const texels = view.curveTexels(curve_index);
    return .{
        .p0 = .{ .x = @floatFromInt(texels[0].r), .y = @floatFromInt(texels[0].g) },
        .p1 = .{ .x = @floatFromInt(texels[0].b), .y = @floatFromInt(texels[0].a) },
        .p2 = .{ .x = @floatFromInt(texels[1].r), .y = @floatFromInt(texels[1].g) },
        .p3 = .{ .x = @floatFromInt(texels[1].b), .y = @floatFromInt(texels[1].a) },
    };
}

fn curveWindingAtPoint(curve: Cubic, point: Point) i32 {
    var roots = [_]f64{0} ** 4;
    roots[0] = 0;
    roots[1] = 1;
    var root_count: usize = 2;
    appendDerivativeRoots(&roots, &root_count, curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y);
    std.mem.sort(f64, roots[0..root_count], {}, lessThan);

    var winding: i32 = 0;
    for (0..root_count - 1) |i| {
        const ta = roots[i];
        const tb = roots[i + 1];
        if (tb <= ta + 1.0e-9) continue;

        const ya = cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, ta);
        const yb = cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, tb);
        if (!crossesHalfOpen(ya, yb, point.y)) continue;

        const t = solveMonotoneY(curve, point.y, ta, tb);
        const x = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, t);
        if (x > point.x) winding += if (yb > ya) 1 else -1;
    }
    return winding;
}

fn crossesHalfOpen(a: f64, b: f64, y: f64) bool {
    return (a <= y and y < b) or (b <= y and y < a);
}

fn solveMonotoneY(curve: Cubic, y: f64, ta: f64, tb: f64) f64 {
    var lo = ta;
    var hi = tb;
    const increasing = cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, tb) >
        cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, ta);
    for (0..48) |_| {
        const mid = (lo + hi) * 0.5;
        const ym = cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, mid);
        if ((ym < y) == increasing) {
            lo = mid;
        } else {
            hi = mid;
        }
    }
    return (lo + hi) * 0.5;
}

fn cubicAt(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const u = 1.0 - t;
    return u * u * u * p0 + 3.0 * u * u * t * p1 + 3.0 * u * t * t * p2 + t * t * t * p3;
}

fn appendDerivativeRoots(roots: *[4]f64, count: *usize, p0: f64, p1: f64, p2: f64, p3: f64) void {
    const a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
    const b = 2.0 * (p0 - 2.0 * p1 + p2);
    const c = p1 - p0;
    appendQuadraticRoots01(roots, count, 3.0 * a, 3.0 * b, 3.0 * c);
}

fn appendQuadraticRoots01(roots: *[4]f64, count: *usize, a: f64, b: f64, c: f64) void {
    if (@abs(a) <= 1.0e-12) {
        if (@abs(b) > 1.0e-12) appendRoot01(roots, count, -c / b);
        return;
    }

    const disc = b * b - 4.0 * a * c;
    if (disc < 0) return;
    const d = @sqrt(@max(disc, 0));
    appendRoot01(roots, count, (-b - d) / (2.0 * a));
    appendRoot01(roots, count, (-b + d) / (2.0 * a));
}

fn appendRoot01(roots: *[4]f64, count: *usize, t: f64) void {
    if (t <= 1.0e-9 or t >= 1.0 - 1.0e-9) return;
    for (roots[0..count.*]) |existing| {
        if (@abs(existing - t) <= 1.0e-8) return;
    }
    if (count.* < roots.len) {
        roots[count.*] = t;
        count.* += 1;
    }
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

test "reference: h-band candidates are a superset of full-scan y-overlap" {
    const encode = @import("encode.zig");
    const EncodeCubic = encode.Cubic;
    const curves = [_]EncodeCubic{
        .{
            .p0 = .{ .x = 0, .y = 0 },
            .p1 = .{ .x = 1, .y = 1 },
            .p2 = .{ .x = 2, .y = 2 },
            .p3 = .{ .x = 3, .y = 3 },
        },
        .{
            .p0 = .{ .x = 0, .y = 5 },
            .p1 = .{ .x = 1, .y = 6 },
            .p2 = .{ .x = 2, .y = 7 },
            .p3 = .{ .x = 3, .y = 8 },
        },
    };

    var blob = try encode.curves(std.testing.allocator, &curves);
    defer blob.deinit();

    const view = try decode.BlobView.initCoverageBlob(blob);
    for (0..hband.count(view)) |band_index| {
        const candidates = try hband.candidateIds(std.testing.allocator, view, @intCast(band_index));
        defer std.testing.allocator.free(candidates);
        const reference_ids = try curvesOverlappingBand(std.testing.allocator, view, @intCast(band_index));
        defer std.testing.allocator.free(reference_ids);

        for (reference_ids) |id| {
            try std.testing.expect(containsId(candidates, id));
        }
    }
}

test "reference: analytic point coverage handles filled contours" {
    const encode = @import("encode.zig");
    const CubicForEncode = encode.Cubic;
    const square = [_]CubicForEncode{
        .{ .p0 = .{ .x = 0, .y = 0 }, .p1 = .{ .x = 1, .y = 0 }, .p2 = .{ .x = 2, .y = 0 }, .p3 = .{ .x = 3, .y = 0 } },
        .{ .p0 = .{ .x = 3, .y = 0 }, .p1 = .{ .x = 3, .y = 1 }, .p2 = .{ .x = 3, .y = 2 }, .p3 = .{ .x = 3, .y = 3 } },
        .{ .p0 = .{ .x = 3, .y = 3 }, .p1 = .{ .x = 2, .y = 3 }, .p2 = .{ .x = 1, .y = 3 }, .p3 = .{ .x = 0, .y = 3 } },
        .{ .p0 = .{ .x = 0, .y = 3 }, .p1 = .{ .x = 0, .y = 2 }, .p2 = .{ .x = 0, .y = 1 }, .p3 = .{ .x = 0, .y = 0 } },
    };

    var blob = try encode.curves(std.testing.allocator, &square);
    defer blob.deinit();
    const view = try decode.BlobView.initCoverageBlob(blob);

    try std.testing.expect(coverageAtPoint(view, .{ .x = 6, .y = 6 }, false));
    try std.testing.expect(!coverageAtPoint(view, .{ .x = 20, .y = 6 }, false));
}
