// shaders/slug_fragment.slang
// Fragment shader: Slug band/coverage algorithm for exact glyph rendering.
// Adapted from Eric Lengyel's reference SlugPixelShader.hlsl (MIT).

import pga;
import slug_common;

// --- Resource bindings ---

[[vk::binding(0, 0)]]
ByteAddressBuffer glyphBlobs[];

// --- Interpolants from mesh shader ---

struct FragmentInput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
    float2 texcoord    : TEXCOORD0;         // em-space sample coordinates
    nointerpolation uint descriptorIndex : TEXCOORD1;
    nointerpolation uint flags           : TEXCOORD2;
};

// --- Slug algorithm core ---

// Calculate root eligibility code for a sample-relative quadratic Bezier.
// Extracts sign bits of the three control points' y (or x) coordinates.
// Eligibility is returned in bits 0 and 8.
uint calcRootCode(float y1, float y2, float y3)
{
    uint i1 = asuint(y1) >> 31u;
    uint i2 = asuint(y2) >> 30u;
    uint i3 = asuint(y3) >> 29u;

    uint shift = (i2 & 2u) | (i1 & ~2u);
    shift = (i3 & 4u) | (shift & ~4u);

    return ((0x2E74u >> shift) & 0x0101u);
}

// Solve for t where the curve crosses y = 0 (horizontal ray test).
// Returns x coordinates at the two roots.
// Polynomial: a*t^2 - 2*b*t + c, where a = p1-2*p2+p3, b = p1-p2, c = p1.
float2 solveHorizPoly(float4 p12, float2 p3)
{
    float2 a = p12.xy - p12.zw * 2.0 + p3;
    float2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.y;
    float rb = 0.5 / b.y;

    float d = sqrt(max(b.y * b.y - a.y * p12.y, 0.0));
    float t1 = (b.y - d) * ra;
    float t2 = (b.y + d) * ra;

    // Nearly linear: solve -2b*t + c = 0.
    if (abs(a.y) < 1.0 / 65536.0)
        t1 = t2 = p12.y * rb;

    return float2(
        (a.x * t1 - b.x * 2.0) * t1 + p12.x,
        (a.x * t2 - b.x * 2.0) * t2 + p12.x
    );
}

// Solve for t where the curve crosses x = 0 (vertical ray test).
// Returns y coordinates at the two roots.
float2 solveVertPoly(float4 p12, float2 p3)
{
    float2 a = p12.xy - p12.zw * 2.0 + p3;
    float2 b = p12.xy - p12.zw;
    float ra = 1.0 / a.x;
    float rb = 0.5 / b.x;

    float d = sqrt(max(b.x * b.x - a.x * p12.x, 0.0));
    float t1 = (b.x - d) * ra;
    float t2 = (b.x + d) * ra;

    if (abs(a.x) < 1.0 / 65536.0)
        t1 = t2 = p12.x * rb;

    return float2(
        (a.y * t1 - b.y * 2.0) * t1 + p12.y,
        (a.y * t2 - b.y * 2.0) * t2 + p12.y
    );
}

// Combine horizontal and vertical coverage with weights.
float calcCoverage(float xcov, float ycov, float xwgt, float ywgt, uint flags)
{
    float coverage = max(
        abs(xcov * xwgt + ycov * ywgt) / max(xwgt + ywgt, 1.0 / 65536.0),
        min(abs(xcov), abs(ycov))
    );

    bool evenOdd = (flags & 1u) != 0u;
    if (evenOdd)
    {
        coverage = 1.0 - abs(1.0 - frac(coverage * 0.5) * 2.0);
    }
    else
    {
        coverage = saturate(coverage);
    }

    return coverage;
}

// Main Slug rendering function. Reads glyph blob and computes pixel coverage.
float slugRender(BlobReader blob, float2 renderCoord, uint flags)
{
    // Read header: bounds and band counts.
    float4 bounds;
    int2 bandCounts;
    blob.readHeader(bounds, bandCounts);
    int numHBands = bandCounts.x;
    int numVBands = bandCounts.y;

    if (numHBands == 0 && numVBands == 0)
        return 0.0;

    // Pixel dimensions in em-space.
    float2 emsPerPixel = fwidth(renderCoord);
    float2 pixelsPerEm = 1.0 / emsPerPixel;

    // Compute band indices from render coordinates.
    // Horizontal bands partition by y coordinate; vertical bands partition by x.
    // bounds = (min_x, min_y, max_x, max_y).
    float hBandScale = float(numHBands) / max(bounds.w - bounds.y, 1.0 / 65536.0);
    float vBandScale = float(numVBands) / max(bounds.z - bounds.x, 1.0 / 65536.0);
    int2 bandIndex = clamp(
        int2(int((renderCoord.y - bounds.y) * hBandScale),
             int((renderCoord.x - bounds.x) * vBandScale)),
        int2(0, 0),
        int2(numHBands - 1, numVBands - 1)
    );

    // --- Horizontal band processing (x-direction coverage) ---
    float xcov = 0.0;
    float xwgt = 0.0;

    uint hbandTexel = HEADER_LEN + uint(bandIndex.x);
    uint hCurveCount, hDescOff;
    uint hAscOff_unused; float hSplit_unused;  // ascending-list optimization deferred
    blob.readBandHeader(hbandTexel, hCurveCount, hDescOff, hAscOff_unused, hSplit_unused);

    for (uint ci = 0; ci < hCurveCount; ci++)
    {
        uint curveDataOff = blob.readCurveIndex(hDescOff + ci);

        // Read control points: texel at curveDataOff has (p1.x, p1.y, p2.x, p2.y),
        // texel at curveDataOff+1 has (p3.x, p3.y, ...).
        float4 p12raw = blob.readTexelF(curveDataOff);
        float4 p3raw  = blob.readTexelF(curveDataOff + 1);

        // Make curve relative to sample position.
        float4 p12 = p12raw - float4(renderCoord, renderCoord);
        float2 p3  = p3raw.xy - renderCoord;

        // Early exit: curves sorted by max-x descending.
        if (max(max(p12.x, p12.z), p3.x) * pixelsPerEm.x < -0.5)
            break;

        uint code = calcRootCode(p12.y, p12.w, p3.y);
        if (code != 0u)
        {
            float2 r = solveHorizPoly(p12, p3) * pixelsPerEm.x;

            if ((code & 1u) != 0u)
            {
                xcov += saturate(r.x + 0.5);
                xwgt = max(xwgt, saturate(1.0 - abs(r.x) * 2.0));
            }
            if (code > 1u)
            {
                xcov -= saturate(r.y + 0.5);
                xwgt = max(xwgt, saturate(1.0 - abs(r.y) * 2.0));
            }
        }
    }

    // --- Vertical band processing (y-direction coverage) ---
    float ycov = 0.0;
    float ywgt = 0.0;

    uint vbandTexel = HEADER_LEN + uint(numHBands) + uint(bandIndex.y);
    uint vCurveCount, vDescOff;
    uint vAscOff_unused; float vSplit_unused;  // ascending-list optimization deferred
    blob.readBandHeader(vbandTexel, vCurveCount, vDescOff, vAscOff_unused, vSplit_unused);

    for (uint ci = 0; ci < vCurveCount; ci++)
    {
        uint curveDataOff = blob.readCurveIndex(vDescOff + ci);

        float4 p12raw = blob.readTexelF(curveDataOff);
        float4 p3raw  = blob.readTexelF(curveDataOff + 1);

        float4 p12 = p12raw - float4(renderCoord, renderCoord);
        float2 p3  = p3raw.xy - renderCoord;

        // Early exit: curves sorted by max-y descending.
        if (max(max(p12.y, p12.w), p3.y) * pixelsPerEm.y < -0.5)
            break;

        uint code = calcRootCode(p12.x, p12.z, p3.x);
        if (code != 0u)
        {
            float2 r = solveVertPoly(p12, p3) * pixelsPerEm.y;

            if ((code & 1u) != 0u)
            {
                ycov -= saturate(r.x + 0.5);
                ywgt = max(ywgt, saturate(1.0 - abs(r.x) * 2.0));
            }
            if (code > 1u)
            {
                ycov += saturate(r.y + 0.5);
                ywgt = max(ywgt, saturate(1.0 - abs(r.y) * 2.0));
            }
        }
    }

    return calcCoverage(xcov, ycov, xwgt, ywgt, flags);
}

// --- Entry point ---

[shader("fragment")]
float4 fragmentMain(FragmentInput input) : SV_Target
{
    BlobReader blob;
    blob.buf = glyphBlobs[input.descriptorIndex];

    float coverage = slugRender(blob, input.texcoord, input.flags);
    return input.color * coverage;
}
