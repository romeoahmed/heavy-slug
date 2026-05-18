//! Slang compilation and reflection-driven GPU ABI generation.

const std = @import("std");

const Stage = enum {
    task,
    mesh,
    fragment,

    fn source(self: Stage) []const u8 {
        return switch (self) {
            .task => "shaders/entries/task.slang",
            .mesh => "shaders/entries/mesh.slang",
            .fragment => "shaders/entries/fragment.slang",
        };
    }

    fn outputName(self: Stage, target: SlangTarget) []const u8 {
        return switch (target) {
            .spirv => switch (self) {
                .task => "task.spv",
                .mesh => "mesh.spv",
                .fragment => "fragment.spv",
            },
            .msl => switch (self) {
                .task => "task.metal",
                .mesh => "mesh.metal",
                .fragment => "fragment.metal",
            },
        };
    }
};

const SlangTarget = enum { spirv, msl };
const spirv_profile = "spirv_1_6";
const metal_capability = "metallib_4_0";

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
    const task_spv = compileStage(b, .spirv, .task, shader_stats);
    const mesh_spv = compileStage(b, .spirv, .mesh, shader_stats);
    const fragment_spv = compileStage(b, .spirv, .fragment, shader_stats);

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
    const task_msl = compileStage(b, .msl, .task, shader_stats);
    const mesh_msl = compileStage(b, .msl, .mesh, shader_stats);
    const fragment_msl = compileStage(b, .msl, .fragment, shader_stats);

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
    cmd.setName("slangc reflection");
    cmd.addFileArg(b.path(Stage.task.source()));
    addCommonArgs(b, cmd, .spirv, .task, false);
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

fn compileStage(
    b: *std.Build,
    target: SlangTarget,
    stage: Stage,
    shader_stats: bool,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.setName(b.fmt("slangc {s} {s}", .{ @tagName(target), @tagName(stage) }));
    cmd.addFileArg(b.path(stage.source()));
    addCommonArgs(b, cmd, target, stage, shader_stats);
    cmd.addArg("-o");
    return cmd.addOutputFileArg(stage.outputName(target));
}

fn addCommonArgs(
    b: *std.Build,
    cmd: *std.Build.Step.Run,
    target: SlangTarget,
    stage: Stage,
    shader_stats: bool,
) void {
    cmd.addArgs(&.{ "-std", "2026" });
    cmd.addArgs(&.{if (target == .msl) "-DHEAVY_SLUG_METAL=1" else "-DHEAVY_SLUG_METAL=0"});
    cmd.addArgs(&.{if (shader_stats) "-DHEAVY_SLUG_SHADER_STATS=1" else "-DHEAVY_SLUG_SHADER_STATS=0"});

    switch (target) {
        .spirv => {
            cmd.addArgs(&.{ "-target", "spirv" });
            cmd.addArgs(&.{ "-profile", spirv_profile });
            addCapabilities(cmd, spirvCapabilities(stage));
        },
        .msl => {
            cmd.addArgs(&.{ "-target", "metal" });
            cmd.addArgs(&.{ "-capability", metal_capability });
        },
    }

    addSlangImportInputs(b, cmd, target);
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{ "-I", "shaders/core" });
    cmd.addArgs(&.{ "-I", switch (target) {
        .spirv => "shaders/backend_vulkan",
        .msl => "shaders/backend_metal",
    } });
    cmd.addArgs(&.{ "-I", "shaders/entries" });
    cmd.addArgs(&.{"-restrictive-capability-check"});
    cmd.addArgs(&.{ "-warnings-as-errors", "all" });
    cmd.addArgs(&.{"-O2"});
}

fn addCapabilities(cmd: *std.Build.Step.Run, caps: []const []const u8) void {
    for (caps) |cap| cmd.addArgs(&.{ "-capability", cap });
}

fn spirvCapabilities(stage: Stage) []const []const u8 {
    return switch (stage) {
        .task => &.{
            "SPV_EXT_mesh_shader",
            "spvMeshShadingEXT",
            "spvGroupNonUniform",
            "spvGroupNonUniformBallot",
            "spvGroupNonUniformArithmetic",
        },
        .mesh => &.{
            "SPV_EXT_mesh_shader",
            "spvMeshShadingEXT",
        },
        .fragment => &.{},
    };
}

fn addSlangImportInputs(b: *std.Build, cmd: *std.Build.Step.Run, target: SlangTarget) void {
    const core_inputs = [_][]const u8{
        "shaders/core/abi.slang",
        "shaders/core/coverage_blob.slang",
        "shaders/core/coverage_integral.slang",
        "shaders/core/hband.slang",
        "shaders/core/mesh_clip.slang",
        "shaders/core/screen_mapping.slang",
        "shaders/core/stats.slang",
    };
    for (core_inputs) |path| cmd.addFileInput(b.path(path));
    cmd.addFileInput(b.path(switch (target) {
        .spirv => "shaders/backend_vulkan/resources.slang",
        .msl => "shaders/backend_metal/resources.slang",
    }));
}
