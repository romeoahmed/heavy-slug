#language slang 2026
module abi;

// GPU ABI shared by all heavy-slug shader stages.
// CPU structs are generated from slangc reflection of these definitions.

public struct GlyphInstance
{
    public float4 motor;
    public float4 color;
    public float  em_x_min;
    public float  em_y_min;
    public float  em_x_max;
    public float  em_y_max;
    public uint   blob_ref;
    public uint   flags;
    public uint2  _pad;
};

public struct FrameParams
{
    public float4x4 projection;
    public float2   viewport_size;
    public uint     glyph_count;
    public uint     glyph_base;
};

public static const uint kTaskGroupSize = 32;
public static const uint kMeshThreadCount = 32;
public static const uint kMaxSubdivisionsPerGlyph = 16;
public static const uint kTaskMaxMeshlets = kTaskGroupSize * kMaxSubdivisionsPerGlyph;
public static const uint kMeshOutputVertices = 4;
public static const uint kMeshOutputPrimitives = 2;

public struct TaskPayload
{
    public uint glyphIndices[kTaskMaxMeshlets];
    public uint sliceInfos[kTaskMaxMeshlets];
};
