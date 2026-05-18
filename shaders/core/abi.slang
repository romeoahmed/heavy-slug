#language slang 2026
module abi;

// GPU ABI shared by all heavy-slug shader stages.
// CPU structs are generated from slangc reflection of these definitions.

public struct GlyphInstance
{
    public float4 color;
    public uint   blob_ref;
    public uint   flags;
    public uint   precision_bits;
    public uint   chart_flags;
    public int4   local_bounds_q;
    public int2   glyph_anchor_q;
    public float2 screen_anchor_px;
    public float4 screen_from_local_2x2;
    public float4 local_from_screen_2x2;
};

public struct FrameParams
{
    public float2   viewport_size;
    public uint     glyph_count;
    public uint     glyph_base;
    public uint     diagnostic_flags;
};

public static const uint kTaskGroupSize = 32;
public static const uint kMeshThreadCount = 32;
public static const uint kMaxSubdivisionsPerGlyph = 16;
public static const uint kTaskMaxMeshlets = kTaskGroupSize * kMaxSubdivisionsPerGlyph;
public static const uint kMeshOutputVertices = 8;
public static const uint kMeshOutputPrimitives = 6;

public struct TaskPayload
{
    public uint glyphIndices[kTaskMaxMeshlets];
    public uint sliceInfos[kTaskMaxMeshlets];
};
