//! Public core value types used by renderers and applications.

const std = @import("std");
const pga = @import("../math/pga.zig");

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

pub const Projection = extern struct {
    columns: [4][4]f32,

    pub const identity: Projection = .{ .columns = .{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    } };

    pub fn fromColumns(columns: [4][4]f32) Projection {
        return .{ .columns = columns };
    }
};

pub const Transform = extern struct {
    motor: pga.Motor,

    pub const identity: Transform = .{ .motor = pga.Motor.identity };

    pub fn translation(x: f32, y: f32) Transform {
        return .{ .motor = pga.Motor.fromTranslation(x, y) };
    }

    pub fn rotation(angle_radians: f32) Transform {
        return .{ .motor = pga.Motor.fromRotation(angle_radians) };
    }

    pub fn rotationAbout(angle_radians: f32, x: f32, y: f32) Transform {
        return .{ .motor = pga.Motor.fromRotationAbout(angle_radians, x, y) };
    }

    pub fn compose(a: Transform, b: Transform) Transform {
        return .{ .motor = pga.Motor.compose(a.motor, b.motor) };
    }

    pub fn translate(self: Transform, x: f32, y: f32) Transform {
        return .{ .motor = self.motor.composeTranslation(x, y) };
    }

    pub fn apply(self: Transform, point: [2]f32) [2]f32 {
        return self.motor.apply(point);
    }

    pub fn toMotor(self: Transform) pga.Motor {
        return self.motor;
    }

    pub fn toProjectionMatrix(self: Transform, projection: [4][4]f32) [4][4]f32 {
        return self.motor.toMat(projection);
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
    std.debug.assert(@sizeOf(Projection) == 64);
    std.debug.assert(@sizeOf(Transform) == 16);
    std.debug.assert(@sizeOf(FontHandle) == 4);
}

test "Color exposes common constants and RGBA constructor" {
    try std.testing.expectEqual(@as(f32, 0), Color.black.rgba[0]);
    try std.testing.expectEqual(@as(f32, 1), Color.white.rgba[3]);
    const c = Color.fromRgba(0.25, 0.5, 0.75, 1);
    try std.testing.expectEqual(@as(f32, 0.75), c.rgba[2]);
}

test "Transform wraps PGA motor without changing behavior" {
    const t = Transform.translation(10, -2);
    const p = t.apply(.{ 1, 2 });
    try std.testing.expectApproxEqAbs(@as(f32, 11), p[0], 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 0), p[1], 1.0e-6);

    const r = Transform.rotation(std.math.pi / 2.0);
    const q = r.apply(.{ 1, 0 });
    try std.testing.expectApproxEqAbs(@as(f32, 0), q[0], 1.0e-5);
    try std.testing.expectApproxEqAbs(@as(f32, 1), q[1], 1.0e-5);
}

test "FillRule maps to shader flags" {
    try std.testing.expectEqual(@as(u32, 0), FillRule.non_zero.shaderFlags());
    try std.testing.expectEqual(@as(u32, 1), FillRule.even_odd.shaderFlags());
}
