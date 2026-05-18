//! Vulkan pNext chain initializers with explicit sType values.

const std = @import("std");
const vk = @import("vulkan");

pub fn meshShaderProperties() vk.PhysicalDeviceMeshShaderPropertiesEXT {
    var props = std.mem.zeroes(vk.PhysicalDeviceMeshShaderPropertiesEXT);
    props.s_type = .physical_device_mesh_shader_properties_ext;
    props.p_next = null;
    return props;
}

pub fn vulkan14Properties(p_next: ?*anyopaque) vk.PhysicalDeviceVulkan14Properties {
    var props = std.mem.zeroes(vk.PhysicalDeviceVulkan14Properties);
    props.s_type = .physical_device_vulkan_1_4_properties;
    props.p_next = p_next;
    return props;
}

pub fn shaderObjectProperties(p_next: ?*anyopaque) vk.PhysicalDeviceShaderObjectPropertiesEXT {
    var props = std.mem.zeroes(vk.PhysicalDeviceShaderObjectPropertiesEXT);
    props.s_type = .physical_device_shader_object_properties_ext;
    props.p_next = p_next;
    return props;
}

pub fn physicalDeviceProperties2(p_next: ?*anyopaque) vk.PhysicalDeviceProperties2 {
    var props = std.mem.zeroes(vk.PhysicalDeviceProperties2);
    props.s_type = .physical_device_properties_2;
    props.p_next = p_next;
    return props;
}

pub fn meshShaderFeatures() vk.PhysicalDeviceMeshShaderFeaturesEXT {
    var features = std.mem.zeroes(vk.PhysicalDeviceMeshShaderFeaturesEXT);
    features.s_type = .physical_device_mesh_shader_features_ext;
    features.p_next = null;
    return features;
}

pub fn vulkan14Features(p_next: ?*anyopaque) vk.PhysicalDeviceVulkan14Features {
    var features = std.mem.zeroes(vk.PhysicalDeviceVulkan14Features);
    features.s_type = .physical_device_vulkan_1_4_features;
    features.p_next = p_next;
    return features;
}

pub fn shaderObjectFeatures() vk.PhysicalDeviceShaderObjectFeaturesEXT {
    var features = std.mem.zeroes(vk.PhysicalDeviceShaderObjectFeaturesEXT);
    features.s_type = .physical_device_shader_object_features_ext;
    features.p_next = null;
    return features;
}

pub fn vulkan13Features(p_next: ?*anyopaque) vk.PhysicalDeviceVulkan13Features {
    var features = std.mem.zeroes(vk.PhysicalDeviceVulkan13Features);
    features.s_type = .physical_device_vulkan_1_3_features;
    features.p_next = p_next;
    return features;
}

pub fn physicalDeviceFeatures2(p_next: ?*anyopaque) vk.PhysicalDeviceFeatures2 {
    var features = std.mem.zeroes(vk.PhysicalDeviceFeatures2);
    features.s_type = .physical_device_features_2;
    features.p_next = p_next;
    return features;
}

pub const PropertyChain = struct {
    mesh_shader: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    shader_object: vk.PhysicalDeviceShaderObjectPropertiesEXT,
    vulkan14: vk.PhysicalDeviceVulkan14Properties,
    root: vk.PhysicalDeviceProperties2,

    pub fn init() PropertyChain {
        return .{
            .mesh_shader = meshShaderProperties(),
            .shader_object = shaderObjectProperties(null),
            .vulkan14 = vulkan14Properties(null),
            .root = physicalDeviceProperties2(null),
        };
    }

    pub fn rootInfo(self: *PropertyChain) *vk.PhysicalDeviceProperties2 {
        self.mesh_shader.p_next = null;
        self.shader_object.p_next = @ptrCast(&self.mesh_shader);
        self.vulkan14.p_next = @ptrCast(&self.shader_object);
        self.root.p_next = @ptrCast(&self.vulkan14);
        return &self.root;
    }
};

pub const FeatureChain = struct {
    mesh_shader: vk.PhysicalDeviceMeshShaderFeaturesEXT,
    shader_object: vk.PhysicalDeviceShaderObjectFeaturesEXT,
    vulkan14: vk.PhysicalDeviceVulkan14Features,
    vulkan13: vk.PhysicalDeviceVulkan13Features,
    root: vk.PhysicalDeviceFeatures2,

    pub fn init() FeatureChain {
        return .{
            .mesh_shader = meshShaderFeatures(),
            .shader_object = shaderObjectFeatures(),
            .vulkan14 = vulkan14Features(null),
            .vulkan13 = vulkan13Features(null),
            .root = physicalDeviceFeatures2(null),
        };
    }

    pub fn rootInfo(self: *FeatureChain) *vk.PhysicalDeviceFeatures2 {
        self.mesh_shader.p_next = null;
        self.shader_object.p_next = @ptrCast(&self.mesh_shader);
        self.vulkan14.p_next = @ptrCast(&self.shader_object);
        self.vulkan13.p_next = @ptrCast(&self.vulkan14);
        self.root.p_next = @ptrCast(&self.vulkan13);
        return &self.root;
    }

    pub fn enableRendererFeatures(self: *FeatureChain) void {
        self.vulkan13.dynamic_rendering = .true;
        self.vulkan14.push_descriptor = .true;
        self.shader_object.shader_object = .true;
        self.mesh_shader.task_shader = .true;
        self.mesh_shader.mesh_shader = .true;
    }

    pub fn enableSynchronization2(self: *FeatureChain) void {
        self.vulkan13.synchronization_2 = .true;
    }

    pub fn hasRendererFeatures(self: FeatureChain) bool {
        return self.vulkan13.dynamic_rendering == .true and
            self.vulkan14.push_descriptor == .true and
            self.shader_object.shader_object == .true and
            self.mesh_shader.task_shader == .true and
            self.mesh_shader.mesh_shader == .true;
    }

    pub fn hasSynchronization2(self: FeatureChain) bool {
        return self.vulkan13.synchronization_2 == .true;
    }
};

test "properties2 chain roots keep sType and zeroed payloads" {
    var mesh_props = meshShaderProperties();
    var shader_object_props = shaderObjectProperties(@ptrCast(&mesh_props));
    var vk14_props = vulkan14Properties(@ptrCast(&shader_object_props));
    const properties2 = physicalDeviceProperties2(@ptrCast(&vk14_props));

    try std.testing.expectEqual(vk.StructureType.physical_device_properties_2, properties2.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_vulkan_1_4_properties, vk14_props.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_shader_object_properties_ext, shader_object_props.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_mesh_shader_properties_ext, mesh_props.s_type);
    try std.testing.expectEqual(@as(u32, 0), properties2.properties.api_version);
}

test "features2 chain roots keep sType values" {
    var mesh_features = meshShaderFeatures();
    var shader_object_features = shaderObjectFeatures();
    shader_object_features.p_next = @ptrCast(&mesh_features);
    var vk14_features = vulkan14Features(@ptrCast(&shader_object_features));
    var vk13_features = vulkan13Features(@ptrCast(&vk14_features));
    const features2 = physicalDeviceFeatures2(@ptrCast(&vk13_features));

    try std.testing.expectEqual(vk.StructureType.physical_device_features_2, features2.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_vulkan_1_3_features, vk13_features.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_vulkan_1_4_features, vk14_features.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_shader_object_features_ext, shader_object_features.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_mesh_shader_features_ext, mesh_features.s_type);
}

test "PropertyChain wires Vulkan 1.4 and mesh shader property queries" {
    var chain = PropertyChain.init();
    const root = chain.rootInfo();

    try std.testing.expectEqual(vk.StructureType.physical_device_properties_2, root.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_vulkan_1_4_properties, chain.vulkan14.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_shader_object_properties_ext, chain.shader_object.s_type);
    try std.testing.expectEqual(vk.StructureType.physical_device_mesh_shader_properties_ext, chain.mesh_shader.s_type);
    try std.testing.expect(root.p_next != null);
    try std.testing.expect(chain.vulkan14.p_next != null);
    try std.testing.expect(chain.shader_object.p_next != null);
}

test "FeatureChain enables renderer and demo feature bits" {
    var chain = FeatureChain.init();
    try std.testing.expect(!chain.hasRendererFeatures());
    try std.testing.expect(!chain.hasSynchronization2());

    _ = chain.rootInfo();
    chain.enableRendererFeatures();
    try std.testing.expect(chain.hasRendererFeatures());
    try std.testing.expect(!chain.hasSynchronization2());

    chain.enableSynchronization2();
    try std.testing.expect(chain.hasSynchronization2());
}
