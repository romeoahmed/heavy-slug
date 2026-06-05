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

[[vk::push_constant]]
public FrameParams pc;
