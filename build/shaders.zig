//! Slang compilation and reflection-driven GPU ABI generation.

const std = @import("std");

pub const SpirvBundle = struct {
    task: std.Build.LazyPath,
    mesh: std.Build.LazyPath,
    fragment: std.Build.LazyPath,
    module: *std.Build.Module,
};

pub const MslBundle = struct {
    task: std.Build.LazyPath,
    mesh: std.Build.LazyPath,
    fragment: std.Build.LazyPath,
    module: *std.Build.Module,
};

pub fn compileSpirv(b: *std.Build, shader_stats: bool) SpirvBundle {
    const task_spv = compileSpirvStage(
        b,
        "task.spv",
        "shaders/entries/task.slang",
        "taskMain",
        "amplification",
        "spvGroupNonUniform+spvGroupNonUniformBallot+spvGroupNonUniformArithmetic",
        shader_stats,
    );
    const mesh_spv = compileSpirvStage(b, "mesh.spv", "shaders/entries/mesh.slang", "meshMain", "mesh", "", shader_stats);
    const fragment_spv = compileSpirvStage(b, "fragment.spv", "shaders/entries/fragment.slang", "fragmentMain", "fragment", "", shader_stats);

    const files = b.addWriteFiles();
    _ = files.addCopyFile(task_spv, "task.spv");
    _ = files.addCopyFile(mesh_spv, "mesh.spv");
    _ = files.addCopyFile(fragment_spv, "fragment.spv");
    const module_zig = files.add("spirv_shaders.zig",
        \\pub const task: []align(4) const u8 = @alignCast(@embedFile("task.spv"));
        \\pub const mesh: []align(4) const u8 = @alignCast(@embedFile("mesh.spv"));
        \\pub const fragment: []align(4) const u8 = @alignCast(@embedFile("fragment.spv"));
    );

    return .{
        .task = task_spv,
        .mesh = mesh_spv,
        .fragment = fragment_spv,
        .module = b.addModule("spirv_shaders", .{ .root_source_file = module_zig }),
    };
}

pub fn compileMsl(b: *std.Build, shader_stats: bool) MslBundle {
    const task_msl = compileMslStage(b, "task.metal", "shaders/entries/task.slang", "taskMain", "amplification", shader_stats);
    const mesh_msl = compileMslStage(b, "mesh.metal", "shaders/entries/mesh.slang", "meshMain", "mesh", shader_stats);
    const fragment_msl = compileMslStage(b, "fragment.metal", "shaders/entries/fragment.slang", "fragmentMain", "fragment", shader_stats);

    const files = b.addWriteFiles();
    _ = files.addCopyFile(task_msl, "task.metal");
    _ = files.addCopyFile(mesh_msl, "mesh.metal");
    _ = files.addCopyFile(fragment_msl, "fragment.metal");
    const module_zig = files.add("msl_shaders.zig",
        \\pub const task: []const u8 = @embedFile("task.metal");
        \\pub const mesh: []const u8 = @embedFile("mesh.metal");
        \\pub const fragment: []const u8 = @embedFile("fragment.metal");
    );

    return .{
        .task = task_msl,
        .mesh = mesh_msl,
        .fragment = fragment_msl,
        .module = b.addModule("msl_shaders", .{ .root_source_file = module_zig }),
    };
}

pub fn installSpirv(
    b: *std.Build,
    step: *std.Build.Step,
    spirv: SpirvBundle,
) void {
    const install_task = b.addInstallFile(spirv.task, "shaders/spirv/task.spv");
    const install_mesh = b.addInstallFile(spirv.mesh, "shaders/spirv/mesh.spv");
    const install_fragment = b.addInstallFile(spirv.fragment, "shaders/spirv/fragment.spv");
    step.dependOn(&install_task.step);
    step.dependOn(&install_mesh.step);
    step.dependOn(&install_fragment.step);
}

pub fn installMsl(
    b: *std.Build,
    step: *std.Build.Step,
    msl: MslBundle,
) void {
    const install_task = b.addInstallFile(msl.task, "shaders/msl/task.metal");
    const install_mesh = b.addInstallFile(msl.mesh, "shaders/msl/mesh.metal");
    const install_fragment = b.addInstallFile(msl.fragment, "shaders/msl/fragment.metal");
    step.dependOn(&install_task.step);
    step.dependOn(&install_mesh.step);
    step.dependOn(&install_fragment.step);
}

fn generateReflectionJson(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path("shaders/entries/task.slang"));
    addStageArgs(cmd, "taskMain", "amplification", .spirv, false);
    cmd.addArgs(&.{ "-target", "spirv" });
    cmd.addArgs(&.{ "-profile", "spirv_1_6+spvGroupNonUniform+spvGroupNonUniformBallot+spvGroupNonUniformArithmetic" });
    addIncludeAndOptArgs(b, cmd, .spirv);
    cmd.addArg("-o");
    _ = cmd.addOutputFileArg("reflection.spv");
    cmd.addArg("-reflection-json");
    return cmd.addOutputFileArg("reflection.json");
}

fn generateGpuStructs(
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

pub fn buildGpuStructsModule(b: *std.Build) *std.Build.Module {
    const reflection_json = generateReflectionJson(b);
    const gpu_structs_zig = generateGpuStructs(b, reflection_json);
    return b.addModule("gpu_structs", .{ .root_source_file = gpu_structs_zig });
}

fn compileSpirvStage(
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
    addStageArgs(cmd, entry, stage, .spirv, shader_stats);
    cmd.addArgs(&.{ "-target", "spirv" });
    const profile = if (extra_caps.len > 0)
        std.mem.concat(b.allocator, u8, &.{ "spirv_1_6+", extra_caps }) catch @panic("OOM")
    else
        "spirv_1_6";
    cmd.addArgs(&.{ "-profile", profile });
    addIncludeAndOptArgs(b, cmd, .spirv);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn compileMslStage(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
    shader_stats: bool,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path(source));
    addStageArgs(cmd, entry, stage, .msl, shader_stats);
    cmd.addArgs(&.{ "-target", "metal" });
    cmd.addArgs(&.{ "-capability", "metallib_4_0" });
    addIncludeAndOptArgs(b, cmd, .msl);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn addStageArgs(
    cmd: *std.Build.Step.Run,
    entry: []const u8,
    stage: []const u8,
    target: SlangTarget,
    shader_stats: bool,
) void {
    cmd.addArgs(&.{if (target == .msl) "-DHEAVY_SLUG_METAL=1" else "-DHEAVY_SLUG_METAL=0"});
    cmd.addArgs(&.{if (shader_stats) "-DHEAVY_SLUG_SHADER_STATS=1" else "-DHEAVY_SLUG_SHADER_STATS=0"});
    cmd.addArgs(&.{ "-entry", entry });
    cmd.addArgs(&.{ "-stage", stage });
}

const SlangTarget = enum { spirv, msl };

fn addIncludeAndOptArgs(b: *std.Build, cmd: *std.Build.Step.Run, target: SlangTarget) void {
    addSlangImportInputs(b, cmd, target);
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{ "-I", "shaders/core" });
    cmd.addArgs(&.{ "-I", switch (target) {
        .spirv => "shaders/backend_vulkan",
        .msl => "shaders/backend_metal",
    } });
    cmd.addArgs(&.{ "-I", "shaders/entries" });
    cmd.addArgs(&.{"-O2"});
}

fn addSlangImportInputs(b: *std.Build, cmd: *std.Build.Step.Run, target: SlangTarget) void {
    const core_inputs = [_][]const u8{
        "shaders/core/abi.slang",
        "shaders/core/coverage_blob.slang",
        "shaders/core/coverage_integral.slang",
        "shaders/core/hband.slang",
        "shaders/core/pga.slang",
    };
    for (core_inputs) |path| cmd.addFileInput(b.path(path));
    cmd.addFileInput(b.path(switch (target) {
        .spirv => "shaders/backend_vulkan/resources.slang",
        .msl => "shaders/backend_metal/resources.slang",
    }));
}
