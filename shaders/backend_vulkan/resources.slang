#language slang 2026
module resources;

// Vulkan resource bindings.

import abi;

[[vk::binding(0, 0)]]
public ByteAddressBuffer glyphPool;

[[vk::binding(1, 0)]]
public StructuredBuffer<GlyphInstance> glyphs;

#if HEAVY_SLUG_SHADER_STATS
[[vk::binding(2, 0)]]
public RWStructuredBuffer<uint> shaderStats;
#endif

[[vk::push_constant]]
public FrameParams pc;
