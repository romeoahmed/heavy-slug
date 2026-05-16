// Task shader: frustum-cull glyphs and compact visible indices for mesh workgroups.

import pga;
import abi;
import resources;

struct TaskPayload
{
    uint glyphIndices[kTaskGroupSize];
    float motorScales[kTaskGroupSize];   // precomputed motor scale (dot product of motor rotor)
    float2 emPerPixels[kTaskGroupSize];  // precomputed em-per-pixel for dilation
};

groupshared TaskPayload s_payload;
#if HEAVY_SLUG_METAL
groupshared uint s_survivorCount;
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

[shader("amplification")]
[numthreads(kTaskGroupSize, 1, 1)]
void taskMain(uint gtid : SV_GroupThreadID, uint gid : SV_GroupID)
{
    uint localIndex = gid * kTaskGroupSize + gtid;
    uint glyphIndex = pc.glyph_base + localIndex;
    bool alive = false;

    GlyphCommand cmd;

    if (localIndex < pc.glyph_count)
    {
        cmd = commands[glyphIndex];
        Motor motor = { cmd.motor };

        float2 emMin = float2(cmd.em_x_min, cmd.em_y_min);
        float2 emMax = float2(cmd.em_x_max, cmd.em_y_max);

        float4 c0 = mul(pc.proj, float4(motor.apply(emMin), 0, 1));
        float4 c1 = mul(pc.proj, float4(motor.apply(float2(emMax.x, emMin.y)), 0, 1));
        float4 c2 = mul(pc.proj, float4(motor.apply(emMax), 0, 1));
        float4 c3 = mul(pc.proj, float4(motor.apply(float2(emMin.x, emMax.y)), 0, 1));

        alive = isVisible(c0, c1, c2, c3);
    }

#if HEAVY_SLUG_METAL
    // Slang's Metal target lacks wave ballot intrinsics for object functions.
    // Use one taskgroup-local atomic counter instead.
    if (gtid == 0) s_survivorCount = 0;
    GroupMemoryBarrierWithGroupSync();

    uint survivorCount = 0;
    uint localIdx = 0;
    if (alive)
    {
        InterlockedAdd(s_survivorCount, 1, localIdx);
        s_payload.glyphIndices[localIdx] = glyphIndex;

        float ms = cmd.motor.x * cmd.motor.x + cmd.motor.y * cmd.motor.y;
        float2 halfDim = pc.viewport_dim * 0.5;
        float2 ppe = float2(
            length(float2(pc.proj[0][0] * halfDim.x, pc.proj[1][0] * halfDim.y)),
            length(float2(pc.proj[0][1] * halfDim.x, pc.proj[1][1] * halfDim.y))
        );
        s_payload.motorScales[localIdx] = ms;
        s_payload.emPerPixels[localIdx] = 1.0 / (ppe * ms);
    }

    GroupMemoryBarrierWithGroupSync();
    survivorCount = s_survivorCount;
#else
    // Wave ballot compaction avoids shared-memory atomics.
    uint survivorCount = WaveActiveCountBits(alive);
    uint localIdx = WavePrefixCountBits(alive);

    if (alive)
    {
        s_payload.glyphIndices[localIdx] = glyphIndex;

        // Avoid two sqrt operations per mesh workgroup.
        float ms = cmd.motor.x * cmd.motor.x + cmd.motor.y * cmd.motor.y;
        float2 halfDim = pc.viewport_dim * 0.5;
        float2 ppe = float2(
            length(float2(pc.proj[0][0] * halfDim.x, pc.proj[1][0] * halfDim.y)),
            length(float2(pc.proj[0][1] * halfDim.x, pc.proj[1][1] * halfDim.y))
        );
        s_payload.motorScales[localIdx] = ms;
        s_payload.emPerPixels[localIdx] = 1.0 / (ppe * ms);
    }

    GroupMemoryBarrierWithGroupSync();
#endif

    if (gtid == 0)
    {
        DispatchMesh(survivorCount, 1, 1, s_payload);
    }
}
