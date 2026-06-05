#language slang 2026
module resources;

// Metal resource bindings as seen by Slang before MSL generation.

import abi;

[[vk::binding(0, 0)]]
public ByteAddressBuffer glyphPool;

[[vk::binding(1, 0)]]
public StructuredBuffer<GlyphInstance> glyphs;

[[vk::binding(2, 0)]]
public StructuredBuffer<GlyphMeshlet> meshlets;

#if HEAVY_SLUG_SHADER_STATS
[[vk::binding(3, 0)]]
public RWStructuredBuffer<uint> shaderStats;
#endif

// Metal has no native push-constant slot; Slang materializes the push
// constant as an ordinary buffer parameter and would otherwise auto-assign
// its [[buffer(N)]] index. Pin it to slot 4 explicitly via `register(b4)`
// so the CPU bridge uses a constant index regardless of whether the
// optional shader-stats RW buffer at slot 3 is compiled in.
// (Slang Metal target: register(bN)/tN/uN map to [[buffer(N)]].)
[[vk::push_constant]]
public FrameParams pc : register(b4);
