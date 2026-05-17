const std = @import("std");
const math = std.math;
const testing = std.testing;

const Vec2 = @Vector(2, f32);
const Vec4 = @Vector(4, f32);

/// PGA Cl(2,0,1) motor for 2D rigid transforms.
/// Storage layout: [s, e12, e01, e02] matching GPU float4.
pub const Motor = extern struct {
    m: [4]f32,

    /// Identity motor (no rotation, no translation).
    pub const identity = Motor{ .m = .{ 1, 0, 0, 0 } };

    /// Precomputed state for composing many translations onto the same motor.
    pub const TranslationComposer = struct {
        base: Motor,
        c3: f32,
        s3: f32,

        pub fn compose(self: TranslationComposer, tx: f32, ty: f32) Motor {
            const half_translation: Vec2 = .{ tx * 0.5, ty * 0.5 };
            const translated = rotate(.{ self.c3, self.s3 }, half_translation);
            return .{ .m = .{
                self.base.m[0],
                self.base.m[1],
                translated[0] + self.base.m[2],
                translated[1] + self.base.m[3],
            } };
        }
    };

    /// Precompute constants used by repeated `composeTranslation()` calls.
    pub fn translationComposer(self: Motor) TranslationComposer {
        const rot3 = tripleHalfRotor(self.rotor());
        return .{
            .base = self,
            .c3 = rot3[0],
            .s3 = rot3[1],
        };
    }

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

    /// Compose two motors: result applies `b` first, then `a`.
    /// Consistent with apply()/toMat() CCW convention.
    ///
    /// Derived from the functional composition constraint:
    ///   compose(a, b).apply(p) == a.apply(b.apply(p))
    ///
    /// Translation is stored as q = R(θ/2)·T/2, so composition reduces to:
    ///   q' = R(θB/2)·qA + R(3θA/2)·qB
    /// where R(3θA/2) uses the triple-angle identities below.
    pub fn compose(a: Motor, b: Motor) Motor {
        const rotor_a = a.rotor();
        const rotor_b = b.rotor();
        const rotor_c = multiplyRotors(rotor_a, rotor_b);
        const translation = rotate(rotor_b, a.translationStorage()) +
            rotate(tripleHalfRotor(rotor_a), b.translationStorage());

        return .{ .m = .{
            rotor_c[0],
            rotor_c[1],
            translation[0],
            translation[1],
        } };
    }

    /// Compose this motor with a pure translation.
    /// Equivalent to `compose(self, fromTranslation(tx, ty))` but avoids
    /// redundant terms (sb=1, ab=0).
    ///
    /// With sb=1, ab=0 the compose formula reduces to rotation of [htx,hty]
    /// by 3·(θ/2) and adding the existing translation:
    ///   c3 = s·(1−4α²),  s3 = α·(3−4α²)   (triple-half-angle: cos/sin of 3θ/2)
    ///   e01' = c3·htx − s3·hty + txA
    ///   e02' = s3·htx + c3·hty + tyA
    pub fn composeTranslation(self: Motor, tx: f32, ty: f32) Motor {
        return self.translationComposer().compose(tx, ty);
    }

    /// Expand motor to a column-major 4×4 matrix, pre-multiplied by `projection`.
    /// Result = projection × motor_mat.  Exploits motor matrix sparsity (cols 2,3
    /// are identity/translation) to avoid a full 4×4 multiply.
    ///
    /// Motor matrix (column-major, [col][row]):
    ///   col0 = [1-2α²,  2sα,  0, 0]
    ///   col1 = [-2sα,  1-2α², 0, 0]
    ///   col2 = [0,      0,    1, 0]
    ///   col3 = [2(s·tx+α·ty), 2(s·ty-α·tx), 0, 1]
    pub fn toMat(self: Motor, projection: [4][4]f32) [4][4]f32 {
        const linear = self.linearRotor();
        const translation = self.translationVector();
        const c: Vec4 = @splat(linear[0]);
        const s: Vec4 = @splat(linear[1]);
        const dx: Vec4 = @splat(translation[0]);
        const dy: Vec4 = @splat(translation[1]);
        const p0: Vec4 = projection[0];
        const p1: Vec4 = projection[1];
        return .{
            p0 * c + p1 * s,
            p1 * c - p0 * s,
            projection[2],
            p0 * dx + p1 * dy + @as(Vec4, projection[3]),
        };
    }

    /// Apply motor to a 2D point via sandwich product M·p·M̃.
    /// Uses unit-motor identity: s² + α² = 1 ⟹ s² - α² = 1 - 2α².
    /// For motor [s, α, tx, ty] and point (x, y):
    ///   x' = (1-2α²)·x - 2sα·y + 2(s·tx + α·ty)
    ///   y' =  2sα·x + (1-2α²)·y + 2(s·ty - α·tx)
    pub fn apply(self: Motor, p: [2]f32) [2]f32 {
        const transformed = rotate(self.linearRotor(), @as(Vec2, p)) + self.translationVector();
        return transformed;
    }

    /// Reverse of a unit motor — the inverse transform.
    /// Converts through Euclidean translation space because this storage keeps
    /// translation as a half-angle-rotated homogeneous component.
    pub fn reverse(self: Motor) Motor {
        const inverse_rotor: Vec2 = .{ self.m[0], -self.m[1] };
        const linear = self.linearRotor();
        const translation = self.translationVector();
        const inverse_linear: Vec2 = .{ linear[0], -linear[1] };
        const inverse_translation = @as(Vec2, @splat(-1.0)) * rotate(inverse_linear, translation);
        const inverse_storage = @as(Vec2, @splat(0.5)) * rotate(inverse_rotor, inverse_translation);

        return .{ .m = .{
            inverse_rotor[0],
            inverse_rotor[1],
            inverse_storage[0],
            inverse_storage[1],
        } };
    }

    /// Motor from rotation by `angle` radians about an arbitrary center `(cx, cy)`.
    /// Equivalent to translate(cx,cy) ∘ rotate(angle) ∘ translate(-cx,-cy).
    pub fn fromRotationAbout(angle: f32, cx: f32, cy: f32) Motor {
        const t_neg = Motor.fromTranslation(-cx, -cy);
        const rot = Motor.fromRotation(angle);
        const t_pos = Motor.fromTranslation(cx, cy);
        return Motor.compose(t_pos, Motor.compose(rot, t_neg));
    }

    /// Renormalize a motor so that s² + e12² = 1.
    /// Scales every component because motors are homogeneous coordinates.
    pub fn unitize(self: Motor) Motor {
        const r = self.rotor();
        const norm_sq = @reduce(.Add, r * r);
        std.debug.assert(std.math.isFinite(norm_sq) and norm_sq > 0.0);

        const scaled: Vec4 = @as(Vec4, self.m) * @as(Vec4, @splat(1.0 / @sqrt(norm_sq)));
        return .{ .m = scaled };
    }

    fn rotor(self: Motor) Vec2 {
        return .{ self.m[0], self.m[1] };
    }

    fn translationStorage(self: Motor) Vec2 {
        return .{ self.m[2], self.m[3] };
    }

    fn linearRotor(self: Motor) Vec2 {
        const s = self.m[0];
        const a = self.m[1];
        return .{ 1.0 - 2.0 * a * a, 2.0 * s * a };
    }

    fn translationVector(self: Motor) Vec2 {
        return @as(Vec2, @splat(2.0)) * rotate(.{ self.m[0], -self.m[1] }, self.translationStorage());
    }
};

fn multiplyRotors(a: Vec2, b: Vec2) Vec2 {
    return .{
        a[0] * b[0] - a[1] * b[1],
        a[0] * b[1] + a[1] * b[0],
    };
}

fn tripleHalfRotor(rotor: Vec2) Vec2 {
    const s = rotor[0];
    const a = rotor[1];
    const a2 = a * a;
    return .{ s * (1.0 - 4.0 * a2), a * (3.0 - 4.0 * a2) };
}

fn rotate(rotor: Vec2, v: Vec2) Vec2 {
    const swapped = @shuffle(f32, v, undefined, [2]i32{ 1, 0 });
    return @as(Vec2, @splat(rotor[0])) * v + Vec2{ -rotor[1], rotor[1] } * swapped;
}

comptime {
    std.debug.assert(@sizeOf(Motor) == 16);
    std.debug.assert(@alignOf(Motor) == 4);
}

/// 2D point in Euclidean coordinates.
/// Storage: [x, y] as [2]f32 (w=1 implicit).
pub const Point = extern struct {
    v: [2]f32,

    pub fn init(x: f32, y: f32) Point {
        return .{ .v = .{ x, y } };
    }

    /// Transform this point by a motor.
    pub fn transform(self: Point, motor: Motor) Point {
        return .{ .v = motor.apply(self.v) };
    }
};

comptime {
    std.debug.assert(@sizeOf(Point) == 8);
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

test "Motor.compose identity is neutral" {
    const m = Motor.fromTranslation(5.0, 3.0);
    const c1 = Motor.compose(Motor.identity, m);
    const c2 = Motor.compose(m, Motor.identity);
    for (0..4) |i| {
        try testing.expectApproxEqAbs(m.m[i], c1.m[i], 1e-6);
        try testing.expectApproxEqAbs(m.m[i], c2.m[i], 1e-6);
    }
}

test "Motor.compose two translations add" {
    const a = Motor.fromTranslation(3.0, 0.0);
    const b = Motor.fromTranslation(0.0, 4.0);
    const ab = Motor.compose(a, b);
    const p = ab.apply(.{ 0.0, 0.0 });
    try testing.expectApproxEqAbs(@as(f32, 3.0), p[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 4.0), p[1], 1e-5);
}

test "Motor.compose rotate then translate" {
    // compose(tr, rot) applies rot first, then tr.
    const rot = Motor.fromRotation(std.math.pi / 2.0);
    const tr = Motor.fromTranslation(2.0, 0.0);
    const m = Motor.compose(tr, rot);
    // (1,0) → rotate 90° CCW → (0,1) → translate (2,0) → (2,1)
    const p = m.apply(.{ 1.0, 0.0 });
    try testing.expectApproxEqAbs(@as(f32, 2.0), p[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p[1], 1e-5);
}

test "Motor.toMat identity produces identity matrix" {
    const projection = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const result = Motor.identity.toMat(projection);
    for (0..4) |col| {
        for (0..4) |row| {
            const expected: f32 = if (row == col) 1.0 else 0.0;
            try testing.expectApproxEqAbs(expected, result[col][row], 1e-6);
        }
    }
}

test "Motor.toMat translation appears in column 3" {
    const projection = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const m = Motor.fromTranslation(5.0, -2.0);
    const result = m.toMat(projection);
    try testing.expectApproxEqAbs(@as(f32, 5.0), result[3][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -2.0), result[3][1], 1e-5);
}

test "Motor.toMat rotation matches apply" {
    const projection = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const m = Motor.fromRotation(std.math.pi / 3.0);
    const mat = m.toMat(projection);
    const px: f32 = 3.0;
    const py: f32 = 1.0;
    // Transform via matrix (column-major: result[col][row]).
    const mat_x = mat[0][0] * px + mat[1][0] * py + mat[3][0];
    const mat_y = mat[0][1] * px + mat[1][1] * py + mat[3][1];
    const applied = m.apply(.{ px, py });
    try testing.expectApproxEqAbs(applied[0], mat_x, 1e-5);
    try testing.expectApproxEqAbs(applied[1], mat_y, 1e-5);
}

test "Motor.toMat respects non-identity projection" {
    // Uniform scale projection: 2x in x, 3x in y.
    const projection = [4][4]f32{
        .{ 2, 0, 0, 0 },
        .{ 0, 3, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    // Pure translation by (4, 6).
    const m = Motor.fromTranslation(4.0, 6.0);
    const result = m.toMat(projection);
    // projection × motor_mat: translation column is projection × [4, 6, 0, 1]ᵀ = [8, 18, 0, 1]
    try testing.expectApproxEqAbs(@as(f32, 8.0), result[3][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 18.0), result[3][1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), result[3][3], 1e-5);
}

test "Motor.toMat combined motor matches apply" {
    const projection = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    // Combine: rotate 45° then translate (1, 2).
    const rot = Motor.fromRotation(std.math.pi / 4.0);
    const tr = Motor.fromTranslation(1.0, 2.0);
    const m = Motor.compose(tr, rot); // rot first, then tr

    const mat = m.toMat(projection);
    // Test point (2, 0).
    const px: f32 = 2.0;
    const py: f32 = 0.0;
    const mat_x = mat[0][0] * px + mat[1][0] * py + mat[3][0];
    const mat_y = mat[0][1] * px + mat[1][1] * py + mat[3][1];
    const applied = m.apply(.{ px, py });
    try testing.expectApproxEqAbs(applied[0], mat_x, 1e-5);
    try testing.expectApproxEqAbs(applied[1], mat_y, 1e-5);
}

test "Point.transform matches Motor.apply" {
    const m = Motor.compose(
        Motor.fromTranslation(1.0, 2.0),
        Motor.fromRotation(std.math.pi / 4.0),
    );
    const p = Point.init(3.0, 0.0);
    const transformed = p.transform(m);
    const applied = m.apply(.{ 3.0, 0.0 });
    try testing.expectApproxEqAbs(applied[0], transformed.v[0], 1e-6);
    try testing.expectApproxEqAbs(applied[1], transformed.v[1], 1e-6);
}

test "Motor round-trip: reverse recovers original point" {
    const angle: f32 = 1.2;
    const tx: f32 = 7.0;
    const ty: f32 = -3.0;
    const rot = Motor.fromRotation(angle);
    const tr = Motor.fromTranslation(tx, ty);
    const original = [2]f32{ 42.0, -17.0 };
    // Forward: compose(tr, rot) applies rot first, then tr.
    const m = Motor.compose(tr, rot);
    const forward = m.apply(original);
    // Inverse: undo tr, then undo rot.
    const back = rot.reverse().apply(tr.reverse().apply(forward));
    try testing.expectApproxEqAbs(original[0], back[0], 1e-4);
    try testing.expectApproxEqAbs(original[1], back[1], 1e-4);
}

test "Motor.reverse inverts composed motor directly" {
    const m = Motor.compose(
        Motor.fromRotationAbout(0.8, 3.0, -4.0),
        Motor.compose(Motor.fromTranslation(12.0, -7.0), Motor.fromRotation(-0.35)),
    );
    const points = [_][2]f32{
        .{ 0, 0 },
        .{ 1, -2 },
        .{ 128, 64 },
    };

    const inverse = m.reverse();
    for (points) |point| {
        const round_trip = inverse.apply(m.apply(point));
        try testing.expectApproxEqAbs(point[0], round_trip[0], 1.0e-4);
        try testing.expectApproxEqAbs(point[1], round_trip[1], 1.0e-4);
    }
}

test "Motor.fromRotationAbout: center is fixed point" {
    // Rotation about (3, 5) at various angles must leave (3, 5) unchanged.
    const cx: f32 = 3.0;
    const cy: f32 = 5.0;
    const angles = [_]f32{ 0.0, std.math.pi / 6.0, std.math.pi / 2.0, std.math.pi, 2.3 };
    for (angles) |angle| {
        const m = Motor.fromRotationAbout(angle, cx, cy);
        const p = m.apply(.{ cx, cy });
        try testing.expectApproxEqAbs(cx, p[0], 1e-4);
        try testing.expectApproxEqAbs(cy, p[1], 1e-4);
    }
}

test "Motor.fromRotationAbout: 90° rotates non-center point correctly" {
    // Rotate (1, 0) by 90° CCW about (0, 1).
    // Expected: R(90°)×((1,0)-(0,1)) + (0,1) = R(90°)×(1,-1) + (0,1) = (1,1) + (0,1) = (1,2)
    const m = Motor.fromRotationAbout(std.math.pi / 2.0, 0.0, 1.0);
    const p = m.apply(.{ 1.0, 0.0 });
    try testing.expectApproxEqAbs(@as(f32, 1.0), p[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 2.0), p[1], 1e-5);
}

test "Motor.fromRotationAbout: toMat matches apply" {
    const projection = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const m = Motor.fromRotationAbout(std.math.pi / 3.0, 4.0, -2.0);
    const mat = m.toMat(projection);
    const points = [_][2]f32{ .{ 4, -2 }, .{ 0, 0 }, .{ 10, 5 }, .{ -3, 7 } };
    for (points) |pt| {
        const mat_x = mat[0][0] * pt[0] + mat[1][0] * pt[1] + mat[3][0];
        const mat_y = mat[0][1] * pt[0] + mat[1][1] * pt[1] + mat[3][1];
        const applied = m.apply(pt);
        try testing.expectApproxEqAbs(applied[0], mat_x, 1e-4);
        try testing.expectApproxEqAbs(applied[1], mat_y, 1e-4);
    }
}

test "Motor.compose: rotation+translation matches sequential apply" {
    // compose(a, b).apply(p) must equal a.apply(b.apply(p)).
    // Nonzero rotation exercises the c1/sw1 cross-terms in the composition formula.
    const rot_a = Motor.fromRotationAbout(std.math.pi / 3.0, 1.0, 2.0);
    const rot_b = Motor.fromRotation(std.math.pi / 6.0);
    const tr_b = Motor.fromTranslation(3.0, -1.0);
    const motor_b = Motor.compose(tr_b, rot_b);
    const composed = Motor.compose(rot_a, motor_b);

    const p = [2]f32{ 2.0, 1.0 };
    const step1 = motor_b.apply(p);
    const step2 = rot_a.apply(step1);
    const result = composed.apply(p);
    try testing.expectApproxEqAbs(step2[0], result[0], 1e-5);
    try testing.expectApproxEqAbs(step2[1], result[1], 1e-5);
}

test "Motor.composeTranslation matches general composition" {
    const motor = Motor.compose(
        Motor.fromTranslation(50.0, 30.0),
        Motor.fromRotation(std.math.pi / 6.0),
    );
    const advances = [_]f32{ 640, 1280, 1920 };
    const point = [2]f32{ 10.0, 5.0 };

    for (advances) |tx| {
        const specialized = motor.composeTranslation(tx, 0).apply(point);
        const general = Motor.compose(motor, Motor.fromTranslation(tx, 0)).apply(point);

        try testing.expectApproxEqAbs(general[0], specialized[0], 1e-2);
        try testing.expectApproxEqAbs(general[1], specialized[1], 1e-2);
    }
}

test "Motor.translationComposer matches repeated translation composition" {
    const motor = Motor.compose(
        Motor.fromTranslation(10.0, -20.0),
        Motor.fromRotation(std.math.pi / 3.0),
    );
    const composer = motor.translationComposer();
    const translations = [_][2]f32{
        .{ 0, 0 },
        .{ 64, 0 },
        .{ 64, -32 },
        .{ 128, 96 },
    };

    for (translations) |translation| {
        const cached = composer.compose(translation[0], translation[1]);
        const direct = motor.composeTranslation(translation[0], translation[1]);
        const general = Motor.compose(motor, Motor.fromTranslation(translation[0], translation[1]));

        for (cached.m, direct.m) |actual, expected| {
            try testing.expectApproxEqAbs(expected, actual, 1.0e-6);
        }
        for (cached.m, general.m) |actual, expected| {
            try testing.expectApproxEqAbs(expected, actual, 1.0e-6);
        }
    }
}

test "Motor.unitize restores rotor norm after repeated composition" {
    const small = Motor.fromRotation(0.01);
    var accumulated = small;
    for (0..999) |_| accumulated = Motor.compose(accumulated, small);

    const fixed = accumulated.unitize();
    const fixed_norm = fixed.m[0] * fixed.m[0] + fixed.m[1] * fixed.m[1];
    try testing.expectApproxEqAbs(@as(f32, 1.0), fixed_norm, 1e-6);

    const fresh = Motor.fromRotation(1000.0 * 0.01);
    const point = [2]f32{ 1, 0 };
    const fixed_point = fixed.apply(point);
    const fresh_point = fresh.apply(point);
    try testing.expectApproxEqAbs(fresh_point[0], fixed_point[0], 0.01);
    try testing.expectApproxEqAbs(fresh_point[1], fixed_point[1], 0.01);
}

test "Motor.unitize rescales homogeneous motor coordinates" {
    const base = Motor.compose(
        Motor.fromTranslation(8.0, -3.0),
        Motor.fromRotation(std.math.pi / 5.0),
    );
    const scaled = Motor{ .m = .{
        base.m[0] * 4.0,
        base.m[1] * 4.0,
        base.m[2] * 4.0,
        base.m[3] * 4.0,
    } };
    const normalized = scaled.unitize();

    for (base.m, normalized.m) |expected, actual| {
        try testing.expectApproxEqAbs(expected, actual, 1.0e-6);
    }
}
