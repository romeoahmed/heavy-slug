const std = @import("std");
const math = std.math;
const testing = std.testing;

/// PGA Cl(2,0,1) Motor — encodes 2D rigid-body transforms.
/// Storage layout: [s, e12, e01, e02] matching GPU float4.
pub const Motor = extern struct {
    m: [4]f32,

    /// Identity motor (no rotation, no translation).
    pub const identity = Motor{ .m = .{ 1, 0, 0, 0 } };

    /// Convert storage array to @Vector for SIMD operations.
    /// Free conversion — same memory layout, no copy.
    inline fn vec(self: Motor) @Vector(4, f32) {
        return self.m;
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

    /// Compose two motors (geometric product): result applies `b` first, then `a`.
    /// For motors A=[sA, αA, txA, tyA] and B=[sB, αB, txB, tyB]:
    ///   s'   = sA·sB - αA·αB
    ///   e12' = sA·αB + αA·sB
    ///   e01' = sA·txB + txA·sB + αA·tyB - tyA·αB
    ///   e02' = sA·tyB + tyA·sB - αA·txB + txA·αB
    pub fn compose(a: Motor, b: Motor) Motor {
        const av = a.vec();
        const bv = b.vec();

        // Broadcast each scalar component of A across a full vector
        const sa: @Vector(4, f32) = @splat(av[0]); // [sA, sA, sA, sA]
        const alpha_a: @Vector(4, f32) = @splat(av[1]); // [αA, αA, αA, αA]
        const txa: @Vector(4, f32) = @splat(av[2]); // [txA, txA, txA, txA]
        const tya: @Vector(4, f32) = @splat(av[3]); // [tyA, tyA, tyA, tyA]

        // Swizzle B components for the cross-terms:
        // bv           = [sB,  αB,  txB, tyB]
        // b_swap_01    = [αB,  sB,  tyB, txB]  (swap pairs)
        const b_swap_01: @Vector(4, f32) = @shuffle(f32, bv, undefined, [4]i32{ 1, 0, 3, 2 });

        // Term 1: sa * bv = [sA·sB, sA·αB, sA·txB, sA·tyB]
        const term1 = sa * bv;
        // Term 2: alpha_a * b_swap = [αA·αB, αA·sB, αA·tyB, αA·txB]
        const term2 = alpha_a * b_swap_01;
        // b_s_a = [sB, sB, sB, αB] — slots 2,3 carry sB and αB for tx/ty cross-terms.
        // b_a_s = [sB, sB, αB, sB] — slots 2,3 carry αB and sB for ty/tx cross-terms.
        // Slots 0,1 of both hold sB but are masked to zero by signs_34/signs_34n below.
        const b_s_a: @Vector(4, f32) = @shuffle(f32, bv, undefined, [4]i32{ 0, 0, 0, 1 });
        const b_a_s: @Vector(4, f32) = @shuffle(f32, bv, undefined, [4]i32{ 0, 0, 1, 0 });
        const term3 = txa * b_s_a; // slots 2,3: txA·sB, txA·αB (slots 0,1 masked below)
        const term4 = tya * b_a_s; // slots 2,3: tyA·αB, tyA·sB (slots 0,1 masked below)

        // Signs for the geometric product formula.
        // signs_34/signs_34n: zeros in slots 0,1 mask out tx/ty contributions from
        // s' and e12'; ±1 in slots 2,3 apply the required sign for e01' and e02'.

        // Signs: s' = +sa·sB - αA·αB, α' = +sA·αB + αA·sB
        //        tx' = +sA·txB + txA·sB + αA·tyB - tyA·αB
        //        ty' = +sA·tyB + tyA·sB - αA·txB + txA·αB
        const signs_2 = @Vector(4, f32){ -1, 1, 1, -1 };
        const signs_34 = @Vector(4, f32){ 0, 0, 1, 1 };
        const signs_34n = @Vector(4, f32){ 0, 0, -1, 1 };

        const result = term1 + term2 * signs_2 + term3 * signs_34 + term4 * signs_34n;

        return .{ .m = result };
    }

    /// Expand motor to a column-major 4×4 matrix, pre-multiplied by `proj`.
    /// Result = proj × motor_mat.
    ///
    /// Motor matrix (column-major, [col][row]):
    ///   col0 = [s²-α²,  2sα,  0, 0]
    ///   col1 = [-2sα,  s²-α², 0, 0]
    ///   col2 = [0,      0,    1, 0]
    ///   col3 = [2(s·tx+α·ty), 2(s·ty-α·tx), 0, 1]
    pub fn toMat(self: Motor, proj: [4][4]f32) [4][4]f32 {
        const s = self.m[0];
        const alpha = self.m[1];
        const tx = self.m[2];
        const ty = self.m[3];

        const s2_a2 = s * s - alpha * alpha;
        const two_sa = 2.0 * s * alpha;
        const dx = 2.0 * (s * tx + alpha * ty);
        const dy = 2.0 * (s * ty - alpha * tx);

        const motor_mat = [4][4]f32{
            .{ s2_a2, two_sa, 0, 0 },
            .{ -two_sa, s2_a2, 0, 0 },
            .{ 0, 0, 1, 0 },
            .{ dx, dy, 0, 1 },
        };

        return matMul(proj, motor_mat);
    }

    /// Apply motor to a 2D point via sandwich product M·p·M̃.
    /// For motor [s, α, tx, ty] and point (x, y):
    ///   x' = (s²-α²)·x - 2sα·y + 2(s·tx + α·ty)
    ///   y' =  2sα·x + (s²-α²)·y + 2(s·ty - α·tx)
    pub fn apply(self: Motor, p: [2]f32) [2]f32 {
        const v = self.vec();
        const s = v[0];
        const alpha = v[1];

        const s2_a2 = s * s - alpha * alpha;
        const two_sa = 2.0 * s * alpha;

        const pv: @Vector(2, f32) = p;
        const rot = @Vector(2, f32){ s2_a2, two_sa } * @as(@Vector(2, f32), @splat(pv[0])) +
            @Vector(2, f32){ -two_sa, s2_a2 } * @as(@Vector(2, f32), @splat(pv[1]));
        const trans = @Vector(2, f32){
            2.0 * (s * v[2] + alpha * v[3]),
            2.0 * (s * v[3] - alpha * v[2]),
        };

        return rot + trans;
    }
};

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

/// Column-major 4×4 matrix multiply: result = a × b.
/// Each column of the result is a linear combination of columns of a,
/// weighted by the corresponding column of b. Uses @Vector(4, f32)
/// for SIMD column operations.
fn matMul(a: [4][4]f32, b: [4][4]f32) [4][4]f32 {
    var result: [4][4]f32 = undefined;
    inline for (0..4) |col| {
        const bc: @Vector(4, f32) = b[col];
        var sum: @Vector(4, f32) = @splat(@as(f32, 0));
        inline for (0..4) |k| {
            const ac: @Vector(4, f32) = a[k];
            sum += ac * @as(@Vector(4, f32), @splat(bc[k]));
        }
        result[col] = sum;
    }
    return result;
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
    // compose(tr, rot) applies rot first, then tr
    const rot = Motor.fromRotation(std.math.pi / 2.0);
    const tr = Motor.fromTranslation(2.0, 0.0);
    const m = Motor.compose(tr, rot);
    // (1,0) → rotate 90° CCW → (0,1) → translate (2,0) → (2,1)
    const p = m.apply(.{ 1.0, 0.0 });
    try testing.expectApproxEqAbs(@as(f32, 2.0), p[0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), p[1], 1e-5);
}

test "Motor.toMat identity produces identity matrix" {
    const proj = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const result = Motor.identity.toMat(proj);
    for (0..4) |col| {
        for (0..4) |row| {
            const expected: f32 = if (row == col) 1.0 else 0.0;
            try testing.expectApproxEqAbs(expected, result[col][row], 1e-6);
        }
    }
}

test "Motor.toMat translation appears in column 3" {
    const proj = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const m = Motor.fromTranslation(5.0, -2.0);
    const result = m.toMat(proj);
    try testing.expectApproxEqAbs(@as(f32, 5.0), result[3][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, -2.0), result[3][1], 1e-5);
}

test "Motor.toMat rotation matches apply" {
    const proj = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    const m = Motor.fromRotation(std.math.pi / 3.0);
    const mat = m.toMat(proj);
    const px: f32 = 3.0;
    const py: f32 = 1.0;
    // Transform via matrix (column-major: result[col][row])
    const mat_x = mat[0][0] * px + mat[1][0] * py + mat[3][0];
    const mat_y = mat[0][1] * px + mat[1][1] * py + mat[3][1];
    const applied = m.apply(.{ px, py });
    try testing.expectApproxEqAbs(applied[0], mat_x, 1e-5);
    try testing.expectApproxEqAbs(applied[1], mat_y, 1e-5);
}

test "Motor.toMat respects non-identity proj" {
    // Uniform scale proj (2x in x, 3x in y)
    const proj = [4][4]f32{
        .{ 2, 0, 0, 0 },
        .{ 0, 3, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    // Pure translation by (4, 6)
    const m = Motor.fromTranslation(4.0, 6.0);
    const result = m.toMat(proj);
    // proj × motor_mat: translation column is proj × [4, 6, 0, 1]ᵀ = [8, 18, 0, 1]
    try testing.expectApproxEqAbs(@as(f32, 8.0), result[3][0], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 18.0), result[3][1], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 1.0), result[3][3], 1e-5);
}

test "Motor.toMat combined motor matches apply" {
    const proj = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    // Combine: rotate 45° then translate (1, 2)
    const rot = Motor.fromRotation(std.math.pi / 4.0);
    const tr = Motor.fromTranslation(1.0, 2.0);
    const m = Motor.compose(tr, rot); // rot first, then tr

    const mat = m.toMat(proj);
    // Test point (2, 0)
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
    // For a normalized motor, reverse M~ = [s, -e12, -e01, -e02] is the inverse.
    // This holds for pure rotors and pure translators individually.
    // Apply the inverse in reverse order: undo rotation, then undo translation.
    const angle: f32 = 1.2;
    const tx: f32 = 7.0;
    const ty: f32 = -3.0;
    const rot = Motor.fromRotation(angle);
    const tr = Motor.fromTranslation(tx, ty);
    const rot_rev = Motor{ .m = .{ rot.m[0], -rot.m[1], -rot.m[2], -rot.m[3] } };
    const tr_rev = Motor{ .m = .{ tr.m[0], -tr.m[1], -tr.m[2], -tr.m[3] } };
    const original = [2]f32{ 42.0, -17.0 };
    // Forward: compose(tr, rot) applies rot first, then tr.
    const m = Motor.compose(tr, rot);
    const forward = m.apply(original);
    // Inverse: undo tr (tr_rev), then undo rot (rot_rev).
    const after_tr_rev = tr_rev.apply(forward);
    const back = rot_rev.apply(after_tr_rev);
    try testing.expectApproxEqAbs(original[0], back[0], 1e-4);
    try testing.expectApproxEqAbs(original[1], back[1], 1e-4);
}
