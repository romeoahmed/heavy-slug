//! Demo executable build helpers.

const std = @import("std");
const backends = @import("backends.zig");
const deps = @import("deps.zig");
const objcxx = @import("objcxx.zig");

const WaylandProtocol = struct {
    xml: []const u8,
    header: []const u8,
    code: []const u8,
};

const wayland_protocol_specs = [_]WaylandProtocol{
    .{
        .xml = "stable/xdg-shell/xdg-shell.xml",
        .header = "xdg-shell-client-protocol.h",
        .code = "xdg-shell-protocol.c",
    },
    .{
        .xml = "stable/viewporter/viewporter.xml",
        .header = "viewporter-client-protocol.h",
        .code = "viewporter-protocol.c",
    },
    .{
        .xml = "staging/fractional-scale/fractional-scale-v1.xml",
        .header = "fractional-scale-v1-client-protocol.h",
        .code = "fractional-scale-v1-protocol.c",
    },
    .{
        .xml = "stable/tablet/tablet-v2.xml",
        .header = "tablet-v2-client-protocol.h",
        .code = "tablet-v2-protocol.c",
    },
    .{
        .xml = "staging/cursor-shape/cursor-shape-v1.xml",
        .header = "cursor-shape-v1-client-protocol.h",
        .code = "cursor-shape-v1-protocol.c",
    },
};

comptime {
    for (wayland_protocol_specs) |protocol| {
        if (std.mem.startsWith(u8, protocol.xml, "unstable/")) {
            @compileError("Wayland demo protocol XML must use stable or staging paths");
        }
    }
}

const wayland_protocol_sources = protocolCodeFiles(&wayland_protocol_specs);

pub fn buildVulkan(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    backend: backends.VulkanBackend,
    thin_lto: bool,
) ?*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "heavy_slug_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/vulkan/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = core_mod },
                .{ .name = "heavy_slug_vulkan", .module = backend.module },
                .{ .name = "vulkan", .module = backend.bindings },
            },
        }),
    });

    const demo_input = buildDemoInputModule(b, target, optimize);
    const demo_scene = buildDemoSceneModule(b, target, optimize, core_mod, demo_input);
    const demo_platform = buildVulkanPlatformModule(b, target, optimize, backend.bindings, demo_input, exe) orelse return null;

    exe.root_module.addImport("demo_scene", demo_scene);
    exe.root_module.addImport("demo_platform", demo_platform);

    deps.enableThinLtoAll(thin_lto, &.{exe});
    return exe;
}

pub fn buildMetal(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    backend: backends.MetalBackend,
    thin_lto: bool,
) ?*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "heavy_slug_demo",
        .root_module = b.createModule(.{
            .root_source_file = b.path("demo/metal/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = core_mod },
                .{ .name = "heavy_slug_metal", .module = backend.module },
            },
        }),
    });

    const demo_input = buildDemoInputModule(b, target, optimize);
    const demo_scene = buildDemoSceneModule(b, target, optimize, core_mod, demo_input);
    const demo_platform = b.createModule(.{
        .root_source_file = b.path("demo/platform/cocoa.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "demo_input", .module = demo_input },
        },
    });

    exe.root_module.addImport("demo_scene", demo_scene);
    exe.root_module.addImport("demo_platform", demo_platform);
    exe.root_module.addIncludePath(b.path("demo/platform"));
    exe.root_module.link_libcpp = true;
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.addCSourceFiles(.{
        .root = b.path("demo/platform"),
        .files = &.{"cocoa.mm"},
        .flags = objcxx.flags(b, optimize, &.{}),
    });

    deps.enableThinLtoAll(thin_lto, &.{exe});
    return exe;
}

fn buildDemoInputModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("demo/common/input.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn buildDemoSceneModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    demo_input: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("demo/common/scene.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "heavy_slug", .module = core_mod },
            .{ .name = "demo_input", .module = demo_input },
        },
    });
}

fn buildVulkanPlatformModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    vulkan_mod: *std.Build.Module,
    demo_input: *std.Build.Module,
    exe: *std.Build.Step.Compile,
) ?*std.Build.Module {
    return switch (target.result.os.tag) {
        .windows => blk: {
            exe.root_module.linkSystemLibrary("user32", .{});
            exe.win32_manifest = b.path("demo/platform/windows.manifest");
            break :blk b.createModule(.{
                .root_source_file = b.path("demo/platform/windows.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "demo_input", .module = demo_input },
                    .{ .name = "vulkan", .module = vulkan_mod },
                },
            });
        },
        .linux => blk: {
            const wayland_protocols_src = b.lazyDependency("wayland_protocols_src", .{}) orelse return null;
            const generated_protocols = generateWaylandProtocols(b, wayland_protocols_src);
            const wayland_c = translateWaylandC(b, target, optimize, generated_protocols);
            exe.root_module.link_libc = true;
            exe.root_module.linkSystemLibrary("wayland-client", .{});
            exe.root_module.linkSystemLibrary("xkbcommon", .{});
            exe.root_module.addIncludePath(generated_protocols);
            exe.root_module.addCSourceFiles(.{
                .root = generated_protocols,
                .files = &wayland_protocol_sources,
            });
            break :blk b.createModule(.{
                .root_source_file = b.path("demo/platform/wayland.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "demo_input", .module = demo_input },
                    .{ .name = "vulkan", .module = vulkan_mod },
                    .{ .name = "wayland_c", .module = wayland_c },
                },
            });
        },
        else => @panic("Vulkan demo platform is supported only on Windows and Linux"),
    };
}

fn translateWaylandC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    wayland_protocols: std.Build.LazyPath,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("demo/platform/wayland.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(wayland_protocols);
    return translate.createModule();
}

fn protocolCodeFiles(comptime protocols: []const WaylandProtocol) [protocols.len][]const u8 {
    var files: [protocols.len][]const u8 = undefined;
    for (protocols, 0..) |protocol, index| {
        files[index] = protocol.code;
    }
    return files;
}

fn generateWaylandProtocols(
    b: *std.Build,
    wayland_protocols_src: *std.Build.Dependency,
) std.Build.LazyPath {
    const scanner = b.option([]const u8, "wayland-scanner", "Path or executable name for wayland-scanner") orelse "wayland-scanner";

    const wf = b.addWriteFiles();
    for (wayland_protocol_specs) |protocol| {
        const protocol_xml = wayland_protocols_src.path(protocol.xml);

        const header_cmd = b.addSystemCommand(&.{scanner});
        header_cmd.addArg("client-header");
        header_cmd.addFileArg(protocol_xml);
        const header = header_cmd.addOutputFileArg(protocol.header);

        const code_cmd = b.addSystemCommand(&.{scanner});
        code_cmd.addArg("private-code");
        code_cmd.addFileArg(protocol_xml);
        const code = code_cmd.addOutputFileArg(protocol.code);

        _ = wf.addCopyFile(header, protocol.header);
        _ = wf.addCopyFile(code, protocol.code);
    }
    return wf.getDirectory();
}
