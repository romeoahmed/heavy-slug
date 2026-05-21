#language slang 2026
module candidate_index;

// CSR h-band candidate traversal. Each band stores a sorted curve-id list; a
// fragment merges at most kMaxMergedCandidateBands adjacent bands and dedupes
// repeated curve IDs before running the analytic cubic integral.

import coverage_blob;
import coverage_integral;
import abi;

static const uint kInvalidCurveIndex = 0xffffffffu;

public struct CandidateResult
{
    public float signedArea;
    public uint curveTests;
    public uint bboxRejects;
    public uint integrations;
};

struct CandidateCursor
{
    uint start;
    uint count;
    uint cursor;
    uint head;
};

CandidateResult emptyCandidateResult()
{
    CandidateResult result;
    result.signedArea = 0.0;
    result.curveTests = 0;
    result.bboxRejects = 0;
    result.integrations = 0;
    return result;
}

CandidateCursor loadCandidateCursor(
    BlobReader blob,
    uint bandBase,
    uint idBase,
    uint firstBand,
    uint bandOffset,
    uint bandSpan)
{
    CandidateCursor cursor;
    cursor.start = 0;
    cursor.count = 0;
    cursor.cursor = 0;
    cursor.head = kInvalidCurveIndex;

    if (bandOffset >= bandSpan)
        return cursor;

    blob.readBand(bandBase, firstBand + bandOffset, cursor.start, cursor.count);
    cursor.head = cursor.count > 0
        ? blob.readCurveId(idBase, cursor.start)
        : kInvalidCurveIndex;
    return cursor;
}

uint minCandidateHead(CandidateCursor cursors[kMaxMergedCandidateBands])
{
    uint curveIndex = kInvalidCurveIndex;
    for (uint band = 0; band < kMaxMergedCandidateBands; band++)
        curveIndex = min(curveIndex, cursors[band].head);
    return curveIndex;
}

void consumeCandidateHead(
    inout CandidateCursor cursors[kMaxMergedCandidateBands],
    BlobReader blob,
    uint idBase,
    uint curveIndex)
{
    for (uint band = 0; band < kMaxMergedCandidateBands; band++)
    {
        while (cursors[band].head == curveIndex)
        {
            cursors[band].cursor++;
            cursors[band].head = cursors[band].cursor < cursors[band].count
                ? blob.readCurveId(idBase, cursors[band].start + cursors[band].cursor)
                : kInvalidCurveIndex;
        }
    }
}

void integrateCandidateCurve(
    inout CandidateResult result,
    BlobReader blob,
    uint curveBase,
    uint curveIndex,
    int2 coordAnchorQ,
    float invScale,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
#if HEAVY_SLUG_SHADER_STATS
    result.curveTests++;
    bool bboxRejected;
    result.signedArea += integrateCurveFromBlobWithStats(
        blob,
        curveBase,
        curveIndex,
        coordAnchorQ,
        invScale,
        renderCoord,
        dx,
        dy,
        invDet,
        bboxRejected);
    result.bboxRejects += bboxRejected ? 1u : 0u;
    result.integrations += bboxRejected ? 0u : 1u;
#else
    float contribution;
    bool bboxRejected;
    if (integrateCurveFromBlob(
        blob,
        curveBase,
        curveIndex,
        coordAnchorQ,
        invScale,
        renderCoord,
        dx,
        dy,
        invDet,
        contribution,
        bboxRejected))
        result.signedArea += contribution;
#endif
}

public CandidateResult integrateCandidateBandRange(
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
    CandidateResult result = emptyCandidateResult();

    CandidateCursor cursors[kMaxMergedCandidateBands];
    for (uint band = 0; band < kMaxMergedCandidateBands; band++)
    {
        cursors[band] = loadCandidateCursor(blob, bandBase, idBase, firstBand, band, bandSpan);
    }

    while (true)
    {
        uint curveIndex = minCandidateHead(cursors);
        if (curveIndex == kInvalidCurveIndex)
            break;

        consumeCandidateHead(cursors, blob, idBase, curveIndex);
        if (curveIndex < curveCount)
        {
            integrateCandidateCurve(
                result,
                blob,
                curveBase,
                curveIndex,
                coordAnchorQ,
                invScale,
                renderCoord,
                dx,
                dy,
                invDet);
        }
    }

    return result;
}
