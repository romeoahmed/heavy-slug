const std = @import("std");

pub const DemoBackendRequest = enum {
    auto,
    vulkan,
    metal,
};

pub const DemoBackend = enum {
    vulkan,
    metal,
};

pub const ThinLtoRequest = enum {
    auto,
    on,
    off,
};

pub const BuildOptions = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    demo: bool,
    demo_backend: ?DemoBackend,
    vulkan: bool,
    metal: bool,
    thin_lto: bool,
    shader_stats: bool,
};

pub fn resolve(b: *std.Build) BuildOptions {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const demo = b.option(bool, "demo", "Build demo executable") orelse false;
    const demo_backend_request = b.option(DemoBackendRequest, "demo-backend", "Demo backend: auto, vulkan, metal") orelse .auto;
    const thin_lto_request = b.option(ThinLtoRequest, "thinlto", "ThinLTO: auto, on, off") orelse .auto;
    const shader_stats = b.option(bool, "shader-stats", "Enable opt-in GPU shader statistics buffers") orelse false;
    const demo_backend = enabledDemoBackend(target.result.os.tag, demo, demo_backend_request);
    const requested_vulkan = b.option(bool, "vulkan", "Build the Vulkan SPIR-V 1.6 backend module") orelse false;
    const requested_metal = b.option(bool, "metal", "Build the Metal 4 backend module") orelse false;
    const vulkan = requested_vulkan or (demo_backend != null and demo_backend.? == .vulkan);
    const metal = requested_metal or (demo_backend != null and demo_backend.? == .metal);

    if (metal and target.result.os.tag != .macos) {
        std.process.fatal("Metal backend is supported only on macOS targets", .{});
    }

    return .{
        .target = target,
        .optimize = optimize,
        .demo = demo,
        .demo_backend = demo_backend,
        .vulkan = vulkan,
        .metal = metal,
        .thin_lto = thinLtoEnabled(optimize, target.result, thin_lto_request),
        .shader_stats = shader_stats,
    };
}

fn selectDemoBackend(
    os: std.Target.Os.Tag,
    requested: DemoBackendRequest,
) DemoBackend {
    const resolved: DemoBackend = switch (requested) {
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

fn enabledDemoBackend(
    os: std.Target.Os.Tag,
    demo: bool,
    requested: DemoBackendRequest,
) ?DemoBackend {
    return if (demo) selectDemoBackend(os, requested) else null;
}

fn thinLtoEnabled(
    optimize: std.builtin.OptimizeMode,
    target: std.Target,
    mode: ThinLtoRequest,
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

test "enabledDemoBackend ignores demo-backend unless demo is enabled" {
    try std.testing.expectEqual(@as(?DemoBackend, null), enabledDemoBackend(.linux, false, .metal));
    try std.testing.expectEqual(DemoBackend.vulkan, enabledDemoBackend(.linux, true, .auto).?);
}

test "selectDemoBackend maps supported requests" {
    try std.testing.expectEqual(DemoBackend.vulkan, selectDemoBackend(.linux, .auto));
    try std.testing.expectEqual(DemoBackend.vulkan, selectDemoBackend(.windows, .auto));
    try std.testing.expectEqual(DemoBackend.metal, selectDemoBackend(.macos, .auto));
    try std.testing.expectEqual(DemoBackend.vulkan, selectDemoBackend(.linux, .vulkan));
    try std.testing.expectEqual(DemoBackend.metal, selectDemoBackend(.macos, .metal));
}

test "thinLtoEnabled treats auto and on as different user intents" {
    var target = @import("builtin").target;

    target.ofmt = .elf;
    try std.testing.expect(!thinLtoEnabled(.Debug, target, .auto));
    try std.testing.expect(thinLtoEnabled(.Debug, target, .on));
    try std.testing.expect(thinLtoEnabled(.ReleaseFast, target, .auto));
    try std.testing.expect(!thinLtoEnabled(.ReleaseFast, target, .off));

    target.ofmt = .macho;
    try std.testing.expect(!thinLtoEnabled(.ReleaseFast, target, .auto));
}
