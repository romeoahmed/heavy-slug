#language slang 2026
module stats;

public static const uint kShaderStatCounterCount = 24;

public static const uint kShaderStatFragmentInvocations = 0;
public static const uint kShaderStatCandidatePathFragments = 1;
public static const uint kShaderStatFullScanFragments = 2;
public static const uint kShaderStatCandidateCurveTests = 3;
public static const uint kShaderStatFullScanCurveTests = 4;
public static const uint kShaderStatEmptyFragments = 5;
public static const uint kShaderStatSubmittedGlyphs = 6;
public static const uint kShaderStatSubmittedMeshlets = 7;
public static const uint kShaderStatDrawChunks = 8;
public static const uint kShaderStatFrameSubmissions = 9;
public static const uint kShaderStatMeshWorkgroups = 10;
public static const uint kShaderStatCandidateCurveBboxRejects = 11;
public static const uint kShaderStatFullScanCurveBboxRejects = 12;
public static const uint kShaderStatCandidateCurveIntegrations = 13;
public static const uint kShaderStatFullScanCurveIntegrations = 14;
public static const uint kShaderStatBboxEmptyFragments = 15;
public static const uint kShaderStatCoverageZeroFragments = 16;
public static const uint kShaderStatMeshletsEmitted = 17;
public static const uint kShaderStatMeshletsCulled = 18;
public static const uint kShaderStatMeshletCullEmptySlices = 19;
public static const uint kShaderStatMeshletCullInvalidStrips = 20;
public static const uint kShaderStatMeshletCullZeroArea = 21;
public static const uint kShaderStatMeshletCullClipEmpty = 22;
public static const uint kShaderStatMeshletCullNonFinite = 23;

public static const uint kMeshletCullNone = 0;
public static const uint kMeshletCullEmptySlice = 1;
public static const uint kMeshletCullInvalidStrip = 2;
public static const uint kMeshletCullZeroArea = 3;
public static const uint kMeshletCullClipEmpty = 4;
public static const uint kMeshletCullNonFinite = 5;

[ForceInline] public void addShaderStat(RWStructuredBuffer<uint> counters, uint index, uint value)
{
    InterlockedAdd(counters[index], value);
}

[ForceInline] public void addMeshletStat(RWStructuredBuffer<uint> counters, bool emitted, uint cullReason)
{
    if (emitted)
    {
        addShaderStat(counters, kShaderStatMeshletsEmitted, 1);
        return;
    }

    addShaderStat(counters, kShaderStatMeshletsCulled, 1);
    if (cullReason == kMeshletCullEmptySlice)
        addShaderStat(counters, kShaderStatMeshletCullEmptySlices, 1);
    else if (cullReason == kMeshletCullInvalidStrip)
        addShaderStat(counters, kShaderStatMeshletCullInvalidStrips, 1);
    else if (cullReason == kMeshletCullZeroArea)
        addShaderStat(counters, kShaderStatMeshletCullZeroArea, 1);
    else if (cullReason == kMeshletCullClipEmpty)
        addShaderStat(counters, kShaderStatMeshletCullClipEmpty, 1);
    else if (cullReason == kMeshletCullNonFinite)
        addShaderStat(counters, kShaderStatMeshletCullNonFinite, 1);
}
