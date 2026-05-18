//! Public core value types used by renderers and applications.

const std = @import("std");

const Vec2 = @Vector(2, f64);

pub const Point2D64 = extern struct {
    x: f64,
    y: f64,

    pub fn init(x: f64, y: f64) Point2D64 {
        return .{ .x = x, .y = y };
    }
};

pub const Rect64 = extern struct {
    x_min: f64,
    y_min: f64,
    x_max: f64,
    y_max: f64,

    pub fn init(x_min: f64, y_min: f64, x_max: f64, y_max: f64) Rect64 {
        return .{
            .x_min = @min(x_min, x_max),
            .y_min = @min(y_min, y_max),
            .x_max = @max(x_min, x_max),
            .y_max = @max(y_min, y_max),
        };
    }

    pub fn isFinite(self: Rect64) bool {
        return std.math.isFinite(self.x_min) and
            std.math.isFinite(self.y_min) and
            std.math.isFinite(self.x_max) and
            std.math.isFinite(self.y_max);
    }

    pub fn isEmpty(self: Rect64) bool {
        return self.x_max <= self.x_min or self.y_max <= self.y_min;
    }

    pub fn intersects(self: Rect64, other: Rect64) bool {
        return self.x_max > other.x_min and self.x_min < other.x_max and
            self.y_max > other.y_min and self.y_min < other.y_max;
    }
};

/// 2D affine transform in column-vector convention:
///
/// x' = xx*x + yx*y + tx
/// y' = xy*x + yy*y + ty
pub const Affine2D64 = extern struct {
    xx: f64,
    xy: f64,
    yx: f64,
    yy: f64,
    tx: f64,
    ty: f64,

    pub const identity: Affine2D64 = .{
        .xx = 1,
        .xy = 0,
        .yx = 0,
        .yy = 1,
        .tx = 0,
        .ty = 0,
    };

    pub fn init(xx: f64, xy: f64, yx: f64, yy: f64, tx: f64, ty: f64) Affine2D64 {
        return .{ .xx = xx, .xy = xy, .yx = yx, .yy = yy, .tx = tx, .ty = ty };
    }

    pub fn translation(x: f64, y: f64) Affine2D64 {
        return .{ .xx = 1, .xy = 0, .yx = 0, .yy = 1, .tx = x, .ty = y };
    }

    pub fn scale(sx: f64, sy: f64) Affine2D64 {
        return .{ .xx = sx, .xy = 0, .yx = 0, .yy = sy, .tx = 0, .ty = 0 };
    }

    pub fn rotation(angle_radians: f64) Affine2D64 {
        const c = @cos(angle_radians);
        const s = @sin(angle_radians);
        return .{ .xx = c, .xy = s, .yx = -s, .yy = c, .tx = 0, .ty = 0 };
    }

    pub fn rotationAbout(angle_radians: f64, x: f64, y: f64) Affine2D64 {
        return compose(
            translation(x, y),
            compose(rotation(angle_radians), translation(-x, -y)),
        );
    }

    /// Return `a * b`, i.e. apply `b` first and then `a`.
    pub fn compose(a: Affine2D64, b: Affine2D64) Affine2D64 {
        return .{
            .xx = a.xx * b.xx + a.yx * b.xy,
            .xy = a.xy * b.xx + a.yy * b.xy,
            .yx = a.xx * b.yx + a.yx * b.yy,
            .yy = a.xy * b.yx + a.yy * b.yy,
            .tx = a.xx * b.tx + a.yx * b.ty + a.tx,
            .ty = a.xy * b.tx + a.yy * b.ty + a.ty,
        };
    }

    pub fn translate(self: Affine2D64, x: f64, y: f64) Affine2D64 {
        return compose(self, translation(x, y));
    }

    pub fn apply(self: Affine2D64, point: anytype) [2]f64 {
        const x: f64 = @floatCast(point[0]);
        const y: f64 = @floatCast(point[1]);
        return .{
            self.xx * x + self.yx * y + self.tx,
            self.xy * x + self.yy * y + self.ty,
        };
    }

    pub fn applyVector(self: Affine2D64, vector: anytype) [2]f64 {
        const x: f64 = @floatCast(vector[0]);
        const y: f64 = @floatCast(vector[1]);
        return .{
            self.xx * x + self.yx * y,
            self.xy * x + self.yy * y,
        };
    }

    pub fn applyPoint(self: Affine2D64, point: Point2D64) Point2D64 {
        const out = self.apply(.{ point.x, point.y });
        return .{ .x = out[0], .y = out[1] };
    }

    pub fn transformRect(self: Affine2D64, rect: Rect64) Rect64 {
        const p0 = self.apply(.{ rect.x_min, rect.y_min });
        const p1 = self.apply(.{ rect.x_max, rect.y_min });
        const p2 = self.apply(.{ rect.x_max, rect.y_max });
        const p3 = self.apply(.{ rect.x_min, rect.y_max });
        const xs: Vec2 = .{ @min(p0[0], p1[0]), @min(p2[0], p3[0]) };
        const ys: Vec2 = .{ @min(p0[1], p1[1]), @min(p2[1], p3[1]) };
        const xe: Vec2 = .{ @max(p0[0], p1[0]), @max(p2[0], p3[0]) };
        const ye: Vec2 = .{ @max(p0[1], p1[1]), @max(p2[1], p3[1]) };
        return .{
            .x_min = @reduce(.Min, xs),
            .y_min = @reduce(.Min, ys),
            .x_max = @reduce(.Max, xe),
            .y_max = @reduce(.Max, ye),
        };
    }

    pub fn determinant(self: Affine2D64) f64 {
        return self.xx * self.yy - self.yx * self.xy;
    }

    pub fn inverse(self: Affine2D64) ?Affine2D64 {
        const det = self.determinant();
        if (!std.math.isFinite(det) or det == 0) return null;
        const inv_det = 1.0 / det;
        if (!std.math.isFinite(inv_det)) return null;
        const xx = self.yy * inv_det;
        const xy = -self.xy * inv_det;
        const yx = -self.yx * inv_det;
        const yy = self.xx * inv_det;
        return .{
            .xx = xx,
            .xy = xy,
            .yx = yx,
            .yy = yy,
            .tx = -(xx * self.tx + yx * self.ty),
            .ty = -(xy * self.tx + yy * self.ty),
        };
    }

    pub fn normInf(self: Affine2D64) f64 {
        return @max(@abs(self.xx) + @abs(self.yx), @abs(self.xy) + @abs(self.yy));
    }

    pub fn isFinite(self: Affine2D64) bool {
        return std.math.isFinite(self.xx) and
            std.math.isFinite(self.xy) and
            std.math.isFinite(self.yx) and
            std.math.isFinite(self.yy) and
            std.math.isFinite(self.tx) and
            std.math.isFinite(self.ty);
    }

    pub fn linearScaled(self: Affine2D64, scale_factor: f64) Affine2D64 {
        return .{
            .xx = self.xx * scale_factor,
            .xy = self.xy * scale_factor,
            .yx = self.yx * scale_factor,
            .yy = self.yy * scale_factor,
            .tx = self.tx,
            .ty = self.ty,
        };
    }
};

pub const Transform = Affine2D64;

pub const FrameView2D = extern struct {
    viewport_width: f64,
    viewport_height: f64,
    screen_from_world: Affine2D64,

    pub fn init(width: f64, height: f64, screen_from_world: Affine2D64) FrameView2D {
        return .{
            .viewport_width = width,
            .viewport_height = height,
            .screen_from_world = screen_from_world,
        };
    }

    pub fn identity(width: f64, height: f64) FrameView2D {
        return init(width, height, .identity);
    }

    pub fn viewportRect(self: FrameView2D) Rect64 {
        return .{ .x_min = 0, .y_min = 0, .x_max = self.viewport_width, .y_max = self.viewport_height };
    }

    pub fn isFinite(self: FrameView2D) bool {
        return std.math.isFinite(self.viewport_width) and
            std.math.isFinite(self.viewport_height) and
            self.viewport_width > 0 and
            self.viewport_height > 0 and
            self.screen_from_world.isFinite();
    }
};

pub const PrecisionPolicy = extern struct {
    target_error_px: f64 = 0.125,
    max_condition_number: f64 = 1.0e8,
    min_fraction_bits: u8 = 12,
    max_fraction_bits: u8 = 24,
    hysteresis_frames: u8 = 8,
    _pad: u8 = 0,

    pub fn selectFractionBits(self: PrecisionPolicy, screen_from_local: Affine2D64) !u8 {
        if (!screen_from_local.isFinite()) return error.InvalidTransform;
        const sigma = screen_from_local.normInf();
        if (!std.math.isFinite(sigma) or sigma <= 0) return error.InvalidTransform;
        const local_from_screen = screen_from_local.inverse() orelse return error.InvalidTransform;
        const condition = sigma * local_from_screen.normInf();
        if (!std.math.isFinite(condition) or
            !std.math.isFinite(self.max_condition_number) or
            self.max_condition_number <= 0 or
            condition > self.max_condition_number)
        {
            return error.InvalidTransform;
        }
        if (!std.math.isFinite(self.target_error_px) or self.target_error_px <= 0) {
            return error.InvalidPrecisionPolicy;
        }
        if (self.min_fraction_bits > self.max_fraction_bits) return error.InvalidPrecisionPolicy;

        const required_f = std.math.log2(sigma / (2.0 * self.target_error_px));
        if (!std.math.isFinite(required_f)) return error.PrecisionUnsupported;
        if (required_f > @as(f64, @floatFromInt(std.math.maxInt(i32)))) return error.PrecisionUnsupported;
        const required_i: i32 = if (required_f <= 0)
            0
        else
            @intFromFloat(@ceil(required_f));
        if (required_i > self.max_fraction_bits) return error.PrecisionUnsupported;

        const min_bits: i32 = self.min_fraction_bits;
        const clamped: u8 = @intCast(@max(required_i, min_bits));
        return nextEvenTier(clamped, self.max_fraction_bits) orelse error.PrecisionUnsupported;
    }

    pub fn fixedScale(_: PrecisionPolicy, fraction_bits: u8) !i32 {
        if (fraction_bits > 30) return error.PrecisionUnsupported;
        return @as(i32, 1) << @intCast(fraction_bits);
    }
};

fn nextEvenTier(bits: u8, max_bits: u8) ?u8 {
    var tier = bits;
    if (tier % 2 != 0) tier += 1;
    return if (tier <= max_bits) tier else null;
}

pub const FillRule = enum(u32) {
    non_zero = 0,
    even_odd = 1,

    pub fn shaderFlags(self: FillRule) u32 {
        return switch (self) {
            .non_zero => 0,
            .even_odd => 1,
        };
    }
};

pub const Color = extern struct {
    rgba: [4]f32,

    pub const black: Color = .{ .rgba = .{ 0, 0, 0, 1 } };
    pub const white: Color = .{ .rgba = .{ 1, 1, 1, 1 } };
    pub const transparent: Color = .{ .rgba = .{ 0, 0, 0, 0 } };

    pub fn fromRgba(r: f32, g: f32, b: f32, a: f32) Color {
        return .{ .rgba = .{ r, g, b, a } };
    }
};

pub const Viewport = extern struct {
    width: f32,
    height: f32,

    pub fn init(width: f32, height: f32) Viewport {
        return .{ .width = width, .height = height };
    }

    pub fn asArray(self: Viewport) [2]f32 {
        return .{ self.width, self.height };
    }
};

pub const FontHandle = extern struct {
    id: u32,

    pub const invalid: FontHandle = .{ .id = std.math.maxInt(u32) };
};

pub const FontSource = union(enum) {
    path: [*:0]const u8,
};

pub const FontOptions = struct {
    size_px: u32,
    face_index: u32 = 0,
    variation_key: u64 = 0,
};

pub const GlyphKey = extern struct {
    font_id: u32,
    glyph_id: u32,
    face_index: u32 = 0,
    size_px: u32 = 0,
    variation_key: u64 = 0,
    fill_rule: FillRule = .non_zero,
};

comptime {
    std.debug.assert(@sizeOf(Color) == 16);
    std.debug.assert(@sizeOf(Viewport) == 8);
    std.debug.assert(@sizeOf(Point2D64) == 16);
    std.debug.assert(@sizeOf(Rect64) == 32);
    std.debug.assert(@sizeOf(Affine2D64) == 48);
    std.debug.assert(@sizeOf(FrameView2D) == 64);
    std.debug.assert(@sizeOf(FontHandle) == 4);
}

test "Color exposes common constants and RGBA constructor" {
    try std.testing.expectEqual(@as(f32, 0), Color.black.rgba[0]);
    try std.testing.expectEqual(@as(f32, 1), Color.white.rgba[3]);
    const c = Color.fromRgba(0.25, 0.5, 0.75, 1);
    try std.testing.expectEqual(@as(f32, 0.75), c.rgba[2]);
}

test "Transform aliases the f64 affine frame transform" {
    const t = Transform.translation(10, -2);
    const p = t.apply(.{ 1, 2 });
    try std.testing.expectApproxEqAbs(@as(f64, 11), p[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), p[1], 1.0e-12);

    const r = Transform.rotation(std.math.pi / 2.0);
    const q = r.apply(.{ 1, 0 });
    try std.testing.expectApproxEqAbs(@as(f64, 0), q[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 1), q[1], 1.0e-12);
}

test "Affine2D64 applies points and vectors with distinct affine semantics" {
    const t = Affine2D64.init(2, 3, 5, 7, 11, 13);

    const point = t.apply(.{ 17, 19 });
    try std.testing.expectApproxEqAbs(@as(f64, 140), point[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 197), point[1], 1.0e-12);

    const vector = t.applyVector(.{ 17, 19 });
    try std.testing.expectApproxEqAbs(@as(f64, 129), vector[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 184), vector[1], 1.0e-12);
}

test "Affine2D64 composes, inverts, and transforms bounds" {
    const t = Affine2D64.compose(Affine2D64.translation(10, 20), Affine2D64.scale(2, 3));
    const p = t.apply(.{ 4, 5 });
    try std.testing.expectApproxEqAbs(@as(f64, 18), p[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 35), p[1], 1.0e-12);

    const inv = t.inverse().?;
    const q = inv.apply(p);
    try std.testing.expectApproxEqAbs(@as(f64, 4), q[0], 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 5), q[1], 1.0e-12);

    const bounds = Affine2D64.rotation(std.math.pi / 2.0).transformRect(.{ .x_min = 0, .y_min = 0, .x_max = 2, .y_max = 1 });
    try std.testing.expectApproxEqAbs(@as(f64, -1), bounds.x_min, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 2), bounds.y_max, 1.0e-12);
}

test "PrecisionPolicy selects even tiers and rejects unsupported zoom" {
    const policy = PrecisionPolicy{};
    const moderate = Affine2D64.scale(1024, 1024);
    try std.testing.expectEqual(@as(u8, 12), try policy.selectFractionBits(moderate));

    const high = Affine2D64.scale(1_000_000, 1_000_000);
    try std.testing.expectEqual(@as(u8, 22), try policy.selectFractionBits(high));

    const too_high = Affine2D64.scale(100_000_000, 100_000_000);
    try std.testing.expectError(error.PrecisionUnsupported, policy.selectFractionBits(too_high));

    try std.testing.expectError(
        error.InvalidPrecisionPolicy,
        (PrecisionPolicy{ .min_fraction_bits = 24, .max_fraction_bits = 12 }).selectFractionBits(moderate),
    );

    const nearly_singular = Affine2D64.scale(1.0e6, 1.0e-6);
    try std.testing.expectError(error.InvalidTransform, policy.selectFractionBits(nearly_singular));
}

test "FillRule maps to shader flags" {
    try std.testing.expectEqual(@as(u32, 0), FillRule.non_zero.shaderFlags());
    try std.testing.expectEqual(@as(u32, 1), FillRule.even_odd.shaderFlags());
}
