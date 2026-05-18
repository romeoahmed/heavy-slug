#language slang 2026
module mesh_clip;

// Clip a convex NDC quad against the viewport. With affine screen charts the
// mesh shader should only emit bounded W=1 positions.

import abi;
import screen_mapping;

static const uint kClipPlaneLeft = 0;
static const uint kClipPlaneRight = 1;
static const uint kClipPlaneBottom = 2;
static const uint kClipPlaneTop = 3;
static const float kMinClipArea2 = 1.0e-12;

float planeDistance(float2 p, uint plane)
{
    if (plane == kClipPlaneLeft)
        return p.x + 1.0;
    if (plane == kClipPlaneRight)
        return 1.0 - p.x;
    if (plane == kClipPlaneBottom)
        return p.y + 1.0;
    return 1.0 - p.y;
}

void appendVertex(inout float2 poly[kMeshOutputVertices], inout uint count, float2 p)
{
    if (count < kMeshOutputVertices && isFinite2(p))
    {
        poly[count] = p;
        count++;
    }
}

void clearPolygon(out float2 poly[kMeshOutputVertices])
{
    for (uint i = 0; i < kMeshOutputVertices; i++)
        poly[i] = float2(0.0, 0.0);
}

void clipAgainstPlane(
    float2 inPoly[kMeshOutputVertices],
    uint inCount,
    uint plane,
    out float2 outPoly[kMeshOutputVertices],
    out uint outCount)
{
    outCount = 0;
    clearPolygon(outPoly);
    if (inCount == 0)
        return;

    float2 prev = inPoly[inCount - 1u];
    float prevDistance = planeDistance(prev, plane);
    bool prevInside = prevDistance >= 0.0;

    for (uint i = 0; i < inCount; i++)
    {
        float2 curr = inPoly[i];
        float currDistance = planeDistance(curr, plane);
        bool currInside = currDistance >= 0.0;

        if (currInside != prevInside)
        {
            float denom = prevDistance - currDistance;
            float t = abs(denom) > 1.0e-20 ? saturate(prevDistance / denom) : 0.0;
            appendVertex(outPoly, outCount, lerp(prev, curr, t));
        }
        if (currInside)
            appendVertex(outPoly, outCount, curr);

        prev = curr;
        prevDistance = currDistance;
        prevInside = currInside;
    }
}

float polygonArea2(float2 poly[kMeshOutputVertices], uint count)
{
    float area2 = 0.0;
    if (count < 3)
        return 0.0;

    float2 prev = poly[count - 1u];
    for (uint i = 0; i < count; i++)
    {
        float2 curr = poly[i];
        area2 += prev.x * curr.y - prev.y * curr.x;
        prev = curr;
    }
    return area2;
}

public bool clipNdcQuad(
    float2 p0,
    float2 p1,
    float2 p2,
    float2 p3,
    out float2 clipped[kMeshOutputVertices],
    out uint clippedCount)
{
    clippedCount = 0;
    clearPolygon(clipped);

    float2 a[kMeshOutputVertices];
    float2 b[kMeshOutputVertices];
    clearPolygon(a);
    clearPolygon(b);

    if (!isFinite2(p0) || !isFinite2(p1) || !isFinite2(p2) || !isFinite2(p3))
        return false;

    a[0] = p0;
    a[1] = p1;
    a[2] = p2;
    a[3] = p3;

    uint count = 4;
    clipAgainstPlane(a, count, kClipPlaneLeft, b, count);
    clipAgainstPlane(b, count, kClipPlaneRight, a, count);
    clipAgainstPlane(a, count, kClipPlaneBottom, b, count);
    clipAgainstPlane(b, count, kClipPlaneTop, a, count);
    if (count < 3)
        return false;

    float area2 = polygonArea2(a, count);
    if (!isfinite(area2) || abs(area2) <= kMinClipArea2)
        return false;

    for (uint i = 0; i < count; i++)
        clipped[i] = a[i];
    clippedCount = count;
    return true;
}
