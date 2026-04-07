//! VulkanContext: wraps a caller-provided Vulkan device.
//! Full implementation in a later plan — this stub validates
//! that vulkan-zig bindings are available and key types compile.

const std = @import("std");
const vk = @import("vulkan");

/// Filtered device dispatch struct — only the commands heavy-slug uses.
/// vulkan-zig API: define a struct with the exact vkXxx fields you need,
/// then pass its type to DeviceWrapperWithCustomDispatch() to get a
/// wrapper type with named helper methods + a .load() constructor.
const HeavySlugDispatch = struct {
    vkDestroyDevice: ?vk.PfnDestroyDevice = null,
    vkCreateDescriptorSetLayout: ?vk.PfnCreateDescriptorSetLayout = null,
    vkDestroyDescriptorSetLayout: ?vk.PfnDestroyDescriptorSetLayout = null,
    vkCreateDescriptorPool: ?vk.PfnCreateDescriptorPool = null,
    vkDestroyDescriptorPool: ?vk.PfnDestroyDescriptorPool = null,
    vkAllocateDescriptorSets: ?vk.PfnAllocateDescriptorSets = null,
    vkUpdateDescriptorSets: ?vk.PfnUpdateDescriptorSets = null,
    vkCreatePipelineLayout: ?vk.PfnCreatePipelineLayout = null,
    vkDestroyPipelineLayout: ?vk.PfnDestroyPipelineLayout = null,
    vkCreateGraphicsPipelines: ?vk.PfnCreateGraphicsPipelines = null,
    vkDestroyPipeline: ?vk.PfnDestroyPipeline = null,
    vkCreateShaderModule: ?vk.PfnCreateShaderModule = null,
    vkDestroyShaderModule: ?vk.PfnDestroyShaderModule = null,
    vkCreateBuffer: ?vk.PfnCreateBuffer = null,
    vkDestroyBuffer: ?vk.PfnDestroyBuffer = null,
    vkAllocateMemory: ?vk.PfnAllocateMemory = null,
    vkFreeMemory: ?vk.PfnFreeMemory = null,
    vkBindBufferMemory: ?vk.PfnBindBufferMemory = null,
    vkMapMemory: ?vk.PfnMapMemory = null,
    vkUnmapMemory: ?vk.PfnUnmapMemory = null,
    vkGetBufferDeviceAddress: ?vk.PfnGetBufferDeviceAddress = null,
    vkCmdBindPipeline: ?vk.PfnCmdBindPipeline = null,
    vkCmdBindDescriptorSets: ?vk.PfnCmdBindDescriptorSets = null,
    vkCmdPushConstants: ?vk.PfnCmdPushConstants = null,
    vkCmdDrawMeshTasksEXT: ?vk.PfnCmdDrawMeshTasksEXT = null,
    vkQueueSubmit2: ?vk.PfnQueueSubmit2 = null,
    vkDeviceWaitIdle: ?vk.PfnDeviceWaitIdle = null,
    vkGetDeviceProcAddr: ?vk.PfnGetDeviceProcAddr = null,
    vkGetBufferMemoryRequirements: ?vk.PfnGetBufferMemoryRequirements = null,
    vkCmdSetViewport: ?vk.PfnCmdSetViewport = null,
    vkCmdSetScissor: ?vk.PfnCmdSetScissor = null,
};

/// Vulkan device dispatch wrapper — provides named helper methods for
/// all commands in HeavySlugDispatch. Load via DeviceDispatch.load(device, loader).
pub const DeviceDispatch = vk.DeviceWrapperWithCustomDispatch(HeavySlugDispatch);

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
    // Verify the filtered dispatch wrapper type is valid
    _ = DeviceDispatch;
    _ = @hasField(HeavySlugDispatch, "vkDestroyDevice");
    _ = @hasField(HeavySlugDispatch, "vkCreateBuffer");
    _ = @hasField(HeavySlugDispatch, "vkCmdDrawMeshTasksEXT");
}

test "HeavySlugDispatch has buffer and viewport commands" {
    comptime {
        std.debug.assert(@hasField(HeavySlugDispatch, "vkGetBufferMemoryRequirements"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetViewport"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetScissor"));
    }
}
