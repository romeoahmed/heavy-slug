#language slang 2026
module coverage_integral;

// Analytic cubic coverage integration helpers.

import coverage_blob;
import shader_math;

struct Cubic
{
    float2 p0;
    float2 p1;
    float2 p2;
    float2 p3;
};

// Shared across modules — fragment.slang reads it for stats reporting.
public static const float kCoverageEpsilon = 1.0 / 1048576.0;

// Internal — keep within this module.
static const float kParamEpsilon = 1.0e-8;
static const float kRootMergeEpsilon = 1.0e-7;
// 3-point Gauss-Legendre on [-1, 1] (exact for polynomials up to degree 5,
// which is what (x(t) - x_L) * y'(t) evaluates to for a cubic Bézier curve).
static const float kGaussRoot = 0.7745966692414834;
static const float kGaussSideWeight = 0.5555555555555556;
static const float kGaussCenterWeight = 0.8888888888888888;

[ForceInline] float cubicAt(float p0, float p1, float p2, float p3, float t)
{
    // Two-stage de Casteljau: l_i are first-pass linear blends, q_i are
    // second-pass quadratics. Written out explicitly so the shared
    // (p1*u + p2*t) blend is computed once rather than relying on the
    // downstream optimizer to common-subexpression-eliminate it.
    float u = 1.0 - t;
    float l0 = p0 * u + p1 * t;
    float l1 = p1 * u + p2 * t;
    float l2 = p2 * u + p3 * t;
    float q0 = l0 * u + l1 * t;
    float q1 = l1 * u + l2 * t;
    return q0 * u + q1 * t;
}

[ForceInline] float cubicAxisDerivative(float p0, float p1, float p2, float p3, float t)
{
    float u = 1.0 - t;
    return 3.0 * (u * u * (p1 - p0) + 2.0 * u * t * (p2 - p1) + t * t * (p3 - p2));
}

[ForceInline] bool crossesValue(float a, float b, float value)
{
    return (a < value && b > value) || (a > value && b < value);
}

[ForceInline] float solveMonotoneCubicAt(float p0, float p1, float p2, float p3, float value)
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

    // 40 iterations (was 24): at extreme renderer-policy scales the inner
    // bisection-fallback worst case needed extra steps to drive the residual
    // below kCoverageEpsilon. The early-exit guard turns the cap into a
    // loose upper bound that converges in single digits for normal curves.
    float f = cubicAt(p0, p1, p2, p3, t) - value;
    for (uint i = 0; i < 40 && abs(f) > kCoverageEpsilon; i++)
    {
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
        f = cubicAt(p0, p1, p2, p3, t) - value;
    }

    return saturate(t);
}

[ForceInline] void splitCubic(Cubic curve, float t, out Cubic left, out Cubic right)
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

[ForceInline] float evalXDy(Cubic curve, float xLeft, float t)
{
    float x = cubicAt(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x, t);
    float dy = cubicAxisDerivative(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y, t);
    return (x - xLeft) * dy;
}

[ForceInline] float integrateInsideXDy(Cubic curve, float xLeft, float a, float b)
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

[ForceInline] float integrateClampedSpan(Cubic curve, float a, float b)
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

[ForceInline] void addSplitRoot(inout float r0, inout float r1, inout uint rootCount, float root, float ta, float tb)
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

// Precondition: `curve` must be monotone in BOTH x and y over [0, 1].
// The only caller is `integrateCurve` (below), which guarantees this by
// splitting the input cubic at every dy/dt = 0 and dx/dt = 0 root before
// calling. With monotonicity in y, mapping clip planes y = ±0.5 back to
// parameter space reduces to one Newton solve in `solveMonotoneCubicAt`;
// with monotonicity in x, the x = ±0.5 crossings produce at most two
// split parameters (`r0`, `r1`), yielding the three Gauss-integrated
// spans below. Passing a non-monotone curve will silently undercount
// crossings and corrupt the signed area.
[ForceInline] float integrateYMonotoneCoverage(Cubic curve)
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

[ForceInline] void appendRoot(inout float roots[6], inout uint rootCount, float root)
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

[ForceInline] void appendDerivativeRoots(inout float roots[6], inout uint rootCount, float p0, float p1, float p2, float p3)
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

[ForceInline] void sortRoots(inout float roots[6], uint rootCount)
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

[ForceInline] float integrateCurve(Cubic curve)
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

[ForceInline] float2 toPixelLocal(float2 p, float2 center, float2 dx, float2 dy, float invDet)
{
    float2 d = p - center;
    return float2(
        (d.x * dy.y - d.y * dy.x) * invDet,
        (dx.x * d.y - dx.y * d.x) * invDet
    );
}

// Blob header bounds are packed as [min_x, min_y, max_x, max_y].
[ForceInline] public bool rectBoundsRelativeTo(int4 boundsQ, int2 anchorQ, float invScale, out float4 bounds)
{
    bounds = float4(0.0, 0.0, 0.0, 0.0);
    int minX;
    int minY;
    int maxX;
    int maxY;
    if (!relativeExactQ(boundsQ.x, anchorQ.x, minX) ||
        !relativeExactQ(boundsQ.y, anchorQ.y, minY) ||
        !relativeExactQ(boundsQ.z, anchorQ.x, maxX) ||
        !relativeExactQ(boundsQ.w, anchorQ.y, maxY))
        return false;

    bounds = float4(minX, minY, maxX, maxY) * invScale;
    return true;
}

// Per-curve bounds are packed as [min_x, min_y, max_x, max_y].
[ForceInline] float4 curveBoundsRelativeTo(float4 bbox)
{
    return bbox;
}

[ForceInline] bool localCurveBboxMayContribute(float4 bbox, float2 center, float2 dx, float2 dy, float invDet)
{
    float2 bboxMin = bbox.xy;
    float2 bboxMax = bbox.zw;
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

[ForceInline] public bool curveBboxMayContribute(
    float4 bbox,
    float2 center,
    float2 dx,
    float2 dy,
    float invDet)
{
    return localCurveBboxMayContribute(curveBoundsRelativeTo(bbox), center, dx, dy, invDet);
}

[ForceInline] public float resolveCoverage(float signedArea, float fillSign, float detSign, uint flags)
{
    bool evenOdd = (flags & 1u) != 0u;
    if (evenOdd)
    {
        // Even-odd is a triangle wave on |signedArea|; the sign of the
        // accumulated area (and hence fillSign / detSign) drops out.
        float w = abs(signedArea);
        return 1.0 - abs(1.0 - frac(w * 0.5) * 2.0);
    }

    return saturate(fillSign * detSign * signedArea);
}

[ForceInline] public bool integrateCurvePayload(
    BlobReader blob,
    uint curveBase,
    uint curveIndex,
    int2 anchorQ,
    float invScale,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out float contribution)
{
    contribution = 0.0;
    CurveQ cq = blob.readCurveQ(curveBase, curveIndex);
    float2 p0g, p1g, p2g, p3g;
    if (!blob.curvePointsRelativeExact(cq, anchorQ, invScale, p0g, p1g, p2g, p3g))
        return false;

    Cubic curve;
    curve.p0 = toPixelLocal(p0g, renderCoord, dx, dy, invDet);
    curve.p1 = toPixelLocal(p1g, renderCoord, dx, dy, invDet);
    curve.p2 = toPixelLocal(p2g, renderCoord, dx, dy, invDet);
    curve.p3 = toPixelLocal(p3g, renderCoord, dx, dy, invDet);

    contribution = integrateCurve(curve);
    return true;
}

[ForceInline] public bool integrateCurveFromBlob(
    BlobReader blob,
    uint curveBase,
    uint curveIndex,
    int2 anchorQ,
    float invScale,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out float contribution,
    out bool bboxRejected)
{
    contribution = 0.0;
    bboxRejected = false;

    float4 bbox;
    if (!blob.readCurveBoundsRelativeExact(curveBase, curveIndex, anchorQ, invScale, bbox))
    {
        bboxRejected = true;
        return false;
    }

    if (!curveBboxMayContribute(bbox, renderCoord, dx, dy, invDet))
    {
        bboxRejected = true;
        return false;
    }

    return integrateCurvePayload(blob, curveBase, curveIndex, anchorQ, invScale, renderCoord, dx, dy, invDet, contribution);
}

[ForceInline] public float integrateFullScan(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    int2 anchorQ,
    float invScale,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet)
{
    float signedArea = 0.0;
    for (uint ci = 0; ci < curveCount; ci++)
    {
        float contribution;
        bool bboxRejected;
        if (integrateCurveFromBlob(blob, curveBase, ci, anchorQ, invScale, renderCoord, dx, dy, invDet, contribution, bboxRejected))
            signedArea += contribution;
    }
    return signedArea;
}

#if HEAVY_SLUG_SHADER_STATS
[ForceInline] public float integrateCurveFromBlobWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveIndex,
    int2 anchorQ,
    float invScale,
    float2 renderCoord,
    float2 dx,
    float2 dy,
    float invDet,
    out bool bboxRejected)
{
    float contribution;
    bool integrated = integrateCurveFromBlob(
        blob,
        curveBase,
        curveIndex,
        anchorQ,
        invScale,
        renderCoord,
        dx,
        dy,
        invDet,
        contribution,
        bboxRejected);
    return integrated ? contribution : 0.0;
}

[ForceInline] public float integrateFullScanWithStats(
    BlobReader blob,
    uint curveBase,
    uint curveCount,
    int2 anchorQ,
    float invScale,
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
        signedArea += integrateCurveFromBlobWithStats(blob, curveBase, ci, anchorQ, invScale, renderCoord, dx, dy, invDet, bboxRejected);
        bboxRejects += bboxRejected ? 1u : 0u;
        integrations += bboxRejected ? 0u : 1u;
    }
    return signedArea;
}
#endif
