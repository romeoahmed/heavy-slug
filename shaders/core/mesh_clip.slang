#language slang 2026
module mesh_clip;

// Fixed-function rasterizers are least surprising when mesh shader output is
// already bounded to the viewport.  A convex glyph strip clipped against the
// NDC rectangle can produce at most eight vertices.

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

public bool clipRectToNdc(
    AnchoredLocalToClip frame,
    float4 rect,
    out float2 clipped[kMeshOutputVertices],
    out uint clippedCount)
{
    clippedCount = 0;
    clearPolygon(clipped);

    float2 a[kMeshOutputVertices];
    float2 b[kMeshOutputVertices];
    clearPolygon(a);
    clearPolygon(b);

    if (!projectAnchoredLocalToNdc(frame, rect.xy, a[0]) ||
        !projectAnchoredLocalToNdc(frame, float2(rect.z, rect.y), a[1]) ||
        !projectAnchoredLocalToNdc(frame, rect.zw, a[2]) ||
        !projectAnchoredLocalToNdc(frame, float2(rect.x, rect.w), a[3]))
    {
        return false;
    }

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
