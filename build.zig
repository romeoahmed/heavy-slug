const std = @import("std");

const DemoBackend = enum {
    auto,
    vulkan_spirv16,
    metal4,
};

const ResolvedDemoBackend = enum {
    vulkan_spirv16,
    metal4,
};

const ThinLtoMode = enum {
    auto,
    on,
    off,
};

const SpirvShaders = struct {
    task: std.Build.LazyPath,
    mesh: std.Build.LazyPath,
    fragment: std.Build.LazyPath,
    module: *std.Build.Module,
};

const MetalShaders = struct {
    task: std.Build.LazyPath,
    mesh: std.Build.LazyPath,
    fragment: std.Build.LazyPath,
    module: *std.Build.Module,
};

const VulkanBackend = struct {
    module: *std.Build.Module,
    bindings: *std.Build.Module,
    headers: *std.Build.Dependency,
};

const MetalBackend = struct {
    module: *std.Build.Module,
};

const CoreCDeps = struct {
    freetype: *std.Build.Dependency,
    harfbuzz: *std.Build.Dependency,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const build_demo = b.option(bool, "demo", "Build demo executable") orelse false;
    const demo_backend_opt = b.option(DemoBackend, "demo-backend", "Demo backend: auto, vulkan_spirv16, metal4") orelse .auto;
    const thin_lto_mode = b.option(ThinLtoMode, "thinlto", "ThinLTO: auto, on, off") orelse .auto;
    const demo_backend = resolveDemoBackend(target.result.os.tag, demo_backend_opt);
    const build_vulkan = (b.option(bool, "vulkan", "Build the Vulkan SPIR-V 1.6 backend module") orelse false) or
        (build_demo and demo_backend == .vulkan_spirv16);
    const build_metal = (b.option(bool, "metal", "Build the Metal 4 backend module") orelse false) or
        (build_demo and demo_backend == .metal4);
    if (build_metal and target.result.os.tag != .macos) {
        std.process.fatal("Metal backend is supported only on macOS targets", .{});
    }

    // --- Shader compilation: Slang -> SPIR-V ---
    const shader_step = b.step("shaders", "Compile Slang shaders to SPIR-V");
    const spirv = buildSpirvShaders(b);
    addShaderInstallSteps(b, shader_step, spirv);
    const metal_shader_step = b.step("metal-shaders", "Compile Slang shaders to Metal source");
    const metal_shaders = buildMetalShaders(b);
    addMetalShaderInstallSteps(b, metal_shader_step, metal_shaders);

    // --- Library module ---
    const mod = b.addModule("heavy_slug", .{
        .root_source_file = b.path("src/root.zig"),
        .target = target,
    });

    // --- C libraries (library deps only: FreeType + HarfBuzz) ---
    const c_deps = CoreCDeps{
        .freetype = b.dependency("freetype_src", .{}),
        .harfbuzz = b.dependency("harfbuzz_src", .{}),
    };
    const ft_lib = buildFreetype(b, target, optimize, c_deps.freetype);
    const hb_lib = buildHarfbuzz(b, target, optimize, c_deps, ft_lib);
    const c_mod = translateHeavySlugC(b, target, optimize, c_deps);
    mod.addImport("heavy_slug_c", c_mod);
    mod.linkLibrary(ft_lib);
    mod.linkLibrary(hb_lib);

    // --- ThinLTO for release builds ---
    const use_lto = resolveThinLto(optimize, target.result, thin_lto_mode);
    enableThinLtoAll(use_lto, &.{ ft_lib, hb_lib });

    // --- Tests ---
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = mod })).step);
    test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("tools/layout_gen.zig"),
        .target = b.graph.host,
    }) })).step);

    const vulkan_backend = if (build_vulkan) buildVulkanBackend(b, target, mod, spirv) orelse return else null;
    if (vulkan_backend) |backend| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = backend.module })).step);
    }
    const metal_backend = if (build_metal) buildMetalBackend(b, target, mod, metal_shaders) else null;
    if (metal_backend) |backend| {
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = backend.module })).step);
    }

    // --- Demo executable (opt-in via -Ddemo) ---
    if (build_demo) {
        const exe = switch (demo_backend) {
            .vulkan_spirv16 => buildVulkanDemo(
                b,
                target,
                optimize,
                mod,
                vulkan_backend.?,
                use_lto,
            ) orelse return,
            .metal4 => buildMetalDemo(b, target, optimize, mod, metal_backend.?, use_lto) orelse return,
        };

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

fn resolveDemoBackend(
    os: std.Target.Os.Tag,
    requested: DemoBackend,
) ResolvedDemoBackend {
    const resolved: ResolvedDemoBackend = switch (requested) {
        .auto => switch (os) {
            .windows, .linux => .vulkan_spirv16,
            .macos => .metal4,
            else => std.process.fatal("unsupported demo target OS: {s}", .{@tagName(os)}),
        },
        .vulkan_spirv16 => .vulkan_spirv16,
        .metal4 => .metal4,
    };

    switch (resolved) {
        .vulkan_spirv16 => switch (os) {
            .windows, .linux => {},
            else => std.process.fatal("demo-backend=vulkan_spirv16 is supported on Windows/Linux targets; {s} selects the Metal 4 demo path", .{@tagName(os)}),
        },
        .metal4 => if (os != .macos) {
            std.process.fatal("demo-backend=metal4 is supported only on macOS targets", .{});
        },
    }

    return resolved;
}

fn resolveThinLto(
    optimize: std.builtin.OptimizeMode,
    target: std.Target,
    mode: ThinLtoMode,
) bool {
    if (optimize == .Debug or mode == .off) return false;

    // Zig 0.16 emits "LTO requires using LLD", but also reports
    // "using LLD to link macho files is unsupported" for native macOS.
    const can_link_with_lld = target.ofmt != .macho;
    if (!can_link_with_lld) {
        if (mode == .on) {
            std.process.fatal("ThinLTO is unsupported for Mach-O targets in Zig 0.16 because LLD Mach-O linking is unavailable", .{});
        }
        return false;
    }

    return true;
}

fn buildSpirvShaders(b: *std.Build) SpirvShaders {
    const task_spv = compileSlangShader(b, "slug_task.spv", "shaders/slug_task.slang", "taskMain", "amplification", "spvGroupNonUniform+spvGroupNonUniformBallot");
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

    return .{
        .task = task_spv,
        .mesh = mesh_spv,
        .fragment = frag_spv,
        .module = b.addModule("shader_spv", .{ .root_source_file = spv_zig }),
    };
}

fn buildMetalShaders(b: *std.Build) MetalShaders {
    const task_msl = compileSlangMetalShader(b, "slug_task.metal", "shaders/slug_task.slang", "taskMain", "amplification");
    const mesh_msl = compileSlangMetalShader(b, "slug_mesh.metal", "shaders/slug_mesh.slang", "meshMain", "mesh");
    const frag_msl = compileSlangMetalShader(b, "slug_fragment.metal", "shaders/slug_fragment.slang", "fragmentMain", "fragment");

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

fn addShaderInstallSteps(
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

fn addMetalShaderInstallSteps(
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

fn buildVulkanBackend(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    core_mod: *std.Build.Module,
    spirv: SpirvShaders,
) ?VulkanBackend {
    const vk_headers = b.lazyDependency("vulkan_headers", .{});
    const vk_dep = b.lazyDependency("vulkan", .{});
    if (vk_headers == null or vk_dep == null) return null;

    const registry = vk_headers.?.path("registry/vk.xml");
    const vk_gen = vk_dep.?.artifact("vulkan-zig-generator");
    const vk_generate_cmd = b.addRunArtifact(vk_gen);
    vk_generate_cmd.addFileArg(registry);
    const vulkan_zig = b.addModule("vulkan-zig", .{
        .root_source_file = vk_generate_cmd.addOutputFileArg("vk.zig"),
    });

    const reflection_json = generateReflectionJson(b);
    const gpu_structs_zig = generateGpuStructs(b, reflection_json);
    const gpu_structs_mod = b.addModule("gpu_structs", .{ .root_source_file = gpu_structs_zig });

    const mod = b.addModule("heavy_slug_vulkan", .{
        .root_source_file = b.path("src/vulkan/root.zig"),
        .target = target,
    });
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("vulkan", vulkan_zig);
    mod.addImport("shader_spv", spirv.module);
    mod.addImport("gpu_structs", gpu_structs_mod);

    return .{
        .module = mod,
        .bindings = vulkan_zig,
        .headers = vk_headers.?,
    };
}

fn buildMetalBackend(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    core_mod: *std.Build.Module,
    metal_shaders: MetalShaders,
) MetalBackend {
    const reflection_json = generateReflectionJson(b);
    const gpu_structs_zig = generateGpuStructs(b, reflection_json);
    const gpu_structs_mod = b.addModule("gpu_structs", .{ .root_source_file = gpu_structs_zig });

    const mod = b.addModule("heavy_slug_metal", .{
        .root_source_file = b.path("src/metal/root.zig"),
        .target = target,
    });
    mod.addImport("heavy_slug", core_mod);
    mod.addImport("metal_shaders", metal_shaders.module);
    mod.addImport("gpu_structs", gpu_structs_mod);
    mod.addIncludePath(b.path("src/metal"));
    mod.link_libcpp = true;
    mod.linkFramework("QuartzCore", .{});
    mod.linkFramework("Metal", .{});
    mod.linkFramework("Foundation", .{});
    mod.addCSourceFiles(.{
        .root = b.path("src/metal"),
        .files = &.{"bridge.mm"},
        .flags = &.{ "-std=c++17", "-fobjc-arc" },
    });

    return .{ .module = mod };
}

fn buildVulkanDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    backend: VulkanBackend,
    use_lto: bool,
) ?*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "heavy_slug",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = core_mod },
                .{ .name = "heavy_slug_vulkan", .module = backend.module },
                .{ .name = "vulkan", .module = backend.bindings },
            },
        }),
    });

    const glfw_dep = b.lazyDependency("glfw_src", .{}) orelse return null;
    const glfw_lib = buildGlfw(b, glfw_dep, backend.headers, target, optimize);
    const glfw_c = translateGlfwC(b, target, optimize, glfw_dep);
    exe.root_module.linkLibrary(glfw_lib);
    exe.root_module.addImport("glfw_c", glfw_c);
    exe.root_module.addIncludePath(glfw_dep.path("include"));

    if (target.result.os.tag == .linux) {
        exe.root_module.linkSystemLibrary("wayland-client", .{});
        exe.root_module.linkSystemLibrary("wayland-cursor", .{});
        exe.root_module.linkSystemLibrary("wayland-egl", .{});
        exe.root_module.linkSystemLibrary("xkbcommon", .{});
    }

    enableThinLtoAll(use_lto, &.{ glfw_lib, exe });

    return exe;
}

fn buildMetalDemo(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    core_mod: *std.Build.Module,
    backend: MetalBackend,
    use_lto: bool,
) ?*std.Build.Step.Compile {
    const exe = b.addExecutable(.{
        .name = "heavy_slug_metal4",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/demo/metal4_main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "heavy_slug", .module = core_mod },
                .{ .name = "heavy_slug_metal", .module = backend.module },
            },
        }),
    });

    const glfw_dep = b.lazyDependency("glfw_src", .{}) orelse return null;
    const glfw_lib = buildGlfw(b, glfw_dep, null, target, optimize);
    const glfw_c = translateGlfwC(b, target, optimize, glfw_dep);
    exe.root_module.linkLibrary(glfw_lib);
    exe.root_module.addImport("glfw_c", glfw_c);
    exe.root_module.addIncludePath(glfw_dep.path("include"));
    exe.root_module.addIncludePath(b.path("src/demo"));
    exe.root_module.link_libcpp = true;
    exe.root_module.linkFramework("Cocoa", .{});
    exe.root_module.linkFramework("QuartzCore", .{});
    exe.root_module.linkFramework("Metal", .{});
    exe.root_module.linkFramework("Foundation", .{});
    exe.root_module.addCSourceFiles(.{
        .root = b.path("src/demo"),
        .files = &.{"metal_host.mm"},
        .flags = &.{ "-std=c++17", "-fobjc-arc" },
    });

    enableThinLtoAll(use_lto, &.{ glfw_lib, exe });

    return exe;
}

fn enableThinLtoAll(enabled: bool, compile_steps: []const *std.Build.Step.Compile) void {
    if (!enabled) return;
    for (compile_steps) |compile_step| {
        compile_step.use_lld = true;
        compile_step.lto = .thin;
    }
}

fn translateHeavySlugC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: CoreCDeps,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/heavy_slug.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(deps.freetype.path("include"));
    translate.addIncludePath(deps.harfbuzz.path("src"));
    return translate.createModule();
}

fn translateGlfwC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    glfw_dep: *std.Build.Dependency,
) *std.Build.Module {
    const translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/glfw.h"),
        .target = target,
        .optimize = optimize,
    });
    translate.addIncludePath(glfw_dep.path("include"));
    return translate.createModule();
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
    cmd.addArgs(&.{"-DHEAVY_SLUG_METAL=0"});
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

fn compileSlangMetalShader(
    b: *std.Build,
    name: []const u8,
    source: []const u8,
    entry: []const u8,
    stage: []const u8,
) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path(source));
    cmd.addArgs(&.{"-DHEAVY_SLUG_METAL=1"});
    cmd.addArgs(&.{ "-entry", entry });
    cmd.addArgs(&.{ "-stage", stage });
    cmd.addArgs(&.{ "-target", "metal" });
    cmd.addArgs(&.{ "-capability", "metallib_4_0" });
    cmd.addArgs(&.{"-matrix-layout-column-major"});
    cmd.addArgs(&.{ "-I", "shaders" });
    cmd.addArgs(&.{"-O2"});
    cmd.addArg("-o");
    return cmd.addOutputFileArg(name);
}

fn generateReflectionJson(b: *std.Build) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"slangc"});
    cmd.addFileArg(b.path("shaders/slug_task.slang"));
    cmd.addArgs(&.{"-DHEAVY_SLUG_METAL=0"});
    cmd.addArgs(&.{ "-entry", "taskMain" });
    cmd.addArgs(&.{ "-stage", "amplification" });
    cmd.addArgs(&.{ "-target", "spirv" });
    cmd.addArgs(&.{ "-profile", "spirv_1_6+spvGroupNonUniform+spvGroupNonUniformBallot" });
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
    glfw_dep: *std.Build.Dependency,
    vk_headers: ?*std.Build.Dependency,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) *std.Build.Step.Compile {
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
    if (vk_headers) |headers| {
        lib.root_module.addIncludePath(headers.path("include"));
    }

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
        .macos => {
            lib.root_module.addCSourceFiles(.{
                .root = glfw_dep.path(""),
                .files = &.{
                    "src/cocoa_init.m",
                    "src/cocoa_joystick.m",
                    "src/cocoa_monitor.m",
                    "src/cocoa_window.m",
                    "src/nsgl_context.m",
                    "src/cocoa_time.c",
                    "src/posix_module.c",
                    "src/posix_thread.c",
                },
                .flags = platform_flags,
            });
            lib.root_module.linkFramework("Cocoa", .{});
            lib.root_module.linkFramework("IOKit", .{});
            lib.root_module.linkFramework("CoreFoundation", .{});
        },
        else => {},
    }

    return lib;
}

fn buildFreetype(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ft_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
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
    deps: CoreCDeps,
    ft_lib: *std.Build.Step.Compile,
) *std.Build.Step.Compile {
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

    lib.root_module.addIncludePath(deps.harfbuzz.path("src"));
    lib.root_module.addIncludePath(deps.freetype.path("include"));
    lib.root_module.linkLibrary(ft_lib);

    lib.root_module.addCSourceFiles(.{
        .root = deps.harfbuzz.path("src"),
        .files = &.{"harfbuzz.cc"},
        .flags = &.{ "-DHAVE_FREETYPE=1", "-fno-exceptions", "-fno-rtti" },
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
