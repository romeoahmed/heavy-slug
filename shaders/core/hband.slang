#language slang 2026
module hband;

// Conservative h-band range selection for curve candidate lookup.

static const float kHBandEpsilon = 1.0 / 1048576.0;

public bool conservativeHBandRange(
    float2 renderCoord,
    float2 dx,
    float invDet,
    float4 bounds,
    out float minY,
    out float maxY)
{
    minY = bounds.y;
    maxY = bounds.w;

    float nx = -dx.y * invDet;
    float ny = dx.x * invDet;

    if (abs(ny) <= kHBandEpsilon)
    {
        float ly0 = nx * (bounds.x - renderCoord.x);
        float ly1 = nx * (bounds.z - renderCoord.x);
        float stripMin = min(ly0, ly1);
        float stripMax = max(ly0, ly1);
        if (stripMax < -0.5 || stripMin > 0.5)
            return false;

        minY = bounds.y;
        maxY = bounds.w;
        return true;
    }

    float y00 = renderCoord.y + (-0.5 - nx * (bounds.x - renderCoord.x)) / ny;
    float y01 = renderCoord.y + (-0.5 - nx * (bounds.z - renderCoord.x)) / ny;
    float y10 = renderCoord.y + ( 0.5 - nx * (bounds.x - renderCoord.x)) / ny;
    float y11 = renderCoord.y + ( 0.5 - nx * (bounds.z - renderCoord.x)) / ny;
    minY = max(bounds.y, min(min(y00, y01), min(y10, y11)) - kHBandEpsilon);
    maxY = min(bounds.w, max(max(y00, y01), max(y10, y11)) + kHBandEpsilon);
    return maxY >= minY;
}
