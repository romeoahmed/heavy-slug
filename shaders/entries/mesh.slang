#language slang 2026
module mesh;

// Mesh shader: emit one tightened h-band strip per visible glyph meshlet.

import pga;
import abi;
import coverage_blob;
import resources;
import stats;

static const float kNoBoundsMin = 1.0e20;
static const float kNoBoundsMax = -1.0e20;

struct VertexOutput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
#if HEAVY_SLUG_METAL
    float2 texcoord    : TEXCOORD;
    nointerpolation uint blobRef : TEXCOORD_1;
    nointerpolation uint flags           : TEXCOORD_2;
#else
    float2 texcoord    : TEXCOORD0;
    nointerpolation uint blobRef : TEXCOORD1;
    nointerpolation uint flags           : TEXCOORD2;
#endif
};

// Quad corner order: BL, BR, TR, TL (CCW triangles: 0-1-2, 0-2-3).
static const float2 kCornerOffsets[4] = {
    float2(0.0, 0.0),  // BL
    float2(1.0, 0.0),  // BR
    float2(1.0, 1.0),  // TR
    float2(0.0, 1.0),  // TL
};

static const uint3 kTriIndices[2] = {
    uint3(0, 1, 2),
    uint3(0, 2, 3),
};

groupshared float s_threadMinX[kMeshThreadCount];
groupshared float s_threadMaxX[kMeshThreadCount];
groupshared uint s_threadCandidateCounts[kMeshThreadCount];
groupshared float4 s_rect;
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

float2 emPerPixel(GlyphInstance glyph)
{
    float2 halfDim = pc.viewport_size * 0.5;
    float2 ppe = float2(
        length(float2(pc.projection[0][0] * halfDim.x, pc.projection[1][0] * halfDim.y)),
        length(float2(pc.projection[0][1] * halfDim.x, pc.projection[1][1] * halfDim.y))
    );
    float ms = glyph.motor.x * glyph.motor.x + glyph.motor.y * glyph.motor.y;
    return (1.0 / ppe) / ms;
}

void scanSliceXBounds(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    uint bandBase,
    uint idBase,
    uint bandStart,
    uint bandEnd,
    uint gtid)
{
    float localMinX = kNoBoundsMin;
    float localMaxX = kNoBoundsMax;
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
                float4 bbox = blob.readCurveBounds(curveBase, curveIndex);
                localMinX = min(localMinX, bbox.x);
                localMaxX = max(localMaxX, bbox.y);
            }
        }
    }

    s_threadMinX[gtid] = localMinX;
    s_threadMaxX[gtid] = localMaxX;
    s_threadCandidateCounts[gtid] = localCandidates;
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

    uint effectiveSlices = min(requestedSlices, max(bandCount, 1u));
    bool hasSlice = curveCount != 0 && bandCount != 0 && requestedSlice < effectiveSlices;
    uint bandStart = hasSlice ? (requestedSlice * bandCount) / effectiveSlices : 0;
    uint bandEnd = hasSlice ? ((requestedSlice + 1u) * bandCount) / effectiveSlices : 0;
    hasSlice = hasSlice && bandEnd > bandStart;

    if (hasSlice)
        scanSliceXBounds(blob, curveBase, curveCount, bandBase, idBase, bandStart, bandEnd, gtid);
    else
    {
        s_threadMinX[gtid] = kNoBoundsMin;
        s_threadMaxX[gtid] = kNoBoundsMax;
        s_threadCandidateCounts[gtid] = 0;
    }

    GroupMemoryBarrierWithGroupSync();

    if (gtid == 0)
    {
        float minX = kNoBoundsMin;
        float maxX = kNoBoundsMax;
        uint candidateCount = 0;
        for (uint i = 0; i < kMeshThreadCount; i++)
        {
            minX = min(minX, s_threadMinX[i]);
            maxX = max(maxX, s_threadMaxX[i]);
            candidateCount += s_threadCandidateCounts[i];
        }

        float2 dilate = emPerPixel(glyph) * 0.5;
        float yMin = max(glyph.em_y_min, (float(bandMin) + float(bandStart)) * bandHeight);
        float yMax = min(glyph.em_y_max, (float(bandMin) + float(bandEnd)) * bandHeight);

        if (bandStart == 0)
            yMin -= dilate.y;
        if (bandEnd == bandCount)
            yMax += dilate.y;

        float2 rectMin = float2(max(glyph.em_x_min, minX) - dilate.x, yMin);
        float2 rectMax = float2(min(glyph.em_x_max, maxX) + dilate.x, yMax);

        bool emit = candidateCount != 0 && rectMax.x > rectMin.x && rectMax.y > rectMin.y;
        s_rect = float4(rectMin, rectMax);
        s_emit = emit ? 1u : 0u;

#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(shaderStats, emit ? kShaderStatMeshTilesEmitted : kShaderStatMeshTilesCulled, 1);
#endif
    }

    GroupMemoryBarrierWithGroupSync();
    SetMeshOutputCounts(
        s_emit != 0 ? kMeshOutputVertices : 0,
        s_emit != 0 ? kMeshOutputPrimitives : 0);
    if (s_emit == 0)
        return;

    if (gtid < 4)
    {
        Motor motor = { glyph.motor };
        float2 corner = kCornerOffsets[gtid];
        float2 emPos = lerp(s_rect.xy, s_rect.zw, corner);
        float2 worldPos = motor.apply(emPos);
        float4 clipPos = mul(pc.projection, float4(worldPos, 0.0, 1.0));

        VertexOutput v;
        v.position = clipPos;
        v.color = glyph.color;
        v.texcoord = emPos;
        v.blobRef = glyph.blob_ref;
        v.flags = glyph.flags;
        verts[gtid] = v;
    }

    if (gtid < 2)
    {
        tris[gtid] = kTriIndices[gtid];
    }
}
