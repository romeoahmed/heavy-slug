// GPU ABI shared by all heavy-slug shader stages.
// CPU structs are generated from slangc reflection of these definitions.

struct GlyphCommand
{
    float4 motor;
    float4 color;
    float  em_x_min;
    float  em_y_min;
    float  em_x_max;
    float  em_y_max;
    uint   glyph_ref;
    uint   flags;
    uint2  _pad;
};

struct PushConstants
{
    float4x4 proj;
    float2   viewport_dim;
    uint     glyph_count;
    uint     glyph_base;
};

static const uint kTaskGroupSize = 32;
static const uint kMeshThreadCount = 32;
static const uint kMaxSubdivisionsPerGlyph = 16;
static const uint kTaskMaxMeshlets = kTaskGroupSize * kMaxSubdivisionsPerGlyph;
static const uint kMeshOutputVertices = 4;
static const uint kMeshOutputPrimitives = 2;

struct TaskPayload
{
    uint glyphIndices[kTaskMaxMeshlets];
    uint sliceInfos[kTaskMaxMeshlets];
};
