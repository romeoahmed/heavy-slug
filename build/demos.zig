//! Demo executable build helpers.

const std = @import("std");
const backends = @import("backends.zig");
const c_libs = @import("c_libs.zig");
const deps = @import("deps.zig");

pub fn buildVulkan(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    backend: backends.VulkanBackend,
    use_lto: bool,
) ?*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "heavy_slug_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo/vulkan/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = core_mod },
                .{ .name = "heavy_slug_vulkan", .module = backend.module },
                .{ .name = "vulkan", .module = backend.bindings },
            },
        }),
    });

    const glfw_dep = b.lazyDependency("glfw_src", .{}) orelse return null;
    const glfw_lib = c_libs.buildGlfw(b, glfw_dep, backend.headers, target, optimize);
    const glfw_c = c_libs.translateGlfwC(b, target, optimize, glfw_dep);
    const demo_glfw = buildDemoGlfwModule(b, target, optimize, glfw_c);
    const demo_scene = buildDemoSceneModule(b, target, optimize, core_mod, demo_glfw);

    exe.root_module.linkLibrary(glfw_lib);
    exe.root_module.addImport("glfw_c", glfw_c);
    exe.root_module.addImport("demo_glfw", demo_glfw);
    exe.root_module.addImport("demo_scene", demo_scene);
    exe.root_module.addIncludePath(glfw_dep.path("include"));

    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("wayland-client", .{});
        exe.root_module.linkSystemLibrary("wayland-cursor", .{});
        exe.root_module.linkSystemLibrary("wayland-egl", .{});
        exe.root_module.linkSystemLibrary("xkbcommon", .{});
    }

    deps.enableThinLtoAll(use_lto, &.{ glfw_lib, exe });
    return exe;
}

pub fn buildMetal(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    backend: backends.MetalBackend,
    use_lto: bool,
) ?*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "heavy_slug_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo/metal/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = core_mod },
                .{ .name = "heavy_slug_metal", .module = backend.module },
            },
        }),
    });

    const glfw_dep = b.lazyDependency("glfw_src", .{}) orelse return null;
    const glfw_lib = c_libs.buildGlfw(b, glfw_dep, null, target, optimize);
    const glfw_c = c_libs.translateGlfwC(b, target, optimize, glfw_dep);
    const demo_glfw = buildDemoGlfwModule(b, target, optimize, glfw_c);
    const demo_scene = buildDemoSceneModule(b, target, optimize, core_mod, demo_glfw);

    exe.root_module.linkLibrary(glfw_lib);
    exe.root_module.addImport("glfw_c", glfw_c);
    exe.root_module.addImport("demo_glfw", demo_glfw);
    exe.root_module.addImport("demo_scene", demo_scene);
    exe.root_module.addIncludePath(glfw_dep.path("include"));
    exe.root_module.addIncludePath(b.path("src/demo/metal"));
    exe.root_module.link_libcpp = true;
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src/demo/metal"),
        .files = &.{"host.mm"},
        .flags = &.{ "-std=c++17", "-fobjc-arc" },
    });

    deps.enableThinLtoAll(use_lto, &.{ glfw_lib, exe });
    return exe;
}

fn buildDemoGlfwModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_c: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/demo/common/glfw.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "glfw_c", .module = glfw_c }},
    });
}

fn buildDemoSceneModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    demo_glfw: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("src/demo/common/scene.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "heavy_slug", .module = core_mod },
            .{ .name = "demo_glfw", .module = demo_glfw },
        },
    });
}
