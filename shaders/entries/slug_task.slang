// Task shader: frustum-cull glyphs and compact visible h-band meshlets.

import pga;
import abi;
import resources;

static const float kTargetMeshletExtentPixels = 96.0;

struct TaskPayload
{
    uint glyphIndices[kTaskMaxMeshlets];
    uint sliceInfos[kTaskMaxMeshlets];
};

#if HEAVY_SLUG_SHADER_STATS
static const uint kShaderStatTaskWorkgroups = 6;
static const uint kShaderStatTaskGlyphsTested = 7;
static const uint kShaderStatTaskGlyphsVisible = 8;
static const uint kShaderStatTaskGlyphsCulled = 9;
#endif

groupshared TaskPayload s_payload;
#if HEAVY_SLUG_METAL
groupshared uint s_survivorCount;
groupshared uint s_meshletCount;
#endif

#if HEAVY_SLUG_SHADER_STATS
void addShaderStat(uint index, uint value)
{
    InterlockedAdd(shaderStats[index], value);
}
#endif

// Divide by w so the cull works for both orthographic and perspective projections.
bool isVisible(float4 c0, float4 c1, float4 c2, float4 c3)
{
    float2 ndc0 = c0.xy / c0.w;
    float2 ndc1 = c1.xy / c1.w;
    float2 ndc2 = c2.xy / c2.w;
    float2 ndc3 = c3.xy / c3.w;

    float2 ndcMin = min(min(ndc0, ndc1), min(ndc2, ndc3));
    float2 ndcMax = max(max(ndc0, ndc1), max(ndc2, ndc3));

    if (ndcMax.x < -1.0 || ndcMin.x > 1.0) return false;
    if (ndcMax.y < -1.0 || ndcMin.y > 1.0) return false;

    return true;
}

uint packSliceInfo(uint sliceIndex, uint sliceCount)
{
    return (sliceCount << 16) | sliceIndex;
}

float2 visiblePixelExtent(float4 c0, float4 c1, float4 c2, float4 c3)
{
    float2 ndc0 = c0.xy / c0.w;
    float2 ndc1 = c1.xy / c1.w;
    float2 ndc2 = c2.xy / c2.w;
    float2 ndc3 = c3.xy / c3.w;

    float2 ndcMin = max(min(min(ndc0, ndc1), min(ndc2, ndc3)), float2(-1.0, -1.0));
    float2 ndcMax = min(max(max(ndc0, ndc1), max(ndc2, ndc3)), float2(1.0, 1.0));
    return max(ndcMax - ndcMin, float2(0.0, 0.0)) * (pc.viewport_dim * 0.5);
}

uint subdivisionCount(float4 c0, float4 c1, float4 c2, float4 c3)
{
    float2 extent = visiblePixelExtent(c0, c1, c2, c3);
    float maxExtent = max(extent.x, extent.y);
    uint count = uint(ceil(maxExtent / kTargetMeshletExtentPixels));
    if (maxExtent >= 16.0)
        count = max(count, 4u);
    return clamp(count, 1u, kMaxSubdivisionsPerGlyph);
}

[shader("amplification")]
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

    GlyphCommand cmd;

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
        cmd = commands[glyphIndex];
        Motor motor = { cmd.motor };
        MotorAffine affine = motor.affine();

        float2 emMin = float2(cmd.em_x_min, cmd.em_y_min);
        float2 emMax = float2(cmd.em_x_max, cmd.em_y_max);

        float4 c0 = mul(pc.proj, float4(affine.apply(emMin), 0, 1));
        float4 c1 = mul(pc.proj, float4(affine.apply(float2(emMax.x, emMin.y)), 0, 1));
        float4 c2 = mul(pc.proj, float4(affine.apply(emMax), 0, 1));
        float4 c3 = mul(pc.proj, float4(affine.apply(float2(emMin.x, emMax.y)), 0, 1));

        alive = isVisible(c0, c1, c2, c3);
        slices = alive ? subdivisionCount(c0, c1, c2, c3) : 0;
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
        addShaderStat(kShaderStatTaskWorkgroups, 1);
        addShaderStat(kShaderStatTaskGlyphsTested, groupSize);
        addShaderStat(kShaderStatTaskGlyphsVisible, survivorCount);
        addShaderStat(kShaderStatTaskGlyphsCulled, groupSize - survivorCount);
#endif
        DispatchMesh(meshletCount, 1, 1, s_payload);
    }
}
