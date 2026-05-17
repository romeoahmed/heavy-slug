#language slang 2026
module resources;

// Metal resource bindings as seen by Slang before MSL generation.

import abi;

[[vk::binding(0, 0)]]
public ByteAddressBuffer glyphPool : register(t0);

[[vk::binding(1, 0)]]
public StructuredBuffer<GlyphInstance> glyphs;

#if HEAVY_SLUG_SHADER_STATS
[[vk::binding(2, 0)]]
public RWStructuredBuffer<uint> shaderStats : register(u2);
#endif

[[vk::push_constant]]
public FrameParams pc;
