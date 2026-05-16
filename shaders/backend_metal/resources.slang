// Metal resource bindings as seen by Slang before MSL generation.

import abi;

[[vk::binding(0, 0)]]
ByteAddressBuffer glyphPool : register(t0);

[[vk::binding(1, 0)]]
StructuredBuffer<GlyphCommand> commands;

#if HEAVY_SLUG_SHADER_STATS
[[vk::binding(2, 0)]]
RWStructuredBuffer<uint> shaderStats : register(u2);
#endif

[[vk::push_constant]]
PushConstants pc;
