#language slang 2026
module mesh;

// Mesh shader: emit one tightened h-band strip per CPU-authored glyph meshlet.

import abi;
import coverage_blob;
import mesh_clip;
import resources;
import screen_mapping;
import stats;

struct VertexOutput
{
    float4 position : SV_Position;
#if HEAVY_SLUG_METAL
    nointerpolation uint meshletIndex : TEXCOORD_1;
#else
    nointerpolation uint meshletIndex : TEXCOORD1;
#endif
};

groupshared float2 s_clipVertices[kMeshOutputVertices];
groupshared uint s_vertexCount;
groupshared uint s_primitiveCount;
groupshared uint s_emit;

bool rectIsInvalid(int2 rectMinQ, int2 rectMaxQ)
{
    return rectMaxQ.x <= rectMinQ.x || rectMaxQ.y <= rectMinQ.y;
}

[shader("mesh")]
[numthreads(kMeshThreadCount, 1, 1)]
[outputtopology("triangle")]
void meshMain(
    uint gtid : SV_GroupThreadID,
    uint gid  : SV_GroupID,
    OutputVertices<VertexOutput, kMeshOutputVertices> verts,
    OutputIndices<uint3, kMeshOutputPrimitives> tris)
{
#if HEAVY_SLUG_SHADER_STATS
    if (gtid == 0)
        addShaderStat(shaderStats, kShaderStatMeshWorkgroups, 1);
#endif

    uint meshletIndex = pc.meshlet_base + gid;
    bool inRange = gid < pc.meshlet_count;
    GlyphMeshlet meshlet = inRange ? meshlets[meshletIndex] : (GlyphMeshlet)0;
    GlyphInstance glyph = inRange ? glyphs[meshlet.glyph_index] : (GlyphInstance)0;

    if (gtid == 0)
    {
        bool emit = inRange;
        uint cullReason = kMeshCullNone;

        if (!inRange || rectIsInvalid(meshlet.rect_min_q, meshlet.rect_max_q))
        {
            emit = false;
            cullReason = kMeshCullInvalidStrip;
        }

        float2 clipped[kMeshOutputVertices];
        uint clippedCount = 0;
        for (uint i = 0; i < kMeshOutputVertices; i++)
            clipped[i] = float2(0.0, 0.0);

        if (emit)
        {
            float2 p0 = screenToNdc(glyphLocalQToScreen(glyph, meshlet.rect_min_q), pc.viewport_size);
            float2 p1 = screenToNdc(glyphLocalQToScreen(glyph, int2(meshlet.rect_max_q.x, meshlet.rect_min_q.y)), pc.viewport_size);
            float2 p2 = screenToNdc(glyphLocalQToScreen(glyph, meshlet.rect_max_q), pc.viewport_size);
            float2 p3 = screenToNdc(glyphLocalQToScreen(glyph, int2(meshlet.rect_min_q.x, meshlet.rect_max_q.y)), pc.viewport_size);
            float area2 = p0.x * p1.y - p0.y * p1.x +
                          p1.x * p2.y - p1.y * p2.x +
                          p2.x * p3.y - p2.y * p3.x +
                          p3.x * p0.y - p3.y * p0.x;
            if (!isFinite2(meshlet.screen_anchor_px) || !isFinite2(p0) || !isFinite2(p1) || !isFinite2(p2) || !isFinite2(p3))
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
        v.meshletIndex = meshletIndex;
        verts[gtid] = v;
    }

    if (gtid < s_primitiveCount)
    {
        tris[gtid] = uint3(0, gtid + 1u, gtid + 2u);
    }
}
