#language slang 2026
module fragment;

// Fragment shader: CoverageBlob analytic cubic coverage.

import abi;
import candidate_index;
import coverage_blob;
import coverage_integral;
import hband;
import resources;
import screen_mapping;
import shader_math;
import stats;

struct FragmentInput
{
    float4 position    : SV_Position;
    nointerpolation uint meshletIndex : TEXCOORD1;
};

struct CoverageAccumulation
{
    float signedArea;
    uint integrations;
};

float zeroCoverage(bool empty)
{
#if HEAVY_SLUG_SHADER_STATS
    if (empty)
        addShaderStat(shaderStats, kShaderStatEmptyFragments, 1);
    addShaderStat(shaderStats, kShaderStatCoverageZeroFragments, 1);
#endif
    return 0.0;
}

CoverageAccumulation fullScanCoverage(
    BlobReader blob,
    BlobHeader header,
    int2 coordAnchorQ,
    float invScale,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    CoverageAccumulation result;
#if HEAVY_SLUG_SHADER_STATS
    addShaderStat(shaderStats, kShaderStatFullScanFragments, 1);
    addShaderStat(shaderStats, kShaderStatFullScanCurveTests, header.curveCount);
    uint bboxRejects;
    result.signedArea = integrateFullScanWithStats(
        blob,
        header.curveBaseWords,
        header.curveCount,
        coordAnchorQ,
        invScale,
        renderCoord,
        dx,
        dy,
        invDet,
        bboxRejects,
        result.integrations);
    addShaderStat(shaderStats, kShaderStatFullScanCurveBboxRejects, bboxRejects);
    addShaderStat(shaderStats, kShaderStatFullScanCurveIntegrations, result.integrations);
#else
    result.signedArea = integrateFullScan(
        blob,
        header.curveBaseWords,
        header.curveCount,
        coordAnchorQ,
        invScale,
        renderCoord,
        dx,
        dy,
        invDet);
    result.integrations = 0;
#endif
    return result;
}

CoverageAccumulation candidateCoverage(
    BlobReader blob,
    BlobHeader header,
    int2 coordAnchorQ,
    float invScale,
    uint firstBand,
    uint bandSpan,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    CandidateResult candidate = integrateCandidateBandRange(
        blob,
        header.curveBaseWords,
        header.curveCount,
        header.bandBaseWords,
        header.idBaseWords,
        coordAnchorQ,
        invScale,
        firstBand,
        bandSpan,
        renderCoord,
        dx,
        dy,
        invDet);

#if HEAVY_SLUG_SHADER_STATS
    addShaderStat(shaderStats, kShaderStatCandidatePathFragments, 1);
    addShaderStat(shaderStats, kShaderStatCandidateCurveTests, candidate.curveTests);
    addShaderStat(shaderStats, kShaderStatCandidateCurveBboxRejects, candidate.bboxRejects);
    addShaderStat(shaderStats, kShaderStatCandidateCurveIntegrations, candidate.integrations);
#endif

    CoverageAccumulation result;
    result.signedArea = candidate.signedArea;
    result.integrations = candidate.integrations;
    return result;
}

bool candidateBandWindow(
    BlobHeader header,
    int2 coordAnchorQ,
    float candidateMinY,
    float candidateMaxY,
    out uint firstBand,
    out uint bandSpan)
{
    firstBand = 0;
    bandSpan = 0;
    if (!header.hasCandidateIndex())
        return false;

    int first = anchoredHBandIndexQ(
        floorLocalToQ(candidateMinY, header.fractionBits),
        coordAnchorQ.y,
        header.bandHeightQ) - header.bandMin;
    int last = anchoredHBandIndexQ(
        ceilLocalToQ(candidateMaxY, header.fractionBits),
        coordAnchorQ.y,
        header.bandHeightQ) - header.bandMin;
    if (last < first || first < 0 || uint(last) >= header.bandCount)
        return false;

    uint span = uint(last - first + 1);
    if (span == 0 || span > kMaxMergedCandidateBands)
        return false;

    firstBand = uint(first);
    bandSpan = span;
    return true;
}

float slugRender(BlobReader blob, LocalFrame frame, int2 coordAnchorQ, uint flags)
{
    BlobHeader header = blob.readHeader();
#if HEAVY_SLUG_SHADER_STATS
    addShaderStat(shaderStats, kShaderStatFragmentInvocations, 1);
#endif
    if (!header.isSupported())
        return zeroCoverage(false);
    if (header.curveCount == 0)
        return zeroCoverage(true);

    float2 renderCoord = frame.coord;
    float2 dx = frame.dx;
    float2 dy = frame.dy;
    if (!isFinite2(renderCoord) || !isFinite2(dx) || !isFinite2(dy))
        return zeroCoverage(false);

    float det = dx.x * dy.y - dx.y * dy.x;
    float invDet = 1.0 / det;
    if (!isfinite(invDet))
        return zeroCoverage(false);
    float detSign = det < 0.0 ? -1.0 : 1.0;
    float invScale = header.invScale();

    float candidateMinY;
    float candidateMaxY;
    float4 localBounds;

    uint firstBand;
    uint bandSpan;
    CoverageAccumulation coverage;
    bool useCandidateWindow = false;
    if (rectBoundsRelativeTo(header.boundsQ, coordAnchorQ, invScale, localBounds))
    {
        if (!conservativeHBandRange(renderCoord, dx, invDet, localBounds, candidateMinY, candidateMaxY))
            return zeroCoverage(true);

        useCandidateWindow = candidateBandWindow(
            header,
            coordAnchorQ,
            candidateMinY,
            candidateMaxY,
            firstBand,
            bandSpan);
    }
    if (useCandidateWindow)
    {
        coverage = candidateCoverage(
            blob,
            header,
            coordAnchorQ,
            invScale,
            firstBand,
            bandSpan,
            renderCoord,
            dx,
            dy,
            invDet);
    }
    else
    {
        coverage = fullScanCoverage(
            blob,
            header,
            coordAnchorQ,
            invScale,
            renderCoord,
            dx,
            dy,
            invDet);
    }

#if HEAVY_SLUG_SHADER_STATS
    if (coverage.integrations == 0)
        addShaderStat(shaderStats, kShaderStatBboxEmptyFragments, 1);
#endif

    float resolvedCoverage = resolveCoverage(coverage.signedArea, header.fillSign, detSign, flags);
#if HEAVY_SLUG_SHADER_STATS
    if (resolvedCoverage <= kCoverageEpsilon)
        addShaderStat(shaderStats, kShaderStatCoverageZeroFragments, 1);
#endif

    return resolvedCoverage;
}

[shader("fragment")]
float4 fragmentMain(FragmentInput input) : SV_Target
{
    GlyphMeshlet meshlet = meshlets[input.meshletIndex];
    GlyphInstance glyph = glyphs[meshlet.glyph_index];

    BlobReader blob;
    blob.buf = glyphPool;
    blob.base = glyph.blob_ref;

    float2 screen = framebufferToScreenYUp(input.position.xy, pc);
    LocalFrame frame = localFrameFromScreenYUp(screen, meshlet.screen_anchor_px, glyph.local_from_screen_2x2);
    float coverage = slugRender(blob, frame, meshlet.mesh_anchor_q, glyph.flags);
    return glyph.color * coverage;
}
