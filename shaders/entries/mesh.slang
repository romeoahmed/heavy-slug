#language slang 2026
module mesh;

// Mesh shader: emit one tightened h-band strip per visible glyph meshlet.

import abi;
import coverage_blob;
import mesh_clip;
import resources;
import screen_mapping;
import stats;

static const float kNoBoundsMax = -1.0e20;

struct VertexOutput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
#if HEAVY_SLUG_METAL
    nointerpolation uint blobRef : TEXCOORD_1;
    nointerpolation uint flags           : TEXCOORD_2;
    nointerpolation float2 texcoordAnchor : TEXCOORD_3;
    nointerpolation float3 screenToLocalX : TEXCOORD_4;
    nointerpolation float3 screenToLocalY : TEXCOORD_5;
    nointerpolation float3 screenToLocalT : TEXCOORD_6;
#else
    nointerpolation uint blobRef : TEXCOORD1;
    nointerpolation uint flags           : TEXCOORD2;
    nointerpolation float2 texcoordAnchor : TEXCOORD3;
    nointerpolation float3 screenToLocalX : TEXCOORD4;
    nointerpolation float3 screenToLocalY : TEXCOORD5;
    nointerpolation float3 screenToLocalT : TEXCOORD6;
#endif
};

groupshared float s_threadMaxX[kMeshThreadCount];
groupshared uint s_threadCandidateCounts[kMeshThreadCount];
groupshared float2 s_anchor;
groupshared float2 s_clipVertices[kMeshOutputVertices];
groupshared float3 s_screenToLocalX;
groupshared float3 s_screenToLocalY;
groupshared float3 s_screenToLocalT;
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
                localMaxX = max(localMaxX, bbox.y);
            }
        }
    }

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
        scanSliceRightBound(blob, curveBase, curveCount, bandBase, idBase, bandStart, bandEnd, gtid);
    else
    {
        s_threadMaxX[gtid] = kNoBoundsMax;
        s_threadCandidateCounts[gtid] = 0;
    }

    GroupMemoryBarrierWithGroupSync();

    if (gtid == 0)
    {
        float maxX = kNoBoundsMax;
        uint candidateCount = 0;
        for (uint i = 0; i < kMeshThreadCount; i++)
        {
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

        // The fragment integral resolves interior coverage from right-side
        // contour crossings.  A slice with only a right boundary can still
        // cover every pixel to its left, so the mesh strip must use the
        // glyph's global left bound rather than the leftmost candidate curve.
        float2 rectMin = float2(glyph.em_x_min - dilate.x, yMin);
        float2 rectMax = float2(min(glyph.em_x_max, maxX) + dilate.x, yMax);

        uint cullReason = kMeshCullNone;
        if (candidateCount == 0)
            cullReason = kMeshCullEmptySlice;
        else if (!isFinite2(rectMin) ||
                 !isFinite2(rectMax) ||
                 rectMax.x <= rectMin.x ||
                 rectMax.y <= rectMin.y)
        {
            cullReason = kMeshCullInvalidStrip;
        }

        bool emit = cullReason == kMeshCullNone;
        float2 anchor = (rectMin + rectMax) * 0.5;
        ScreenToLocal localTransform;
        LocalToClip glyphToClip = localToClipForGlyph(glyph, pc.projection);
        AnchoredLocalToClip anchoredFrame;
        float2 clipped[kMeshOutputVertices];
        uint clippedCount = 0;
        for (uint i = 0; i < kMeshOutputVertices; i++)
            clipped[i] = float2(0.0, 0.0);
        clearScreenToLocal(localTransform);
        if (emit)
        {
            float4 rect = float4(rectMin, rectMax);
            emit = anchorForRectAtNdc(glyphToClip, rect, float2(0.0, 0.0), anchoredFrame);
            if (!emit)
                cullReason = kMeshCullAnchorFailed;
            anchor = anchoredFrame.anchor;
            if (emit)
            {
                emit = clipRectToNdc(anchoredFrame, rect, clipped, clippedCount);
                if (!emit)
                    cullReason = kMeshCullClipEmpty;
            }
        }
        if (emit)
        {
            emit = screenToLocalTransform(anchoredFrame, pc.viewport_size, localTransform);
            if (!emit)
                cullReason = kMeshCullTransformFailed;
        }

        s_anchor = anchor;
        s_screenToLocalX = localTransform.x;
        s_screenToLocalY = localTransform.y;
        s_screenToLocalT = localTransform.t;
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
        float2 anchor = s_anchor;

        VertexOutput v;
        v.position = float4(s_clipVertices[gtid], 0.0, 1.0);
        v.color = glyph.color;
        v.blobRef = glyph.blob_ref;
        v.flags = glyph.flags;
        v.texcoordAnchor = anchor;
        v.screenToLocalX = s_screenToLocalX;
        v.screenToLocalY = s_screenToLocalY;
        v.screenToLocalT = s_screenToLocalT;
        verts[gtid] = v;
    }

    if (gtid < s_primitiveCount)
    {
        tris[gtid] = uint3(0, gtid + 1u, gtid + 2u);
    }
}
