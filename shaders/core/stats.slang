#language slang 2026
module stats;

public static const uint kShaderStatCounterCount = 24;

public static const uint kShaderStatFragmentInvocations = 0;
public static const uint kShaderStatCandidatePathFragments = 1;
public static const uint kShaderStatFullScanFragments = 2;
public static const uint kShaderStatCandidateCurveTests = 3;
public static const uint kShaderStatFullScanCurveTests = 4;
public static const uint kShaderStatEmptyFragments = 5;
public static const uint kShaderStatCpuGlyphsSubmitted = 6;
public static const uint kShaderStatCpuMeshletsSubmitted = 7;
public static const uint kShaderStatDrawChunks = 8;
public static const uint kShaderStatFrameSubmissions = 9;
public static const uint kShaderStatMeshWorkgroups = 10;
public static const uint kShaderStatCandidateCurveBboxRejects = 11;
public static const uint kShaderStatFullScanCurveBboxRejects = 12;
public static const uint kShaderStatCandidateCurveIntegrations = 13;
public static const uint kShaderStatFullScanCurveIntegrations = 14;
public static const uint kShaderStatBboxEmptyFragments = 15;
public static const uint kShaderStatCoverageZeroFragments = 16;
public static const uint kShaderStatMeshTilesEmitted = 17;
public static const uint kShaderStatMeshTilesCulled = 18;
public static const uint kShaderStatMeshCullEmptySlices = 19;
public static const uint kShaderStatMeshCullInvalidStrips = 20;
public static const uint kShaderStatMeshCullZeroArea = 21;
public static const uint kShaderStatMeshCullClipEmpty = 22;
public static const uint kShaderStatMeshCullNonFinite = 23;

public static const uint kMeshCullNone = 0;
public static const uint kMeshCullEmptySlice = 1;
public static const uint kMeshCullInvalidStrip = 2;
public static const uint kMeshCullZeroArea = 3;
public static const uint kMeshCullClipEmpty = 4;
public static const uint kMeshCullNonFinite = 5;

public void addShaderStat(RWStructuredBuffer<uint> counters, uint index, uint value)
{
    InterlockedAdd(counters[index], value);
}

public void addMeshTileStat(RWStructuredBuffer<uint> counters, bool emitted, uint cullReason)
{
    if (emitted)
    {
        addShaderStat(counters, kShaderStatMeshTilesEmitted, 1);
        return;
    }

    addShaderStat(counters, kShaderStatMeshTilesCulled, 1);
    if (cullReason == kMeshCullEmptySlice)
        addShaderStat(counters, kShaderStatMeshCullEmptySlices, 1);
    else if (cullReason == kMeshCullInvalidStrip)
        addShaderStat(counters, kShaderStatMeshCullInvalidStrips, 1);
    else if (cullReason == kMeshCullZeroArea)
        addShaderStat(counters, kShaderStatMeshCullZeroArea, 1);
    else if (cullReason == kMeshCullClipEmpty)
        addShaderStat(counters, kShaderStatMeshCullClipEmpty, 1);
    else if (cullReason == kMeshCullNonFinite)
        addShaderStat(counters, kShaderStatMeshCullNonFinite, 1);
}
