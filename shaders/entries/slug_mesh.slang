// Mesh shader: emit one dilated quad per visible glyph.

import pga;
import abi;
import resources;

struct TaskPayload
{
    uint glyphIndices[kTaskGroupSize];
    float2 emPerPixels[kTaskGroupSize];  // precomputed em-per-pixel for dilation
};

struct VertexOutput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
#if HEAVY_SLUG_METAL
    float2 texcoord    : TEXCOORD;
    nointerpolation uint glyphRef : TEXCOORD_1;
    nointerpolation uint flags           : TEXCOORD_2;
#else
    float2 texcoord    : TEXCOORD0;
    nointerpolation uint glyphRef : TEXCOORD1;
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

#if HEAVY_SLUG_SHADER_STATS
static const uint kShaderStatMeshWorkgroups = 10;

void addShaderStat(uint index, uint value)
{
    InterlockedAdd(shaderStats[index], value);
}
#endif

[shader("mesh")]
[numthreads(4, 1, 1)]
[outputtopology("triangle")]
void meshMain(
    uint gtid : SV_GroupThreadID,
    uint gid  : SV_GroupID,
    in payload TaskPayload taskPayload,
    OutputVertices<VertexOutput, 4> verts,
    OutputIndices<uint3, 2> tris)
{
    SetMeshOutputCounts(4, 2);
#if HEAVY_SLUG_SHADER_STATS
    if (gtid == 0)
        addShaderStat(kShaderStatMeshWorkgroups, 1);
#endif

    uint glyphIndex = taskPayload.glyphIndices[gid];
    GlyphCommand cmd = commands[glyphIndex];
    Motor motor = { cmd.motor };

    float2 emMin = float2(cmd.em_x_min, cmd.em_y_min);
    float2 emMax = float2(cmd.em_x_max, cmd.em_y_max);

    // Half-pixel dilation prevents clipping fragments at analytic edges.
    float2 emPerPixel = taskPayload.emPerPixels[gid];
    float2 dilate = emPerPixel * 0.5;
    float2 dilMin = emMin - dilate;
    float2 dilMax = emMax + dilate;
    float2 dilSize = dilMax - dilMin;

    float2 corner = kCornerOffsets[gtid];
    float2 emPos = dilMin + corner * dilSize;

    float2 worldPos = motor.apply(emPos);
    float4 clipPos = mul(pc.proj, float4(worldPos, 0.0, 1.0));

    // Sample coordinates must match the dilated quad used for rasterization.
    float2 texcoord = emPos;

    VertexOutput v;
    v.position = clipPos;
    v.color = cmd.color;
    v.texcoord = texcoord;
    v.glyphRef = cmd.glyph_ref;
    v.flags = cmd.flags;
    verts[gtid] = v;

    if (gtid < 2)
    {
        tris[gtid] = kTriIndices[gtid];
    }
}
