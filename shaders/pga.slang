// shaders/pga.slang
// PGA Cl(2,0,1) Motor — mirrors src/math/pga.zig layout.
// Storage: float4 [s, e12, e01, e02] = 16 bytes.

struct Motor
{
    float4 m; // [s, e12, e01, e02]

    // Apply motor to a 2D point via sandwich product.
    // For motor [s, α, tx, ty] and point (x, y):
    //   x' = (s²-α²)·x - 2sα·y + 2(s·tx + α·ty)
    //   y' =  2sα·x + (s²-α²)·y + 2(s·ty - α·tx)
    float2 apply(float2 p)
    {
        float s = m.x;
        float alpha = m.y;
        float tx = m.z;
        float ty = m.w;

        float s2_a2 = s * s - alpha * alpha;
        float two_sa = 2.0 * s * alpha;

        float2 rot = float2(
            s2_a2 * p.x - two_sa * p.y,
            two_sa * p.x + s2_a2 * p.y
        );
        float2 trans = float2(
            2.0 * (s * tx + alpha * ty),
            2.0 * (s * ty - alpha * tx)
        );
        return rot + trans;
    }

    // Expand motor to row-major 4x4 matrix, pre-multiplied by proj.
    // Returns proj * motor_mat.
    float4x4 toMat(float4x4 proj)
    {
        float s = m.x;
        float alpha = m.y;
        float tx = m.z;
        float ty = m.w;

        float s2_a2 = s * s - alpha * alpha;
        float two_sa = 2.0 * s * alpha;
        float dx = 2.0 * (s * tx + alpha * ty);
        float dy = 2.0 * (s * ty - alpha * tx);

        float4x4 motor_mat = float4x4(
            float4(s2_a2,  -two_sa, 0.0, dx),
            float4(two_sa,  s2_a2,  0.0, dy),
            float4(0.0,     0.0,    1.0,  0.0),
            float4(0.0,     0.0,    0.0,  1.0)
        );

        return mul(proj, motor_mat);
    }
};
