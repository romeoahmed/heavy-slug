// shaders/slug_common.slang
// Shared types and blob reader for heavy-slug shaders.
// Mirrors src/gpu/descriptors.zig struct layouts exactly.

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
    float4x4 proj;          // offset  0: column-major projection matrix
    float2   viewport_dim;  // offset 64: viewport width, height in pixels
    uint     glyph_count;   // offset 72: number of glyphs this frame
    uint     _pad;          // offset 76: align to 80B
};

// --- HarfBuzz blob constants ---

static const float UNITS_PER_EM = 4.0;  // HB_GPU_UNITS_PER_EM
static const uint  HEADER_LEN = 2;       // texels 0-1 are header

// --- Blob texel reader ---
// Each texel is 8 bytes: 4x int16 packed as 2x uint32.
// Storage buffer contains raw bytes; we unpack int16 manually.

struct BlobReader
{
    ByteAddressBuffer buf;

    // Read one RGBA16I texel at the given index.
    // Returns 4 int16 values sign-extended to int32.
    int4 readTexel(uint index)
    {
        uint2 raw = buf.Load2(index * 8);
        int r = int(raw.x << 16) >> 16;
        int g = int(raw.x) >> 16;
        int b = int(raw.y << 16) >> 16;
        int a = int(raw.y) >> 16;
        return int4(r, g, b, a);
    }

    // Read texel and dequantize to float4 (divide by UNITS_PER_EM).
    float4 readTexelF(uint index)
    {
        return float4(readTexel(index)) / UNITS_PER_EM;
    }

    // Decode a biased offset from int16: stored as (offset - 32768).
    uint decodeOffset(int encoded)
    {
        return uint(encoded) + 32768u;
    }

    // Read blob header: glyph bounds + band counts.
    void readHeader(out float4 bounds, out int2 bandCounts)
    {
        int4 t0 = readTexel(0);  // (min_x, min_y, max_x, max_y)
        int4 t1 = readTexel(1);  // (num_hbands, num_vbands, x_scale, y_scale)
        bounds = float4(t0) / UNITS_PER_EM;
        bandCounts = int2(t1.x, t1.y);
        // t1.b (x_scale) and t1.a (y_scale) are font design units; not needed by band lookup.
    }

    // Read a band header at the given texel index.
    // descOffset: start of curve index list sorted by max coordinate descending
    //             (use for forward iteration with early-exit when max < sample - 0.5px).
    // ascOffset:  start of curve index list sorted by min coordinate ascending
    //             (use for reverse iteration with early-exit when min > sample + 0.5px).
    // split:      coordinate separating which list has fewer curves for this sample.
    void readBandHeader(uint texelIndex, out uint curveCount, out uint descOffset,
                        out uint ascOffset, out float split)
    {
        int4 t = readTexel(texelIndex);
        curveCount = uint(t.x);
        descOffset = decodeOffset(t.y);
        ascOffset  = decodeOffset(t.z);
        split      = float(t.w) / UNITS_PER_EM;
    }

    // Read a curve index entry: returns decoded offset to curve data.
    uint readCurveIndex(uint texelIndex)
    {
        int4 t = readTexel(texelIndex);
        // t.gba are always zero per encoder spec; only .r contains the offset.
        return decodeOffset(t.x);
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
