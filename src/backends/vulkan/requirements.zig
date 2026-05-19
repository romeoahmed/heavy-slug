//! Vulkan device requirements for the heavy_slug shader-object backend.

const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const chains = @import("chains.zig");

const mesh_limits = heavy_slug.gpu.mesh_limits;
const resource_model = heavy_slug.gpu.resource_model;

pub const required_api_version = vk.API_VERSION_1_4.toU32();
pub const required_push_descriptors: u32 = resource_model.max_descriptor_binding_count;

pub const required_device_extensions = [_][*:0]const u8{
    "VK_EXT_mesh_shader",
    "VK_EXT_shader_object",
};

pub const FeatureError = error{
    Vulkan14NotSupported,
    MeshShaderNotSupported,
    MeshShaderLimitsNotSupported,
    DynamicRenderingNotSupported,
    PushDescriptorNotSupported,
    PushDescriptorLimitNotSupported,
    ShaderObjectNotSupported,
    ExtensionNotSupported,
};

pub fn requiredFeatureChain() chains.FeatureChain {
    var features = chains.FeatureChain.init();
    features.enableRendererFeatures();
    return features;
}

pub fn validateApiVersion(api_version: u32) FeatureError!void {
    if (api_version < required_api_version) {
        return FeatureError.Vulkan14NotSupported;
    }
}

pub fn validateDeviceExtensions(
    available: []const vk.ExtensionProperties,
    required_extensions: []const [*:0]const u8,
) FeatureError!void {
    for (required_extensions) |required| {
        const req_name = std.mem.span(required);
        for (available) |extension| {
            const ext_name = std.mem.sliceTo(&extension.extension_name, 0);
            if (std.mem.eql(u8, ext_name, req_name)) break;
        } else {
            return FeatureError.ExtensionNotSupported;
        }
    }
}

pub fn validateMeshShaderLimits(props: vk.PhysicalDeviceMeshShaderPropertiesEXT) FeatureError!void {
    const output_bytes = mesh_limits.outputMemoryBytes(
        props.mesh_output_per_vertex_granularity,
        props.mesh_output_per_primitive_granularity,
    );
    const payload_output_bytes = mesh_limits.payloadAndOutputMemoryBytes(
        props.mesh_output_per_vertex_granularity,
        props.mesh_output_per_primitive_granularity,
    );

    if (props.max_mesh_work_group_total_count == 0 or
        props.max_mesh_work_group_count[0] == 0 or
        props.max_mesh_work_group_invocations < mesh_limits.mesh_thread_count or
        props.max_mesh_work_group_size[0] < mesh_limits.mesh_workgroup_size[0] or
        props.max_mesh_work_group_size[1] < mesh_limits.mesh_workgroup_size[1] or
        props.max_mesh_work_group_size[2] < mesh_limits.mesh_workgroup_size[2] or
        props.max_mesh_output_vertices < mesh_limits.mesh_output_vertices or
        props.max_mesh_output_primitives < mesh_limits.mesh_output_primitives or
        props.max_mesh_output_components < mesh_limits.mesh_output_components_per_vertex or
        props.max_mesh_shared_memory_size < mesh_limits.mesh_shared_bytes or
        props.max_mesh_payload_and_shared_memory_size < mesh_limits.mesh_payload_and_shared_bytes or
        props.max_mesh_output_memory_size < output_bytes or
        props.max_mesh_payload_and_output_memory_size < payload_output_bytes)
    {
        return FeatureError.MeshShaderLimitsNotSupported;
    }
}

pub fn validateVulkan14Properties(props: vk.PhysicalDeviceVulkan14Properties) FeatureError!void {
    if (props.max_push_descriptors < required_push_descriptors) {
        return FeatureError.PushDescriptorLimitNotSupported;
    }
}

pub fn validateShaderObjectSupport(features: vk.PhysicalDeviceShaderObjectFeaturesEXT) FeatureError!void {
    if (features.shader_object == .false) {
        return FeatureError.ShaderObjectNotSupported;
    }
}

pub fn validateDeviceProperties(
    api_version: u32,
    mesh_props: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    vk14_props: vk.PhysicalDeviceVulkan14Properties,
) FeatureError!void {
    try validateApiVersion(api_version);
    try validateMeshShaderLimits(mesh_props);
    try validateVulkan14Properties(vk14_props);
}

pub fn validateDeviceFeatures(features: chains.FeatureChain) FeatureError!void {
    if (features.vulkan13.dynamic_rendering == .false) {
        return FeatureError.DynamicRenderingNotSupported;
    }
    if (features.mesh_shader.mesh_shader == .false) {
        return FeatureError.MeshShaderNotSupported;
    }
    try validateShaderObjectSupport(features.shader_object);
    if (features.vulkan14.push_descriptor == .false) {
        return FeatureError.PushDescriptorNotSupported;
    }
}

fn supportedMeshProps() vk.PhysicalDeviceMeshShaderPropertiesEXT {
    var props = chains.meshShaderProperties();
    props.max_task_work_group_total_count = 0;
    props.max_task_work_group_count = .{ 0, 0, 0 };
    props.max_task_work_group_invocations = 0;
    props.max_task_work_group_size = .{ 0, 0, 0 };
    props.max_task_payload_size = 0;
    props.max_task_payload_and_shared_memory_size = 0;
    props.max_mesh_work_group_total_count = mesh_limits.maxMeshletsForGlyphCapacity(16_384);
    props.max_mesh_work_group_count = .{ mesh_limits.maxMeshletsForGlyphCapacity(16_384), 1, 1 };
    props.max_mesh_work_group_invocations = mesh_limits.mesh_thread_count;
    props.max_mesh_work_group_size = mesh_limits.mesh_workgroup_size;
    props.max_mesh_shared_memory_size = mesh_limits.mesh_shared_bytes;
    props.max_mesh_output_vertices = mesh_limits.mesh_output_vertices;
    props.max_mesh_output_primitives = mesh_limits.mesh_output_primitives;
    props.max_mesh_output_components = mesh_limits.mesh_output_components_per_vertex;
    props.max_mesh_payload_and_shared_memory_size = mesh_limits.mesh_payload_and_shared_bytes;
    props.mesh_output_per_vertex_granularity = 1;
    props.mesh_output_per_primitive_granularity = 1;
    props.max_mesh_output_memory_size = mesh_limits.outputMemoryBytes(1, 1);
    props.max_mesh_payload_and_output_memory_size = mesh_limits.payloadAndOutputMemoryBytes(1, 1);
    return props;
}

fn supportedVulkan14Props() vk.PhysicalDeviceVulkan14Properties {
    var props = chains.vulkan14Properties(null);
    props.max_push_descriptors = required_push_descriptors;
    return props;
}

test "required device extensions name mesh shader and shader object" {
    var has_mesh = false;
    var has_shader_object = false;
    for (required_device_extensions) |ext| {
        const slice = std.mem.span(ext);
        if (std.mem.eql(u8, slice, "VK_EXT_mesh_shader")) has_mesh = true;
        if (std.mem.eql(u8, slice, "VK_EXT_shader_object")) has_shader_object = true;
    }
    try std.testing.expect(has_mesh);
    try std.testing.expect(has_shader_object);
}

test "required API version is Vulkan 1.4" {
    try std.testing.expectEqual(vk.API_VERSION_1_4.toU32(), required_api_version);
}

test "validateDeviceProperties requires Vulkan 1.4 and mesh shader budgets" {
    try validateDeviceProperties(vk.API_VERSION_1_4.toU32(), supportedMeshProps(), supportedVulkan14Props());

    try std.testing.expectError(
        FeatureError.Vulkan14NotSupported,
        validateDeviceProperties(vk.API_VERSION_1_3.toU32(), supportedMeshProps(), supportedVulkan14Props()),
    );

    var low_mesh_grid = supportedMeshProps();
    low_mesh_grid.max_mesh_work_group_count[0] = 0;
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

    var low_output_components = supportedMeshProps();
    low_output_components.max_mesh_output_components = mesh_limits.mesh_output_components_per_vertex - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_output_components, supportedVulkan14Props()),
    );

    var low_workgroup_y = supportedMeshProps();
    low_workgroup_y.max_mesh_work_group_size[1] = 0;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_workgroup_y, supportedVulkan14Props()),
    );

    var low_shared = supportedMeshProps();
    low_shared.max_mesh_shared_memory_size = mesh_limits.mesh_shared_bytes - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_shared, supportedVulkan14Props()),
    );

    var low_output_memory = supportedMeshProps();
    low_output_memory.max_mesh_output_memory_size = mesh_limits.outputMemoryBytes(1, 1) - 1;
    try std.testing.expectError(
        FeatureError.MeshShaderLimitsNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), low_output_memory, supportedVulkan14Props()),
    );
}

test "validateShaderObjectSupport requires shaderObject feature" {
    var features = chains.shaderObjectFeatures();
    try std.testing.expectError(FeatureError.ShaderObjectNotSupported, validateShaderObjectSupport(features));
    features.shader_object = .true;
    try validateShaderObjectSupport(features);
}

test "validateDeviceProperties requires enough Vulkan 1.4 push descriptors" {
    var low_push_descriptors = supportedVulkan14Props();
    low_push_descriptors.max_push_descriptors = required_push_descriptors - 1;
    try std.testing.expectError(
        FeatureError.PushDescriptorLimitNotSupported,
        validateDeviceProperties(vk.API_VERSION_1_4.toU32(), supportedMeshProps(), low_push_descriptors),
    );
}

test "validateDeviceExtensions reports missing required extension" {
    const available = [_]vk.ExtensionProperties{
        .{ .extension_name = extensionName("VK_EXT_mesh_shader"), .spec_version = 1 },
    };
    try std.testing.expectError(
        FeatureError.ExtensionNotSupported,
        validateDeviceExtensions(&available, &required_device_extensions),
    );
}

fn extensionName(comptime name: []const u8) [vk.MAX_EXTENSION_NAME_SIZE]u8 {
    comptime {
        if (name.len >= vk.MAX_EXTENSION_NAME_SIZE) @compileError("extension name too long");
    }
    var out = [_]u8{0} ** vk.MAX_EXTENSION_NAME_SIZE;
    @memcpy(out[0..name.len], name);
    return out;
}
