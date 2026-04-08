// shaders/pga.slang
// PGA Cl(2,0,1) Motor — mirrors src/math/pga.zig layout.
// Storage: float4 [s, e12, e01, e02] = 16 bytes.

struct Motor
{
    float4 m; // [s, e12, e01, e02]

    // Apply motor to a 2D point via sandwich product.
    // Uses unit-motor identity: s^2 + alpha^2 = 1  =>  s^2 - alpha^2 = 1 - 2*alpha^2.
    // For motor [s, alpha, tx, ty] and point (x, y):
    //   x' = (1-2*alpha^2)*x - 2*s*alpha*y + 2*(s*tx + alpha*ty)
    //   y' =  2*s*alpha*x + (1-2*alpha^2)*y + 2*(s*ty - alpha*tx)
    float2 apply(float2 p)
    {
        float s = m.x;
        float a = m.y;
        float tx = m.z;
        float ty = m.w;

        float z2 = 1.0 - 2.0 * a * a;
        float zw = 2.0 * s * a;

        return float2(
            z2 * p.x - zw * p.y + 2.0 * (s * tx + a * ty),
            zw * p.x + z2 * p.y + 2.0 * (s * ty - a * tx)
        );
    }
};
