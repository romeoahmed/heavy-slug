// PGA Cl(2,0,1) motor; mirrors src/math/pga.zig layout.
// Storage: float4 [s, e12, e01, e02] = 16 bytes.

struct MotorAffine
{
    float c;
    float r;
    float2 t;

    float2 apply(float2 p)
    {
        return float2(c * p.x - r * p.y, r * p.x + c * p.y) + t;
    }
};

struct Motor
{
    float4 m; // [s, e12, e01, e02]

    MotorAffine affine()
    {
        float s = m.x;
        float a = m.y;
        float tx = m.z;
        float ty = m.w;

        MotorAffine out;
        out.c = 1.0 - 2.0 * a * a;
        out.r = 2.0 * s * a;
        out.t = 2.0 * float2(s * tx + a * ty, s * ty - a * tx);
        return out;
    }

    // Unit-motor identity: s^2 + alpha^2 = 1  =>  s^2 - alpha^2 = 1 - 2*alpha^2.
    // For motor [s, alpha, tx, ty] and point (x, y):
    //   x' = (1-2*alpha^2)*x - 2*s*alpha*y + 2*(s*tx + alpha*ty)
    //   y' =  2*s*alpha*x + (1-2*alpha^2)*y + 2*(s*ty - alpha*tx)
    float2 apply(float2 p)
    {
        return affine().apply(p);
    }
};
