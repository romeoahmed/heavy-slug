//! Wraps caller-owned Vulkan objects and validates heavy-slug device requirements.

const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");

const mesh_limits = heavy_slug.gpu.mesh_limits;

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
    if (props.max_task_work_group_invocations < mesh_limits.task_group_size or
        props.max_task_work_group_size[0] < mesh_limits.task_group_size or
        props.max_task_payload_size < mesh_limits.task_payload_bytes or
        props.max_task_payload_and_shared_memory_size < mesh_limits.task_payload_bytes or
        props.max_mesh_work_group_invocations < mesh_limits.mesh_thread_count or
        props.max_mesh_work_group_size[0] < mesh_limits.mesh_thread_count or
        props.max_mesh_output_vertices < mesh_limits.mesh_output_vertices or
        props.max_mesh_output_primitives < mesh_limits.mesh_output_primitives or
        props.max_mesh_payload_and_shared_memory_size < mesh_limits.mesh_payload_and_shared_bytes)
    {
        return FeatureError.MeshShaderLimitsNotSupported;
    }
}

pub fn validateDeviceProperties(
    api_version: u32,
    mesh_props: vk.PhysicalDeviceMeshShaderPropertiesEXT,
) FeatureError!void {
    try validateApiVersion(api_version);
    try validateMeshShaderLimits(mesh_props);
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

        var mesh_properties = vk.PhysicalDeviceMeshShaderPropertiesEXT{};
        var properties2 = vk.PhysicalDeviceProperties2{
            .p_next = @ptrCast(&mesh_properties),
            .properties = .{},
        };
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, &properties2);
        try validateDeviceProperties(properties2.properties.api_version, mesh_properties);

        var mesh_features = vk.PhysicalDeviceMeshShaderFeaturesEXT{};
        var vk14_features = vk.PhysicalDeviceVulkan14Features{
            .p_next = @ptrCast(&mesh_features),
        };
        var vk13_features = vk.PhysicalDeviceVulkan13Features{
            .p_next = @ptrCast(&vk14_features),
        };
        var features2 = vk.PhysicalDeviceFeatures2{
            .p_next = @ptrCast(&vk13_features),
            .features = .{},
        };
        instance_dispatch.getPhysicalDeviceFeatures2(physical_device, &features2);

        if (vk13_features.dynamic_rendering == .false) {
            return FeatureError.DynamicRenderingNotSupported;
        }
        if (mesh_features.task_shader == .false or mesh_features.mesh_shader == .false) {
            return FeatureError.MeshShaderNotSupported;
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
        var mesh_shader_properties = vk.PhysicalDeviceMeshShaderPropertiesEXT{};
        var properties2 = vk.PhysicalDeviceProperties2{
            .p_next = @ptrCast(&mesh_shader_properties),
            .properties = .{},
        };
        instance_dispatch.getPhysicalDeviceProperties2(physical_device, &properties2);
        return .{
            .device = device,
            .dispatch = dispatch,
            .physical_device = physical_device,
            .api_version = properties2.properties.api_version,
            .memory_properties = mem_props,
            .mesh_shader_properties = mesh_shader_properties,
        };
    }
};

/// Device commands used by the Vulkan backend.
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

/// vulkan-zig wrapper loaded from `HeavySlugDispatch`.
pub const DeviceDispatch = vk.DeviceWrapperWithCustomDispatch(HeavySlugDispatch);

pub const FeatureError = error{
    Vulkan14NotSupported,
    MeshShaderNotSupported,
    MeshShaderLimitsNotSupported,
    DynamicRenderingNotSupported,
    ExtensionNotSupported,
};

test "HeavySlugDispatch has buffer and viewport commands" {
    comptime {
        std.debug.assert(@hasField(HeavySlugDispatch, "vkGetBufferMemoryRequirements"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetViewport"));
        std.debug.assert(@hasField(HeavySlugDispatch, "vkCmdSetScissor"));
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
    var props = std.mem.zeroes(vk.PhysicalDeviceMeshShaderPropertiesEXT);
    props.max_task_work_group_invocations = mesh_limits.task_group_size;
    props.max_task_work_group_size = .{ mesh_limits.task_group_size, 1, 1 };
    props.max_task_payload_size = mesh_limits.task_payload_bytes;
    props.max_task_payload_and_shared_memory_size = mesh_limits.task_payload_bytes;
    props.max_mesh_work_group_invocations = mesh_limits.mesh_thread_count;
    props.max_mesh_work_group_size = .{ mesh_limits.mesh_thread_count, 1, 1 };
    props.max_mesh_output_vertices = mesh_limits.mesh_output_vertices;
    props.max_mesh_output_primitives = mesh_limits.mesh_output_primitives;
    props.max_mesh_payload_and_shared_memory_size = mesh_limits.mesh_payload_and_shared_bytes;
    return props;
}

test "validateDeviceProperties requires Vulkan 1.4 and mesh shader budgets" {
    try validateDeviceProperties(vk.API_VERSION_1_4.toU32(), supportedMeshProps());

    try std.testing.expectError(
        FeatureError.Vulkan14NotSupported,
        validateDeviceProperties(vk.API_VERSION_1_3.toU32(), supportedMeshProps()),
    );

    var low_payload = supportedMeshProps();
    low_payload.max_task_payload_size = mesh_limits.task_payload_bytes - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_payload),
    );

    var low_output = supportedMeshProps();
    low_output.max_mesh_output_vertices = mesh_limits.mesh_output_vertices - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_output),
    );
}
