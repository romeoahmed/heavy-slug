//! Wraps caller-owned Vulkan objects and validates heavy-slug device requirements.

const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const chains = @import("chains.zig");

const mesh_limits = heavy_slug.gpu.mesh_limits;
const required_push_descriptors: u32 = 3;

/// Device extensions that callers must enable on the VkDevice.
const required_extensions = [_][*:0]const u8{
    "VK_EXT_mesh_shader",
};

/// Instance commands needed for device capability queries.
const HeavySlugInstanceDispatch = struct {
    vkGetPhysicalDeviceMemoryProperties: ?vk.PfnGetPhysicalDeviceMemoryProperties = null,
    vkGetPhysicalDeviceFeatures2: ?vk.PfnGetPhysicalDeviceFeatures2 = null,
    vkEnumerateDeviceExtensionProperties: ?vk.PfnEnumerateDeviceExtensionProperties = null,
    vkGetPhysicalDeviceProperties2: ?vk.PfnGetPhysicalDeviceProperties2 = null,
};

pub const InstanceDispatch = vk.InstanceWrapperWithCustomDispatch(HeavySlugInstanceDispatch);
pub const required_api_version = vk.API_VERSION_1_4.toU32();

fn validateApiVersion(api_version: u32) FeatureError!void {
    if (api_version < required_api_version) {
        return FeatureError.Vulkan14NotSupported;
    }
}

pub fn validateMeshShaderLimits(props: vk.PhysicalDeviceMeshShaderPropertiesEXT) FeatureError!void {
    if (props.max_task_work_group_total_count == 0 or
        props.max_task_work_group_count[0] == 0 or
        props.max_task_work_group_invocations < mesh_limits.task_group_size or
        props.max_task_work_group_size[0] < mesh_limits.task_group_size or
        props.max_task_payload_size < mesh_limits.task_payload_bytes or
        props.max_task_payload_and_shared_memory_size < mesh_limits.task_payload_bytes or
        props.max_mesh_work_group_total_count < mesh_limits.task_max_meshlets or
        props.max_mesh_work_group_count[0] < mesh_limits.task_max_meshlets or
        props.max_mesh_work_group_invocations < mesh_limits.mesh_thread_count or
        props.max_mesh_work_group_size[0] < mesh_limits.mesh_thread_count or
        props.max_mesh_output_vertices < mesh_limits.mesh_output_vertices or
        props.max_mesh_output_primitives < mesh_limits.mesh_output_primitives or
        props.max_mesh_payload_and_shared_memory_size < mesh_limits.mesh_payload_and_shared_bytes)
    {
        return FeatureError.MeshShaderLimitsNotSupported;
    }
}

pub fn validatePushDescriptorSupport(props: vk.PhysicalDeviceVulkan14Properties) FeatureError!void {
    if (props.max_push_descriptors < required_push_descriptors) {
        return FeatureError.PushDescriptorLimitNotSupported;
    }
}

pub fn validateDeviceProperties(
    api_version: u32,
    mesh_props: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    vk14_props: vk.PhysicalDeviceVulkan14Properties,
) FeatureError!void {
    try validateApiVersion(api_version);
    try validateMeshShaderLimits(mesh_props);
    try validatePushDescriptorSupport(vk14_props);
}

/// Caller-owned Vulkan device plus loaded dispatch and queried properties.
///
/// Usage:
/// 1. Call `VulkanContext.checkDeviceSupport(physical_device, instance_dispatch)` to validate
/// 2. Create a VkDevice with all extensions in `VulkanContext.required_device_extensions`
///    and the features validated by `checkDeviceSupport`
/// 3. Call `VulkanContext.init(physical_device, device, instance_dispatch, get_device_proc_addr)`
/// 4. Use `Renderer.init(ctx, ...)` to create a renderer
pub const VulkanContext = struct {
    device: vk.Device,
    dispatch: DeviceDispatch,
    physical_device: vk.PhysicalDevice,
    api_version: u32,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    mesh_shader_properties: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    vulkan14_properties: vk.PhysicalDeviceVulkan14Properties,

    /// Required device extensions. Enable all of these in VkDeviceCreateInfo.
    pub const required_device_extensions = required_extensions;

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

        var properties2 = chains.physicalDeviceProperties2(null);
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, &properties2);
        try validateApiVersion(properties2.properties.api_version);

        var mesh_properties = chains.meshShaderProperties();
        var vk14_properties = chains.vulkan14Properties(@ptrCast(&mesh_properties));
        properties2 = chains.physicalDeviceProperties2(@ptrCast(&vk14_properties));
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, &properties2);
        try validateDeviceProperties(properties2.properties.api_version, mesh_properties, vk14_properties);

        var mesh_features = chains.meshShaderFeatures();
        var vk14_features = chains.vulkan14Features(@ptrCast(&mesh_features));
        var vk13_features = chains.vulkan13Features(@ptrCast(&vk14_features));
        var features2 = chains.physicalDeviceFeatures2(@ptrCast(&vk13_features));
        instance_dispatch.getPhysicalDeviceFeatures2(physical_device, &features2);

        if (vk13_features.dynamic_rendering == .false) {
            return FeatureError.DynamicRenderingNotSupported;
        }
        if (mesh_features.task_shader == .false or mesh_features.mesh_shader == .false) {
            return FeatureError.MeshShaderNotSupported;
        }
        if (vk14_features.push_descriptor == .false) {
            return FeatureError.PushDescriptorNotSupported;
        }
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
    ) VulkanContext {
        const dispatch = DeviceDispatch.load(device, get_device_proc_addr);
        const mem_props = instance_dispatch.getPhysicalDeviceMemoryProperties(physical_device);
        var mesh_shader_properties = chains.meshShaderProperties();
        var vulkan14_properties = chains.vulkan14Properties(@ptrCast(&mesh_shader_properties));
        var properties2 = chains.physicalDeviceProperties2(@ptrCast(&vulkan14_properties));
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, &properties2);
        return .{
            .device = device,
            .dispatch = dispatch,
            .physical_device = physical_device,
            .api_version = properties2.properties.api_version,
            .memory_properties = mem_props,
            .mesh_shader_properties = mesh_shader_properties,
            .vulkan14_properties = vulkan14_properties,
        };
    }
};

/// Device commands used by the Vulkan backend.
const HeavySlugDispatch = struct {
    vkDestroyDevice: ?vk.PfnDestroyDevice = null,
    vkCreateDescriptorSetLayout: ?vk.PfnCreateDescriptorSetLayout = null,
    vkDestroyDescriptorSetLayout: ?vk.PfnDestroyDescriptorSetLayout = null,
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
    vkCmdBindPipeline: ?vk.PfnCmdBindPipeline = null,
    vkCmdPushDescriptorSet: ?vk.PfnCmdPushDescriptorSet = null,
    vkCmdPushConstants: ?vk.PfnCmdPushConstants = null,
    vkCmdDrawMeshTasksEXT: ?vk.PfnCmdDrawMeshTasksEXT = null,
    vkQueueSubmit2: ?vk.PfnQueueSubmit2 = null,
    vkDeviceWaitIdle: ?vk.PfnDeviceWaitIdle = null,
    vkGetDeviceProcAddr: ?vk.PfnGetDeviceProcAddr = null,
    vkGetBufferMemoryRequirements: ?vk.PfnGetBufferMemoryRequirements = null,
    vkCmdSetViewport: ?vk.PfnCmdSetViewport = null,
    vkCmdSetScissor: ?vk.PfnCmdSetScissor = null,
};

/// vulkan-zig wrapper loaded from `HeavySlugDispatch`.
pub const DeviceDispatch = vk.DeviceWrapperWithCustomDispatch(HeavySlugDispatch);

pub const FeatureError = error{
    Vulkan14NotSupported,
    MeshShaderNotSupported,
    MeshShaderLimitsNotSupported,
    DynamicRenderingNotSupported,
    PushDescriptorNotSupported,
    PushDescriptorLimitNotSupported,
    ExtensionNotSupported,
};

test "HeavySlugDispatch has buffer, viewport, and push descriptor commands" {
    comptime {
        std.debug.assert(@hasField(HeavySlugDispatch, "vkGetBufferMemoryRequirements"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetViewport"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetScissor"));
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

test "required_device_extensions includes mesh shader" {
    const exts = VulkanContext.required_device_extensions;
    try std.testing.expect(exts.len >= 1);
    var has_mesh = false;
    for (exts) |ext| {
        const slice = std.mem.span(ext);
        if (std.mem.eql(u8, slice, "VK_EXT_mesh_shader")) has_mesh = true;
    }
    try std.testing.expect(has_mesh);
}

test "required_api_version is Vulkan 1.4" {
    try std.testing.expectEqual(vk.API_VERSION_1_4.toU32(), required_api_version);
}

fn supportedMeshProps() vk.PhysicalDeviceMeshShaderPropertiesEXT {
    var props = chains.meshShaderProperties();
    props.max_task_work_group_total_count = 1;
    props.max_task_work_group_count = .{ 1, 1, 1 };
    props.max_task_work_group_invocations = mesh_limits.task_group_size;
    props.max_task_work_group_size = .{ mesh_limits.task_group_size, 1, 1 };
    props.max_task_payload_size = mesh_limits.task_payload_bytes;
    props.max_task_payload_and_shared_memory_size = mesh_limits.task_payload_bytes;
    props.max_mesh_work_group_total_count = mesh_limits.task_max_meshlets;
    props.max_mesh_work_group_count = .{ mesh_limits.task_max_meshlets, 1, 1 };
    props.max_mesh_work_group_invocations = mesh_limits.mesh_thread_count;
    props.max_mesh_work_group_size = .{ mesh_limits.mesh_thread_count, 1, 1 };
    props.max_mesh_output_vertices = mesh_limits.mesh_output_vertices;
    props.max_mesh_output_primitives = mesh_limits.mesh_output_primitives;
    props.max_mesh_payload_and_shared_memory_size = mesh_limits.mesh_payload_and_shared_bytes;
    return props;
}

fn supportedVulkan14Props() vk.PhysicalDeviceVulkan14Properties {
    var props = chains.vulkan14Properties(null);
    props.max_push_descriptors = required_push_descriptors;
    return props;
}

test "validateDeviceProperties requires Vulkan 1.4 and mesh shader budgets" {
    try validateDeviceProperties(vk.API_VERSION_1_4.toU32(), supportedMeshProps(), supportedVulkan14Props());

    try std.testing.expectError(
        FeatureError.Vulkan14NotSupported,
        validateDeviceProperties(vk.API_VERSION_1_3.toU32(), supportedMeshProps(), supportedVulkan14Props()),
    );

    var low_payload = supportedMeshProps();
    low_payload.max_task_payload_size = mesh_limits.task_payload_bytes - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_payload, supportedVulkan14Props()),
    );

    var no_task_grid = supportedMeshProps();
    no_task_grid.max_task_work_group_count[0] = 0;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), no_task_grid, supportedVulkan14Props()),
    );

    var low_mesh_grid = supportedMeshProps();
    low_mesh_grid.max_mesh_work_group_count[0] = mesh_limits.task_max_meshlets - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_mesh_grid, supportedVulkan14Props()),
    );

    var low_output = supportedMeshProps();
    low_output.max_mesh_output_vertices = mesh_limits.mesh_output_vertices - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_output, supportedVulkan14Props()),
    );
}

test "validateDeviceProperties requires enough Vulkan 1.4 push descriptors" {
    var low_push_descriptors = supportedVulkan14Props();
    low_push_descriptors.max_push_descriptors = required_push_descriptors - 1;
    try std.testing.expectError(
        FeatureError.PushDescriptorLimitNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), supportedMeshProps(), low_push_descriptors),
    );
}
