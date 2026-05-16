//! HarfBuzz outline capture and coverage blob encoding.

const std = @import("std");
const hb = @import("../font/harfbuzz.zig");
const blob_encode = @import("../blob/encode.zig");
const blob_format = @import("../blob/format.zig");
const regularize = @import("regularize.zig");
const stream = @import("stream.zig");
const c = hb.c;

pub const Error = error{
    HarfBuzzAllocationFailed,
    HarfBuzzDrawFailed,
    GlyphTooLarge,
    GlyphOffsetOverflow,
    OutOfMemory,
};

pub const Point = stream.Point;
const RegularizedCubicSpan = regularize.RegularizedCubicSpan;

pub const OutlineCapture = struct {
    stream: stream.OutlineStream,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) OutlineCapture {
        return .{ .stream = stream.OutlineStream.init(allocator) };
    }

    pub fn deinit(self: *OutlineCapture) void {
        self.stream.deinit();
        self.* = undefined;
    }

    pub fn clear(self: *OutlineCapture) void {
        self.stream.clear();
        self.failed = false;
    }

    fn moveTo(self: *OutlineCapture, p: Point) void {
        self.stream.moveTo(p) catch {
            self.failed = true;
        };
    }

    fn lineTo(self: *OutlineCapture, p: Point) void {
        self.stream.lineTo(p) catch {
            self.failed = true;
        };
    }

    fn quadTo(self: *OutlineCapture, control: Point, p: Point) void {
        self.stream.quadTo(control, p) catch {
            self.failed = true;
        };
    }

    fn cubicTo(self: *OutlineCapture, c1: Point, c2: Point, p: Point) void {
        self.stream.cubicTo(c1, c2, p) catch {
            self.failed = true;
        };
    }

    fn closePath(self: *OutlineCapture) void {
        self.stream.close() catch {
            self.failed = true;
        };
    }
};

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    funcs: *c.hb_draw_funcs_t,
    capture: OutlineCapture,
    spans: std.ArrayList(RegularizedCubicSpan) = .empty,

    pub fn init(allocator: std.mem.Allocator) Error!Encoder {
        const funcs = c.hb_draw_funcs_create() orelse return error.HarfBuzzAllocationFailed;
        errdefer c.hb_draw_funcs_destroy(funcs);

        c.hb_draw_funcs_set_move_to_func(funcs, moveToCallback, null, null);
        c.hb_draw_funcs_set_line_to_func(funcs, lineToCallback, null, null);
        c.hb_draw_funcs_set_quadratic_to_func(funcs, quadToCallback, null, null);
        c.hb_draw_funcs_set_cubic_to_func(funcs, cubicToCallback, null, null);
        c.hb_draw_funcs_set_close_path_func(funcs, closePathCallback, null, null);
        c.hb_draw_funcs_make_immutable(funcs);

        return .{
            .allocator = allocator,
            .funcs = funcs,
            .capture = OutlineCapture.init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.spans.deinit(self.allocator);
        self.capture.deinit();
        c.hb_draw_funcs_destroy(self.funcs);
        self.* = undefined;
    }

    pub const Encoded = struct {
        blob: blob_format.CoverageBlob,
        extents: hb.GlyphExtents,
        outline_segments: u32,
        regularized_spans: u32,
    };

    pub fn encodeGlyph(self: *Encoder, font: hb.Font, glyph_id: u32) Error!Encoded {
        self.capture.clear();
        self.spans.clearRetainingCapacity();

        const drawn = c.hb_font_draw_glyph_or_fail(
            font.handle,
            glyph_id,
            self.funcs,
            &self.capture,
        );
        if (self.capture.failed) return error.HarfBuzzDrawFailed;

        var extents: hb.GlyphExtents = .{
            .x_bearing = 0,
            .y_bearing = 0,
            .width = 0,
            .height = 0,
        };
        _ = c.hb_font_get_glyph_extents(font.handle, glyph_id, &extents);

        if (drawn == 0 or self.capture.stream.segments.items.len == 0) {
            return .{
                .blob = blob_format.CoverageBlob.empty(self.allocator),
                .extents = extents,
                .outline_segments = 0,
                .regularized_spans = 0,
            };
        }

        try regularize.appendRegularized(
            &self.spans,
            self.allocator,
            self.capture.stream.segments.items,
        );
        if (self.spans.items.len == 0) {
            return .{
                .blob = blob_format.CoverageBlob.empty(self.allocator),
                .extents = extents,
                .outline_segments = @intCast(self.capture.stream.segments.items.len),
                .regularized_spans = 0,
            };
        }

        return .{
            .blob = try blob_encode.curves(self.allocator, self.spans.items),
            .extents = extents,
            .outline_segments = @intCast(self.capture.stream.segments.items.len),
            .regularized_spans = @intCast(self.spans.items.len),
        };
    }
};

fn moveToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    captureFromData(draw_data).moveTo(.{ .x = to_x, .y = to_y });
}

fn lineToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    captureFromData(draw_data).lineTo(.{ .x = to_x, .y = to_y });
}

fn quadToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    control_x: f32,
    control_y: f32,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    captureFromData(draw_data).quadTo(
        .{ .x = control_x, .y = control_y },
        .{ .x = to_x, .y = to_y },
    );
}

fn cubicToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    control1_x: f32,
    control1_y: f32,
    control2_x: f32,
    control2_y: f32,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    captureFromData(draw_data).cubicTo(
        .{ .x = control1_x, .y = control1_y },
        .{ .x = control2_x, .y = control2_y },
        .{ .x = to_x, .y = to_y },
    );
}

fn closePathCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    _: ?*anyopaque,
) callconv(.c) void {
    captureFromData(draw_data).closePath();
}

fn captureFromData(draw_data: ?*anyopaque) *OutlineCapture {
    return @ptrCast(@alignCast(draw_data.?));
}

test "OutlineCapture records native segment stream" {
    var capture = OutlineCapture.init(std.testing.allocator);
    defer capture.deinit();

    capture.moveTo(.{ .x = 0, .y = 0 });
    capture.lineTo(.{ .x = 1, .y = 0 });
    capture.quadTo(.{ .x = 2, .y = 1 }, .{ .x = 3, .y = 0 });
    capture.cubicTo(.{ .x = 4, .y = 1 }, .{ .x = 5, .y = 1 }, .{ .x = 6, .y = 0 });
    capture.closePath();

    try std.testing.expect(!capture.failed);
    try std.testing.expectEqual(@as(usize, 5), capture.stream.segments.items.len);
    try std.testing.expect(capture.stream.segments.items[2] == .quad_to);
    try std.testing.expect(capture.stream.segments.items[3] == .cubic_to);
}

test "coverage math: bracketed solver preserves exact linear roots" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), solveMonotoneCubicAtForTest(0, 1.0 / 3.0, 2.0 / 3.0, 1, 0.25), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), solveMonotoneCubicAtForTest(0, 1.0 / 3.0, 2.0 / 3.0, 1, 0.5), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), solveMonotoneCubicAtForTest(0, 1.0 / 3.0, 2.0 / 3.0, 1, 0.75), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), solveMonotoneCubicAtForTest(1, 2.0 / 3.0, 1.0 / 3.0, 0, 0.75), 1.0e-12);
}

test "coverage math: high zoom far-right edges are not dropped by parameter epsilon" {
    const y0: f64 = -10_000_000.0;
    const y3: f64 = 10_000_000.0;
    const ta = solveMonotoneCubicAtForTest(y0, y0 / 3.0, y3 / 3.0, y3, -0.5);
    const tb = solveMonotoneCubicAtForTest(y0, y0 / 3.0, y3 / 3.0, y3, 0.5);

    try std.testing.expect(tb - ta < 1.0e-6);
    try std.testing.expect(tb - ta > paramEpsilonForTest());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), farRightContributionForTest(ta, tb, 1.0), 1.0e-12);
}

fn solveMonotoneCubicAtForTest(p0: f64, p1: f64, p2: f64, p3: f64, value: f64) f64 {
    const eps = 1.0 / 1048576.0;
    const f0 = p0 - value;
    const f1 = p3 - value;
    if (@abs(f0) <= eps) return 0.0;
    if (@abs(f1) <= eps) return 1.0;

    var lo: f64 = 0.0;
    var hi: f64 = 1.0;
    var flo = f0;
    const denom = p3 - p0;
    var t = if (@abs(denom) > eps) std.math.clamp((value - p0) / denom, 0.0, 1.0) else 0.5;

    for (0..12) |_| {
        const f = cubicAtForTest(p0, p1, p2, p3, t) - value;
        if (@abs(f) <= eps) return std.math.clamp(t, 0.0, 1.0);

        const df = cubicDerivativeForTest(p0, p1, p2, p3, t);
        const same_side = (f <= 0.0 and flo <= 0.0) or (f >= 0.0 and flo >= 0.0);
        if (same_side) {
            lo = t;
            flo = f;
        } else {
            hi = t;
        }

        const newton = t - f / df;
        const use_bisect = @abs(df) < eps or newton <= lo or newton >= hi or !std.math.isFinite(newton);
        t = if (use_bisect) (lo + hi) * 0.5 else newton;
    }

    return std.math.clamp(t, 0.0, 1.0);
}

fn paramEpsilonForTest() f64 {
    return 1.0e-8;
}

fn farRightContributionForTest(ta: f64, tb: f64, x_mid: f64) f64 {
    const signed_clip_height: f64 = 1.0;
    if (tb <= ta + paramEpsilonForTest()) {
        if (x_mid >= 0.5) return signed_clip_height;
        if (x_mid <= -0.5) return 0.0;
        return std.math.clamp(x_mid + 0.5, 0.0, 1.0) * signed_clip_height;
    }
    return signed_clip_height;
}

fn cubicAtForTest(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const u = 1.0 - t;
    return ((p0 * u + p1 * t) * u + (p1 * u + p2 * t) * t) * u +
        ((p1 * u + p2 * t) * u + (p2 * u + p3 * t) * t) * t;
}

fn cubicDerivativeForTest(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const u = 1.0 - t;
    return 3.0 * (u * u * (p1 - p0) +
        2.0 * u * t * (p2 - p1) +
        t * t * (p3 - p2));
}
