//! Slang shader compilation and reflection-driven ABI generation.

const std = @import("std");

pub const SpirvShaders = struct {
    task: std.Build.LazyPath,
    mesh: std.Build.LazyPath,
    fragment: std.Build.LazyPath,
    module: *std.Build.Module,
};

pub const MetalShaders = struct {
    task: std.Build.LazyPath,
    mesh: std.Build.LazyPath,
    fragment: std.Build.LazyPath,
    module: *std.Build.Module,
};

pub fn buildSpirv(b: *std.Build, shader_stats: bool) SpirvShaders {
    const task_spv = compileSlangSpirv(b, "slug_task.spv", "shaders/entries/slug_task.slang", "taskMain", "amplification", "spvGroupNonUniform+spvGroupNonUniformBallot", shader_stats);
    const mesh_spv = compileSlangSpirv(b, "slug_mesh.spv", "shaders/entries/slug_mesh.slang", "meshMain", "mesh", "", shader_stats);
    const frag_spv = compileSlangSpirv(
        b,
        "slug_fragment.spv",
        "shaders/entries/slug_fragment.slang",
        "fragmentMain",
        "fragment",
        "SPV_EXT_descriptor_indexing+spvShaderNonUniform+SPV_GOOGLE_user_type+spvDerivativeControl+spvImageQuery+spvImageGatherExtended+spvSparseResidency+spvMinLod+spvFragmentFullyCoveredEXT",
        shader_stats,
    );

    const shader_wf = b.addWriteFiles();
    _ = shader_wf.addCopyFile(task_spv, "slug_task.spv");
    _ = shader_wf.addCopyFile(mesh_spv, "slug_mesh.spv");
    _ = shader_wf.addCopyFile(frag_spv, "slug_fragment.spv");
    const spv_zig = shader_wf.add("spv.zig",
        \\pub const task: []align(4) const u8 = @alignCast(@embedFile("slug_task.spv"));
        \\pub const mesh: []align(4) const u8 = @alignCast(@embedFile("slug_mesh.spv"));
        \\pub const fragment: []align(4) const u8 = @alignCast(@embedFile("slug_fragment.spv"));
    );

    return .{
        .task = task_spv,
        .mesh = mesh_spv,
        .fragment = frag_spv,
        .module = b.addModule("shader_spv", .{ .root_source_file = spv_zig }),
    };
}

pub fn buildMetal(b: *std.Build, shader_stats: bool) MetalShaders {
    const task_msl = compileSlangMetal(b, "slug_task.metal", "shaders/entries/slug_task.slang", "taskMain", "amplification", shader_stats);
    const mesh_msl = compileSlangMetal(b, "slug_mesh.metal", "shaders/entries/slug_mesh.slang", "meshMain", "mesh", shader_stats);
    const frag_msl = compileSlangMetal(b, "slug_fragment.metal", "shaders/entries/slug_fragment.slang", "fragmentMain", "fragment", shader_stats);

    const shader_wf = b.addWriteFiles();
    _ = shader_wf.addCopyFile(task_msl, "slug_task.metal");
    _ = shader_wf.addCopyFile(mesh_msl, "slug_mesh.metal");
    _ = shader_wf.addCopyFile(frag_msl, "slug_fragment.metal");
    const msl_zig = shader_wf.add("metal_shaders.zig",
        \\pub const task: []const u8 = @embedFile("slug_task.metal");
        \\pub const mesh: []const u8 = @embedFile("slug_mesh.metal");
        \\pub const fragment: []const u8 = @embedFile("slug_fragment.metal");
    );

    return .{
        .task = task_msl,
        .mesh = mesh_msl,
        .fragment = frag_msl,
        .module = b.addModule("metal_shaders", .{ .root_source_file = msl_zig }),
    };
}

pub fn addSpirvInstallSteps(
    b: *std.Build,
    shader_step: *std.Build.Step,
    spirv: SpirvShaders,
) void {
    const install_task = b.addInstallFile(spirv.task, "shaders/slug_task.spv");
    const install_mesh = b.addInstallFile(spirv.mesh, "shaders/slug_mesh.spv");
    const install_frag = b.addInstallFile(spirv.fragment, "shaders/slug_fragment.spv");
    shader_step.dependOn(&install_task.step);
    shader_step.dependOn(&install_mesh.step);
    shader_step.dependOn(&install_frag.step);
}

pub fn addMetalInstallSteps(
    b: *std.Build,
    shader_step: *std.Build.Step,
    metal_shaders: MetalShaders,
) void {
    const install_task = b.addInstallFile(metal_shaders.task, "shaders/slug_task.metal");
    const install_mesh = b.addInstallFile(metal_shaders.mesh, "shaders/slug_mesh.metal");
    const install_frag = b.addInstallFile(metal_shaders.fragment, "shaders/slug_fragment.metal");
    shader_step.dependOn(&install_task.step);
    shader_step.dependOn(&install_mesh.step);
    shader_step.dependOn(&install_frag.step);
}

pub fn generateReflectionJson(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path("shaders/entries/slug_task.slang"));
    addSharedSlangArgs(cmd, "taskMain", "amplification", false, false);
    cmd.addArgs(&.{ "-target", "spirv" });
    cmd.addArgs(&.{ "-profile", "spirv_1_6+spvGroupNonUniform+spvGroupNonUniformBallot" });
    addSharedIncludeAndOptArgs(b, cmd, .vulkan);
    cmd.addArg("-o");
    _ = cmd.addOutputFileArg("reflection_task.spv");
    cmd.addArg("-reflection-json");
    return cmd.addOutputFileArg("reflection.json");
}

pub fn generateGpuStructs(
    b: *std.Build,
    reflection_json: std.Build.LazyPath,
) std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "layout_gen",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/layout_gen.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.addFileArg(reflection_json);
    return run.captureStdOut(.{ .basename = "gpu_structs.zig" });
}

fn compileSlangSpirv(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
    extra_caps: []const u8,
    shader_stats: bool,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path(source));
    addSharedSlangArgs(cmd, entry, stage, false, shader_stats);
    cmd.addArgs(&.{ "-target", "spirv" });
    const profile = if (extra_caps.len > 0)
        std.mem.concat(b.allocator, u8, &.{ "spirv_1_6+", extra_caps }) catch @panic("OOM")
    else
        "spirv_1_6";
    cmd.addArgs(&.{ "-profile", profile });
    addSharedIncludeAndOptArgs(b, cmd, .vulkan);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn compileSlangMetal(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
    shader_stats: bool,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path(source));
    addSharedSlangArgs(cmd, entry, stage, true, shader_stats);
    cmd.addArgs(&.{ "-target", "metal" });
    cmd.addArgs(&.{ "-capability", "metallib_4_0" });
    addSharedIncludeAndOptArgs(b, cmd, .metal);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn addSharedSlangArgs(
    cmd: *std.Build.Step.Run,
    entry: []const u8,
    stage: []const u8,
    comptime metal: bool,
    shader_stats: bool,
) void {
    cmd.addArgs(&.{if (metal) "-DHEAVY_SLUG_METAL=1" else "-DHEAVY_SLUG_METAL=0"});
    cmd.addArgs(&.{if (shader_stats) "-DHEAVY_SLUG_SHADER_STATS=1" else "-DHEAVY_SLUG_SHADER_STATS=0"});
    cmd.addArgs(&.{ "-entry", entry });
    cmd.addArgs(&.{ "-stage", stage });
}

const ShaderBackend = enum { vulkan, metal };

fn addSharedIncludeAndOptArgs(b: *std.Build, cmd: *std.Build.Step.Run, backend: ShaderBackend) void {
    addSlangImportInputs(b, cmd, backend);
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{ "-I", "shaders/core" });
    cmd.addArgs(&.{ "-I", switch (backend) {
        .vulkan => "shaders/backend_vulkan",
        .metal => "shaders/backend_metal",
    } });
    cmd.addArgs(&.{ "-I", "shaders/entries" });
    cmd.addArgs(&.{"-O2"});
}

fn addSlangImportInputs(b: *std.Build, cmd: *std.Build.Step.Run, backend: ShaderBackend) void {
    const core_inputs = [_][]const u8{
        "shaders/core/abi.slang",
        "shaders/core/coverage_blob.slang",
        "shaders/core/coverage_integral.slang",
        "shaders/core/hband.slang",
        "shaders/core/pga.slang",
    };
    for (core_inputs) |path| cmd.addFileInput(b.path(path));
    cmd.addFileInput(b.path(switch (backend) {
        .vulkan => "shaders/backend_vulkan/resources.slang",
        .metal => "shaders/backend_metal/resources.slang",
    }));
}
