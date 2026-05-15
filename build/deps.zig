const std = @import("std");

pub const DemoBackend = enum {
    auto,
    vulkan_spirv16,
    metal4,
};

pub const ResolvedDemoBackend = enum {
    vulkan_spirv16,
    metal4,
};

pub const ThinLtoMode = enum {
    auto,
    on,
    off,
};

pub const Options = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_demo: bool,
    demo_backend: ResolvedDemoBackend,
    build_vulkan: bool,
    build_metal: bool,
    use_lto: bool,
};

pub fn resolve(b: *std.Build) Options {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_demo = b.option(bool, "demo", "Build demo executable") orelse false;
    const requested_backend = b.option(DemoBackend, "demo-backend", "Demo backend: auto, vulkan_spirv16, metal4") orelse .auto;
    const thin_lto_mode = b.option(ThinLtoMode, "thinlto", "ThinLTO: auto, on, off") orelse .auto;
    const demo_backend = resolveDemoBackend(target.result.os.tag, requested_backend);
    const build_vulkan = (b.option(bool, "vulkan", "Build the Vulkan SPIR-V 1.6 backend module") orelse false) or
        (build_demo and demo_backend == .vulkan_spirv16);
    const build_metal = (b.option(bool, "metal", "Build the Metal 4 backend module") orelse false) or
        (build_demo and demo_backend == .metal4);

    if (build_metal and target.result.os.tag != .macos) {
        std.process.fatal("Metal backend is supported only on macOS targets", .{});
    }

    return .{
        .target = target,
        .optimize = optimize,
        .build_demo = build_demo,
        .demo_backend = demo_backend,
        .build_vulkan = build_vulkan,
        .build_metal = build_metal,
        .use_lto = resolveThinLto(optimize, target.result, thin_lto_mode),
    };
}

fn resolveDemoBackend(
    os: std.Target.Os.Tag,
    requested: DemoBackend,
) ResolvedDemoBackend {
    const resolved: ResolvedDemoBackend = switch (requested) {
        .auto => switch (os) {
            .windows, .linux => .vulkan_spirv16,
            .macos => .metal4,
            else => std.process.fatal("unsupported demo target OS: {s}", .{@tagName(os)}),
        },
        .vulkan_spirv16 => .vulkan_spirv16,
        .metal4 => .metal4,
    };

    switch (resolved) {
        .vulkan_spirv16 => switch (os) {
            .windows, .linux => {},
            else => std.process.fatal("demo-backend=vulkan_spirv16 is supported on Windows/Linux targets; {s} selects the Metal 4 demo path", .{@tagName(os)}),
        },
        .metal4 => if (os != .macos) {
            std.process.fatal("demo-backend=metal4 is supported only on macOS targets", .{});
        },
    }

    return resolved;
}

fn resolveThinLto(
    optimize: std.builtin.OptimizeMode,
    target: std.Target,
    mode: ThinLtoMode,
) bool {
    if (optimize == .Debug or mode == .off) return false;

    // Zig 0.16 requires LLD for LTO, but native Mach-O LLD linking is not
    // available. Keep auto conservative and make -Dthinlto=on fail loudly.
    const can_link_with_lld = target.ofmt != .macho;
    if (!can_link_with_lld) {
        if (mode == .on) {
            std.process.fatal("ThinLTO is unsupported for Mach-O targets in Zig 0.16 because LLD Mach-O linking is unavailable", .{});
        }
        return false;
    }

    return true;
}

pub fn enableThinLtoAll(enabled: bool, compile_steps: []const *std.Build.Step.Compile) void {
    if (!enabled) return;
    for (compile_steps) |compile_step| {
        compile_step.use_lld = true;
        compile_step.lto = .thin;
    }
}
