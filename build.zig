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
    const lazy_deps = deps.resolveLazy(b, opts);
    if (!lazy_deps.complete) return;

    const core = buildCore(b, opts);
    b.installArtifact(core.library);

    var shader_cache = ShaderCache{
        .b = b,
        .shader_stats = opts.shader_stats,
    };
    const spirv_step = b.step("spirv", "Compile Slang shaders to SPIR-V 1.6");
    shaders.installSpirv(b, spirv_step, shader_cache.spirv());

    const msl_step = b.step("msl", "Compile Slang shaders to Metal Shading Language");
    shaders.installMsl(b, msl_step, shader_cache.msl());

    const swift_format_step = b.step("swift-format-lint", "Lint Swift sources with swift-format");
    swift.addFormatLintStep(b, swift_format_step);

    const gpu_structs_mod = if (opts.needsGpuStructs())
        shader_cache.gpuStructs()
    else
        null;
    const swift_toolchain = if (opts.metal) swift.resolveToolchain(b, opts.target) else null;

    const test_step = b.step("test", "Run tests");
    addModuleTest(b, test_step, "heavy_slug", core.module);
    addBuildHelperTests(b, test_step);
    addToolTests(b, test_step);
    addDemoCommonTests(b, test_step, opts, core.module);

    const vulkan_backend = if (opts.vulkan)
        backends.buildVulkan(
            b,
            opts.target,
            core.module,
            lazy_deps.vulkan.?,
            shader_cache.spirv(),
            gpu_structs_mod.?,
            opts.shader_stats,
        )
    else
        null;
    if (vulkan_backend) |backend| {
        addModuleTest(b, test_step, "heavy_slug_vulkan", backend.module);
    }

    const metal_backend = if (opts.metal)
        backends.buildMetal(
            b,
            opts.target,
            opts.optimize,
            core.module,
            swift_toolchain.?,
            shader_cache.msl(),
            gpu_structs_mod.?,
            opts.shader_stats,
        )
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
                core.module,
                vulkan_backend.?,
                lazy_deps.wayland_protocols,
                opts.thin_lto,
            ),
            .metal => demos.buildMetal(
                b,
                opts.target,
                opts.optimize,
                core.module,
                metal_backend.?,
                swift_toolchain.?,
                opts.thin_lto,
            ),
        };

        b.installArtifact(exe);
        addDemoRunStep(b, exe);
        addModuleTest(b, test_step, "heavy_slug_demo", exe.root_module);
    }
}

const CoreBuild = struct {
    module: *std.Build.Module,
    library: *std.Build.Step.Compile,
};

const ShaderCache = struct {
    b: *std.Build,
    shader_stats: bool,
    spirv_bundle: ?shaders.SpirvBundle = null,
    msl_bundle: ?shaders.MslBundle = null,
    gpu_structs_mod: ?*std.Build.Module = null,

    fn spirv(self: *ShaderCache) shaders.SpirvBundle {
        if (self.spirv_bundle == null) {
            self.spirv_bundle = shaders.compileSpirv(self.b, self.shader_stats);
        }
        return self.spirv_bundle.?;
    }

    fn msl(self: *ShaderCache) shaders.MslBundle {
        if (self.msl_bundle == null) {
            self.msl_bundle = shaders.compileMsl(self.b, self.shader_stats);
        }
        return self.msl_bundle.?;
    }

    fn gpuStructs(self: *ShaderCache) *std.Build.Module {
        if (self.gpu_structs_mod == null) {
            self.gpu_structs_mod = shaders.buildGpuStructsModule(self.b);
        }
        return self.gpu_structs_mod.?;
    }
};

fn buildCore(b: *std.Build, opts: deps.BuildOptions) CoreBuild {
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

    return .{
        .module = core_mod,
        .library = core_lib,
    };
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
    const run = b.addRunArtifact(tests);
    run.skip_foreign_checks = isForeignTarget(b, tests);
    test_step.dependOn(&run.step);
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

fn addDemoCommonTests(
    b: *std.Build,
    test_step: *std.Build.Step,
    opts: deps.BuildOptions,
    core_mod: *std.Build.Module,
) void {
    const demo_input = b.createModule(.{
        .root_source_file = b.path("demo/common/input.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    const demo_title = b.createModule(.{
        .root_source_file = b.path("demo/common/title.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
    });
    const demo_scene = b.createModule(.{
        .root_source_file = b.path("demo/common/scene.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "heavy_slug", .module = core_mod },
            .{ .name = "demo_input", .module = demo_input },
        },
    });
    const wayland_title = b.createModule(.{
        .root_source_file = b.path("demo/platform/wayland_title.zig"),
        .target = opts.target,
        .optimize = opts.optimize,
        .imports = &.{
            .{ .name = "demo_title", .module = demo_title },
        },
    });
    addModuleTest(b, test_step, "heavy_slug_demo_title", demo_title);
    addModuleTest(b, test_step, "heavy_slug_demo_wayland_title", wayland_title);
    addModuleTest(b, test_step, "heavy_slug_demo_common", demo_scene);
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

fn isForeignTarget(b: *std.Build, artifact: *std.Build.Step.Compile) bool {
    const target = artifact.rootModuleTarget();
    const host = b.graph.host.result;
    return target.os.tag != host.os.tag or
        target.cpu.arch != host.cpu.arch or
        target.abi != host.abi;
}
