#language slang 2026
module coverage_blob;

// CoverageBlob v2 decoding. The blob is a 32-bit word ABI; all fixed-point
// coordinates are decoded relative to the current meshlet chart before they
// become f32.

static const uint HEADER_WORD_LEN = 17;
static const uint CURVE_WORD_LEN = 12;
static const uint BAND_WORD_LEN = 2;
static const int  EXACT_F32_INT_RADIUS = 16777216;
static const int  I32_MAX_VALUE = 2147483647;
static const int  I32_MIN_VALUE = -2147483647 - 1;

public struct BlobHeader
{
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

    public uint loadU32(uint word)
    {
        return buf.Load(base + word * 4);
    }

    public int loadI32(uint word)
    {
        return asint(loadU32(word));
    }

    public BlobHeader readHeader()
    {
        BlobHeader h;
        h.fractionBits = loadU32(1);
        h.flags = loadU32(2);
        h.fillSign = loadI32(3) < 0 ? -1.0 : 1.0;
        h.curveCount = loadU32(4);
        h.bandMin = loadI32(5);
        h.bandCount = loadU32(6);
        h.bandHeightQ = loadI32(7);
        h.idCount = loadU32(8);
        h.wordCount = loadU32(9);
        h.boundsQ = int4(loadI32(10), loadI32(11), loadI32(12), loadI32(13));
        h.curveBaseWords = loadU32(14);
        h.bandBaseWords = loadU32(15);
        h.idBaseWords = loadU32(16);
        return h;
    }

    public CurveQ readCurveQ(uint curveBaseWords, uint curveIndex)
    {
        uint off = curveBaseWords + curveIndex * CURVE_WORD_LEN;
        CurveQ c;
        c.p0 = int2(loadI32(off + 0), loadI32(off + 1));
        c.p1 = int2(loadI32(off + 2), loadI32(off + 3));
        c.p2 = int2(loadI32(off + 4), loadI32(off + 5));
        c.p3 = int2(loadI32(off + 6), loadI32(off + 7));
        c.bbox = int4(loadI32(off + 8), loadI32(off + 9), loadI32(off + 10), loadI32(off + 11));
        return c;
    }

    public int4 readCurveBoundsQ(uint curveBaseWords, uint curveIndex)
    {
        uint off = curveBaseWords + curveIndex * CURVE_WORD_LEN + 8;
        return int4(loadI32(off + 0), loadI32(off + 1), loadI32(off + 2), loadI32(off + 3));
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
