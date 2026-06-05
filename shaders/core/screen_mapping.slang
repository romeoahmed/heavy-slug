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

public bool localQToScreenExact(
    float2 screenAnchorPx,
    float4 screenFromLocal,
    uint precisionBits,
    int2 anchorQ,
    int2 localQ,
    out float2 screen)
{
    screen = float2(0.0, 0.0);
    int2 deltaQ;
    if (!relativeExactQ2(localQ, anchorQ, deltaQ))
        return false;

    float invScale = exp2(-float(precisionBits));
    float2 localDelta = float2(deltaQ) * invScale;
    screen = screenAnchorPx + mul2x2(screenFromLocal, localDelta);
    return isFinite2(screen);
}

public bool meshletLocalQToScreen(GlyphInstance glyph, GlyphMeshlet meshlet, int2 localQ, out float2 screen)
{
    return localQToScreenExact(
        meshlet.screen_anchor_px,
        glyph.screen_from_local_2x2,
        glyph.precision_bits,
        meshlet.mesh_anchor_q,
        localQ,
        screen);
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
