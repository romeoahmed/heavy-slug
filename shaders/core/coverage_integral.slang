// Analytic cubic coverage integration helpers.

import coverage_blob;

struct Cubic
{
    float2 p0;
    float2 p1;
    float2 p2;
    float2 p3;
};

static const float kCoverageEpsilon = 1.0 / 1048576.0;
static const float kParamEpsilon = 1.0e-8;
static const float kRootMergeEpsilon = 1.0e-7;
static const float kGaussRoot = 0.7745966692414834;
static const float kGaussSideWeight = 0.5555555555555556;
static const float kGaussCenterWeight = 0.8888888888888888;

float cubicAt(float p0, float p1, float p2, float p3, float t)
{
    float u = 1.0 - t;
    return ((p0 * u + p1 * t) * u + (p1 * u + p2 * t) * t) * u +
           ((p1 * u + p2 * t) * u + (p2 * u + p3 * t) * t) * t;
}

float cubicAxisDerivative(float p0, float p1, float p2, float p3, float t)
{
    float u = 1.0 - t;
    return 3.0 * (u * u * (p1 - p0) + 2.0 * u * t * (p2 - p1) + t * t * (p3 - p2));
}

bool crossesValue(float a, float b, float value)
{
    return (a < value && b > value) || (a > value && b < value);
}

float solveMonotoneCubicAt(float p0, float p1, float p2, float p3, float value)
{
    float f0 = p0 - value;
    float f1 = p3 - value;
    if (abs(f0) <= kCoverageEpsilon) return 0.0;
    if (abs(f1) <= kCoverageEpsilon) return 1.0;

    float lo = 0.0;
    float hi = 1.0;
    float flo = f0;
    float denom = p3 - p0;
    float t = abs(denom) > kCoverageEpsilon ? saturate((value - p0) / denom) : 0.5;

    for (uint i = 0; i < 24; i++)
    {
        float f = cubicAt(p0, p1, p2, p3, t) - value;
        if (abs(f) <= kCoverageEpsilon)
            return saturate(t);

        float df = cubicAxisDerivative(p0, p1, p2, p3, t);
        bool sameSideAsLo = (f <= 0.0 && flo <= 0.0) || (f >= 0.0 && flo >= 0.0);
        if (sameSideAsLo)
        {
            lo = t;
            flo = f;
        }
        else
        {
            hi = t;
        }

        float newton = t - f / df;
        bool useBisect = abs(df) < kCoverageEpsilon || newton <= lo || newton >= hi || !isfinite(newton);
        t = useBisect ? (lo + hi) * 0.5 : newton;
    }

    return saturate(t);
}

void splitCubic(Cubic curve, float t, out Cubic left, out Cubic right)
{
    float2 p01 = lerp(curve.p0, curve.p1, t);
    float2 p12 = lerp(curve.p1, curve.p2, t);
    float2 p23 = lerp(curve.p2, curve.p3, t);
    float2 p012 = lerp(p01, p12, t);
    float2 p123 = lerp(p12, p23, t);
    float2 p0123 = lerp(p012, p123, t);

    left.p0 = curve.p0;
    left.p1 = p01;
    left.p2 = p012;
    left.p3 = p0123;
    right.p0 = p0123;
    right.p1 = p123;
    right.p2 = p23;
    right.p3 = curve.p3;
}

Cubic subCubic(Cubic curve, float ta, float tb)
{
    if (ta <= kParamEpsilon && tb >= 1.0 - kParamEpsilon)
        return curve;

    Cubic left;
    Cubic right;
    if (ta > kParamEpsilon)
    {
        splitCubic(curve, ta, left, right);
        curve = right;
        tb = (tb - ta) / max(1.0 - ta, kParamEpsilon);
    }

    if (tb < 1.0 - kParamEpsilon)
    {
        splitCubic(curve, tb, left, right);
        curve = left;
    }

    return curve;
}

float evalXDy(Cubic curve, float xLeft, float t)
{
    float x = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, t);
    float dy = cubicAxisDerivative(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, t);
    return (x - xLeft) * dy;
}

float integrateInsideXDy(Cubic curve, float xLeft, float a, float b)
{
    float half = (b - a) * 0.5;
    if (abs(half) <= kParamEpsilon)
        return 0.0;

    float mid = (a + b) * 0.5;
    float span = half * kGaussRoot;
    return half * (
        kGaussSideWeight * evalXDy(curve, xLeft, mid - span) +
        kGaussCenterWeight * evalXDy(curve, xLeft, mid) +
        kGaussSideWeight * evalXDy(curve, xLeft, mid + span)
    );
}

float integrateClampedSpan(Cubic curve, float a, float b)
{
    if (b <= a + kParamEpsilon)
        return 0.0;

    float mid = (a + b) * 0.5;
    float xMid = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, mid);
    if (xMid <= -0.5)
        return 0.0;

    float dy = cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, b) -
               cubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, a);
    if (xMid >= 0.5)
        return dy;

    return integrateInsideXDy(curve, -0.5, a, b);
}

void addSplitRoot(inout float r0, inout float r1, inout uint rootCount, float root, float ta, float tb)
{
    if (root <= ta + kParamEpsilon || root >= tb - kParamEpsilon)
        return;

    if (rootCount == 0)
    {
        r0 = root;
        rootCount = 1;
    }
    else if (abs(root - r0) > kRootMergeEpsilon)
    {
        r1 = root;
        rootCount = 2;
    }
}

float integrateYMonotoneCoverage(Cubic curve)
{
    float curveStartY = curve.p0.y;
    float curveEndY = curve.p3.y;
    float curveMinY = min(curveStartY, curveEndY);
    float curveMaxY = max(curveStartY, curveEndY);
    float clipMinY = max(-0.5, curveMinY);
    float clipMaxY = min(0.5, curveMaxY);
    if (clipMaxY <= clipMinY + kCoverageEpsilon)
        return 0.0;

    float ta;
    float tb;
    if (curveEndY > curveStartY)
    {
        ta = clipMinY <= curveStartY + kCoverageEpsilon
            ? 0.0
            : solveMonotoneCubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, clipMinY);
        tb = clipMaxY >= curveEndY - kCoverageEpsilon
            ? 1.0
            : solveMonotoneCubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, clipMaxY);
    }
    else
    {
        ta = clipMaxY >= curveStartY - kCoverageEpsilon
            ? 0.0
            : solveMonotoneCubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, clipMaxY);
        tb = clipMinY <= curveEndY + kCoverageEpsilon
            ? 1.0
            : solveMonotoneCubicAt(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, clipMinY);
    }

    float signedClipHeight = curveEndY > curveStartY
        ? clipMaxY - clipMinY
        : clipMinY - clipMaxY;

    if (tb <= ta + kParamEpsilon)
    {
        float xMidCollapsed = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, saturate((ta + tb) * 0.5));
        if (xMidCollapsed >= 0.5)
            return signedClipHeight;
        if (xMidCollapsed <= -0.5)
            return 0.0;
        return saturate(xMidCollapsed + 0.5) * signedClipHeight;
    }

    float xa = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, ta);
    float xb = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, tb);
    float minSpanX = min(xa, xb);
    float maxSpanX = max(xa, xb);
    if (minSpanX >= 0.5)
        return signedClipHeight;
    if (maxSpanX <= -0.5)
        return 0.0;

    float r0 = tb;
    float r1 = tb;
    uint rootCount = 0;

    if (crossesValue(xa, xb, -0.5))
        addSplitRoot(r0, r1, rootCount, solveMonotoneCubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, -0.5), ta, tb);
    if (crossesValue(xa, xb, 0.5))
        addSplitRoot(r0, r1, rootCount, solveMonotoneCubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, 0.5), ta, tb);

    if (rootCount == 2 && r1 < r0)
    {
        float tmp = r0;
        r0 = r1;
        r1 = tmp;
    }

    float area = integrateClampedSpan(curve, ta, r0);
    if (rootCount == 0)
        return area;
    if (rootCount == 1)
        return area + integrateClampedSpan(curve, r0, tb);

    return area + integrateClampedSpan(curve, r0, r1) + integrateClampedSpan(curve, r1, tb);
}

void appendRoot(inout float roots[6], inout uint rootCount, float root)
{
    if (root <= kParamEpsilon || root >= 1.0 - kParamEpsilon)
        return;

    for (uint i = 0; i < rootCount; i++)
    {
        if (abs(root - roots[i]) <= kRootMergeEpsilon)
            return;
    }

    if (rootCount < 6)
    {
        roots[rootCount] = root;
        rootCount++;
    }
}

void appendDerivativeRoots(inout float roots[6], inout uint rootCount, float p0, float p1, float p2, float p3)
{
    float a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
    float b = 2.0 * (p0 - 2.0 * p1 + p2);
    float c = p1 - p0;
    float qa = 3.0 * a;
    float qb = 3.0 * b;
    float qc = 3.0 * c;

    if (abs(qa) <= kCoverageEpsilon)
    {
        if (abs(qb) > kCoverageEpsilon)
            appendRoot(roots, rootCount, -qc / qb);
        return;
    }

    float disc = qb * qb - 4.0 * qa * qc;
    if (disc < 0.0)
        return;

    float d = sqrt(max(disc, 0.0));
    float inv = 0.5 / qa;
    appendRoot(roots, rootCount, (-qb - d) * inv);
    appendRoot(roots, rootCount, (-qb + d) * inv);
}

void sortRoots(inout float roots[6], uint rootCount)
{
    for (uint i = 1; i < rootCount; i++)
    {
        float v = roots[i];
        uint j = i;
        while (j > 0 && roots[j - 1] > v)
        {
            roots[j] = roots[j - 1];
            j--;
        }
        roots[j] = v;
    }
}

float integrateCurve(Cubic curve)
{
    float roots[6];
    roots[0] = 0.0;
    roots[1] = 1.0;
    uint rootCount = 2;
    appendDerivativeRoots(roots, rootCount, curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x);
    appendDerivativeRoots(roots, rootCount, curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y);
    sortRoots(roots, rootCount);

    float area = 0.0;
    for (uint i = 0; i + 1 < rootCount; i++)
    {
        float ta = roots[i];
        float tb = roots[i + 1];
        if (tb <= ta + kParamEpsilon)
            continue;

        Cubic sub = subCubic(curve, ta, tb);
        area += integrateYMonotoneCoverage(sub);
    }

    return area;
}

float2 toPixelLocal(float2 p, float2 center, float2 dx, float2 dy, float invDet)
{
    float2 d = p - center;
    return float2(
        (d.x * dy.y - d.y * dy.x) * invDet,
        (dx.x * d.y - dx.y * d.x) * invDet
    );
}

bool curveBboxMayContribute(float4 bbox, float2 center, float2 dx, float2 dy, float invDet)
{
    float2 bboxMin = float2(bbox.x, bbox.z);
    float2 bboxMax = float2(bbox.y, bbox.w);
    float2 bboxCenter = (bboxMin + bboxMax) * 0.5;
    float2 bboxHalfExtent = (bboxMax - bboxMin) * 0.5;

    float2 localXAxis = float2(dy.y, -dy.x) * invDet;
    float2 localYAxis = float2(-dx.y, dx.x) * invDet;
    float2 d = bboxCenter - center;

    float localCenterX = dot(d, localXAxis);
    float localCenterY = dot(d, localYAxis);
    float radiusX = dot(abs(localXAxis), bboxHalfExtent);
    float radiusY = dot(abs(localYAxis), bboxHalfExtent);

    if (localCenterY + radiusY < -0.5 - kCoverageEpsilon)
        return false;
    if (localCenterY - radiusY > 0.5 + kCoverageEpsilon)
        return false;
    if (localCenterX + radiusX < -0.5 - kCoverageEpsilon)
        return false;

    return true;
}

float resolveCoverage(float signedArea, float fillSign, float detSign, uint flags)
{
    float windingCoverage = signedArea;
    float coverage = fillSign * detSign * windingCoverage;

    bool evenOdd = (flags & 1u) != 0u;
    if (evenOdd)
    {
        coverage = abs(windingCoverage);
        coverage = 1.0 - abs(1.0 - frac(coverage * 0.5) * 2.0);
    }
    else
    {
        coverage = saturate(coverage);
    }

    return coverage;
}

float integrateCurvePayload(
    BlobReader blob,
    uint curveBase,
    uint curveIndex,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    float2 p0g, p1g, p2g, p3g;
    blob.readCurvePoints(curveBase, curveIndex, p0g, p1g, p2g, p3g);
    Cubic curve;
    curve.p0 = toPixelLocal(p0g, renderCoord, dx, dy, invDet);
    curve.p1 = toPixelLocal(p1g, renderCoord, dx, dy, invDet);
    curve.p2 = toPixelLocal(p2g, renderCoord, dx, dy, invDet);
    curve.p3 = toPixelLocal(p3g, renderCoord, dx, dy, invDet);

    return integrateCurve(curve);
}

float integrateFullScan(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    float signedArea = 0.0;
    for (uint ci = 0; ci < curveCount; ci++)
    {
        float4 bbox = blob.readCurveBounds(curveBase, ci);
        if (curveBboxMayContribute(bbox, renderCoord, dx, dy, invDet))
            signedArea += integrateCurvePayload(blob, curveBase, ci, renderCoord, dx, dy, invDet);
    }
    return signedArea;
}

#if HEAVY_SLUG_SHADER_STATS
float integrateCurveFromBlobWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveIndex,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out bool bboxRejected)
{
    float4 bbox = blob.readCurveBounds(curveBase, curveIndex);
    if (!curveBboxMayContribute(bbox, renderCoord, dx, dy, invDet))
    {
        bboxRejected = true;
        return 0.0;
    }

    bboxRejected = false;
    return integrateCurvePayload(blob, curveBase, curveIndex, renderCoord, dx, dy, invDet);
}

float integrateFullScanWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out uint bboxRejects,
    out uint integrations)
{
    float signedArea = 0.0;
    bboxRejects = 0;
    integrations = 0;
    for (uint ci = 0; ci < curveCount; ci++)
    {
        bool bboxRejected;
        signedArea += integrateCurveFromBlobWithStats(blob, curveBase, ci, renderCoord, dx, dy, invDet, bboxRejected);
        bboxRejects += bboxRejected ? 1u : 0u;
        integrations += bboxRejected ? 0u : 1u;
    }
    return signedArea;
}
#endif
