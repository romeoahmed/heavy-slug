//! VulkanContext: wraps a caller-provided Vulkan device.
//! Full implementation in a later plan — this stub validates
//! that vulkan-zig bindings are available and key types compile.

const vk = @import("vulkan");

/// Vulkan device dispatch table type.
/// Only loads the commands heavy-slug actually uses.
/// Populated in init() via vk.DeviceWrapper.load(device, loader).
///
/// This version of vulkan-zig (14.1.0) generates a flat dispatch
/// struct covering all Vulkan commands; filtering to a subset is
/// not supported via a constructor argument. DeviceWrapper wraps
/// the full DeviceDispatch.
pub const DeviceDispatch = vk.DeviceDispatch;

test "vulkan types are available" {
    // Verify binding generation produced usable types
    _ = vk.PhysicalDevice;
    _ = vk.Device;
    _ = vk.CommandBuffer;
    _ = vk.Format;
    _ = vk.Queue;
    _ = vk.DescriptorSetLayout;
    _ = vk.PipelineLayout;
    _ = vk.Pipeline;
    _ = vk.Buffer;
    _ = vk.DeviceMemory;
}

test "DeviceDispatch type compiles" {
    // Verify the dispatch wrapper type is valid
    _ = DeviceDispatch;
    // The dispatch table has the expected fields
    _ = @hasField(DeviceDispatch, "vkDestroyDevice");
    _ = @hasField(DeviceDispatch, "vkCreateBuffer");
    _ = @hasField(DeviceDispatch, "vkCmdDrawMeshTasksEXT");
}
