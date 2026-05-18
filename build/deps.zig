const std = @import("std");

pub const DemoBackend = enum {
    auto,
    vulkan,
    metal,
};

pub const ResolvedDemoBackend = enum {
    vulkan,
    metal,
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
    demo_backend: ?ResolvedDemoBackend,
    build_vulkan: bool,
    build_metal: bool,
    use_lto: bool,
    shader_stats: bool,
};

pub fn resolve(b: *std.Build) Options {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_demo = b.option(bool, "demo", "Build demo executable") orelse false;
    const requested_backend = b.option(DemoBackend, "demo-backend", "Demo backend: auto, vulkan, metal") orelse .auto;
    const thin_lto_mode = b.option(ThinLtoMode, "thinlto", "ThinLTO: auto, on, off") orelse .auto;
    const shader_stats = b.option(bool, "shader-stats", "Enable opt-in GPU shader statistics buffers") orelse false;
    const demo_backend = resolveOptionalDemoBackend(target.result.os.tag, build_demo, requested_backend);
    const requested_vulkan = b.option(bool, "vulkan", "Build the Vulkan SPIR-V 1.6 backend module") orelse false;
    const requested_metal = b.option(bool, "metal", "Build the Metal 4 backend module") orelse false;
    const build_vulkan = requested_vulkan or (demo_backend != null and demo_backend.? == .vulkan);
    const build_metal = requested_metal or (demo_backend != null and demo_backend.? == .metal);

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
        .shader_stats = shader_stats,
    };
}

fn resolveDemoBackend(
    os: std.Target.Os.Tag,
    requested: DemoBackend,
) ResolvedDemoBackend {
    const resolved: ResolvedDemoBackend = switch (requested) {
        .auto => switch (os) {
            .windows, .linux => .vulkan,
            .macos => .metal,
            else => std.process.fatal("unsupported demo target OS: {s}", .{@tagName(os)}),
        },
        .vulkan => .vulkan,
        .metal => .metal,
    };

    switch (resolved) {
        .vulkan => switch (os) {
            .windows, .linux => {},
            else => std.process.fatal("demo-backend=vulkan is supported on Windows/Linux targets; {s} selects the Metal demo path", .{@tagName(os)}),
        },
        .metal => if (os != .macos) {
            std.process.fatal("demo-backend=metal is supported only on macOS targets", .{});
        },
    }

    return resolved;
}

fn resolveOptionalDemoBackend(
    os: std.Target.Os.Tag,
    build_demo: bool,
    requested: DemoBackend,
) ?ResolvedDemoBackend {
    return if (build_demo) resolveDemoBackend(os, requested) else null;
}

fn resolveThinLto(
    optimize: std.builtin.OptimizeMode,
    target: std.Target,
    mode: ThinLtoMode,
) bool {
    if (mode == .off) return false;
    if (mode == .auto and optimize == .Debug) return false;

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

test "resolveOptionalDemoBackend ignores demo-backend unless demo is enabled" {
    try std.testing.expectEqual(@as(?ResolvedDemoBackend, null), resolveOptionalDemoBackend(.linux, false, .metal));
    try std.testing.expectEqual(ResolvedDemoBackend.vulkan, resolveOptionalDemoBackend(.linux, true, .auto).?);
}

test "resolveDemoBackend maps supported requests" {
    try std.testing.expectEqual(ResolvedDemoBackend.vulkan, resolveDemoBackend(.linux, .auto));
    try std.testing.expectEqual(ResolvedDemoBackend.vulkan, resolveDemoBackend(.windows, .auto));
    try std.testing.expectEqual(ResolvedDemoBackend.metal, resolveDemoBackend(.macos, .auto));
    try std.testing.expectEqual(ResolvedDemoBackend.vulkan, resolveDemoBackend(.linux, .vulkan));
    try std.testing.expectEqual(ResolvedDemoBackend.metal, resolveDemoBackend(.macos, .metal));
}

test "resolveThinLto treats auto and on as different user intents" {
    var target = @import("builtin").target;

    target.ofmt = .elf;
    try std.testing.expect(!resolveThinLto(.Debug, target, .auto));
    try std.testing.expect(resolveThinLto(.Debug, target, .on));
    try std.testing.expect(resolveThinLto(.ReleaseFast, target, .auto));
    try std.testing.expect(!resolveThinLto(.ReleaseFast, target, .off));

    target.ofmt = .macho;
    try std.testing.expect(!resolveThinLto(.ReleaseFast, target, .auto));
}
