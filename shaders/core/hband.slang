#language slang 2026
module hband;

// Conservative h-band range selection for curve candidate lookup.

import shader_math;

static const float kHBandEpsilon = 1.0 / 1048576.0;

[ForceInline] public int anchoredHBandIndexQ(int deltaYQ, int anchorYQ, int bandHeightQ)
{
    int k = floorDivInt(anchorYQ, bandHeightQ);
    int r = anchorYQ - k * bandHeightQ;
    return k + floorDivInt(saturatingAddInt(r, deltaYQ), bandHeightQ);
}

[ForceInline] public int floorLocalToQ(float value, uint fractionBits)
{
    return boundedQFromFloat(value * exp2(float(fractionBits)), false);
}

[ForceInline] public int ceilLocalToQ(float value, uint fractionBits)
{
    return boundedQFromFloat(value * exp2(float(fractionBits)), true);
}

[ForceInline] public bool conservativeHBandRange(
    float2 renderCoord,
    float2 dx,
    float invDet,
    float4 rectBounds,
    out float minY,
    out float maxY)
{
    minY = rectBounds.y;
    maxY = rectBounds.w;

    float nx = -dx.y * invDet;
    float ny = dx.x * invDet;

    if (abs(ny) <= kHBandEpsilon)
    {
        float ly0 = nx * (rectBounds.x - renderCoord.x);
        float ly1 = nx * (rectBounds.z - renderCoord.x);
        float stripMin = min(ly0, ly1);
        float stripMax = max(ly0, ly1);
        if (stripMax < -0.5 || stripMin > 0.5)
            return false;

        minY = rectBounds.y;
        maxY = rectBounds.w;
        return true;
    }

    float y00 = renderCoord.y + (-0.5 - nx * (rectBounds.x - renderCoord.x)) / ny;
    float y01 = renderCoord.y + (-0.5 - nx * (rectBounds.z - renderCoord.x)) / ny;
    float y10 = renderCoord.y + ( 0.5 - nx * (rectBounds.x - renderCoord.x)) / ny;
    float y11 = renderCoord.y + ( 0.5 - nx * (rectBounds.z - renderCoord.x)) / ny;
    minY = max(rectBounds.y, min(min(y00, y01), min(y10, y11)) - kHBandEpsilon);
    maxY = min(rectBounds.w, max(max(y00, y01), max(y10, y11)) + kHBandEpsilon);
    return maxY >= minY;
}
