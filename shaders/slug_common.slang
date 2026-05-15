// shaders/slug_common.slang
// Shared types and blob reader for heavy-slug shaders.
// CPU structs in descriptors.zig are generated from this file's reflection data.

import pga;

// --- Structs matching Zig side (extern, tightly packed) ---

struct GlyphCommand  // 64 bytes — matches descriptors.zig
{
    float4 motor;           // offset  0: PGA Motor [s, e12, e01, e02]
    float4 color;           // offset 16: RGBA
    float  em_x_min;        // offset 32
    float  em_y_min;        // offset 36
    float  em_x_max;        // offset 40
    float  em_y_max;        // offset 44
    uint   descriptor_index; // offset 48: index into glyphBlobs[]
    uint   flags;           // offset 52: bit 0 = even-odd fill
    uint2  _pad;            // offset 56: align to 64B
};

struct PushConstants  // 80 bytes — matches descriptors.zig
{
    float4x4 proj;          // offset  0: column-major (Zig layout; slangc -matrix-layout-column-major)
    float2   viewport_dim;  // offset 64: viewport width, height in pixels
    uint     glyph_count;   // offset 72: number of glyphs this frame
    uint     glyph_base;    // offset 76: first glyph index in the command buffer
};

// --- Coverage V3 blob constants ---

static const float UNITS_PER_EM = 4.0;
static const float INV_UNITS_PER_EM = 1.0 / UNITS_PER_EM;  // 0.25 (reciprocal for fast multiply)
static const uint  HEADER_LEN = 4;       // texels 0-3 are header
static const uint  BLOB_VERSION = 3;
static const uint  CURVE_TEXEL_LEN = 3;
static const uint  CURVE_IDS_PER_TEXEL = 4;

// --- Task/mesh workgroup size ---
// Both slug_task.slang and slug_mesh.slang import this constant to keep
// TaskPayload array sizes in sync. Change only here.
static const uint kTaskGroupSize = 32;

// --- Blob texel reader ---
// Each texel is 8 bytes: 4x int16 packed as 2x uint32.
// Storage buffer contains raw bytes; we unpack int16 manually.

struct BlobReader
{
    ByteAddressBuffer buf;
    uint base;

    // Read one RGBA16I texel at the given index.
    // Returns 4 int16 values sign-extended to int32.
    int4 readTexel(uint index)
    {
        uint2 raw = buf.Load2(base + index * 8);
        return int4(
            bitfieldExtract(int(raw.x),  0, 16),
            bitfieldExtract(int(raw.x), 16, 16),
            bitfieldExtract(int(raw.y),  0, 16),
            bitfieldExtract(int(raw.y), 16, 16)
        );
    }

    // Read texel and dequantize to float4 (multiply by INV_UNITS_PER_EM for performance).
    float4 readTexelF(uint index)
    {
        return float4(readTexel(index)) * INV_UNITS_PER_EM;
    }

    // Read Coverage V3 blob header: curves plus optional h-band candidate index.
    void readHeader(
        out float4 bounds,
        out uint curveCount,
        out float fillSign,
        out uint curveBase,
        out int bandMin,
        out uint bandCount,
        out float bandHeight,
        out uint bandBase,
        out uint idBase,
        out uint idCount)
    {
        int4 t0 = readTexel(0);  // (min_x, min_y, max_x, max_y)
        int4 t1 = readTexel(1);  // (curve_count, version, fill_sign, curve_base)
        int4 t2 = readTexel(2);  // (band_min, band_count, band_height, band_base)
        int4 t3 = readTexel(3);  // (id_base, id_count, unused, unused)
        bounds = float4(t0) * INV_UNITS_PER_EM;
        curveCount = uint(max(t1.x, 0));
        fillSign = t1.z < 0 ? -1.0 : 1.0;
        curveBase = uint(max(t1.w, 0));
        bandMin = t2.x;
        bandCount = uint(max(t2.y, 0));
        bandHeight = max(float(t2.z) * INV_UNITS_PER_EM, INV_UNITS_PER_EM);
        bandBase = uint(max(t2.w, 0));
        idBase = uint(max(t3.x, 0));
        idCount = uint(max(t3.y, 0));
    }

    void readCurve(uint curveBase, uint curveIndex, out float2 p0, out float2 p1,
                   out float2 p2, out float2 p3, out float4 bbox)
    {
        uint off = curveBase + curveIndex * CURVE_TEXEL_LEN;
        float4 a = readTexelF(off);
        float4 b = readTexelF(off + 1);
        bbox = readTexelF(off + 2); // min_x, max_x, min_y, max_y
        p0 = a.xy;
        p1 = a.zw;
        p2 = b.xy;
        p3 = b.zw;
    }

    void readBand(uint bandBase, uint bandIndex, out uint idStart, out uint bandIdCount)
    {
        int4 band = readTexel(bandBase + bandIndex);
        idStart = uint(max(band.x, 0));
        bandIdCount = uint(max(band.y, 0));
    }

    uint readCurveId(uint idBase, uint idIndex)
    {
        int4 ids = readTexel(idBase + idIndex / CURVE_IDS_PER_TEXEL);
        uint lane = idIndex % CURVE_IDS_PER_TEXEL;
        int id = lane == 0 ? ids.x : (lane == 1 ? ids.y : (lane == 2 ? ids.z : ids.w));
        return uint(max(id, 0));
    }
};

// --- Descriptor bindings ---
// These are declared in each shader entry point file, not here,
// because Slang modules cannot declare global resource bindings.
// Each shader file imports this module and declares:
//
//   [[vk::binding(0, 0)]] ByteAddressBuffer glyphBlobs[];
//   [[vk::binding(1, 0)]] StructuredBuffer<GlyphCommand> commands;
//   [[vk::push_constant]] PushConstants pc;
