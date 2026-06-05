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
    public int2   glyph_anchor_q;
    public float2 screen_anchor_px;
    public float4 screen_from_local_2x2;
    public float4 local_from_screen_2x2;
};

public struct GlyphMeshlet
{
    public uint   glyph_index;
    public uint   _pad0;
    public int2   rect_min_q;
    public int2   rect_max_q;
    public int2   mesh_anchor_q;
    public float2 screen_anchor_px;
};

public struct FrameParams
{
    public float2   viewport_size;
    public float4   screen_from_framebuffer_2x2;
    public float2   screen_from_framebuffer_offset;
    public uint     meshlet_count;
    public uint     meshlet_base;
};

public static const uint kMeshThreadCount = 32;
public static const uint kMeshOutputVertices = 8;
public static const uint kMeshOutputPrimitives = 6;
public static const uint kMaxMergedCandidateBands = 8;
