#language slang 2026
module task;

// Task shader: frustum-cull glyphs and compact visible h-band meshlets.

import abi;
import resources;
import screen_mapping;
import stats;

static const float kTargetMeshletExtentPixels = 96.0;

groupshared TaskPayload s_payload;
#if HEAVY_SLUG_METAL
groupshared uint s_survivorCount;
groupshared uint s_meshletCount;
#endif

uint packSliceInfo(uint sliceIndex, uint sliceCount)
{
    return (sliceCount << 16) | sliceIndex;
}

uint subdivisionCount(float2 visibleExtent)
{
    float maxExtent = max(visibleExtent.x, visibleExtent.y);
    uint count = uint(ceil(maxExtent / kTargetMeshletExtentPixels));
    if (maxExtent >= 16.0)
        count = max(count, 4u);
    return clamp(count, 1u, kMaxSubdivisionsPerGlyph);
}

[shader("task")]
[numthreads(kTaskGroupSize, 1, 1)]
void taskMain(uint gtid : SV_GroupThreadID, uint gid : SV_GroupID)
{
    uint groupBase = gid * kTaskGroupSize;
    uint groupSize = groupBase < pc.glyph_count
        ? min(kTaskGroupSize, pc.glyph_count - groupBase)
        : 0;
    uint localIndex = groupBase + gtid;
    uint glyphIndex = pc.glyph_base + localIndex;
    bool alive = false;
    uint slices = 0;

    GlyphInstance glyph;

    if (gtid == 0)
    {
#if HEAVY_SLUG_METAL
        s_survivorCount = 0;
        s_meshletCount = 0;
#endif
    }
    GroupMemoryBarrierWithGroupSync();

    if (localIndex < pc.glyph_count)
    {
        glyph = glyphs[glyphIndex];

        float2 visibleExtent = visiblePixelExtent(glyph, pc.viewport_size);

        alive = max(visibleExtent.x, visibleExtent.y) > 0.0;
        slices = alive ? subdivisionCount(visibleExtent) : 0;
    }

#if HEAVY_SLUG_METAL
    // Slang's Metal target lacks wave ballot intrinsics for object functions.
    // Use taskgroup-local atomics for variable-rate meshlet allocation.
    uint survivorCount = 0;
    uint meshletBase = 0;
    if (alive)
    {
        InterlockedAdd(s_survivorCount, 1);
        InterlockedAdd(s_meshletCount, slices, meshletBase);
        for (uint sliceIndex = 0; sliceIndex < slices; sliceIndex++)
        {
            uint meshletIndex = meshletBase + sliceIndex;
            s_payload.glyphIndices[meshletIndex] = glyphIndex;
            s_payload.sliceInfos[meshletIndex] = packSliceInfo(sliceIndex, slices);
        }
    }

    GroupMemoryBarrierWithGroupSync();
    survivorCount = s_survivorCount;
    uint meshletCount = s_meshletCount;
#else
    // Wave prefix sums compact a variable number of glyph meshlets without shared atomics.
    uint survivorCount = WaveActiveCountBits(alive);
    uint meshletCount = WaveActiveSum(slices);
    uint meshletBase = WavePrefixSum(slices);

    if (alive)
    {
        for (uint sliceIndex = 0; sliceIndex < slices; sliceIndex++)
        {
            uint meshletIndex = meshletBase + sliceIndex;
            s_payload.glyphIndices[meshletIndex] = glyphIndex;
            s_payload.sliceInfos[meshletIndex] = packSliceInfo(sliceIndex, slices);
        }
    }

    GroupMemoryBarrierWithGroupSync();
#endif

    if (gtid == 0)
    {
#if HEAVY_SLUG_SHADER_STATS
        addShaderStat(shaderStats, kShaderStatTaskWorkgroups, 1);
        addShaderStat(shaderStats, kShaderStatTaskGlyphsTested, groupSize);
        addShaderStat(shaderStats, kShaderStatTaskGlyphsVisible, survivorCount);
        addShaderStat(shaderStats, kShaderStatTaskGlyphsCulled, groupSize - survivorCount);
#endif
        DispatchMesh(meshletCount, 1, 1, s_payload);
    }
}
