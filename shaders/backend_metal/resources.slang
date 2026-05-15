import abi;

[[vk::binding(0, 0)]]
ByteAddressBuffer glyphPool : register(t0);

[[vk::binding(1, 0)]]
StructuredBuffer<GlyphCommand> commands;

[[vk::push_constant]]
PushConstants pc;
