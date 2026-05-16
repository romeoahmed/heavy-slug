// Fragment shader: CoverageBlob analytic cubic coverage.

import abi;
import coverage_blob;
import coverage_integral;
import hband;
import resources;

struct FragmentInput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
#if HEAVY_SLUG_METAL
    float2 texcoord    : TEXCOORD;
    nointerpolation uint glyphRef : TEXCOORD1;
    nointerpolation uint flags           : TEXCOORD2;
#else
    float2 texcoord    : TEXCOORD0;
    nointerpolation uint glyphRef : TEXCOORD1;
    nointerpolation uint flags           : TEXCOORD2;
#endif
};

static const uint kMaxMergedCandidateBands = 8;
static const uint kInvalidCurveIndex = 0xffffffffu;

#if HEAVY_SLUG_SHADER_STATS
static const uint kShaderStatFragmentInvocations = 0;
static const uint kShaderStatCandidatePathFragments = 1;
static const uint kShaderStatFullScanFragments = 2;
static const uint kShaderStatCandidateCurveTests = 3;
static const uint kShaderStatFullScanCurveTests = 4;
static const uint kShaderStatEmptyFragments = 5;
static const uint kShaderStatCandidateCurveBboxRejects = 11;
static const uint kShaderStatFullScanCurveBboxRejects = 12;
static const uint kShaderStatCandidateCurveIntegrations = 13;
static const uint kShaderStatFullScanCurveIntegrations = 14;
static const uint kShaderStatBboxEmptyFragments = 15;
static const uint kShaderStatCoverageZeroFragments = 16;

void addShaderStat(uint index, uint value)
{
    InterlockedAdd(shaderStats[index], value);
}
#endif

float integrateCandidateCurves(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
    uint bandIndex,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    uint idStart;
    uint bandIdCount;
    blob.readBand(bandBase, bandIndex, idStart, bandIdCount);

    float signedArea = 0.0;
    for (uint i = 0; i < bandIdCount; i++)
    {
        uint idIndex = idStart + i;
        uint curveIndex = blob.readCurveId(idBase, idIndex);
        if (curveIndex < curveCount)
        {
            float4 bbox = blob.readCurveBounds(curveBase, curveIndex);
            if (curveBboxMayContribute(bbox, renderCoord, dx, dy, invDet))
                signedArea += integrateCurvePayload(blob, curveBase, curveIndex, renderCoord, dx, dy, invDet);
        }
    }
    return signedArea;
}

float integrateCandidateBandRange(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
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
    }

    float signedArea = 0.0;
    while (true)
    {
        uint curveIndex = kInvalidCurveIndex;
        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            if (cursors[band] < counts[band])
                curveIndex = min(curveIndex, blob.readCurveId(idBase, starts[band] + cursors[band]));
        }
        if (curveIndex == kInvalidCurveIndex)
            break;

        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            while (cursors[band] < counts[band] &&
                   blob.readCurveId(idBase, starts[band] + cursors[band]) == curveIndex)
            {
                cursors[band]++;
            }
        }

        if (curveIndex < curveCount)
        {
            float4 bbox = blob.readCurveBounds(curveBase, curveIndex);
            if (curveBboxMayContribute(bbox, renderCoord, dx, dy, invDet))
                signedArea += integrateCurvePayload(blob, curveBase, curveIndex, renderCoord, dx, dy, invDet);
        }
    }
    return signedArea;
}

#if HEAVY_SLUG_SHADER_STATS
float integrateCandidateCurvesWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
    uint bandIndex,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out uint bboxRejects,
    out uint integrations)
{
    uint idStart;
    uint bandIdCount;
    blob.readBand(bandBase, bandIndex, idStart, bandIdCount);

    float signedArea = 0.0;
    bboxRejects = 0;
    integrations = 0;
    for (uint i = 0; i < bandIdCount; i++)
    {
        uint idIndex = idStart + i;
        uint curveIndex = blob.readCurveId(idBase, idIndex);
        if (curveIndex < curveCount)
        {
            bool bboxRejected;
            signedArea += integrateCurveFromBlobWithStats(blob, curveBase, curveIndex, renderCoord, dx, dy, invDet, bboxRejected);
            bboxRejects += bboxRejected ? 1u : 0u;
            integrations += bboxRejected ? 0u : 1u;
        }
    }
    return signedArea;
}

float integrateCandidateBandRangeWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
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
            if (cursors[band] < counts[band])
                curveIndex = min(curveIndex, blob.readCurveId(idBase, starts[band] + cursors[band]));
        }
        if (curveIndex == kInvalidCurveIndex)
            break;

        for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        {
            while (cursors[band] < counts[band] &&
                   blob.readCurveId(idBase, starts[band] + cursors[band]) == curveIndex)
            {
                cursors[band]++;
            }
        }

        if (curveIndex < curveCount)
        {
            curveTests++;
            bool bboxRejected;
            signedArea += integrateCurveFromBlobWithStats(blob, curveBase, curveIndex, renderCoord, dx, dy, invDet, bboxRejected);
            bboxRejects += bboxRejected ? 1u : 0u;
            integrations += bboxRejected ? 0u : 1u;
        }
    }
    return signedArea;
}
#endif

float slugRender(BlobReader blob, float2 renderCoord, uint flags)
{
    float4 bounds;
    uint curveCount;
    float fillSign;
    uint curveBase;
    int bandMin;
    uint bandCount;
    float bandHeight;
    uint bandBase;
    uint idBase;
    blob.readHeader(
        bounds,
        curveCount,
        fillSign,
        curveBase,
        bandMin,
        bandCount,
        bandHeight,
        bandBase,
        idBase);
#if HEAVY_SLUG_SHADER_STATS
    addShaderStat(kShaderStatFragmentInvocations, 1);
#endif
    if (curveCount == 0)
    {
#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(kShaderStatEmptyFragments, 1);
#endif
        return 0.0;
    }

    float2 dx = ddx(renderCoord);
    float2 dy = ddy(renderCoord);
    float det = dx.x * dy.y - dx.y * dy.x;
    if (abs(det) <= kCoverageEpsilon)
        return 0.0;

    float invDet = 1.0 / det;
    float detSign = det < 0.0 ? -1.0 : 1.0;

    float candidateMinY;
    float candidateMaxY;
    if (!conservativeHBandRange(renderCoord, dx, invDet, bounds, candidateMinY, candidateMaxY))
    {
#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(kShaderStatEmptyFragments, 1);
#endif
        return 0.0;
    }

    int firstBand = int(floor(candidateMinY / bandHeight)) - bandMin;
    int lastBand = int(floor(candidateMaxY / bandHeight)) - bandMin;
    uint bandSpan = uint(lastBand - firstBand + 1);

    float signedArea = 0.0;
#if HEAVY_SLUG_SHADER_STATS
    uint integrations = 0;
#endif
    if (bandCount > 0 && firstBand >= 0 && uint(lastBand) < bandCount && bandSpan <= kMaxMergedCandidateBands)
    {
#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(kShaderStatCandidatePathFragments, 1);
        uint curveTests;
        uint bboxRejects;
        signedArea = integrateCandidateBandRangeWithStats(
            blob,
            curveBase,
            curveCount,
            bandBase,
            idBase,
            uint(firstBand),
            bandSpan,
            renderCoord,
            dx,
            dy,
            invDet,
            curveTests,
            bboxRejects,
            integrations);
        addShaderStat(kShaderStatCandidateCurveTests, curveTests);
        addShaderStat(kShaderStatCandidateCurveBboxRejects, bboxRejects);
        addShaderStat(kShaderStatCandidateCurveIntegrations, integrations);
#else
        signedArea = integrateCandidateBandRange(
            blob,
            curveBase,
            curveCount,
            bandBase,
            idBase,
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
        addShaderStat(kShaderStatFullScanFragments, 1);
        addShaderStat(kShaderStatFullScanCurveTests, curveCount);
        uint bboxRejects;
        signedArea = integrateFullScanWithStats(blob, curveBase, curveCount, renderCoord, dx, dy, invDet, bboxRejects, integrations);
        addShaderStat(kShaderStatFullScanCurveBboxRejects, bboxRejects);
        addShaderStat(kShaderStatFullScanCurveIntegrations, integrations);
#else
        signedArea = integrateFullScan(blob, curveBase, curveCount, renderCoord, dx, dy, invDet);
#endif
    }

#if HEAVY_SLUG_SHADER_STATS
    if (integrations == 0)
        addShaderStat(kShaderStatBboxEmptyFragments, 1);
#endif

    float coverage = resolveCoverage(signedArea, fillSign, detSign, flags);
#if HEAVY_SLUG_SHADER_STATS
    if (coverage <= kCoverageEpsilon)
        addShaderStat(kShaderStatCoverageZeroFragments, 1);
#endif

    return coverage;
}

[shader("fragment")]
float4 fragmentMain(FragmentInput input) : SV_Target
{
    BlobReader blob;
#if HEAVY_SLUG_METAL
    blob.buf = glyphPool;
    blob.base = input.glyphRef;
#else
    blob.buf = glyphBlobs[NonUniformResourceIndex(input.glyphRef)];
    blob.base = 0;
#endif

    float coverage = slugRender(blob, input.texcoord, input.flags);
    return input.color * coverage;
}
