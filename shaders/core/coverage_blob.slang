#language slang 2026
module coverage_blob;

// CoverageBlob v3 decoding. The blob is a 32-bit word ABI; all fixed-point
// coordinates are decoded relative to the current meshlet chart before they
// become f32.

static const uint BLOB_MAGIC_VERSION = 0x33425348u; // "HSB3", little-endian words.

static const uint HEADER_WORD_LEN = 17;
static const uint CURVE_WORD_LEN = 12;
static const uint BAND_WORD_LEN = 2;
static const int  EXACT_F32_INT_RADIUS = 16777216;
static const int  I32_MAX_VALUE = 2147483647;
static const int  I32_MIN_VALUE = -2147483647 - 1;

static const uint HEADER_MAGIC_VERSION = 0;
static const uint HEADER_FRACTION_BITS = 1;
static const uint HEADER_FLAGS = 2;
static const uint HEADER_FILL_SIGN = 3;
static const uint HEADER_CURVE_COUNT = 4;
static const uint HEADER_BAND_MIN = 5;
static const uint HEADER_BAND_COUNT = 6;
static const uint HEADER_BAND_HEIGHT_Q = 7;
static const uint HEADER_ID_COUNT = 8;
static const uint HEADER_WORD_COUNT = 9;
static const uint HEADER_BOUNDS_MIN_X_Q = 10;
static const uint HEADER_BOUNDS_MIN_Y_Q = 11;
static const uint HEADER_BOUNDS_MAX_X_Q = 12;
static const uint HEADER_BOUNDS_MAX_Y_Q = 13;
static const uint HEADER_CURVE_BASE_WORDS = 14;
static const uint HEADER_BAND_BASE_WORDS = 15;
static const uint HEADER_ID_BASE_WORDS = 16;

static const uint CURVE_P0_X_Q = 0;
static const uint CURVE_P0_Y_Q = 1;
static const uint CURVE_P1_X_Q = 2;
static const uint CURVE_P1_Y_Q = 3;
static const uint CURVE_P2_X_Q = 4;
static const uint CURVE_P2_Y_Q = 5;
static const uint CURVE_P3_X_Q = 6;
static const uint CURVE_P3_Y_Q = 7;
static const uint CURVE_BBOX_MIN_X_Q = 8;
static const uint CURVE_BBOX_MIN_Y_Q = 9;
static const uint CURVE_BBOX_MAX_X_Q = 10;
static const uint CURVE_BBOX_MAX_Y_Q = 11;

public struct BlobHeader
{
    public uint magicVersion;
    public uint fractionBits;
    public uint flags;
    public float fillSign;
    public uint curveCount;
    public int bandMin;
    public uint bandCount;
    public int bandHeightQ;
    public uint idCount;
    public uint wordCount;
    public int4 boundsQ; // min_x, min_y, max_x, max_y
    public uint curveBaseWords;
    public uint bandBaseWords;
    public uint idBaseWords;

    public float invScale()
    {
        return exp2(-float(fractionBits));
    }

    public bool isSupported()
    {
        return magicVersion == BLOB_MAGIC_VERSION;
    }
};

public struct CurveQ
{
    public int2 p0;
    public int2 p1;
    public int2 p2;
    public int2 p3;
    public int4 bbox; // min_x, min_y, max_x, max_y
};

bool diffGreaterThanExactRadius(int valueQ, int anchorQ)
{
    if (valueQ <= anchorQ)
        return false;
    if (anchorQ > I32_MAX_VALUE - EXACT_F32_INT_RADIUS)
        return false;
    return valueQ > anchorQ + EXACT_F32_INT_RADIUS;
}

bool diffLessThanNegativeExactRadius(int valueQ, int anchorQ)
{
    if (valueQ >= anchorQ)
        return false;
    if (anchorQ < I32_MIN_VALUE + EXACT_F32_INT_RADIUS)
        return false;
    return valueQ < anchorQ - EXACT_F32_INT_RADIUS;
}

public bool componentFitsExactRelative(int valueQ, int anchorQ)
{
    return !diffGreaterThanExactRadius(valueQ, anchorQ) &&
           !diffLessThanNegativeExactRadius(valueQ, anchorQ);
}

public int relativeClampQ(int valueQ, int anchorQ)
{
    if (diffGreaterThanExactRadius(valueQ, anchorQ))
        return EXACT_F32_INT_RADIUS;
    if (diffLessThanNegativeExactRadius(valueQ, anchorQ))
        return -EXACT_F32_INT_RADIUS;
    return valueQ - anchorQ;
}

public int2 relativeClampQ2(int2 valueQ, int2 anchorQ)
{
    return int2(
        relativeClampQ(valueQ.x, anchorQ.x),
        relativeClampQ(valueQ.y, anchorQ.y));
}

public struct BlobReader
{
    public ByteAddressBuffer buf;
    public uint base;

    public uint byteAddress(uint word)
    {
        return base + word * 4;
    }

    public uint loadU32(uint word)
    {
        return buf.Load(byteAddress(word));
    }

    public int loadI32(uint word)
    {
        return asint(loadU32(word));
    }

    public BlobHeader readHeader()
    {
        BlobHeader h;
        h.magicVersion = loadU32(HEADER_MAGIC_VERSION);
        h.fractionBits = loadU32(HEADER_FRACTION_BITS);
        h.flags = loadU32(HEADER_FLAGS);
        h.fillSign = loadI32(HEADER_FILL_SIGN) < 0 ? -1.0 : 1.0;
        h.curveCount = loadU32(HEADER_CURVE_COUNT);
        h.bandMin = loadI32(HEADER_BAND_MIN);
        h.bandCount = loadU32(HEADER_BAND_COUNT);
        h.bandHeightQ = loadI32(HEADER_BAND_HEIGHT_Q);
        h.idCount = loadU32(HEADER_ID_COUNT);
        h.wordCount = loadU32(HEADER_WORD_COUNT);
        h.boundsQ = int4(
            loadI32(HEADER_BOUNDS_MIN_X_Q),
            loadI32(HEADER_BOUNDS_MIN_Y_Q),
            loadI32(HEADER_BOUNDS_MAX_X_Q),
            loadI32(HEADER_BOUNDS_MAX_Y_Q));
        h.curveBaseWords = loadU32(HEADER_CURVE_BASE_WORDS);
        h.bandBaseWords = loadU32(HEADER_BAND_BASE_WORDS);
        h.idBaseWords = loadU32(HEADER_ID_BASE_WORDS);
        return h;
    }

    public CurveQ readCurveQ(uint curveBaseWords, uint curveIndex)
    {
        uint off = curveBaseWords + curveIndex * CURVE_WORD_LEN;
        CurveQ c;
        c.p0 = int2(loadI32(off + CURVE_P0_X_Q), loadI32(off + CURVE_P0_Y_Q));
        c.p1 = int2(loadI32(off + CURVE_P1_X_Q), loadI32(off + CURVE_P1_Y_Q));
        c.p2 = int2(loadI32(off + CURVE_P2_X_Q), loadI32(off + CURVE_P2_Y_Q));
        c.p3 = int2(loadI32(off + CURVE_P3_X_Q), loadI32(off + CURVE_P3_Y_Q));
        c.bbox = int4(
            loadI32(off + CURVE_BBOX_MIN_X_Q),
            loadI32(off + CURVE_BBOX_MIN_Y_Q),
            loadI32(off + CURVE_BBOX_MAX_X_Q),
            loadI32(off + CURVE_BBOX_MAX_Y_Q));
        return c;
    }

    public int4 readCurveBoundsQ(uint curveBaseWords, uint curveIndex)
    {
        uint off = curveBaseWords + curveIndex * CURVE_WORD_LEN;
        return int4(
            loadI32(off + CURVE_BBOX_MIN_X_Q),
            loadI32(off + CURVE_BBOX_MIN_Y_Q),
            loadI32(off + CURVE_BBOX_MAX_X_Q),
            loadI32(off + CURVE_BBOX_MAX_Y_Q));
    }

    public float4 readCurveBoundsRelative(uint curveBaseWords, uint curveIndex, int2 anchorQ, float invScale)
    {
        int4 bbox = readCurveBoundsQ(curveBaseWords, curveIndex);
        return float4(
            relativeClampQ(bbox.x, anchorQ.x),
            relativeClampQ(bbox.y, anchorQ.y),
            relativeClampQ(bbox.z, anchorQ.x),
            relativeClampQ(bbox.w, anchorQ.y)) * invScale;
    }

    public bool curveFitsExactRelative(CurveQ c, int2 anchorQ)
    {
        return componentFitsExactRelative(c.p0.x, anchorQ.x) &&
               componentFitsExactRelative(c.p0.y, anchorQ.y) &&
               componentFitsExactRelative(c.p1.x, anchorQ.x) &&
               componentFitsExactRelative(c.p1.y, anchorQ.y) &&
               componentFitsExactRelative(c.p2.x, anchorQ.x) &&
               componentFitsExactRelative(c.p2.y, anchorQ.y) &&
               componentFitsExactRelative(c.p3.x, anchorQ.x) &&
               componentFitsExactRelative(c.p3.y, anchorQ.y) &&
               componentFitsExactRelative(c.bbox.x, anchorQ.x) &&
               componentFitsExactRelative(c.bbox.y, anchorQ.y) &&
               componentFitsExactRelative(c.bbox.z, anchorQ.x) &&
               componentFitsExactRelative(c.bbox.w, anchorQ.y);
    }

    public void curvePointsRelative(
        CurveQ c,
        int2 anchorQ,
        float invScale,
        out float2 p0,
        out float2 p1,
        out float2 p2,
        out float2 p3)
    {
        p0 = float2(relativeClampQ2(c.p0, anchorQ)) * invScale;
        p1 = float2(relativeClampQ2(c.p1, anchorQ)) * invScale;
        p2 = float2(relativeClampQ2(c.p2, anchorQ)) * invScale;
        p3 = float2(relativeClampQ2(c.p3, anchorQ)) * invScale;
    }

    public void readCurvePointsRelative(
        uint curveBaseWords,
        uint curveIndex,
        int2 anchorQ,
        float invScale,
        out float2 p0,
        out float2 p1,
        out float2 p2,
        out float2 p3)
    {
        curvePointsRelative(readCurveQ(curveBaseWords, curveIndex), anchorQ, invScale, p0, p1, p2, p3);
    }

    public void readBand(uint bandBaseWords, uint bandIndex, out uint idStart, out uint bandIdCount)
    {
        uint off = bandBaseWords + bandIndex * BAND_WORD_LEN;
        idStart = loadU32(off);
        bandIdCount = loadU32(off + 1);
    }

    public uint readCurveId(uint idBaseWords, uint idIndex)
    {
        return loadU32(idBaseWords + idIndex);
    }
};
