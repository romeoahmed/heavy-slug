//! Optional backend module wiring for Vulkan and Metal.

const std = @import("std");
const objcxx = @import("objcxx.zig");
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
    const metal_c = translateMetalC(b, target, optimize, shader_stats);
    const mod = b.addModule("heavy_slug_metal", .{
        .root_source_file = b.path("src/backends/metal/root.zig"),
        .target = target,
    });
    const options = b.addOptions();
    options.addOption(bool, "shader_stats", shader_stats);
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("msl_shaders", msl.module);
    mod.addImport("gpu_structs", gpu_structs_mod);
    mod.addImport("metal_c", metal_c);
    mod.addOptions("heavy_slug_backend_options", options);
    mod.addIncludePath(b.path("src/backends/metal"));
    mod.link_libcpp = true;
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("Foundation", .{});
    mod.addCSourceFiles(.{
        .root = b.path("src/backends/metal"),
        .files = &.{"bridge.mm"},
        .flags = objcxx.flags(b, optimize, &.{
            if (shader_stats) "-DHEAVY_SLUG_SHADER_STATS=1" else "-DHEAVY_SLUG_SHADER_STATS=0",
        }),
    });

    return .{ .module = mod };
}

fn translateMetalC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    shader_stats: bool,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/backends/metal/bridge.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(b.path("src/backends/metal"));
    translate.defineCMacro("HEAVY_SLUG_SHADER_STATS", if (shader_stats) "1" else "0");
    return translate.createModule();
}
