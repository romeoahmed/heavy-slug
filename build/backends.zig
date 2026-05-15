const std = @import("std");
const shaders = @import("shaders.zig");

pub const VulkanBackend = struct {
    module: *std.Build.Module,
    bindings: *std.Build.Module,
    headers: *std.Build.Dependency,
};

pub const MetalBackend = struct {
    module: *std.Build.Module,
};

pub fn buildVulkan(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    core_mod: *std.Build.Module,
    spirv: shaders.SpirvShaders,
) ?VulkanBackend {
    const vk_headers = b.lazyDependency("vulkan_headers", .{});
    const vk_dep = b.lazyDependency("vulkan", .{});
    if (vk_headers == null or vk_dep == null) return null;

    const registry = vk_headers.?.path("registry/vk.xml");
    const vk_gen = vk_dep.?.artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.addModule("vulkan-zig", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });

    const reflection_json = shaders.generateReflectionJson(b);
    const gpu_structs_zig = shaders.generateGpuStructs(b, reflection_json);
    const gpu_structs_mod = b.addModule("gpu_structs", .{ .root_source_file = gpu_structs_zig });

    const mod = b.addModule("heavy_slug_vulkan", .{
        .root_source_file = b.path("src/backends/vulkan/root.zig"),
        .target = target,
    });
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("vulkan", vulkan_zig);
    mod.addImport("shader_spv", spirv.module);
    mod.addImport("gpu_structs", gpu_structs_mod);

    return .{
        .module = mod,
        .bindings = vulkan_zig,
        .headers = vk_headers.?,
    };
}

pub fn buildMetal(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    core_mod: *std.Build.Module,
    metal_shaders: shaders.MetalShaders,
) MetalBackend {
    const reflection_json = shaders.generateReflectionJson(b);
    const gpu_structs_zig = shaders.generateGpuStructs(b, reflection_json);
    const gpu_structs_mod = b.addModule("gpu_structs", .{ .root_source_file = gpu_structs_zig });

    const mod = b.addModule("heavy_slug_metal", .{
        .root_source_file = b.path("src/backends/metal/root.zig"),
        .target = target,
    });
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("metal_shaders", metal_shaders.module);
    mod.addImport("gpu_structs", gpu_structs_mod);
    mod.addIncludePath(b.path("src/backends/metal"));
    mod.link_libcpp = true;
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("Foundation", .{});
    mod.addCSourceFiles(.{
        .root = b.path("src/backends/metal"),
        .files = &.{"bridge.mm"},
        .flags = &.{ "-std=c++17", "-fobjc-arc" },
    });

    return .{ .module = mod };
}
