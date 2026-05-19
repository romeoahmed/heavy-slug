//! Normalize native outline segments into quantization-stable cubic spans.

const std = @import("std");
const blob_format = @import("../blob/format.zig");
const geometry = @import("geometry.zig");
const stream = @import("stream.zig");

pub const Error = error{
    GlyphTooLarge,
    PrecisionUnsupported,
    OutOfMemory,
};

pub const Point = stream.Point;
pub const RegularizedCubicSpan = geometry.Cubic;

const max_cubic_prepare_depth = 8;

pub fn lineAsCubic(p0: Point, p1: Point) RegularizedCubicSpan {
    return geometry.lineAsCubic(p0, p1);
}

pub fn quadAsCubic(p0: Point, control: Point, p1: Point) RegularizedCubicSpan {
    return geometry.quadAsCubic(p0, control, p1);
}

/// Split lines, quadratics, and cubics into spans suitable for blob encoding.
pub fn appendRegularized(
    out: *std.ArrayList(RegularizedCubicSpan),
    allocator: std.mem.Allocator,
    outline: []const stream.Segment,
    fraction_bits: u8,
) Error!void {
    try blob_format.validateFractionBits(fraction_bits);

    var builder = Regularizer{
        .out = out,
        .allocator = allocator,
        .fraction_bits = fraction_bits,
    };
    for (outline) |segment| {
        try builder.append(segment);
    }
    try builder.finish();
}

const Regularizer = struct {
    out: *std.ArrayList(RegularizedCubicSpan),
    allocator: std.mem.Allocator,
    fraction_bits: u8,
    current: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    open: bool = false,

    fn append(self: *Regularizer, segment: stream.Segment) Error!void {
        switch (segment) {
            .move_to => |p| try self.moveTo(p),
            .line_to => |p| try self.lineTo(p),
            .quad_to => |q| try self.quadTo(q.control, q.to),
            .cubic_to => |c| try self.cubicTo(c.control1, c.control2, c.to),
            .close => try self.close(),
        }
    }

    fn moveTo(self: *Regularizer, p: Point) Error!void {
        try validatePoint(p);
        try self.close();
        self.current = p;
        self.start = p;
        self.open = true;
    }

    fn lineTo(self: *Regularizer, p: Point) Error!void {
        try validatePoint(p);
        self.ensureOpen();
        if (!geometry.samePoint(self.current, p)) {
            try self.appendPrepared(geometry.lineAsCubic(self.current, p), 0);
        }
        self.current = p;
    }

    fn quadTo(self: *Regularizer, control: Point, p: Point) Error!void {
        try validatePoint(control);
        try validatePoint(p);
        self.ensureOpen();
        if (!geometry.samePoint(self.current, p)) {
            try self.appendSplitCubic(geometry.quadAsCubic(self.current, control, p));
        }
        self.current = p;
    }

    fn cubicTo(self: *Regularizer, c1: Point, c2: Point, p: Point) Error!void {
        try validatePoint(c1);
        try validatePoint(c2);
        try validatePoint(p);
        self.ensureOpen();
        if (!geometry.samePoint(self.current, p) or
            !geometry.samePoint(c1, p) or
            !geometry.samePoint(c2, p))
        {
            try self.appendSplitCubic(.{ .p0 = self.current, .p1 = c1, .p2 = c2, .p3 = p });
        }
        self.current = p;
    }

    fn close(self: *Regularizer) Error!void {
        if (self.open and !geometry.samePoint(self.current, self.start)) {
            try self.appendPrepared(geometry.lineAsCubic(self.current, self.start), 0);
        }
        self.open = false;
    }

    fn finish(self: *Regularizer) Error!void {
        try self.close();
    }

    fn ensureOpen(self: *Regularizer) void {
        if (!self.open) {
            self.start = self.current;
            self.open = true;
        }
    }

    fn appendSplitCubic(self: *Regularizer, source: RegularizedCubicSpan) Error!void {
        if (!source.isFinite()) return error.GlyphTooLarge;

        var roots = geometry.RootList{};
        roots.appendCubicCriticalPoints(source);

        var curve = source;
        var previous_t: f64 = 0.0;
        for (roots.sorted()) |t| {
            if (t <= previous_t or t >= 1.0) continue;
            const local_t = (t - previous_t) / (1.0 - previous_t);
            const split = geometry.splitCubic(curve, local_t);
            try self.appendPrepared(split.left, 0);
            curve = split.right;
            previous_t = t;
        }
        try self.appendPrepared(curve, 0);
    }

    fn appendPrepared(self: *Regularizer, curve: RegularizedCubicSpan, depth: u8) Error!void {
        if (!curve.isFinite()) return error.GlyphTooLarge;
        if (depth >= max_cubic_prepare_depth or cubicControlPolygonMonotoneAfterQuantize(curve, self.fraction_bits)) {
            try self.out.append(self.allocator, curve);
            return;
        }

        const split = geometry.splitCubic(curve, 0.5);
        try self.appendPrepared(split.left, depth + 1);
        try self.appendPrepared(split.right, depth + 1);
    }
};

fn validatePoint(p: Point) Error!void {
    if (!geometry.pointIsFinite(p)) return error.GlyphTooLarge;
}

fn cubicControlPolygonMonotoneAfterQuantize(curve: RegularizedCubicSpan, fraction_bits: u8) bool {
    const x = quantizedAxis4(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, fraction_bits) orelse return false;
    const y = quantizedAxis4(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, fraction_bits) orelse return false;
    return monotone4(x) and monotone4(y);
}

fn quantizedAxis4(a: f64, b: f64, c: f64, d: f64, fraction_bits: u8) ?[4]i32 {
    return .{
        quantizedAxis(a, fraction_bits) orelse return null,
        quantizedAxis(b, fraction_bits) orelse return null,
        quantizedAxis(c, fraction_bits) orelse return null,
        quantizedAxis(d, fraction_bits) orelse return null,
    };
}

fn quantizedAxis(v: f64, fraction_bits: u8) ?i32 {
    const q = std.math.round(v * blob_format.scaleForFractionBits(fraction_bits));
    if (!std.math.isFinite(q) or q < std.math.minInt(i32) or q > std.math.maxInt(i32)) {
        return null;
    }
    return @intFromFloat(q);
}

fn monotone4(v: [4]i32) bool {
    return (v[0] <= v[1] and v[1] <= v[2] and v[2] <= v[3]) or
        (v[0] >= v[1] and v[1] >= v[2] and v[2] >= v[3]);
}

fn hasInteriorAxisExtremum(p0: f64, p1: f64, p2: f64, p3: f64) bool {
    var roots = geometry.RootList{};
    return roots.hasInteriorDerivativeRoot(p0, p1, p2, p3);
}

test "regularize raises lines and quadratics into cubic spans" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.lineTo(.{ .x = 3, .y = 0 });
    try outline.quadTo(.{ .x = 6, .y = 3 }, .{ .x = 9, .y = 0 });

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items, blob_format.default_fraction_bits);

    try std.testing.expectEqual(@as(usize, 4), spans.items.len);
    try std.testing.expectApproxEqAbs(@as(f64, 1), spans.items[0].p1.x, 1.0e-9);
    try std.testing.expect(spans.items[1].p3.x > spans.items[1].p0.x);
}

test "regularize rejects unsupported blob precision before quantization" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.lineTo(.{ .x = 1, .y = 1 });

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.PrecisionUnsupported,
        appendRegularized(&spans, std.testing.allocator, outline.segments.items, blob_format.max_fraction_bits + 1),
    );
}

test "regularize rejects non-finite outline coordinates before subdivision" {
    const outline = [_]stream.Segment{
        .{ .move_to = .{ .x = 0, .y = 0 } },
        .{ .line_to = .{ .x = std.math.inf(f64), .y = 1 } },
    };

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try std.testing.expectError(
        error.GlyphTooLarge,
        appendRegularized(&spans, std.testing.allocator, &outline, blob_format.default_fraction_bits),
    );
}

test "regularize prepares cubic spans at axis extrema" {
    var outline = stream.OutlineStream.init(std.testing.allocator);
    defer outline.deinit();
    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.cubicTo(.{ .x = 100, .y = 200 }, .{ .x = -100, .y = 200 }, .{ .x = 0, .y = 0 });

    var spans: std.ArrayList(RegularizedCubicSpan) = .empty;
    defer spans.deinit(std.testing.allocator);
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items, blob_format.default_fraction_bits);

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
    try appendRegularized(&spans, std.testing.allocator, outline.segments.items, blob_format.default_fraction_bits);

    for (spans.items) |span| {
        try std.testing.expect(cubicControlPolygonMonotoneAfterQuantize(span, blob_format.default_fraction_bits));
    }
}
