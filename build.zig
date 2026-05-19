//! Repository build graph: core library, optional backends, Slang outputs, demos, and tests.

const std = @import("std");
const backends = @import("build/backends.zig");
const c_libs = @import("build/c_libs.zig");
const demos = @import("build/demos.zig");
const deps = @import("build/deps.zig");
const shaders = @import("build/shaders.zig");
const swift = @import("build/swift.zig");

pub fn build(b: *std.Build) void {
    const opts = deps.resolve(b);

    const core_mod = b.addModule("heavy_slug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });

    const c_deps = c_libs.resolveCoreDeps(b);
    const ft_lib = c_libs.buildFreetype(b, opts.target, opts.optimize, c_deps);
    const hb_lib = c_libs.buildHarfbuzz(b, opts.target, opts.optimize, c_deps, ft_lib);
    const c_mod = c_libs.translateHeavySlugC(b, opts.target, opts.optimize, c_deps);
    core_mod.addImport("heavy_slug_c", c_mod);
    core_mod.linkLibrary(ft_lib);
    core_mod.linkLibrary(hb_lib);

    const core_lib = b.addLibrary(.{
        .name = "heavy_slug",
        .linkage = .static,
        .root_module = core_mod,
    });
    deps.enableThinLtoAll(opts.thin_lto, &.{ ft_lib, hb_lib, core_lib });
    b.installArtifact(core_lib);

    const spirv_step = b.step("spirv", "Compile Slang shaders to SPIR-V 1.6");
    const spirv_shaders = shaders.compileSpirv(b, opts.shader_stats);
    shaders.installSpirv(b, spirv_step, spirv_shaders);

    const msl_step = b.step("msl", "Compile Slang shaders to Metal Shading Language");
    const msl_shaders = shaders.compileMsl(b, opts.shader_stats);
    shaders.installMsl(b, msl_step, msl_shaders);

    const swift_format_step = b.step("swift-format-lint", "Lint Swift sources with swift-format");
    swift.addFormatLintStep(b, swift_format_step);

    const gpu_structs_mod = if (opts.vulkan or opts.metal)
        shaders.buildGpuStructsModule(b)
    else
        null;

    const test_step = b.step("test", "Run tests");
    addModuleTest(b, test_step, "heavy_slug", core_mod);
    addBuildHelperTests(b, test_step);
    addToolTests(b, test_step);

    const vulkan_backend = if (opts.vulkan)
        backends.buildVulkan(b, opts.target, core_mod, spirv_shaders, gpu_structs_mod.?, opts.shader_stats) orelse return
    else
        null;
    if (vulkan_backend) |backend| {
        addModuleTest(b, test_step, "heavy_slug_vulkan", backend.module);
    }

    const metal_backend = if (opts.metal)
        backends.buildMetal(b, opts.target, opts.optimize, core_mod, msl_shaders, gpu_structs_mod.?, opts.shader_stats)
    else
        null;
    if (metal_backend) |backend| {
        addModuleTest(b, test_step, "heavy_slug_metal", backend.module);
    }

    if (opts.demo) {
        const exe = switch (opts.demo_backend.?) {
            .vulkan => demos.buildVulkan(
                b,
                opts.target,
                opts.optimize,
                core_mod,
                vulkan_backend.?,
                opts.thin_lto,
            ) orelse return,
            .metal => demos.buildMetal(
                b,
                opts.target,
                opts.optimize,
                core_mod,
                metal_backend.?,
                opts.thin_lto,
            ) orelse return,
        };

        b.installArtifact(exe);
        addDemoRunStep(b, exe);
        addModuleTest(b, test_step, "heavy_slug_demo", exe.root_module);
    }
}

fn addModuleTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    name: []const u8,
    module: *std.Build.Module,
) void {
    const tests = b.addTest(.{
        .name = name,
        .root_module = module,
    });
    test_step.dependOn(&b.addRunArtifact(tests).step);
}

fn addBuildHelperTests(b: *std.Build, test_step: *std.Build.Step) void {
    const deps_mod = b.createModule(.{
        .root_source_file = b.path("build/deps.zig"),
        .target = b.graph.host,
    });
    addModuleTest(b, test_step, "build_deps", deps_mod);

    const swift_mod = b.createModule(.{
        .root_source_file = b.path("build/swift.zig"),
        .target = b.graph.host,
    });
    addModuleTest(b, test_step, "build_swift", swift_mod);
}

fn addToolTests(b: *std.Build, test_step: *std.Build.Step) void {
    const layout_gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/layout_gen.zig"),
        .target = b.graph.host,
    });
    addModuleTest(b, test_step, "layout_gen", layout_gen_mod);
}

fn addDemoRunStep(b: *std.Build, exe: *std.Build.Step.Compile) void {
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }
}
