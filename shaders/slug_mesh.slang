// shaders/slug_mesh.slang
// Mesh shader: emit a dilated screen-space quad per glyph.
// One workgroup = one glyph = 4 vertices + 2 triangles.

import pga;
import slug_common;

// --- Resource bindings ---

[[vk::binding(1, 0)]]
StructuredBuffer<GlyphCommand> commands;

[[vk::push_constant]]
PushConstants pc;

// --- Payload from task shader ---

struct TaskPayload
{
    uint glyphIndices[32];
};

// --- Mesh output ---

struct VertexOutput
{
    float4 position    : SV_Position;
    float4 color       : COLOR;
    float2 texcoord    : TEXCOORD0;
    nointerpolation uint descriptorIndex : TEXCOORD1;
    nointerpolation uint flags           : TEXCOORD2;
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

    uint glyphIndex = taskPayload.glyphIndices[gid];
    GlyphCommand cmd = commands[glyphIndex];
    Motor motor = { cmd.motor };

    // Em-space bounding box.
    float2 emMin = float2(cmd.em_x_min, cmd.em_y_min);
    float2 emMax = float2(cmd.em_x_max, cmd.em_y_max);
    float2 emSize = emMax - emMin;

    // Dilate by half a pixel in em-space to avoid clipping edge fragments.
    // Compute em-per-pixel from the projection + motor scale.
    // Use column vector lengths so rotated projections (via Motor.toMat) work;
    // for a diagonal projection this reduces to abs(proj[i][i]) * viewport/2.
    float motorScale = cmd.motor.x * cmd.motor.x + cmd.motor.y * cmd.motor.y;
    float2 halfDim = pc.viewport_dim * 0.5;
    float2 pixPerEm = float2(
        length(float2(pc.proj[0][0] * halfDim.x, pc.proj[1][0] * halfDim.y)),
        length(float2(pc.proj[0][1] * halfDim.x, pc.proj[1][1] * halfDim.y))
    );
    float2 emPerPixel = 1.0 / (pixPerEm * motorScale);
    float2 dilate = emPerPixel * 0.5;
    float2 dilMin = emMin - dilate;
    float2 dilMax = emMax + dilate;
    float2 dilSize = dilMax - dilMin;

    // Each thread handles one vertex.
    float2 corner = kCornerOffsets[gtid];
    float2 emPos = dilMin + corner * dilSize;

    // Transform through motor → clip space.
    float2 worldPos = motor.apply(emPos);
    float4 clipPos = mul(pc.proj, float4(worldPos, 0.0, 1.0));

    // Em-space texture coordinate (undilated range for accurate sampling).
    float2 texcoord = emMin + corner * emSize;

    VertexOutput v;
    v.position = clipPos;
    v.color = cmd.color;
    v.texcoord = texcoord;
    v.descriptorIndex = cmd.descriptor_index;
    v.flags = cmd.flags;
    verts[gtid] = v;

    // First two threads emit triangle indices.
    if (gtid < 2)
    {
        tris[gtid] = kTriIndices[gtid];
    }
}
