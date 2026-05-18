#language slang 2026
module fragment;

// Fragment shader: CoverageBlob analytic cubic coverage.

import abi;
import coverage_blob;
import coverage_integral;
import hband;
import resources;
import screen_mapping;
import stats;

struct FragmentInput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
#if HEAVY_SLUG_METAL
    nointerpolation uint blobRef : TEXCOORD1;
    nointerpolation uint flags : TEXCOORD2;
    nointerpolation int2 meshAnchorQ : TEXCOORD3;
    nointerpolation float2 screenAnchorPx : TEXCOORD4;
    nointerpolation float4 localFromScreen : TEXCOORD5;
#else
    nointerpolation uint blobRef : TEXCOORD1;
    nointerpolation uint flags : TEXCOORD2;
    nointerpolation int2 meshAnchorQ : TEXCOORD3;
    nointerpolation float2 screenAnchorPx : TEXCOORD4;
    nointerpolation float4 localFromScreen : TEXCOORD5;
#endif
};

static const uint kMaxMergedCandidateBands = 8;
static const uint kInvalidCurveIndex = 0xffffffffu;

#if HEAVY_SLUG_SHADER_STATS
float zeroCoverageFragment(bool empty)
{
    if (empty)
        addShaderStat(shaderStats, kShaderStatEmptyFragments, 1);
    addShaderStat(shaderStats, kShaderStatCoverageZeroFragments, 1);
    return 0.0;
}
#endif

float integrateCandidateBandRange(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
    int2 coordAnchorQ,
    float invScale,
    uint firstBand,
    uint bandSpan,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    uint starts[kMaxMergedCandidateBands];
    uint counts[kMaxMergedCandidateBands];
    uint cursors[kMaxMergedCandidateBands];
    uint heads[kMaxMergedCandidateBands];
    for (uint band = 0; band < kMaxMergedCandidateBands; band++)
    {
        if (band < bandSpan)
            blob.readBand(bandBase, firstBand + band, starts[band], counts[band]);
        else
        {
            starts[band] = 0;
            counts[band] = 0;
        }
        cursors[band] = 0;
        heads[band] = counts[band] > 0
            ? blob.readCurveId(idBase, starts[band])
            : kInvalidCurveIndex;
    }

    float signedArea = 0.0;
    while (true)
    {
        uint curveIndex = kInvalidCurveIndex;
        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            curveIndex = min(curveIndex, heads[band]);
        }
        if (curveIndex == kInvalidCurveIndex)
            break;

        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            while (heads[band] == curveIndex)
            {
                cursors[band]++;
                heads[band] = cursors[band] < counts[band]
                    ? blob.readCurveId(idBase, starts[band] + cursors[band])
                    : kInvalidCurveIndex;
            }
        }

        if (curveIndex < curveCount)
        {
            float4 bbox = blob.readCurveBoundsRelative(curveBase, curveIndex, coordAnchorQ, invScale);
            if (curveBboxMayContribute(bbox, renderCoord, dx, dy, invDet))
                signedArea += integrateCurvePayload(blob, curveBase, curveIndex, coordAnchorQ, invScale, renderCoord, dx, dy, invDet);
        }
    }
    return signedArea;
}

#if HEAVY_SLUG_SHADER_STATS
float integrateCandidateBandRangeWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
    int2 coordAnchorQ,
    float invScale,
    uint firstBand,
    uint bandSpan,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out uint curveTests,
    out uint bboxRejects,
    out uint integrations)
{
    uint starts[kMaxMergedCandidateBands];
    uint counts[kMaxMergedCandidateBands];
    uint cursors[kMaxMergedCandidateBands];
    uint heads[kMaxMergedCandidateBands];
    for (uint band = 0; band < kMaxMergedCandidateBands; band++)
    {
        if (band < bandSpan)
            blob.readBand(bandBase, firstBand + band, starts[band], counts[band]);
        else
        {
            starts[band] = 0;
            counts[band] = 0;
        }
        cursors[band] = 0;
        heads[band] = counts[band] > 0
            ? blob.readCurveId(idBase, starts[band])
            : kInvalidCurveIndex;
    }

    float signedArea = 0.0;
    curveTests = 0;
    bboxRejects = 0;
    integrations = 0;
    while (true)
    {
        uint curveIndex = kInvalidCurveIndex;
        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            curveIndex = min(curveIndex, heads[band]);
        }
        if (curveIndex == kInvalidCurveIndex)
            break;

        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            while (heads[band] == curveIndex)
            {
                cursors[band]++;
                heads[band] = cursors[band] < counts[band]
                    ? blob.readCurveId(idBase, starts[band] + cursors[band])
                    : kInvalidCurveIndex;
            }
        }

        if (curveIndex < curveCount)
        {
            curveTests++;
            bool bboxRejected;
            signedArea += integrateCurveFromBlobWithStats(blob, curveBase, curveIndex, coordAnchorQ, invScale, renderCoord, dx, dy, invDet, bboxRejected);
            bboxRejects += bboxRejected ? 1u : 0u;
            integrations += bboxRejected ? 0u : 1u;
        }
    }
    return signedArea;
}
#endif

float slugRender(BlobReader blob, LocalFrame frame, int2 coordAnchorQ, uint flags)
{
    BlobHeader header = blob.readHeader();
    float invScale = header.invScale();
#if HEAVY_SLUG_SHADER_STATS
    addShaderStat(shaderStats, kShaderStatFragmentInvocations, 1);
#endif
    if (header.curveCount == 0)
    {
#if HEAVY_SLUG_SHADER_STATS
        return zeroCoverageFragment(true);
#else
        return 0.0;
#endif
    }

    float2 renderCoord = frame.coord;
    float2 dx = frame.dx;
    float2 dy = frame.dy;
    if (!isFinite2(renderCoord) || !isFinite2(dx) || !isFinite2(dy))
    {
#if HEAVY_SLUG_SHADER_STATS
        return zeroCoverageFragment(false);
#else
        return 0.0;
#endif
    }

    float det = dx.x * dy.y - dx.y * dy.x;
    float invDet = 1.0 / det;
    if (!isfinite(invDet))
    {
#if HEAVY_SLUG_SHADER_STATS
        return zeroCoverageFragment(false);
#else
        return 0.0;
#endif
    }
    float detSign = det < 0.0 ? -1.0 : 1.0;

    float candidateMinY;
    float candidateMaxY;
    float4 localBounds = rectBoundsRelativeTo(header.boundsQ, coordAnchorQ, invScale);
    if (!conservativeHBandRange(renderCoord, dx, invDet, localBounds, candidateMinY, candidateMaxY))
    {
#if HEAVY_SLUG_SHADER_STATS
        return zeroCoverageFragment(true);
#else
        return 0.0;
#endif
    }

    int firstBand = anchoredHBandIndexQ(floorLocalToQ(candidateMinY, header.fractionBits), coordAnchorQ.y, header.bandHeightQ) - header.bandMin;
    int lastBand = anchoredHBandIndexQ(ceilLocalToQ(candidateMaxY, header.fractionBits), coordAnchorQ.y, header.bandHeightQ) - header.bandMin;
    if (lastBand < firstBand)
    {
#if HEAVY_SLUG_SHADER_STATS
        return zeroCoverageFragment(true);
#else
        return 0.0;
#endif
    }

    uint bandSpan = uint(lastBand - firstBand + 1);

    float signedArea = 0.0;
#if HEAVY_SLUG_SHADER_STATS
    uint integrations = 0;
#endif
    if (header.bandCount > 0 && firstBand >= 0 && uint(lastBand) < header.bandCount && bandSpan <= kMaxMergedCandidateBands)
    {
#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(shaderStats, kShaderStatCandidatePathFragments, 1);
        uint curveTests;
        uint bboxRejects;
        signedArea = integrateCandidateBandRangeWithStats(
            blob,
            header.curveBaseWords,
            header.curveCount,
            header.bandBaseWords,
            header.idBaseWords,
            coordAnchorQ,
            invScale,
            uint(firstBand),
            bandSpan,
            renderCoord,
            dx,
            dy,
            invDet,
            curveTests,
            bboxRejects,
            integrations);
        addShaderStat(shaderStats, kShaderStatCandidateCurveTests, curveTests);
        addShaderStat(shaderStats, kShaderStatCandidateCurveBboxRejects, bboxRejects);
        addShaderStat(shaderStats, kShaderStatCandidateCurveIntegrations, integrations);
#else
        signedArea = integrateCandidateBandRange(
            blob,
            header.curveBaseWords,
            header.curveCount,
            header.bandBaseWords,
            header.idBaseWords,
            coordAnchorQ,
            invScale,
            uint(firstBand),
            bandSpan,
            renderCoord,
            dx,
            dy,
            invDet);
#endif
    }
    else
    {
#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(shaderStats, kShaderStatFullScanFragments, 1);
        addShaderStat(shaderStats, kShaderStatFullScanCurveTests, header.curveCount);
        uint bboxRejects;
        signedArea = integrateFullScanWithStats(blob, header.curveBaseWords, header.curveCount, coordAnchorQ, invScale, renderCoord, dx, dy, invDet, bboxRejects, integrations);
        addShaderStat(shaderStats, kShaderStatFullScanCurveBboxRejects, bboxRejects);
        addShaderStat(shaderStats, kShaderStatFullScanCurveIntegrations, integrations);
#else
        signedArea = integrateFullScan(blob, header.curveBaseWords, header.curveCount, coordAnchorQ, invScale, renderCoord, dx, dy, invDet);
#endif
    }

#if HEAVY_SLUG_SHADER_STATS
    if (integrations == 0)
        addShaderStat(shaderStats, kShaderStatBboxEmptyFragments, 1);
#endif

    float coverage = resolveCoverage(signedArea, header.fillSign, detSign, flags);
#if HEAVY_SLUG_SHADER_STATS
    if (coverage <= kCoverageEpsilon)
        addShaderStat(shaderStats, kShaderStatCoverageZeroFragments, 1);
#endif

    return coverage;
}

[shader("fragment")]
float4 fragmentMain(FragmentInput input) : SV_Target
{
    BlobReader blob;
    blob.buf = glyphPool;
    blob.base = input.blobRef;

    LocalFrame frame = localFrameFromPixel(input.position.xy, input.meshAnchorQ, input.screenAnchorPx, input.localFromScreen);
    float coverage = slugRender(blob, frame, input.meshAnchorQ, input.flags);
    return input.color * coverage;
}
