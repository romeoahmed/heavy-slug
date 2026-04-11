const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_demo = b.option(bool, "demo", "Build demo executable (requires GLFW)") orelse false;

    // --- Vulkan bindings: generate from Vulkan-Headers vk.xml ---
    const registry = b.dependency("vulkan_headers", .{}).path("registry/vk.xml");
    const vk_gen = b.dependency("vulkan", .{}).artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.addModule("vulkan-zig", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });

    // --- Shader compilation: Slang -> SPIR-V ---
    const shader_step = b.step("shaders", "Compile Slang shaders to SPIR-V");

    const task_spv = compileSlangShader(b, "slug_task.spv", "shaders/slug_task.slang", "taskMain", "amplification", "spvGroupNonUniformBallot");
    const mesh_spv = compileSlangShader(b, "slug_mesh.spv", "shaders/slug_mesh.slang", "meshMain", "mesh", "");
    const frag_spv = compileSlangShader(b, "slug_fragment.spv", "shaders/slug_fragment.slang", "fragmentMain", "fragment", "");

    const shader_wf = b.addWriteFiles();
    _ = shader_wf.addCopyFile(task_spv, "slug_task.spv");
    _ = shader_wf.addCopyFile(mesh_spv, "slug_mesh.spv");
    _ = shader_wf.addCopyFile(frag_spv, "slug_fragment.spv");
    const spv_zig = shader_wf.add("spv.zig",
        \\pub const task: []align(4) const u8 = @alignCast(@embedFile("slug_task.spv"));
        \\pub const mesh: []align(4) const u8 = @alignCast(@embedFile("slug_mesh.spv"));
        \\pub const fragment: []align(4) const u8 = @alignCast(@embedFile("slug_fragment.spv"));
    );
    const shader_spv_mod = b.addModule("shader_spv", .{ .root_source_file = spv_zig });

    const install_task = b.addInstallFile(task_spv, "shaders/slug_task.spv");
    const install_mesh = b.addInstallFile(mesh_spv, "shaders/slug_mesh.spv");
    const install_frag = b.addInstallFile(frag_spv, "shaders/slug_fragment.spv");
    shader_step.dependOn(&install_task.step);
    shader_step.dependOn(&install_mesh.step);
    shader_step.dependOn(&install_frag.step);

    // --- GPU struct generation: slangc reflection -> extern struct definitions ---
    const reflection_json = generateReflectionJson(b);
    const gpu_structs_zig = generateGpuStructs(b, reflection_json);
    const gpu_structs_mod = b.addModule("gpu_structs", .{ .root_source_file = gpu_structs_zig });

    // --- Library module ---
    const mod = b.addModule("heavy_slug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });
    mod.addImport("vulkan", vulkan_zig);
    mod.addImport("shader_spv", shader_spv_mod);
    mod.addImport("gpu_structs", gpu_structs_mod);

    // --- C libraries (library deps only: FreeType + HarfBuzz) ---
    const ft_dep = b.dependency("freetype_src", .{});
    const hb_dep = b.dependency("harfbuzz_src", .{});
    const ft_lib = buildFreetype(b, target, optimize);
    const hb_lib = buildHarfbuzz(b, target, optimize, ft_lib);
    mod.linkLibrary(ft_lib);
    mod.linkLibrary(hb_lib);
    mod.addIncludePath(ft_dep.path("include"));
    mod.addIncludePath(hb_dep.path("src"));

    // --- ThinLTO for C libraries in release mode ---
    // Applied to C static libs only. Zig executables with -flto=thin trigger
    // unresolved compiler-rt/musl symbols (frexpf, isnan, __DENORM, etc.)
    // during linking -- a known Zig limitation as of 0.16.0-dev.
    const use_lto = optimize != .Debug;
    if (use_lto) {
        ft_lib.lto = .thin;
        hb_lib.lto = .thin;
    }

    // --- Tests ---
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/layout_gen.zig"),
        .target = b.graph.host,
    }) })).step);

    // --- Demo executable (opt-in via -Ddemo, default true) ---
    if (build_demo) {
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

        // GLFW (demo-only dependency)
        const glfw_dep = b.dependency("glfw_src", .{});
        const glfw_lib = buildGlfw(b, target, optimize);
        exe.root_module.linkLibrary(glfw_lib);
        exe.root_module.addIncludePath(glfw_dep.path("include"));

        if (target.result.os.tag == .linux) {
            exe.root_module.linkSystemLibrary("wayland-client", .{});
            exe.root_module.linkSystemLibrary("wayland-cursor", .{});
            exe.root_module.linkSystemLibrary("wayland-egl", .{});
            exe.root_module.linkSystemLibrary("xkbcommon", .{});
        }

        if (use_lto) {
            glfw_lib.lto = .thin;
        }

        b.installArtifact(exe);

        // Run step
        const run_step = b.step("run", "Run the app");
        const run_cmd = b.addRunArtifact(exe);
        run_step.dependOn(&run_cmd.step);
        run_cmd.step.dependOn(b.getInstallStep());
        if (b.args) |args| {
            run_cmd.addArgs(args);
        }

        // Demo executable tests
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = exe.root_module })).step);
    }
}

fn compileSlangShader(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
    extra_caps: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path(source));
    cmd.addArgs(&.{ "-entry", entry });
    cmd.addArgs(&.{ "-stage", stage });
    cmd.addArgs(&.{ "-target", "spirv" });
    const profile = if (extra_caps.len > 0)
        std.mem.concat(b.allocator, u8, &.{ "spirv_1_6+", extra_caps }) catch @panic("OOM")
    else
        "spirv_1_6";
    cmd.addArgs(&.{ "-profile", profile });
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{"-O2"});
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn generateReflectionJson(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path("shaders/slug_task.slang"));
    cmd.addArgs(&.{ "-entry", "taskMain" });
    cmd.addArgs(&.{ "-stage", "amplification" });
    cmd.addArgs(&.{ "-target", "spirv" });
    cmd.addArgs(&.{ "-profile", "spirv_1_6+spvGroupNonUniformBallot" });
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{"-O2"});
    cmd.addArg("-o");
    _ = cmd.addOutputFileArg("reflection_task.spv");
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

fn buildGlfw(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
    const glfw_dep = b.dependency("glfw_src", .{});
    const vk_headers = b.dependency("vulkan_headers", .{});

    const lib = b.addLibrary(.{
        .name = "glfw",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });

    lib.root_module.addIncludePath(glfw_dep.path("include"));
    lib.root_module.addIncludePath(glfw_dep.path("src"));
    lib.root_module.addIncludePath(vk_headers.path("include"));

    const os = target.result.os.tag;
    const platform_flags: []const []const u8 = switch (os) {
        .windows => &.{"-D_GLFW_WIN32"},
        .linux => &.{ "-D_GLFW_WAYLAND", "-DHAVE_MEMFD_CREATE" },
        .macos => &.{"-D_GLFW_COCOA"},
        else => @panic("unsupported OS for GLFW"),
    };

    lib.root_module.addCSourceFiles(.{
        .root = glfw_dep.path(""),
        .files = &.{
            "src/context.c",
            "src/init.c",
            "src/input.c",
            "src/monitor.c",
            "src/platform.c",
            "src/vulkan.c",
            "src/window.c",
            "src/egl_context.c",
            "src/osmesa_context.c",
            "src/null_init.c",
            "src/null_joystick.c",
            "src/null_monitor.c",
            "src/null_window.c",
        },
        .flags = platform_flags,
    });

    switch (os) {
        .windows => {
            lib.root_module.addCSourceFiles(.{
                .root = glfw_dep.path(""),
                .files = &.{
                    "src/win32_init.c",
                    "src/win32_joystick.c",
                    "src/win32_module.c",
                    "src/win32_monitor.c",
                    "src/win32_thread.c",
                    "src/win32_time.c",
                    "src/win32_window.c",
                    "src/wgl_context.c",
                },
                .flags = platform_flags,
            });
            lib.root_module.linkSystemLibrary("gdi32", .{});
            lib.root_module.linkSystemLibrary("user32", .{});
            lib.root_module.linkSystemLibrary("shell32", .{});
        },
        .linux => {
            const wl_protos = generateWaylandProtocols(b, glfw_dep);
            lib.root_module.addIncludePath(wl_protos);

            lib.root_module.addCSourceFiles(.{
                .root = glfw_dep.path(""),
                .files = &.{
                    "src/wl_init.c",
                    "src/wl_monitor.c",
                    "src/wl_window.c",
                    "src/xkb_unicode.c",
                    "src/posix_module.c",
                    "src/posix_poll.c",
                    "src/posix_thread.c",
                    "src/posix_time.c",
                    "src/linux_joystick.c",
                },
                .flags = platform_flags,
            });
        },
        else => {},
    }

    return lib;
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

    lib.root_module.addCSourceFiles(.{
        .root = hb_dep.path("src"),
        .files = &.{"harfbuzz.cc"},
        .flags = &.{ "-DHAVE_FREETYPE=1", "-fno-exceptions", "-fno-rtti" },
    });

    lib.root_module.addCSourceFiles(.{
        .root = hb_dep.path("src"),
        .files = &.{ "hb-gpu-draw.cc", "hb-gpu-shaders.cc" },
        .flags = &.{ "-DHAVE_FREETYPE=1", "-DHAVE_HB_GPU=1", "-fno-exceptions", "-fno-rtti" },
    });

    return lib;
}

fn generateWaylandProtocols(
    b: *std.Build,
    glfw_dep: *std.Build.Dependency,
) std.Build.LazyPath {
    const protocol_xmls = [_][]const u8{
        "wayland.xml",
        "viewporter.xml",
        "xdg-shell.xml",
        "idle-inhibit-unstable-v1.xml",
        "pointer-constraints-unstable-v1.xml",
        "relative-pointer-unstable-v1.xml",
        "fractional-scale-v1.xml",
        "xdg-activation-v1.xml",
        "xdg-decoration-unstable-v1.xml",
    };

    const wf = b.addWriteFiles();

    for (protocol_xmls) |xml| {
        const name = xml[0 .. xml.len - 4];

        const header_cmd = b.addSystemCommand(&.{"wayland-scanner"});
        header_cmd.addArg("client-header");
        header_cmd.addFileArg(glfw_dep.path(b.fmt("deps/wayland/{s}", .{xml})));
        const header = header_cmd.addOutputFileArg(b.fmt("{s}-client-protocol.h", .{name}));

        const code_cmd = b.addSystemCommand(&.{"wayland-scanner"});
        code_cmd.addArg("private-code");
        code_cmd.addFileArg(glfw_dep.path(b.fmt("deps/wayland/{s}", .{xml})));
        const code = code_cmd.addOutputFileArg(b.fmt("{s}-client-protocol-code.h", .{name}));

        _ = wf.addCopyFile(header, b.fmt("{s}-client-protocol.h", .{name}));
        _ = wf.addCopyFile(code, b.fmt("{s}-client-protocol-code.h", .{name}));
    }

    return wf.getDirectory();
}
