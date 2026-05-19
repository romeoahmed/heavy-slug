#language slang 2026
module screen_mapping;

// Affine-only screen chart helpers. The CPU has already chosen a glyph chart
// whose screen anchor is viewport-relative; mesh chooses a second chart per
// emitted strip. No projective W is part of the hot path.

import abi;
import coverage_blob;
import shader_math;

public struct LocalFrame
{
    public float2 coord;
    public float2 dx;
    public float2 dy;
};

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

public float2 framebufferToScreenYUp(float2 framebuffer, FrameParams params)
{
    return mul2x2(params.screen_from_framebuffer_2x2, framebuffer) +
        params.screen_from_framebuffer_offset;
}

public LocalFrame localFrameFromScreenYUp(float2 screen, float2 screenAnchorPx, float4 localFromScreen)
{
    float2 d = screen - screenAnchorPx;
    LocalFrame frame;
    frame.coord = mul2x2(localFromScreen, d);
    frame.dx = float2(localFromScreen.x, localFromScreen.y);
    frame.dy = float2(localFromScreen.z, localFromScreen.w);
    return frame;
}
