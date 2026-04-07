const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const descriptors = @import("descriptors.zig");
const spv = @import("shader_spv");

pub const Pipeline = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,
};

/// Create a VkShaderModule from embedded SPIR-V bytes.
/// SPIR-V data must be a multiple of 4 bytes (u32-aligned words).
fn createShaderModule(
    _: vk.Device,
    _: gpu_context.DeviceDispatch,
    _: []const u8,
) !vk.ShaderModule {
    @compileError("createShaderModule: implemented in next task");
}

test "Pipeline type compiles with expected fields" {
    _ = Pipeline;
    try std.testing.expect(@hasField(Pipeline, "device"));
    try std.testing.expect(@hasField(Pipeline, "dispatch"));
    try std.testing.expect(@hasField(Pipeline, "pipeline_layout"));
    try std.testing.expect(@hasField(Pipeline, "pipeline"));
}

test "push constant range matches PushConstants size" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(descriptors.PushConstants));
}

test "embedded SPIR-V data is non-empty" {
    try std.testing.expect(spv.task.len > 0);
    try std.testing.expect(spv.mesh.len > 0);
    try std.testing.expect(spv.fragment.len > 0);
}

test "SPIR-V length is multiple of 4 (u32-aligned words)" {
    try std.testing.expectEqual(@as(usize, 0), spv.task.len % 4);
    try std.testing.expectEqual(@as(usize, 0), spv.mesh.len % 4);
    try std.testing.expectEqual(@as(usize, 0), spv.fragment.len % 4);
}
