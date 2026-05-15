// Coverage V3 blob decoding.

static const float UNITS_PER_EM = 4.0;
static const float INV_UNITS_PER_EM = 1.0 / UNITS_PER_EM;
static const uint  HEADER_LEN = 4;
static const uint  BLOB_VERSION = 3;
static const uint  CURVE_TEXEL_LEN = 3;
static const uint  CURVE_IDS_PER_TEXEL = 4;

struct BlobReader
{
    ByteAddressBuffer buf;
    uint base;

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

    float4 readTexelF(uint index)
    {
        return float4(readTexel(index)) * INV_UNITS_PER_EM;
    }

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
        int4 t0 = readTexel(0);
        int4 t1 = readTexel(1);
        int4 t2 = readTexel(2);
        int4 t3 = readTexel(3);
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
        bbox = readTexelF(off + 2);
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
