//! VulkanContext: wraps a caller-provided Vulkan device.
//! Loads the device dispatch table, queries physical device properties,
//! and validates that required features/extensions are supported.

const std = @import("std");
const vk = @import("vulkan");

/// Required device extensions for heavy-slug.
/// Callers must enable these when creating the VkDevice.
const required_extensions = [_][*:0]const u8{
    "VK_EXT_mesh_shader",
    "VK_EXT_robustness2",
};

/// Filtered instance dispatch — only the commands heavy-slug needs
/// for physical device feature/property queries.
const HeavySlugInstanceDispatch = struct {
    vkGetPhysicalDeviceMemoryProperties: ?vk.PfnGetPhysicalDeviceMemoryProperties = null,
    vkGetPhysicalDeviceFeatures2: ?vk.PfnGetPhysicalDeviceFeatures2 = null,
    vkEnumerateDeviceExtensionProperties: ?vk.PfnEnumerateDeviceExtensionProperties = null,
    vkGetPhysicalDeviceProperties2: ?vk.PfnGetPhysicalDeviceProperties2 = null,
};

pub const InstanceDispatch = vk.InstanceWrapperWithCustomDispatch(HeavySlugInstanceDispatch);

/// Wraps a caller-provided Vulkan device with a loaded dispatch table
/// and cached physical device properties.
///
/// Usage:
/// 1. Call `VulkanContext.checkDeviceSupport(physical_device, instance_dispatch)` to validate
/// 2. Create a VkDevice with all extensions in `VulkanContext.required_device_extensions`
/// 3. Call `VulkanContext.init(physical_device, device, instance_dispatch, get_device_proc_addr)`
/// 4. Use `TextRenderer.initFromContext(ctx, ...)` to create a renderer
pub const VulkanContext = struct {
    device: vk.Device,
    dispatch: DeviceDispatch,
    physical_device: vk.PhysicalDevice,
    memory_properties: vk.PhysicalDeviceMemoryProperties,

    /// Required device extensions. Enable all of these in VkDeviceCreateInfo.
    pub const required_device_extensions = required_extensions;

    /// Validate physical device support before creating the VkDevice.
    /// See top-level checkDeviceSupport_impl for full documentation.
    pub const checkDeviceSupport = checkDeviceSupport_impl;

    /// Wrap a caller-provided device. Loads the device dispatch table and
    /// queries physical device memory properties.
    ///
    /// - `physical_device`: the VkPhysicalDevice the device was created from.
    /// - `device`: a VkDevice created with `required_device_extensions` enabled.
    /// - `instance_dispatch`: an InstanceDispatch loaded for the parent VkInstance.
    /// - `get_device_proc_addr`: obtained via `vkGetInstanceProcAddr(instance, "vkGetDeviceProcAddr")`
    ///   or from your Vulkan loader. Used to load the device dispatch table.
    pub fn init(
        physical_device: vk.PhysicalDevice,
        device: vk.Device,
        instance_dispatch: InstanceDispatch,
        get_device_proc_addr: vk.PfnGetDeviceProcAddr,
    ) VulkanContext {
        const dispatch = DeviceDispatch.load(device, get_device_proc_addr);
        const mem_props = instance_dispatch.getPhysicalDeviceMemoryProperties(physical_device);
        return .{
            .device = device,
            .dispatch = dispatch,
            .physical_device = physical_device,
            .memory_properties = mem_props,
        };
    }
};

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

pub const FeatureError = error{
    MeshShaderNotSupported,
    Robustness2NotSupported,
    ExtensionNotSupported,
};

/// Validate that the physical device supports all extensions and features required
/// by heavy-slug. Call this before creating the VkDevice to get a clear error if
/// requirements are not met. The caller is still responsible for enabling these
/// features and extensions in VkDeviceCreateInfo.
fn checkDeviceSupport_impl(
    physical_device: vk.PhysicalDevice,
    instance_dispatch: InstanceDispatch,
    allocator: std.mem.Allocator,
) (FeatureError || error{OutOfMemory})!void {
    // --- Extension validation ---
    const available = instance_dispatch.enumerateDeviceExtensionPropertiesAlloc(
        physical_device,
        null,
        allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return FeatureError.ExtensionNotSupported,
    };
    defer allocator.free(available);

    for (required_extensions) |required| {
        const req_name = std.mem.span(required);
        var found = false;
        for (available) |ext| {
            const ext_name = std.mem.sliceTo(&ext.extension_name, 0);
            if (std.mem.eql(u8, ext_name, req_name)) {
                found = true;
                break;
            }
        }
        if (!found) return FeatureError.ExtensionNotSupported;
    }

    // --- Feature validation ---
    var mesh_features = vk.PhysicalDeviceMeshShaderFeaturesEXT{};
    var robustness_features = vk.PhysicalDeviceRobustness2FeaturesEXT{
        .p_next = @ptrCast(&mesh_features),
    };
    var features2 = vk.PhysicalDeviceFeatures2{
        .p_next = @ptrCast(&robustness_features),
        .features = .{},
    };
    instance_dispatch.getPhysicalDeviceFeatures2(physical_device, &features2);

    if (mesh_features.task_shader == .false or mesh_features.mesh_shader == .false) {
        return FeatureError.MeshShaderNotSupported;
    }
    if (robustness_features.null_descriptor == .false) {
        return FeatureError.Robustness2NotSupported;
    }
}

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

test "InstanceDispatch type compiles" {
    _ = InstanceDispatch;
    comptime {
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkGetPhysicalDeviceFeatures2"));
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkGetPhysicalDeviceMemoryProperties"));
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkEnumerateDeviceExtensionProperties"));
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkGetPhysicalDeviceProperties2"));
    }
}

test "checkDeviceSupport function signature compiles" {
    _ = @TypeOf(VulkanContext.checkDeviceSupport);
}

test "VulkanContext has expected fields" {
    try std.testing.expect(@hasField(VulkanContext, "device"));
    try std.testing.expect(@hasField(VulkanContext, "dispatch"));
    try std.testing.expect(@hasField(VulkanContext, "physical_device"));
    try std.testing.expect(@hasField(VulkanContext, "memory_properties"));
}

test "required_device_extensions includes mesh shader and robustness2" {
    const exts = VulkanContext.required_device_extensions;
    try std.testing.expect(exts.len >= 2);
    var has_mesh = false;
    var has_robustness = false;
    for (exts) |ext| {
        const slice = std.mem.span(ext);
        if (std.mem.eql(u8, slice, "VK_EXT_mesh_shader")) has_mesh = true;
        if (std.mem.eql(u8, slice, "VK_EXT_robustness2")) has_robustness = true;
    }
    try std.testing.expect(has_mesh);
    try std.testing.expect(has_robustness);
}
