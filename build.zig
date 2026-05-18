//! Repository build graph: core library, optional backends, Slang outputs, demos, and tests.

const std = @import("std");
const backends = @import("build/backends.zig");
const c_libs = @import("build/c_libs.zig");
const demos = @import("build/demos.zig");
const deps = @import("build/deps.zig");
const shaders = @import("build/shaders.zig");

pub fn build(b: *std.Build) void {
    const opts = deps.resolve(b);

    const spirv_step = b.step("spirv", "Compile Slang shaders to SPIR-V 1.6");
    const spirv_shaders = shaders.compileSpirv(b, opts.shader_stats);
    shaders.installSpirv(b, spirv_step, spirv_shaders);

    const msl_step = b.step("msl", "Compile Slang shaders to Metal Shading Language");
    const msl_shaders = shaders.compileMsl(b, opts.shader_stats);
    shaders.installMsl(b, msl_step, msl_shaders);

    const core_mod = b.addModule("heavy_slug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = opts.target,
    });
    const gpu_structs_mod = if (opts.build_vulkan or opts.build_metal)
        shaders.buildGpuStructsModule(b)
    else
        null;

    const c_deps = c_libs.resolveCoreDeps(b);
    const ft_lib = c_libs.buildFreetype(b, opts.target, opts.optimize, c_deps);
    const hb_lib = c_libs.buildHarfbuzz(b, opts.target, opts.optimize, c_deps, ft_lib);
    const c_mod = c_libs.translateHeavySlugC(b, opts.target, opts.optimize, c_deps);
    core_mod.addImport("heavy_slug_c", c_mod);
    core_mod.linkLibrary(ft_lib);
    core_mod.linkLibrary(hb_lib);
    deps.enableThinLtoAll(opts.use_lto, &.{ ft_lib, hb_lib });

    const test_step = b.step("test", "Run tests");
    addModuleTest(b, test_step, core_mod);
    addToolTests(b, test_step);

    const vulkan_backend = if (opts.build_vulkan)
        backends.buildVulkan(b, opts.target, core_mod, spirv_shaders, gpu_structs_mod.?, opts.shader_stats) orelse return
    else
        null;
    if (vulkan_backend) |backend| {
        addModuleTest(b, test_step, backend.module);
    }

    const metal_backend = if (opts.build_metal)
        backends.buildMetal(b, opts.target, opts.optimize, core_mod, msl_shaders, gpu_structs_mod.?, opts.shader_stats)
    else
        null;
    if (metal_backend) |backend| {
        addModuleTest(b, test_step, backend.module);
    }

    if (opts.build_demo) {
        const exe = switch (opts.demo_backend) {
            .vulkan => demos.buildVulkan(
                b,
                opts.target,
                opts.optimize,
                core_mod,
                vulkan_backend.?,
                opts.use_lto,
            ) orelse return,
            .metal => demos.buildMetal(
                b,
                opts.target,
                opts.optimize,
                core_mod,
                metal_backend.?,
                opts.use_lto,
            ) orelse return,
        };

        b.installArtifact(exe);
        addDemoRunStep(b, exe);
        addModuleTest(b, test_step, exe.root_module);
    }
}

fn addModuleTest(
    b: *std.Build,
    test_step: *std.Build.Step,
    module: *std.Build.Module,
) void {
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = module })).step);
}

fn addToolTests(b: *std.Build, test_step: *std.Build.Step) void {
    const layout_gen_mod = b.createModule(.{
        .root_source_file = b.path("tools/layout_gen.zig"),
        .target = b.graph.host,
    });
    addModuleTest(b, test_step, layout_gen_mod);
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
