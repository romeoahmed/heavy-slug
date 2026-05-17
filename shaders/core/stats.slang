#language slang 2026
module stats;

public static const uint kShaderStatCounterCount = 19;

public static const uint kShaderStatFragmentInvocations = 0;
public static const uint kShaderStatCandidatePathFragments = 1;
public static const uint kShaderStatFullScanFragments = 2;
public static const uint kShaderStatCandidateCurveTests = 3;
public static const uint kShaderStatFullScanCurveTests = 4;
public static const uint kShaderStatEmptyFragments = 5;
public static const uint kShaderStatTaskWorkgroups = 6;
public static const uint kShaderStatTaskGlyphsTested = 7;
public static const uint kShaderStatTaskGlyphsVisible = 8;
public static const uint kShaderStatTaskGlyphsCulled = 9;
public static const uint kShaderStatMeshWorkgroups = 10;
public static const uint kShaderStatCandidateCurveBboxRejects = 11;
public static const uint kShaderStatFullScanCurveBboxRejects = 12;
public static const uint kShaderStatCandidateCurveIntegrations = 13;
public static const uint kShaderStatFullScanCurveIntegrations = 14;
public static const uint kShaderStatBboxEmptyFragments = 15;
public static const uint kShaderStatCoverageZeroFragments = 16;
public static const uint kShaderStatMeshTilesEmitted = 17;
public static const uint kShaderStatMeshTilesCulled = 18;

public void addShaderStat(RWStructuredBuffer<uint> counters, uint index, uint value)
{
    InterlockedAdd(counters[index], value);
}
