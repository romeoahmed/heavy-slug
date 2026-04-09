// shaders/slug_task.slang
// Task (amplification) shader: frustum cull glyphs and dispatch mesh workgroups.
// Workgroup size: 32 threads, each handles one glyph.

import pga;
import slug_common;

// --- Resource bindings ---

[[vk::binding(1, 0)]]
StructuredBuffer<GlyphCommand> commands;

[[vk::push_constant]]
PushConstants pc;

// Workgroup size constant — must match [numthreads] attribute and glyphIndices array.
static const uint kGroupSize = 32;

// --- Payload to mesh shader ---

struct TaskPayload
{
    uint glyphIndices[kGroupSize];
};

groupshared uint s_survivorCount;
groupshared TaskPayload s_payload;

// XY frustum test: check if a clip-space AABB is at least partially visible.
// Assumes orthographic projection (w = 1 for all vertices).
// Do not use with perspective projection (negative w possible behind near plane).
bool isVisible(float4 c0, float4 c1, float4 c2, float4 c3)
{
    // Divide by w to get NDC. For ortho, w=1 so this is a no-op.
    // Z clip not checked: all glyphs rendered at z=0 (near plane of ortho frustum).
    float2 ndc0 = c0.xy / c0.w;
    float2 ndc1 = c1.xy / c1.w;
    float2 ndc2 = c2.xy / c2.w;
    float2 ndc3 = c3.xy / c3.w;

    float2 ndcMin = min(min(ndc0, ndc1), min(ndc2, ndc3));
    float2 ndcMax = max(max(ndc0, ndc1), max(ndc2, ndc3));

    // Reject if entirely outside the [-1, 1] NDC range.
    if (ndcMax.x < -1.0 || ndcMin.x > 1.0) return false;
    if (ndcMax.y < -1.0 || ndcMin.y > 1.0) return false;

    return true;
}

[shader("amplification")]
[numthreads(kGroupSize, 1, 1)]
void taskMain(uint gtid : SV_GroupThreadID, uint gid : SV_GroupID)
{
    if (gtid == 0)
        s_survivorCount = 0;
    GroupMemoryBarrierWithGroupSync();

    uint localIndex = gid * kGroupSize + gtid;
    uint glyphIndex = pc.glyph_base + localIndex;
    bool alive = false;

    if (localIndex < pc.glyph_count)
    {
        GlyphCommand cmd = commands[glyphIndex];
        Motor motor = { cmd.motor };

        // Transform the 4 em-box corners to clip space.
        float2 emMin = float2(cmd.em_x_min, cmd.em_y_min);
        float2 emMax = float2(cmd.em_x_max, cmd.em_y_max);

        float4 c0 = mul(pc.proj, float4(motor.apply(emMin), 0, 1));
        float4 c1 = mul(pc.proj, float4(motor.apply(float2(emMax.x, emMin.y)), 0, 1));
        float4 c2 = mul(pc.proj, float4(motor.apply(emMax), 0, 1));
        float4 c3 = mul(pc.proj, float4(motor.apply(float2(emMin.x, emMax.y)), 0, 1));

        alive = isVisible(c0, c1, c2, c3);
    }

    // Compact surviving glyphs into payload.
    if (alive)
    {
        uint idx;
        InterlockedAdd(s_survivorCount, 1, idx);
        s_payload.glyphIndices[idx] = glyphIndex;
    }

    GroupMemoryBarrierWithGroupSync();

    // Dispatch one mesh workgroup per surviving glyph.
    if (gtid == 0)
    {
        DispatchMesh(s_survivorCount, 1, 1, s_payload);
    }
}
