const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const mod = b.addModule("heavy_slug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // Vulkan bindings: manual generation from Vulkan-Headers vk.xml
    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.addModule("vulkan-zig", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });
    mod.addImport("vulkan", vulkan_zig);

    // C library compilation (spec §8.2)
    const ft_dep = b.dependency("freetype_src", .{});
    const hb_dep = b.dependency("harfbuzz_src", .{});
    const ft_lib = buildFreetype(b, target, optimize);
    const hb_lib = buildHarfbuzz(b, target, optimize, ft_lib);
    mod.linkLibrary(ft_lib);
    mod.linkLibrary(hb_lib);
    mod.addIncludePath(ft_dep.path("include"));
    mod.addIncludePath(hb_dep.path("src"));

    const exe = b.addExecutable(.{
        .name = "heavy_slug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = mod },
                .{ .name = "vulkan", .module = vulkan_zig },
            },
        }),
    });
    b.installArtifact(exe);

    // Run step
    const run_step = b.step("run", "Run the app");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    // Test step — library module + executable module in parallel
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);

    // Shader compilation: Slang → SPIR-V
    const shader_step = b.step("shaders", "Compile Slang shaders to SPIR-V");

    const task_spv = compileSlangShader(b, "slug_task.spv", "shaders/slug_task.slang", "taskMain", "amplification");
    const mesh_spv = compileSlangShader(b, "slug_mesh.spv", "shaders/slug_mesh.slang", "meshMain", "mesh");
    const frag_spv = compileSlangShader(b, "slug_fragment.spv", "shaders/slug_fragment.slang", "fragmentMain", "fragment");

    // Embed SPIR-V binaries into a Zig module for @embedFile access.
    const shader_wf = b.addWriteFiles();
    _ = shader_wf.addCopyFile(task_spv, "slug_task.spv");
    _ = shader_wf.addCopyFile(mesh_spv, "slug_mesh.spv");
    _ = shader_wf.addCopyFile(frag_spv, "slug_fragment.spv");
    const spv_zig = shader_wf.add("spv.zig",
        \\pub const task: []align(4) const u8 = @alignCast(@embedFile("slug_task.spv"));
        \\pub const mesh: []align(4) const u8 = @alignCast(@embedFile("slug_mesh.spv"));
        \\pub const fragment: []align(4) const u8 = @alignCast(@embedFile("slug_fragment.spv"));
    );
    const shader_spv_mod = b.addModule("shader_spv", .{
        .root_source_file = spv_zig,
    });
    mod.addImport("shader_spv", shader_spv_mod);

    // Layout validation: slangc reflection → generated GPU layout constants
    const reflection_json = generateReflectionJson(b);
    const layout_zig = generateLayoutZig(b, reflection_json);
    mod.addImport("gpu_layout", b.addModule("gpu_layout", .{
        .root_source_file = layout_zig,
    }));

    const install_task = b.addInstallFile(task_spv, "shaders/slug_task.spv");
    const install_mesh = b.addInstallFile(mesh_spv, "shaders/slug_mesh.spv");
    const install_frag = b.addInstallFile(frag_spv, "shaders/slug_fragment.spv");
    shader_step.dependOn(&install_task.step);
    shader_step.dependOn(&install_mesh.step);
    shader_step.dependOn(&install_frag.step);

}

fn compileSlangShader(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path(source));
    cmd.addArgs(&.{ "-entry", entry });
    cmd.addArgs(&.{ "-stage", stage });
    cmd.addArgs(&.{ "-target", "spirv" });
    cmd.addArgs(&.{ "-profile", "spirv_1_6" });
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{"-O2"});
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn generateReflectionJson(b: *std.Build) std.Build.LazyPath {
    // Run slangc on slug_task.slang with -reflection-json flag
    // slug_task.slang includes slug_common.slang which defines both
    // GlyphCommand and PushConstants — one shader gives us both structs.
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path("shaders/slug_task.slang"));
    cmd.addArgs(&.{ "-entry", "taskMain" });
    cmd.addArgs(&.{ "-stage", "amplification" });
    cmd.addArgs(&.{ "-target", "spirv" });
    cmd.addArgs(&.{ "-profile", "spirv_1_6" });
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{"-O2"});
    // slangc requires a SPIR-V output file even when we only want reflection
    cmd.addArg("-o");
    _ = cmd.addOutputFileArg("reflection_task.spv");
    // Reflection JSON output
    cmd.addArg("-reflection-json");
    return cmd.addOutputFileArg("reflection.json");
}

fn generateLayoutZig(
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
    return run.captureStdOut(.{});
}

fn buildFreetype(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const ft_dep = b.dependency("freetype_src", .{});

    const lib = b.addLibrary(.{
        .name = "freetype",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(ft_dep.path("include"));
    lib.root_module.addCSourceFiles(.{
        .root = ft_dep.path(""),
        .files = &.{
            "src/base/ftbase.c",
            "src/base/ftinit.c",
            "src/base/ftsystem.c",
            "src/base/ftdebug.c",
            "src/base/ftbbox.c",
            "src/base/ftbitmap.c",
            "src/base/ftglyph.c",
            "src/base/ftsynth.c",
            "src/base/ftstroke.c",
            "src/base/ftmm.c",
            "src/truetype/truetype.c",
            "src/cff/cff.c",
            "src/cid/type1cid.c",
            "src/type1/type1.c",
            "src/type42/type42.c",
            "src/pfr/pfr.c",
            "src/sfnt/sfnt.c",
            "src/autofit/autofit.c",
            "src/pshinter/pshinter.c",
            "src/raster/raster.c",
            "src/smooth/smooth.c",
            "src/psaux/psaux.c",
            "src/psnames/psnames.c",
            "src/gzip/ftgzip.c",
            "src/lzw/ftlzw.c",
            "src/sdf/sdf.c",
            "src/svg/svg.c",
            "src/winfonts/winfnt.c",
            "src/pcf/pcf.c",
            "src/bdf/bdf.c",
        },
        .flags = &.{"-DFT2_BUILD_LIBRARY"},
    });

    return lib;
}

fn buildHarfbuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ft_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
    const hb_dep = b.dependency("harfbuzz_src", .{});
    const ft_dep = b.dependency("freetype_src", .{});

    const lib = b.addLibrary(.{
        .name = "harfbuzz",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });

    lib.root_module.addIncludePath(hb_dep.path("src"));
    lib.root_module.addIncludePath(ft_dep.path("include"));
    lib.root_module.linkLibrary(ft_lib);

    // Unity build — all core HarfBuzz in one TU
    lib.root_module.addCSourceFiles(.{
        .root = hb_dep.path("src"),
        .files = &.{"harfbuzz.cc"},
        .flags = &.{ "-DHAVE_FREETYPE=1", "-fno-exceptions", "-fno-rtti" },
    });

    // GPU subsystem (libharfbuzz-gpu)
    lib.root_module.addCSourceFiles(.{
        .root = hb_dep.path("src"),
        .files = &.{ "hb-gpu-draw.cc", "hb-gpu-shaders.cc" },
        .flags = &.{ "-DHAVE_FREETYPE=1", "-DHAVE_HB_GPU=1", "-fno-exceptions", "-fno-rtti" },
    });

    return lib;
}
