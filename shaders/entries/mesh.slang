#language slang 2026
module mesh;

// Mesh shader: emit one tightened h-band strip per visible glyph meshlet.

import abi;
import coverage_blob;
import mesh_clip;
import resources;
import screen_mapping;
import stats;

static const int kNoBoundsMaxQ = -2147483647;
static const float kI32MinFloat = -2147483648.0;
static const float kI32MaxFloat = 2147483520.0;

struct VertexOutput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
#if HEAVY_SLUG_METAL
    nointerpolation uint blobRef : TEXCOORD_1;
    nointerpolation uint flags : TEXCOORD_2;
    nointerpolation int2 meshAnchorQ : TEXCOORD_3;
    nointerpolation float2 screenAnchorPx : TEXCOORD_4;
    nointerpolation float4 localFromScreen : TEXCOORD_5;
#else
    nointerpolation uint blobRef : TEXCOORD1;
    nointerpolation uint flags : TEXCOORD2;
    nointerpolation int2 meshAnchorQ : TEXCOORD3;
    nointerpolation float2 screenAnchorPx : TEXCOORD4;
    nointerpolation float4 localFromScreen : TEXCOORD5;
#endif
};

groupshared int s_threadMaxXQ[kMeshThreadCount];
groupshared uint s_threadCandidateCounts[kMeshThreadCount];
groupshared int2 s_meshAnchorQ;
groupshared float2 s_screenAnchorPx;
groupshared float2 s_clipVertices[kMeshOutputVertices];
groupshared uint s_vertexCount;
groupshared uint s_primitiveCount;
groupshared uint s_emit;

BlobReader blobReader(uint blobRef)
{
    BlobReader blob;
    blob.buf = glyphPool;
    blob.base = blobRef;
    return blob;
}

uint sliceIndex(uint sliceInfo)
{
    return sliceInfo & 0xffffu;
}

uint sliceCount(uint sliceInfo)
{
    return sliceInfo >> 16;
}

int boundedQFromFloat(float v, bool upper)
{
    if (!isfinite(v))
        return upper ? 2147483647 : -2147483647 - 1;
    float rounded = upper ? ceil(v) : floor(v);
    if (rounded <= kI32MinFloat)
        return -2147483647 - 1;
    if (rounded >= kI32MaxFloat)
        return 2147483647;
    return int(rounded);
}

int saturatingAddQ(int a, int b)
{
    if (b > 0 && a > 2147483647 - b)
        return 2147483647;
    if (b < 0 && a < (-2147483647 - 1) - b)
        return -2147483647 - 1;
    return a + b;
}

int saturatingSubQ(int a, int b)
{
    if (b == (-2147483647 - 1))
        return 2147483647;
    if (b < 0)
        return saturatingAddQ(a, -b);
    if (a < (-2147483647 - 1) + b)
        return -2147483647 - 1;
    return a - b;
}

int2 localPixelDilationQ(GlyphInstance glyph)
{
    float scale = exp2(float(glyph.precision_bits));
    float2 dx = float2(glyph.local_from_screen_2x2.x, glyph.local_from_screen_2x2.y);
    float2 dy = float2(glyph.local_from_screen_2x2.z, glyph.local_from_screen_2x2.w);
    float2 radius = (abs(dx) + abs(dy)) * 0.5;
    float2 q = radius * scale;
    return int2(boundedQFromFloat(q.x, true), boundedQFromFloat(q.y, true));
}

void scanSliceRightBound(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
    uint bandStart,
    uint bandEnd,
    uint gtid)
{
    int localMaxXQ = kNoBoundsMaxQ;
    uint localCandidates = 0;

    for (uint bandIndex = bandStart + gtid; bandIndex < bandEnd; bandIndex += kMeshThreadCount)
    {
        uint idStart;
        uint bandIdCount;
        blob.readBand(bandBase, bandIndex, idStart, bandIdCount);
        localCandidates += bandIdCount;

        for (uint i = 0; i < bandIdCount; i++)
        {
            uint curveIndex = blob.readCurveId(idBase, idStart + i);
            if (curveIndex < curveCount)
            {
                int4 bbox = blob.readCurveBoundsQ(curveBase, curveIndex);
                localMaxXQ = max(localMaxXQ, bbox.z);
            }
        }
    }

    s_threadMaxXQ[gtid] = localMaxXQ;
    s_threadCandidateCounts[gtid] = localCandidates;
}

int midpointQ(int lo, int hi)
{
    if ((lo < 0) != (hi < 0))
        return (lo + hi) / 2;
    return lo + (hi - lo) / 2;
}

int localScreenToQ(GlyphInstance glyph, float2 screen, uint axis, bool upper)
{
    float2 localDelta = mul2x2(glyph.local_from_screen_2x2, screen - glyph.screen_anchor_px);
    int anchor = axis == 0 ? glyph.glyph_anchor_q.x : glyph.glyph_anchor_q.y;
    // Keep the large fixed-point anchor in integer space; adding it in f32
    // drops subpixel-scale viewport deltas once anchor exceeds 2^24.
    float deltaQ = (axis == 0 ? localDelta.x : localDelta.y) * exp2(float(glyph.precision_bits));
    return saturatingAddQ(anchor, boundedQFromFloat(deltaQ, upper));
}

int4 viewportLocalBoundsQ(GlyphInstance glyph)
{
    float2 s0 = float2(0.0, 0.0);
    float2 s1 = float2(pc.viewport_size.x, 0.0);
    float2 s2 = pc.viewport_size;
    float2 s3 = float2(0.0, pc.viewport_size.y);

    int minX = min(min(localScreenToQ(glyph, s0, 0, false), localScreenToQ(glyph, s1, 0, false)),
                   min(localScreenToQ(glyph, s2, 0, false), localScreenToQ(glyph, s3, 0, false)));
    int maxX = max(max(localScreenToQ(glyph, s0, 0, true), localScreenToQ(glyph, s1, 0, true)),
                   max(localScreenToQ(glyph, s2, 0, true), localScreenToQ(glyph, s3, 0, true)));
    int minY = min(min(localScreenToQ(glyph, s0, 1, false), localScreenToQ(glyph, s1, 1, false)),
                   min(localScreenToQ(glyph, s2, 1, false), localScreenToQ(glyph, s3, 1, false)));
    int maxY = max(max(localScreenToQ(glyph, s0, 1, true), localScreenToQ(glyph, s1, 1, true)),
                   max(localScreenToQ(glyph, s2, 1, true), localScreenToQ(glyph, s3, 1, true)));
    return int4(minX, minY, maxX, maxY);
}

int bandEdgeQ(int bandMin, uint bandOffset, int bandHeightQ, bool upper)
{
    float edge = (float(bandMin) + float(bandOffset)) * float(bandHeightQ);
    return boundedQFromFloat(edge, upper);
}

[shader("mesh")]
[numthreads(kMeshThreadCount, 1, 1)]
[outputtopology("triangle")]
void meshMain(
    uint gtid : SV_GroupThreadID,
    uint gid  : SV_GroupID,
    in payload TaskPayload taskPayload,
    OutputVertices<VertexOutput, kMeshOutputVertices> verts,
    OutputIndices<uint3, kMeshOutputPrimitives> tris)
{
#if HEAVY_SLUG_SHADER_STATS
    if (gtid == 0)
        addShaderStat(shaderStats, kShaderStatMeshWorkgroups, 1);
#endif

    uint glyphIndex = taskPayload.glyphIndices[gid];
    uint info = taskPayload.sliceInfos[gid];
    uint requestedSlice = sliceIndex(info);
    uint requestedSlices = max(sliceCount(info), 1u);

    GlyphInstance glyph = glyphs[glyphIndex];
    BlobReader blob = blobReader(glyph.blob_ref);
    BlobHeader header = blob.readHeader();

    uint effectiveSlices = min(requestedSlices, max(header.bandCount, 1u));
    bool hasSlice = header.curveCount != 0 && header.bandCount != 0 && requestedSlice < effectiveSlices;
    uint bandStart = hasSlice ? (requestedSlice * header.bandCount) / effectiveSlices : 0;
    uint bandEnd = hasSlice ? ((requestedSlice + 1u) * header.bandCount) / effectiveSlices : 0;
    hasSlice = hasSlice && bandEnd > bandStart;

    if (hasSlice)
        scanSliceRightBound(blob, header.curveBaseWords, header.curveCount, header.bandBaseWords, header.idBaseWords, bandStart, bandEnd, gtid);
    else
    {
        s_threadMaxXQ[gtid] = kNoBoundsMaxQ;
        s_threadCandidateCounts[gtid] = 0;
    }

    GroupMemoryBarrierWithGroupSync();

    if (gtid == 0)
    {
        int maxXQ = kNoBoundsMaxQ;
        uint candidateCount = 0;
        for (uint i = 0; i < kMeshThreadCount; i++)
        {
            maxXQ = max(maxXQ, s_threadMaxXQ[i]);
            candidateCount += s_threadCandidateCounts[i];
        }

        int2 dilateQ = localPixelDilationQ(glyph);
        int4 viewportQ = viewportLocalBoundsQ(glyph);
        int yMinQ = max(max(glyph.local_bounds_q.y, saturatingSubQ(viewportQ.y, dilateQ.y)), bandEdgeQ(header.bandMin, bandStart, header.bandHeightQ, false));
        int yMaxQ = min(min(glyph.local_bounds_q.w, saturatingAddQ(viewportQ.w, dilateQ.y)), bandEdgeQ(header.bandMin, bandEnd, header.bandHeightQ, true));

        if (bandStart == 0)
            yMinQ = saturatingSubQ(yMinQ, dilateQ.y);
        if (bandEnd == header.bandCount)
            yMaxQ = saturatingAddQ(yMaxQ, dilateQ.y);

        int2 rectMinQ = int2(max(glyph.local_bounds_q.x, saturatingSubQ(viewportQ.x, dilateQ.x)), yMinQ);
        int2 rectMaxQ = int2(min(saturatingAddQ(min(glyph.local_bounds_q.z, maxXQ), dilateQ.x), saturatingAddQ(viewportQ.z, dilateQ.x)), yMaxQ);

        uint cullReason = kMeshCullNone;
        if (candidateCount == 0)
            cullReason = kMeshCullEmptySlice;
        else if (rectMaxQ.x <= rectMinQ.x || rectMaxQ.y <= rectMinQ.y)
            cullReason = kMeshCullInvalidStrip;

        bool emit = cullReason == kMeshCullNone;
        int2 meshAnchorQ = int2(midpointQ(rectMinQ.x, rectMaxQ.x), midpointQ(rectMinQ.y, rectMaxQ.y));
        float2 screenAnchorPx = glyphLocalQToScreen(glyph, meshAnchorQ);
        float2 clipped[kMeshOutputVertices];
        uint clippedCount = 0;
        for (uint i = 0; i < kMeshOutputVertices; i++)
            clipped[i] = float2(0.0, 0.0);

        if (emit)
        {
            float2 p0 = screenToNdc(glyphLocalQToScreen(glyph, rectMinQ), pc.viewport_size);
            float2 p1 = screenToNdc(glyphLocalQToScreen(glyph, int2(rectMaxQ.x, rectMinQ.y)), pc.viewport_size);
            float2 p2 = screenToNdc(glyphLocalQToScreen(glyph, rectMaxQ), pc.viewport_size);
            float2 p3 = screenToNdc(glyphLocalQToScreen(glyph, int2(rectMinQ.x, rectMaxQ.y)), pc.viewport_size);
            float area2 = p0.x * p1.y - p0.y * p1.x +
                          p1.x * p2.y - p1.y * p2.x +
                          p2.x * p3.y - p2.y * p3.x +
                          p3.x * p0.y - p3.y * p0.x;
            if (!isFinite2(screenAnchorPx) || !isFinite2(p0) || !isFinite2(p1) || !isFinite2(p2) || !isFinite2(p3))
            {
                emit = false;
                cullReason = kMeshCullNonFinite;
            }
            else if (abs(area2) <= 1.0e-12)
            {
                emit = false;
                cullReason = kMeshCullZeroArea;
            }
            else
            {
                emit = clipNdcQuad(p0, p1, p2, p3, clipped, clippedCount);
                if (!emit)
                    cullReason = kMeshCullClipEmpty;
            }
        }

        s_meshAnchorQ = meshAnchorQ;
        s_screenAnchorPx = screenAnchorPx;
        s_vertexCount = emit ? clippedCount : 0u;
        s_primitiveCount = emit ? clippedCount - 2u : 0u;
        for (uint i = 0; i < kMeshOutputVertices; i++)
            s_clipVertices[i] = i < clippedCount ? clipped[i] : float2(0.0, 0.0);
        s_emit = emit ? 1u : 0u;

#if HEAVY_SLUG_SHADER_STATS
        addMeshTileStat(shaderStats, emit, cullReason);
#endif
    }

    GroupMemoryBarrierWithGroupSync();
    SetMeshOutputCounts(s_vertexCount, s_primitiveCount);
    if (s_emit == 0)
        return;

    if (gtid < s_vertexCount)
    {
        VertexOutput v;
        v.position = float4(s_clipVertices[gtid], 0.0, 1.0);
        v.color = glyph.color;
        v.blobRef = glyph.blob_ref;
        v.flags = glyph.flags;
        v.meshAnchorQ = s_meshAnchorQ;
        v.screenAnchorPx = s_screenAnchorPx;
        v.localFromScreen = glyph.local_from_screen_2x2;
        verts[gtid] = v;
    }

    if (gtid < s_primitiveCount)
    {
        tris[gtid] = uint3(0, gtid + 1u, gtid + 2u);
    }
}
