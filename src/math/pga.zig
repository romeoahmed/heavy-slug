const std = @import("std");
const math = std.math;
const testing = std.testing;

/// PGA Cl(2,0,1) Motor — encodes 2D rigid-body transforms.
/// Storage layout: [s, e12, e01, e02] matching GPU float4.
pub const Motor = extern struct {
    m: [4]f32,

    /// Identity motor (no rotation, no translation).
    pub const identity = Motor{ .m = .{ 1, 0, 0, 0 } };

    /// Motor from pure translation (tx, ty).
    /// Encoding: s=1, e12=0, e01=tx/2, e02=ty/2
    pub fn fromTranslation(tx: f32, ty: f32) Motor {
        return .{ .m = .{ 1, 0, tx * 0.5, ty * 0.5 } };
    }

    /// Motor from pure rotation by `angle` radians about the origin.
    /// Encoding: s=cos(θ/2), e12=sin(θ/2), e01=0, e02=0.
    pub fn fromRotation(angle: f32) Motor {
        const half: f32 = angle * 0.5;
        return .{ .m = .{ @cos(half), @sin(half), 0, 0 } };
    }

    /// Apply motor to a 2D point via sandwich product M·p·M̃.
    /// For motor [s, α, tx, ty] and point (x, y):
    ///   x' = (s²-α²)·x - 2sα·y + 2(s·tx + α·ty)
    ///   y' =  2sα·x + (s²-α²)·y + 2(s·ty - α·tx)
    pub fn apply(self: Motor, p: [2]f32) [2]f32 {
        const s = self.m[0];
        const alpha = self.m[1];
        const tx = self.m[2];
        const ty = self.m[3];

        const s2_a2 = s * s - alpha * alpha;
        const two_sa = 2.0 * s * alpha;

        return .{
            s2_a2 * p[0] - two_sa * p[1] + 2.0 * (s * tx + alpha * ty),
            two_sa * p[0] + s2_a2 * p[1] + 2.0 * (s * ty - alpha * tx),
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Motor) == 16);
    std.debug.assert(@alignOf(Motor) == 4);
}

test "Motor identity is unit motor" {
    const id = Motor.identity;
    try testing.expectEqual(@as(f32, 1), id.m[0]);
    try testing.expectEqual(@as(f32, 0), id.m[1]);
    try testing.expectEqual(@as(f32, 0), id.m[2]);
    try testing.expectEqual(@as(f32, 0), id.m[3]);
}

test "Motor.fromTranslation encodes tx, ty" {
    const m = Motor.fromTranslation(3.0, 4.0);
    try testing.expectEqual(@as(f32, 1), m.m[0]);
    try testing.expectEqual(@as(f32, 0), m.m[1]);
    try testing.expectApproxEqAbs(@as(f32, 1.5), m.m[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 2.0), m.m[3], 1e-6);
}

test "Motor.fromRotation encodes angle" {
    const m = Motor.fromRotation(math.pi / 2.0);
    const c: f32 = @cos(@as(f32, math.pi / 4.0));
    const s: f32 = @sin(@as(f32, math.pi / 4.0));
    try testing.expectApproxEqAbs(c, m.m[0], 1e-6);
    try testing.expectApproxEqAbs(s, m.m[1], 1e-6);
    try testing.expectEqual(@as(f32, 0), m.m[2]);
    try testing.expectEqual(@as(f32, 0), m.m[3]);
}

test "Motor.apply identity preserves point" {
    const p = Motor.identity.apply(.{ 5.0, 7.0 });
    try testing.expectApproxEqAbs(@as(f32, 5.0), p[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 7.0), p[1], 1e-6);
}

test "Motor.apply translation moves point" {
    const m = Motor.fromTranslation(10.0, -3.0);
    const p = m.apply(.{ 1.0, 2.0 });
    try testing.expectApproxEqAbs(@as(f32, 11.0), p[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, -1.0), p[1], 1e-6);
}

test "Motor.apply rotation 90° rotates point" {
    const m = Motor.fromRotation(std.math.pi / 2.0);
    const p = m.apply(.{ 1.0, 0.0 });
    try testing.expectApproxEqAbs(@as(f32, 0.0), p[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p[1], 1e-5);
}
