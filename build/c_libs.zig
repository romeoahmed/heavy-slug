//! Build-system helpers for translated C headers and bundled C libraries.

const std = @import("std");

pub const CoreDeps = struct {
    freetype: *std.Build.Dependency,
    harfbuzz: *std.Build.Dependency,
};

pub fn resolveCoreDeps(b: *std.Build) CoreDeps {
    return .{
        .freetype = b.dependency("freetype_src", .{}),
        .harfbuzz = b.dependency("harfbuzz_src", .{}),
    };
}

pub fn buildFreetype(
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

pub fn buildHarfbuzz(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: CoreDeps,
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

pub fn translateHeavySlugC(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    deps: CoreDeps,
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

pub fn translateGlfwC(
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

pub fn buildGlfw(
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
