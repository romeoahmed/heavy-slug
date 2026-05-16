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

static const uint kShaderStatFragmentInvocations = 0;
static const uint kShaderStatCandidatePathFragments = 1;
static const uint kShaderStatFullScanFragments = 2;
static const uint kShaderStatCandidateCurveTests = 3;
static const uint kShaderStatFullScanCurveTests = 4;
static const uint kShaderStatEmptyFragments = 5;
static const uint kShaderStatCandidateCurveBboxRejects = 11;
static const uint kShaderStatFullScanCurveBboxRejects = 12;

void addShaderStat(uint index, uint value)
{
#if HEAVY_SLUG_SHADER_STATS
    InterlockedAdd(shaderStats[index], value);
#else
    return;
#endif
}

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
    float invDet,
    out uint bboxRejects)
{
    uint idStart;
    uint bandIdCount;
    blob.readBand(bandBase, bandIndex, idStart, bandIdCount);

    float signedArea = 0.0;
    bboxRejects = 0;
    for (uint i = 0; i < bandIdCount; i++)
    {
        uint idIndex = idStart + i;
        uint curveIndex = blob.readCurveId(idBase, idIndex);
        if (curveIndex < curveCount)
        {
            bool bboxRejected;
            signedArea += integrateCurveFromBlob(blob, curveBase, curveIndex, renderCoord, dx, dy, invDet, bboxRejected);
            bboxRejects += bboxRejected ? 1u : 0u;
        }
    }
    return signedArea;
}

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
    addShaderStat(kShaderStatFragmentInvocations, 1);
    if (curveCount == 0)
    {
        addShaderStat(kShaderStatEmptyFragments, 1);
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
        addShaderStat(kShaderStatEmptyFragments, 1);
        return 0.0;
    }

    int firstBand = int(floor(candidateMinY / bandHeight)) - bandMin;
    int lastBand = int(floor(candidateMaxY / bandHeight)) - bandMin;

    float signedArea = 0.0;
    if (bandCount > 0 && firstBand == lastBand && firstBand >= 0 && uint(firstBand) < bandCount)
    {
#if HEAVY_SLUG_SHADER_STATS
        uint idStartForStats;
        uint bandIdCountForStats;
        blob.readBand(bandBase, uint(firstBand), idStartForStats, bandIdCountForStats);
        addShaderStat(kShaderStatCandidatePathFragments, 1);
        addShaderStat(kShaderStatCandidateCurveTests, bandIdCountForStats);
#endif
        uint bboxRejects;
        signedArea = integrateCandidateCurves(
            blob,
            curveBase,
            curveCount,
            bandBase,
            idBase,
            uint(firstBand),
            renderCoord,
            dx,
            dy,
            invDet,
            bboxRejects);
        addShaderStat(kShaderStatCandidateCurveBboxRejects, bboxRejects);
    }
    else
    {
        addShaderStat(kShaderStatFullScanFragments, 1);
        addShaderStat(kShaderStatFullScanCurveTests, curveCount);
        uint bboxRejects;
        signedArea = integrateFullScan(blob, curveBase, curveCount, renderCoord, dx, dy, invDet, bboxRejects);
        addShaderStat(kShaderStatFullScanCurveBboxRejects, bboxRejects);
    }

    return resolveCoverage(signedArea, fillSign, detSign, flags);
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
