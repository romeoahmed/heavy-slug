#language slang 2026
module shader_math;

// Small, shared numeric helpers for the Slang hot path. Keep this module free
// of resource bindings so it can be imported by every stage and by CPU-side
// reflection shaders without changing the GPU ABI.
//
// Every callable is marked [ForceInline] so the Metal backend can compile each
// entry-point translation unit independently without emitting duplicate
// external symbols for shared helpers. With Apple's `metal a.ir b.ir` link
// step (Building a shader library by precompiling source files), unattributed
// helpers would collide; ForceInline removes them from the emitted MSL.

public static const int kI32Min = -2147483647 - 1;
public static const int kI32Max = 2147483647;
public static const int kExactF32IntRadius = 16777216;

static const float kI32MinFloat = -2147483648.0;
static const float kI32MaxFloat = 2147483520.0;

[ForceInline] public bool isFinite2(float2 v)
{
    return isfinite(v.x) && isfinite(v.y);
}

[ForceInline] public float2 mul2x2(float4 m, float2 v)
{
    return float2(m.x * v.x + m.z * v.y, m.y * v.x + m.w * v.y);
}

[ForceInline] public int saturatingAddInt(int a, int b)
{
    if (b > 0 && a > kI32Max - b)
        return kI32Max;
    if (b < 0 && a < kI32Min - b)
        return kI32Min;
    return a + b;
}

[ForceInline] public int boundedQFromFloat(float v, bool upper)
{
    if (!isfinite(v))
        return upper ? kI32Max : kI32Min;

    float rounded = upper ? ceil(v) : floor(v);
    if (rounded <= kI32MinFloat)
        return kI32Min;
    if (rounded >= kI32MaxFloat)
        return kI32Max;
    return int(rounded);
}

[ForceInline] public int floorDivInt(int a, int b)
{
    int q = a / b;
    int r = a - q * b;
    if (r != 0 && ((r < 0) != (b < 0)))
        q -= 1;
    return q;
}

[ForceInline] bool diffGreaterThanExactRadius(int valueQ, int anchorQ)
{
    if (valueQ <= anchorQ)
        return false;
    if (anchorQ > kI32Max - kExactF32IntRadius)
        return false;
    return valueQ > anchorQ + kExactF32IntRadius;
}

[ForceInline] bool diffLessThanNegativeExactRadius(int valueQ, int anchorQ)
{
    if (valueQ >= anchorQ)
        return false;
    if (anchorQ < kI32Min + kExactF32IntRadius)
        return false;
    return valueQ < anchorQ - kExactF32IntRadius;
}

[ForceInline] public bool relativeExactQ(int valueQ, int anchorQ, out int deltaQ)
{
    deltaQ = 0;
    if (diffGreaterThanExactRadius(valueQ, anchorQ) ||
        diffLessThanNegativeExactRadius(valueQ, anchorQ))
        return false;

    deltaQ = valueQ - anchorQ;
    return true;
}

[ForceInline] public bool relativeExactQ2(int2 valueQ, int2 anchorQ, out int2 deltaQ)
{
    deltaQ = int2(0, 0);
    int dx;
    int dy;
    if (!relativeExactQ(valueQ.x, anchorQ.x, dx) ||
        !relativeExactQ(valueQ.y, anchorQ.y, dy))
        return false;

    deltaQ = int2(dx, dy);
    return true;
}
