//! Swift compiler wiring for macOS-only Metal and demo bridge objects.

const std = @import("std");

pub const ObjectOptions = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    extra_flags: []const []const u8 = &.{},
};

pub const RuntimeOptions = struct {
    optimize: std.builtin.OptimizeMode,
    swiftui: bool = false,
};

pub fn addObject(b: *std.Build, options: ObjectOptions) std.Build.LazyPath {
    const cmd = b.addSystemCommand(&.{"swiftc"});
    cmd.addArgs(&.{
        "-parse-as-library",
        "-emit-object",
        "-swift-version",
        "6",
        "-target",
        swiftTargetTriple(b, options.target.result),
        "-module-name",
        options.name,
        "-module-cache-path",
    });
    _ = cmd.addOutputDirectoryArg(b.fmt("{s}-module-cache", .{options.name}));
    cmd.addArgs(optimizeFlags(options.optimize));
    cmd.addArgs(options.extra_flags);
    cmd.addArg("-o");
    const object = cmd.addOutputFileArg(b.fmt("{s}.o", .{options.name}));
    cmd.addFileArg(options.source);
    return object;
}

pub fn linkRuntime(b: *std.Build, module: *std.Build.Module, options: RuntimeOptions) void {
    addRuntimeLibraryPaths(b, module);

    for (swift_libraries) |library| {
        module.linkSystemLibrary(library, .{});
    }
    if (options.optimize == .Debug) {
        for (debug_swift_libraries) |library| {
            module.linkSystemLibrary(library, .{});
        }
    }
    if (options.swiftui) {
        for (swiftui_libraries) |library| {
            module.linkSystemLibrary(library, .{});
        }
    }

    for (system_libraries) |library| {
        module.linkSystemLibrary(library, .{});
    }
    for (metal_frameworks) |framework| {
        module.linkFramework(framework, .{});
    }
    if (options.swiftui) {
        for (swiftui_frameworks) |framework| {
            module.linkFramework(framework, .{});
        }
    }
}

fn optimizeFlags(optimize: std.builtin.OptimizeMode) []const []const u8 {
    return switch (optimize) {
        .Debug => &.{"-Onone"},
        .ReleaseSafe, .ReleaseFast => &.{"-O"},
        .ReleaseSmall => &.{"-Osize"},
    };
}

fn swiftTargetTriple(b: *std.Build, target: std.Target) []const u8 {
    if (target.os.tag != .macos) {
        std.process.fatal("Swift bridge objects are supported only for macOS targets", .{});
    }

    const min_version = target.os.version_range.semver.min;
    const metal4_min = std.SemanticVersion{ .major = 26, .minor = 0, .patch = 0 };
    if (min_version.order(metal4_min) == .lt) {
        std.process.fatal(
            "Metal 4 Swift bridge objects require a macOS 26.0 or newer deployment target; got {f}",
            .{min_version},
        );
    }

    return b.fmt("{s}-apple-macosx{s}", .{
        swiftArchName(target.cpu.arch),
        macosVersionString(b, min_version),
    });
}

fn swiftArchName(arch: std.Target.Cpu.Arch) []const u8 {
    return switch (arch) {
        .aarch64 => "arm64",
        .x86_64 => "x86_64",
        else => std.process.fatal(
            "Swift Metal bridge objects support only arm64 and x86_64 macOS targets; got {s}",
            .{@tagName(arch)},
        ),
    };
}

fn macosVersionString(b: *std.Build, version: std.SemanticVersion) []const u8 {
    if (version.patch == 0) {
        return b.fmt("{d}.{d}", .{ version.major, version.minor });
    }
    return b.fmt("{d}.{d}.{d}", .{ version.major, version.minor, version.patch });
}

fn addRuntimeLibraryPaths(b: *std.Build, module: *std.Build.Module) void {
    const sdk_path = trimCommandOutput(b.run(&.{ "xcrun", "--show-sdk-path" }));
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk_path, "usr/lib/swift" }) });
    module.addLibraryPath(.{ .cwd_relative = "/usr/lib/swift" });

    const swiftc_path = trimCommandOutput(b.run(&.{ "xcrun", "--find", "swiftc" }));
    if (std.fs.path.dirname(swiftc_path)) |bin_dir| {
        if (std.fs.path.dirname(bin_dir)) |usr_dir| {
            module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ usr_dir, "lib/swift/macosx" }) });
        }
    }
}

fn trimCommandOutput(output: []const u8) []const u8 {
    return std.mem.trim(u8, output, " \t\r\n");
}

// Swift object files record these in LC_LINKER_OPTION, but Zig 0.16 does not
// consume Swift autolink commands from standalone object files. Keep this list
// in sync with `otool -l` for the bridge sources compiled by Swift 6.3.
const swift_libraries = [_][]const u8{
    "swiftCore",
    "swiftCoreFoundation",
    "swiftDarwin",
    "swiftDispatch",
    "swiftFoundation",
    "swiftIOKit",
    "swiftMetal",
    "swiftObjectiveC",
    "swiftObservation",
    "swiftQuartzCore",
    "swiftSystem",
    "swiftUniformTypeIdentifiers",
    "swiftXPC",
    "swift_Builtin_float",
    "swift_Concurrency",
    "swift_DarwinFoundation1",
    "swift_DarwinFoundation2",
    "swift_DarwinFoundation3",
    "swift_StringProcessing",
};

const debug_swift_libraries = [_][]const u8{
    "swiftSwiftOnoneSupport",
};

const swiftui_libraries = [_][]const u8{
    "swiftCoreImage",
    "swiftOSLog",
    "swiftSpatial",
    "swiftos",
    "swiftsimd",
};

const system_libraries = [_][]const u8{
    "cups",
    "objc",
};

const metal_frameworks = [_][]const u8{
    "ApplicationServices",
    "CFNetwork",
    "ColorSync",
    "Combine",
    "CoreFoundation",
    "CoreGraphics",
    "CoreServices",
    "CoreText",
    "CoreVideo",
    "DiskArbitration",
    "Foundation",
    "IOKit",
    "IOSurface",
    "ImageIO",
    "Metal",
    "OpenGL",
    "QuartzCore",
    "Security",
    "UniformTypeIdentifiers",
};

const swiftui_frameworks = [_][]const u8{
    "Accessibility",
    "AppKit",
    "CoreData",
    "CoreImage",
    "CoreTransferable",
    "DataDetection",
    "DeveloperToolsSupport",
    "OSLog",
    "SwiftUI",
    "SwiftUICore",
    "Symbols",
};

test "Swift optimize flags match Zig optimize modes" {
    try std.testing.expectEqualStrings("-Onone", optimizeFlags(.Debug)[0]);
    try std.testing.expectEqualStrings("-O", optimizeFlags(.ReleaseSafe)[0]);
    try std.testing.expectEqualStrings("-O", optimizeFlags(.ReleaseFast)[0]);
    try std.testing.expectEqualStrings("-Osize", optimizeFlags(.ReleaseSmall)[0]);
}

test "Swift target triples use Apple Swift arch and macOS spelling" {
    try std.testing.expectEqualStrings("arm64", swiftArchName(.aarch64));
    try std.testing.expectEqualStrings("x86_64", swiftArchName(.x86_64));
}
