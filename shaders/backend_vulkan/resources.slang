// Vulkan resource bindings.

import abi;

[[vk::binding(0, 0)]]
ByteAddressBuffer glyphPool;

[[vk::binding(1, 0)]]
StructuredBuffer<GlyphInstance> glyphs;

#if HEAVY_SLUG_SHADER_STATS
[[vk::binding(2, 0)]]
RWStructuredBuffer<uint> shaderStats;
#endif

[[vk::push_constant]]
FrameParams pc;
