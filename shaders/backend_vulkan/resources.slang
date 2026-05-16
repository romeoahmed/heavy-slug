import abi;

[[vk::binding(0, 0)]]
ByteAddressBuffer glyphBlobs[];

[[vk::binding(1, 0)]]
StructuredBuffer<GlyphCommand> commands;

#if HEAVY_SLUG_SHADER_STATS
[[vk::binding(2, 0)]]
RWStructuredBuffer<uint> shaderStats;
#endif

[[vk::push_constant]]
PushConstants pc;
