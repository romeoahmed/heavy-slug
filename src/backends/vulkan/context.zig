//! Wraps caller-owned Vulkan objects and validates heavy-slug device requirements.

const std = @import("std");
const vk = @import("vulkan");
const chains = @import("chains.zig");
const requirements = @import("requirements.zig");

/// Instance commands needed for device capability queries.
const HeavySlugInstanceDispatch = struct {
    vkGetPhysicalDeviceMemoryProperties: ?vk.PfnGetPhysicalDeviceMemoryProperties = null,
    vkGetPhysicalDeviceFeatures2: ?vk.PfnGetPhysicalDeviceFeatures2 = null,
    vkEnumerateDeviceExtensionProperties: ?vk.PfnEnumerateDeviceExtensionProperties = null,
    vkGetPhysicalDeviceProperties2: ?vk.PfnGetPhysicalDeviceProperties2 = null,
};

pub const InstanceDispatch = vk.InstanceWrapperWithCustomDispatch(HeavySlugInstanceDispatch);
pub const required_api_version = requirements.required_api_version;
pub const FeatureError = requirements.FeatureError;
pub const validateDeviceProperties = requirements.validateDeviceProperties;

/// Caller-owned Vulkan device plus loaded dispatch and queried properties.
///
/// Usage:
/// 1. Call `Context.checkDeviceSupport(physical_device, instance_dispatch)` to validate.
/// 2. Create a VkDevice with all extensions in `Context.required_device_extensions`
///    and `Context.requiredFeatureChain().rootInfo()` in the creation pNext chain.
/// 3. Call `try Context.init(physical_device, device, instance_dispatch, get_device_proc_addr)`.
/// 4. Use `Renderer.init(ctx, ...)` to create a renderer.
pub const Context = struct {
    device: vk.Device,
    dispatch: DeviceDispatch,
    physical_device: vk.PhysicalDevice,
    api_version: u32,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    mesh_shader_properties: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    shader_object_properties: vk.PhysicalDeviceShaderObjectPropertiesEXT,
    vulkan14_properties: vk.PhysicalDeviceVulkan14Properties,

    /// Required device extensions. Enable all of these in VkDeviceCreateInfo.
    pub const required_device_extensions = requirements.required_device_extensions;

    /// Feature pNext chain that callers can pass to VkDeviceCreateInfo.
    pub fn requiredFeatureChain() chains.FeatureChain {
        return requirements.requiredFeatureChain();
    }

    /// Validate physical device support before creating the VkDevice.
    /// Call before device creation to get a clear error if requirements are not met.
    /// The caller is still responsible for enabling these features and extensions in
    /// VkDeviceCreateInfo.
    pub fn checkDeviceSupport(
        physical_device: vk.PhysicalDevice,
        instance_dispatch: InstanceDispatch,
        allocator: std.mem.Allocator,
    ) (FeatureError || error{OutOfMemory})!void {
        const available = instance_dispatch.enumerateDeviceExtensionPropertiesAlloc(
            physical_device,
            null,
            allocator,
        ) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return FeatureError.ExtensionNotSupported,
        };
        defer allocator.free(available);

        try requirements.validateDeviceExtensions(available, &required_device_extensions);

        var properties2 = chains.physicalDeviceProperties2(null);
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, &properties2);
        try requirements.validateApiVersion(properties2.properties.api_version);

        var queried_properties = chains.PropertyChain.init();
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, queried_properties.rootInfo());
        try requirements.validateDeviceProperties(
            queried_properties.root.properties.api_version,
            queried_properties.mesh_shader,
            queried_properties.vulkan14,
        );

        var queried_features = chains.FeatureChain.init();
        instance_dispatch.getPhysicalDeviceFeatures2(physical_device, queried_features.rootInfo());
        try requirements.validateDeviceFeatures(queried_features);
    }

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
    ) FeatureError!Context {
        const dispatch = DeviceDispatch.load(device, get_device_proc_addr);
        const mem_props = instance_dispatch.getPhysicalDeviceMemoryProperties(physical_device);
        var queried_properties = chains.PropertyChain.init();
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, queried_properties.rootInfo());
        try requirements.validateDeviceProperties(
            queried_properties.root.properties.api_version,
            queried_properties.mesh_shader,
            queried_properties.vulkan14,
        );
        return .{
            .device = device,
            .dispatch = dispatch,
            .physical_device = physical_device,
            .api_version = queried_properties.root.properties.api_version,
            .memory_properties = mem_props,
            .mesh_shader_properties = queried_properties.mesh_shader,
            .shader_object_properties = queried_properties.shader_object,
            .vulkan14_properties = queried_properties.vulkan14,
        };
    }
};

/// Device commands used by the Vulkan backend.
const HeavySlugDispatch = struct {
    vkCreateDescriptorSetLayout: ?vk.PfnCreateDescriptorSetLayout = null,
    vkDestroyDescriptorSetLayout: ?vk.PfnDestroyDescriptorSetLayout = null,
    vkCreatePipelineLayout: ?vk.PfnCreatePipelineLayout = null,
    vkDestroyPipelineLayout: ?vk.PfnDestroyPipelineLayout = null,
    vkCreateShadersEXT: ?vk.PfnCreateShadersEXT = null,
    vkDestroyShaderEXT: ?vk.PfnDestroyShaderEXT = null,
    vkCreateBuffer: ?vk.PfnCreateBuffer = null,
    vkDestroyBuffer: ?vk.PfnDestroyBuffer = null,
    vkAllocateMemory: ?vk.PfnAllocateMemory = null,
    vkFreeMemory: ?vk.PfnFreeMemory = null,
    vkBindBufferMemory: ?vk.PfnBindBufferMemory = null,
    vkMapMemory: ?vk.PfnMapMemory = null,
    vkUnmapMemory: ?vk.PfnUnmapMemory = null,
    vkCmdBindShadersEXT: ?vk.PfnCmdBindShadersEXT = null,
    vkCmdPushDescriptorSet: ?vk.PfnCmdPushDescriptorSet = null,
    vkCmdPushConstants: ?vk.PfnCmdPushConstants = null,
    vkCmdDrawMeshTasksEXT: ?vk.PfnCmdDrawMeshTasksEXT = null,
    vkGetBufferMemoryRequirements: ?vk.PfnGetBufferMemoryRequirements = null,
    vkCmdSetViewportWithCount: ?vk.PfnCmdSetViewportWithCount = null,
    vkCmdSetScissorWithCount: ?vk.PfnCmdSetScissorWithCount = null,
    vkCmdBindVertexBuffers2: ?vk.PfnCmdBindVertexBuffers2 = null,
    vkCmdSetVertexInputEXT: ?vk.PfnCmdSetVertexInputEXT = null,
    vkCmdSetCullMode: ?vk.PfnCmdSetCullMode = null,
    vkCmdSetFrontFace: ?vk.PfnCmdSetFrontFace = null,
    vkCmdSetPrimitiveTopology: ?vk.PfnCmdSetPrimitiveTopology = null,
    vkCmdSetPrimitiveRestartEnable: ?vk.PfnCmdSetPrimitiveRestartEnable = null,
    vkCmdSetRasterizerDiscardEnable: ?vk.PfnCmdSetRasterizerDiscardEnable = null,
    vkCmdSetLineWidth: ?vk.PfnCmdSetLineWidth = null,
    vkCmdSetDepthBias: ?vk.PfnCmdSetDepthBias = null,
    vkCmdSetDepthBiasEnable: ?vk.PfnCmdSetDepthBiasEnable = null,
    vkCmdSetDepthTestEnable: ?vk.PfnCmdSetDepthTestEnable = null,
    vkCmdSetDepthWriteEnable: ?vk.PfnCmdSetDepthWriteEnable = null,
    vkCmdSetDepthCompareOp: ?vk.PfnCmdSetDepthCompareOp = null,
    vkCmdSetDepthBoundsTestEnable: ?vk.PfnCmdSetDepthBoundsTestEnable = null,
    vkCmdSetDepthBounds: ?vk.PfnCmdSetDepthBounds = null,
    vkCmdSetStencilTestEnable: ?vk.PfnCmdSetStencilTestEnable = null,
    vkCmdSetStencilCompareMask: ?vk.PfnCmdSetStencilCompareMask = null,
    vkCmdSetStencilWriteMask: ?vk.PfnCmdSetStencilWriteMask = null,
    vkCmdSetStencilReference: ?vk.PfnCmdSetStencilReference = null,
    vkCmdSetStencilOp: ?vk.PfnCmdSetStencilOp = null,
    vkCmdSetPatchControlPointsEXT: ?vk.PfnCmdSetPatchControlPointsEXT = null,
    vkCmdSetTessellationDomainOriginEXT: ?vk.PfnCmdSetTessellationDomainOriginEXT = null,
    vkCmdSetDepthClampEnableEXT: ?vk.PfnCmdSetDepthClampEnableEXT = null,
    vkCmdSetPolygonModeEXT: ?vk.PfnCmdSetPolygonModeEXT = null,
    vkCmdSetRasterizationSamplesEXT: ?vk.PfnCmdSetRasterizationSamplesEXT = null,
    vkCmdSetSampleMaskEXT: ?vk.PfnCmdSetSampleMaskEXT = null,
    vkCmdSetAlphaToCoverageEnableEXT: ?vk.PfnCmdSetAlphaToCoverageEnableEXT = null,
    vkCmdSetAlphaToOneEnableEXT: ?vk.PfnCmdSetAlphaToOneEnableEXT = null,
    vkCmdSetLogicOpEnableEXT: ?vk.PfnCmdSetLogicOpEnableEXT = null,
    vkCmdSetLogicOpEXT: ?vk.PfnCmdSetLogicOpEXT = null,
    vkCmdSetColorBlendEnableEXT: ?vk.PfnCmdSetColorBlendEnableEXT = null,
    vkCmdSetColorBlendEquationEXT: ?vk.PfnCmdSetColorBlendEquationEXT = null,
    vkCmdSetBlendConstants: ?vk.PfnCmdSetBlendConstants = null,
    vkCmdSetColorWriteMaskEXT: ?vk.PfnCmdSetColorWriteMaskEXT = null,
};

/// vulkan-zig wrapper loaded from `HeavySlugDispatch`.
pub const DeviceDispatch = vk.DeviceWrapperWithCustomDispatch(HeavySlugDispatch);

test "HeavySlugDispatch has buffer, viewport, and push descriptor commands" {
    comptime {
        std.debug.assert(@hasField(HeavySlugDispatch, "vkGetBufferMemoryRequirements"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCreateShadersEXT"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdBindShadersEXT"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetViewportWithCount"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetScissorWithCount"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetVertexInputEXT"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetColorBlendEquationEXT"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdPushDescriptorSet"));
    }
}

test "HeavySlugInstanceDispatch has feature query commands" {
    _ = InstanceDispatch;
    comptime {
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkGetPhysicalDeviceFeatures2"));
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkGetPhysicalDeviceMemoryProperties"));
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkEnumerateDeviceExtensionProperties"));
        std.debug.assert(@hasField(HeavySlugInstanceDispatch, "vkGetPhysicalDeviceProperties2"));
    }
}

test "required_device_extensions include mesh shader and shader object" {
    const exts = Context.required_device_extensions;
    try std.testing.expect(exts.len >= 2);
    var has_mesh = false;
    var has_shader_object = false;
    for (exts) |ext| {
        const slice = std.mem.span(ext);
        if (std.mem.eql(u8, slice, "VK_EXT_mesh_shader")) has_mesh = true;
        if (std.mem.eql(u8, slice, "VK_EXT_shader_object")) has_shader_object = true;
    }
    try std.testing.expect(has_mesh);
    try std.testing.expect(has_shader_object);
}

test "required_api_version is Vulkan 1.4" {
    try std.testing.expectEqual(vk.API_VERSION_1_4.toU32(), required_api_version);
}
