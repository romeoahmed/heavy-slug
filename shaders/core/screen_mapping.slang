#language slang 2026
module screen_mapping;

// Affine-only screen chart helpers. The CPU has already chosen a glyph chart
// whose screen anchor is viewport-relative; mesh chooses a second chart per
// emitted strip. No projective W is part of the hot path.

import abi;
import coverage_blob;

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

public bool isFinite4(float4 v)
{
    return isfinite(v.x) && isfinite(v.y) && isfinite(v.z) && isfinite(v.w);
}

public float2 mul2x2(float4 m, float2 v)
{
    return float2(m.x * v.x + m.z * v.y, m.y * v.x + m.w * v.y);
}

public float2 glyphLocalQToScreen(GlyphInstance glyph, int2 localQ)
{
    float invScale = exp2(-float(glyph.precision_bits));
    float2 localDelta = float2(relativeClampQ2(localQ, glyph.glyph_anchor_q)) * invScale;
    return glyph.screen_anchor_px + mul2x2(glyph.screen_from_local_2x2, localDelta);
}

public float2 screenToNdc(float2 screen, float2 viewportSize)
{
    return float2(
        screen.x * (2.0 / viewportSize.x) - 1.0,
        screen.y * (2.0 / viewportSize.y) - 1.0);
}

public float2 ndcToScreen(float2 ndc, float2 viewportSize)
{
    return float2(
        (ndc.x + 1.0) * viewportSize.x * 0.5,
        (ndc.y + 1.0) * viewportSize.y * 0.5);
}

public float4 screenBoundsForGlyph(GlyphInstance glyph)
{
    int4 b = glyph.local_bounds_q;
    float2 p0 = glyphLocalQToScreen(glyph, b.xy);
    float2 p1 = glyphLocalQToScreen(glyph, int2(b.z, b.y));
    float2 p2 = glyphLocalQToScreen(glyph, b.zw);
    float2 p3 = glyphLocalQToScreen(glyph, int2(b.x, b.w));
    float2 mn = min(min(p0, p1), min(p2, p3));
    float2 mx = max(max(p0, p1), max(p2, p3));
    return float4(mn, mx);
}

public float2 visiblePixelExtent(GlyphInstance glyph, float2 viewportSize)
{
    float4 b = screenBoundsForGlyph(glyph);
    if (!isFinite4(b))
        return float2(0.0, 0.0);
    float2 mn = max(b.xy, float2(0.0, 0.0));
    float2 mx = min(b.zw, viewportSize);
    return max(mx - mn, float2(0.0, 0.0));
}

public LocalFrame localFrameFromPixel(float2 pixel, int2 meshAnchorQ, float2 screenAnchorPx, float4 localFromScreen)
{
    float2 d = pixel - screenAnchorPx;
    LocalFrame frame;
    frame.coord = mul2x2(localFromScreen, d);
    frame.dx = float2(localFromScreen.x, localFromScreen.y);
    frame.dy = float2(localFromScreen.z, localFromScreen.w);
    return frame;
}
