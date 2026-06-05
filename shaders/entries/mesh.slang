#language slang 2026
module mesh;

// Mesh shader: emit one tightened h-band strip per CPU-authored glyph meshlet.

import abi;
import coverage_blob;
import mesh_clip;
import resources;
import screen_mapping;
import shader_math;
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

float quadArea2(float2 p0, float2 p1, float2 p2, float2 p3)
{
    return p0.x * p1.y - p0.y * p1.x +
           p1.x * p2.y - p1.y * p2.x +
           p2.x * p3.y - p2.y * p3.x +
           p3.x * p0.y - p3.y * p0.x;
}

bool meshletQuadNdc(
    GlyphInstance glyph,
    GlyphMeshlet meshlet,
    out float2 p0,
    out float2 p1,
    out float2 p2,
    out float2 p3)
{
    p0 = float2(0.0, 0.0);
    p1 = float2(0.0, 0.0);
    p2 = float2(0.0, 0.0);
    p3 = float2(0.0, 0.0);

    float2 s0, s1, s2, s3;
    if (!meshletLocalQToScreen(glyph, meshlet, meshlet.rect_min_q, s0) ||
        !meshletLocalQToScreen(glyph, meshlet, int2(meshlet.rect_max_q.x, meshlet.rect_min_q.y), s1) ||
        !meshletLocalQToScreen(glyph, meshlet, meshlet.rect_max_q, s2) ||
        !meshletLocalQToScreen(glyph, meshlet, int2(meshlet.rect_min_q.x, meshlet.rect_max_q.y), s3))
        return false;

    p0 = screenToNdc(s0, pc.viewport_size);
    p1 = screenToNdc(s1, pc.viewport_size);
    p2 = screenToNdc(s2, pc.viewport_size);
    p3 = screenToNdc(s3, pc.viewport_size);

    return isFinite2(meshlet.screen_anchor_px) &&
           isFinite2(p0) &&
           isFinite2(p1) &&
           isFinite2(p2) &&
           isFinite2(p3);
}

bool planMeshletEmission(
    bool inRange,
    GlyphInstance glyph,
    GlyphMeshlet meshlet,
    out float2 clipped[kMeshOutputVertices],
    out uint clippedCount,
    out uint cullReason)
{
    clippedCount = 0;
    cullReason = kMeshletCullNone;
    for (uint i = 0; i < kMeshOutputVertices; i++)
        clipped[i] = float2(0.0, 0.0);

    if (!inRange || rectIsInvalid(meshlet.rect_min_q, meshlet.rect_max_q))
    {
        cullReason = kMeshletCullInvalidStrip;
        return false;
    }

    float2 p0, p1, p2, p3;
    if (!meshletQuadNdc(glyph, meshlet, p0, p1, p2, p3))
    {
        cullReason = kMeshletCullNonFinite;
        return false;
    }

    float area2 = quadArea2(p0, p1, p2, p3);
    if (!isfinite(area2) || abs(area2) <= 1.0e-12)
    {
        cullReason = kMeshletCullZeroArea;
        return false;
    }

    if (!clipNdcQuad(p0, p1, p2, p3, clipped, clippedCount))
    {
        cullReason = kMeshletCullClipEmpty;
        return false;
    }

    return true;
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

    // meshletIndex is a function of pc.meshlet_base + gid, both uniform across
    // the workgroup, so every thread computes the same value without an SSBO
    // load. The expensive reads (meshlets[], glyphs[]) happen only in the
    // leader; the other threads consume the resulting per-vertex data through
    // groupshared memory after the barrier below.
    uint meshletIndex = pc.meshlet_base + gid;

    if (gtid == 0)
    {
        bool inRange = gid < pc.meshlet_count;
        GlyphMeshlet meshlet = inRange ? meshlets[meshletIndex] : (GlyphMeshlet)0;
        GlyphInstance glyph = inRange ? glyphs[meshlet.glyph_index] : (GlyphInstance)0;

        float2 clipped[kMeshOutputVertices];
        uint clippedCount = 0;
        uint cullReason = kMeshletCullNone;
        bool emit = planMeshletEmission(inRange, glyph, meshlet, clipped, clippedCount, cullReason);

        s_vertexCount = emit ? clippedCount : 0u;
        s_primitiveCount = emit ? clippedCount - 2u : 0u;
        for (uint i = 0; i < kMeshOutputVertices; i++)
            s_clipVertices[i] = i < clippedCount ? clipped[i] : float2(0.0, 0.0);
        s_emit = emit ? 1u : 0u;

#if HEAVY_SLUG_SHADER_STATS
        addMeshletStat(shaderStats, emit, cullReason);
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
