//! Optional backend module wiring for Vulkan and Metal.

const std = @import("std");
const shaders = @import("shaders.zig");
const swift = @import("swift.zig");

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
    spirv: shaders.SpirvBundle,
    gpu_structs_mod: *std.Build.Module,
    shader_stats: bool,
) ?VulkanBackend {
    const vk_headers = b.lazyDependency("vulkan_headers", .{});
    const vk_dep = b.lazyDependency("vulkan", .{});
    if (vk_headers == null or vk_dep == null) return null;

    const registry = vk_headers.?.path("registry/vk.xml");
    const vk_gen = vk_dep.?.artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.createModule(.{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });

    const mod = b.addModule("heavy_slug_vulkan", .{
        .root_source_file = b.path("src/backends/vulkan/root.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption(bool, "shader_stats", shader_stats);
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("vulkan", vulkan_zig);
    mod.addImport("spirv_shaders", spirv.module);
    mod.addImport("gpu_structs", gpu_structs_mod);
    mod.addOptions("heavy_slug_backend_options", options);

    return .{
        .module = mod,
        .bindings = vulkan_zig,
        .headers = vk_headers.?,
    };
}

pub fn buildMetal(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    msl: shaders.MslBundle,
    gpu_structs_mod: *std.Build.Module,
    shader_stats: bool,
) MetalBackend {
    if (target.result.os.tag != .macos) {
        @panic("the Swift Metal backend requires a macOS target");
    }

    const mod = b.addModule("heavy_slug_metal", .{
        .root_source_file = b.path("src/backends/metal/root.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption(bool, "shader_stats", shader_stats);
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("msl_shaders", msl.module);
    mod.addImport("gpu_structs", gpu_structs_mod);
    mod.addOptions("heavy_slug_backend_options", options);
    mod.addObjectFile(swift.addObject(b, .{
        .name = "HeavySlugMetalBridge",
        .source = b.path("src/backends/metal/bridge.swift"),
        .target = target,
        .optimize = optimize,
        .extra_flags = if (shader_stats) &.{"-DHEAVY_SLUG_SHADER_STATS"} else &.{},
    }));
    swift.linkRuntime(b, mod, .{ .target = target, .optimize = optimize });

    return .{ .module = mod };
}
