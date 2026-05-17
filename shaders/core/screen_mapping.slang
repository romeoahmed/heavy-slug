#language slang 2026
module screen_mapping;

// Numerically stable local glyph <-> screen homography helpers.
//
// The demo can zoom far enough that `projection * world_position` becomes a
// subtraction of two large f32 values.  The helpers below find a local chart
// near the viewport center once, then express mesh clipping and fragment
// reconstruction relative to that chart.

import abi;
import pga;

static const float kClipWEpsilon = 1.0e-6;

struct HomographyRows
{
    float3 r0;
    float3 r1;
    float3 r2;
};

public struct LocalToClip
{
    public float3 x;
    public float3 y;
    public float3 t;
};

public struct AnchoredLocalToClip
{
    public float2 anchor;
    public float3 x;
    public float3 y;
    public float3 t;
};

public struct ScreenToLocal
{
    public float3 x;
    public float3 y;
    public float3 t;
};

public struct LocalFrame
{
    public float2 coord;
    public float2 dx;
    public float2 dy;
};

public bool isFinite2(float2 v)
{
    return isfinite(v.x) && isfinite(v.y);
}

bool isFinite3(float3 v)
{
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z);
}

float3 cross3(float3 a, float3 b)
{
    return float3(
        a.y * b.z - a.z * b.y,
        a.z * b.x - a.x * b.z,
        a.x * b.y - a.y * b.x);
}

float3 inverseRowsMul(float3 r0, float3 r1, float3 r2, float3 v)
{
    return float3(dot(r0, v), dot(r1, v), dot(r2, v));
}

void clearHomographyRows(out HomographyRows rows)
{
    rows.r0 = float3(0.0, 0.0, 0.0);
    rows.r1 = float3(0.0, 0.0, 0.0);
    rows.r2 = float3(0.0, 0.0, 0.0);
}

bool tryInverseAffineRows(float3 h0, float3 h1, float3 h2, out HomographyRows rows)
{
    clearHomographyRows(rows);
    if (abs(h0.z) > kClipWEpsilon || abs(h1.z) > kClipWEpsilon)
        return false;
    if (!isFinite3(h0) || !isFinite3(h1) || !isFinite3(h2) || abs(h2.z) <= kClipWEpsilon)
        return false;

    float a = h0.x;
    float c = h0.y;
    float b = h1.x;
    float d = h1.y;
    float scale = max(max(abs(a), abs(b)), max(abs(c), abs(d)));
    if (!isfinite(scale) || scale <= kClipWEpsilon)
        return false;

    float invScale = 1.0 / scale;
    float as = a * invScale;
    float bs = b * invScale;
    float cs = c * invScale;
    float ds = d * invScale;
    float det = as * ds - bs * cs;
    float invDet = 1.0 / det;
    if (!isfinite(invDet))
        return false;

    float inv00 = ds * invDet * invScale;
    float inv01 = -bs * invDet * invScale;
    float inv10 = -cs * invDet * invScale;
    float inv11 = as * invDet * invScale;
    float invW = 1.0 / h2.z;

    rows.r0 = float3(inv00, inv01, -(inv00 * h2.x + inv01 * h2.y) * invW);
    rows.r1 = float3(inv10, inv11, -(inv10 * h2.x + inv11 * h2.y) * invW);
    rows.r2 = float3(0.0, 0.0, invW);
    return isFinite3(rows.r0) && isFinite3(rows.r1) && isFinite3(rows.r2);
}

bool tryInverseHomographyRows(float3 h0, float3 h1, float3 h2, out HomographyRows rows)
{
    clearHomographyRows(rows);
    if (!isFinite3(h0) || !isFinite3(h1) || !isFinite3(h2))
        return false;

    if (tryInverseAffineRows(h0, h1, h2, rows))
        return true;

    // Translation magnitude is not part of the local conditioning test.  A
    // valid affine chart at extreme zoom can have huge h2.xy and a perfectly
    // usable Jacobian, so only reject non-finite inverses.
    float3 cof0 = cross3(h1, h2);
    float det = dot(h0, cof0);
    float invDet = 1.0 / det;
    if (!isfinite(invDet))
        return false;

    rows.r0 = cof0 * invDet;
    rows.r1 = cross3(h2, h0) * invDet;
    rows.r2 = cross3(h0, h1) * invDet;
    return isFinite3(rows.r0) && isFinite3(rows.r1) && isFinite3(rows.r2);
}

public LocalToClip localToClipForGlyph(GlyphInstance glyph, float4x4 projection)
{
    Motor motor = { glyph.motor };
    MotorAffine affine = motor.affine();

    float4 colX = mul(projection, float4(affine.c, affine.r, 0.0, 0.0));
    float4 colY = mul(projection, float4(-affine.r, affine.c, 0.0, 0.0));
    float4 origin = mul(projection, float4(affine.t, 0.0, 1.0));

    LocalToClip h;
    h.x = float3(colX.x, colX.y, colX.w);
    h.y = float3(colY.x, colY.y, colY.w);
    h.t = float3(origin.x, origin.y, origin.w);
    return h;
}

float3 localToClipMul(LocalToClip h, float2 p)
{
    return h.x * p.x + h.y * p.y + h.t;
}

float3 anchoredLocalToClipMul(AnchoredLocalToClip h, float2 p)
{
    float2 d = p - h.anchor;
    return h.x * d.x + h.y * d.y + h.t;
}

bool ndcFromClip(float3 q, out float2 ndc)
{
    ndc = float2(0.0, 0.0);
    if (!isFinite3(q) || q.z <= kClipWEpsilon)
        return false;

    ndc = q.xy / q.z;
    return isFinite2(ndc);
}

public bool projectAnchoredLocalToNdc(AnchoredLocalToClip h, float2 p, out float2 ndc)
{
    return ndcFromClip(anchoredLocalToClipMul(h, p), ndc);
}

bool localAtNdc(LocalToClip h, float2 ndc, out float2 local, out float clipW)
{
    local = float2(0.0, 0.0);
    clipW = 1.0;

    HomographyRows rows;
    if (!tryInverseHomographyRows(h.x, h.y, h.t, rows))
        return false;

    float3 q = inverseRowsMul(rows.r0, rows.r1, rows.r2, float3(ndc, 1.0));
    if (!isFinite3(q))
        return false;

    float invW = 1.0 / q.z;
    if (!isfinite(invW))
        return false;

    local = q.xy * invW;
    clipW = localToClipMul(h, local).z;
    return isFinite2(local) && isfinite(clipW) && clipW > kClipWEpsilon;
}

public bool anchorForRectAtNdc(
    LocalToClip h,
    float4 rect,
    float2 ndc,
    out AnchoredLocalToClip anchored)
{
    anchored.anchor = (rect.xy + rect.zw) * 0.5;
    anchored.x = h.x;
    anchored.y = h.y;
    anchored.t = float3(0.0, 0.0, 1.0);

    float2 screenLocal;
    float screenW;
    if (!localAtNdc(h, ndc, screenLocal, screenW))
        return false;

    float2 anchor = clamp(screenLocal, rect.xy, rect.zw);
    float2 delta = anchor - screenLocal;

    anchored.anchor = anchor;
    anchored.x = h.x;
    anchored.y = h.y;
    anchored.t = float3(ndc * screenW, screenW) + h.x * delta.x + h.y * delta.y;
    return isFinite2(anchored.anchor) && isFinite3(anchored.t);
}

public void clearScreenToLocal(out ScreenToLocal xform)
{
    xform.x = float3(0.0, 0.0, 0.0);
    xform.y = float3(0.0, 0.0, 0.0);
    xform.t = float3(0.0, 0.0, 1.0);
}

public bool screenToLocalTransform(
    AnchoredLocalToClip h,
    float2 viewportSize,
    out ScreenToLocal xform)
{
    clearScreenToLocal(xform);

    HomographyRows rows;
    if (!tryInverseHomographyRows(h.x, h.y, h.t, rows))
        return false;

    float3 ndcDx = float3(2.0 / viewportSize.x, 0.0, 0.0);
    float3 ndcDy = float3(0.0, -2.0 / viewportSize.y, 0.0);
    float3 ndcOrigin = float3(-1.0, 1.0, 1.0);

    xform.x = inverseRowsMul(rows.r0, rows.r1, rows.r2, ndcDx);
    xform.y = inverseRowsMul(rows.r0, rows.r1, rows.r2, ndcDy);
    xform.t = inverseRowsMul(rows.r0, rows.r1, rows.r2, ndcOrigin);
    return isFinite3(xform.x) && isFinite3(xform.y) && isFinite3(xform.t);
}

public LocalFrame localFrameFromPixel(ScreenToLocal xform, float2 pixel)
{
    float3 q = xform.x * pixel.x + xform.y * pixel.y + xform.t;
    float invW = 1.0 / q.z;
    float invW2 = invW * invW;

    LocalFrame frame;
    frame.coord = q.xy * invW;
    frame.dx = (xform.x.xy * q.z - q.xy * xform.x.z) * invW2;
    frame.dy = (xform.y.xy * q.z - q.xy * xform.y.z) * invW2;
    return frame;
}

public float2 visiblePixelExtentNdc(LocalToClip h, float4 rect, float2 viewportSize)
{
    AnchoredLocalToClip frame;
    if (!anchorForRectAtNdc(h, rect, float2(0.0, 0.0), frame))
        return float2(0.0, 0.0);

    float2 ndc0;
    float2 ndc1;
    float2 ndc2;
    float2 ndc3;
    if (!projectAnchoredLocalToNdc(frame, rect.xy, ndc0) ||
        !projectAnchoredLocalToNdc(frame, float2(rect.z, rect.y), ndc1) ||
        !projectAnchoredLocalToNdc(frame, rect.zw, ndc2) ||
        !projectAnchoredLocalToNdc(frame, float2(rect.x, rect.w), ndc3))
    {
        return float2(0.0, 0.0);
    }

    float2 ndcMin = max(min(min(ndc0, ndc1), min(ndc2, ndc3)), float2(-1.0, -1.0));
    float2 ndcMax = min(max(max(ndc0, ndc1), max(ndc2, ndc3)), float2(1.0, 1.0));
    return max(ndcMax - ndcMin, float2(0.0, 0.0)) * (viewportSize * 0.5);
}
