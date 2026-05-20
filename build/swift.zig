//! Swift compiler wiring for macOS-only Metal and demo bridge objects.

const std = @import("std");

pub const ObjectOptions = struct {
    name: []const u8,
    source: std.Build.LazyPath,
    toolchain: Toolchain,
    optimize: std.builtin.OptimizeMode,
    extra_flags: []const []const u8 = &.{},
};

pub const RuntimeOptions = struct {
    toolchain: Toolchain,
    optimize: std.builtin.OptimizeMode,
    swiftui: bool = false,
};

const macos_sdk = "macosx";
const swift_language_version = "6";
const min_swift_version = std.SemanticVersion{ .major = 6, .minor = 3, .patch = 0 };
const swift_format_sources = [_][]const u8{
    "src/backends/metal/bridge.swift",
    "demo/platform/cocoa.swift",
};

pub const Toolchain = struct {
    target_triple: []const u8,
    swiftc_path: []const u8,
    sdk_path: []const u8,
    runtime_library_paths: []const []const u8,
};

const SwiftTargetInfo = struct {
    compilerVersion: []const u8,
    paths: SwiftTargetPaths,
};

const SwiftTargetPaths = struct {
    runtimeLibraryPaths: []const []const u8 = &.{},
};

pub fn addObject(b: *std.Build, options: ObjectOptions) std.Build.LazyPath {
    const cmd = addSwiftcCommand(b, options.toolchain);
    cmd.setName(b.fmt("swiftc {s}", .{options.name}));
    cmd.addArgs(&.{
        "-parse-as-library",
        "-emit-object",
        "-swift-version",
        swift_language_version,
        "-target",
        options.toolchain.target_triple,
        "-sdk",
        options.toolchain.sdk_path,
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

pub fn addFormatLintStep(b: *std.Build, step: *std.Build.Step) void {
    const cmd = b.addSystemCommand(&.{
        "xcrun",
        "--sdk",
        macos_sdk,
        "swift",
        "format",
        "lint",
        "--strict",
        "--parallel",
    });
    cmd.setName("swift format lint");
    for (swift_format_sources) |source| {
        cmd.addFileArg(b.path(source));
    }
    step.dependOn(&cmd.step);
}

pub fn linkRuntime(b: *std.Build, module: *std.Build.Module, options: RuntimeOptions) void {
    addRuntimeLibraryPaths(b, module, options.toolchain);

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

fn addSwiftcCommand(b: *std.Build, toolchain: Toolchain) *std.Build.Step.Run {
    return b.addSystemCommand(&.{toolchain.swiftc_path});
}

pub fn resolveToolchain(b: *std.Build, target: std.Build.ResolvedTarget) Toolchain {
    const target_triple = swiftTargetTriple(b, target.result);
    const swiftc_path = trimCommandOutput(b.run(&.{ "xcrun", "--sdk", macos_sdk, "--find", "swiftc" }));
    const sdk_path = trimCommandOutput(b.run(&.{ "xcrun", "--sdk", macos_sdk, "--show-sdk-path" }));
    const target_info = parseSwiftTargetInfo(b, b.run(&.{
        "xcrun",
        "--sdk",
        macos_sdk,
        "swiftc",
        "-print-target-info",
        "-target",
        target_triple,
        "-sdk",
        sdk_path,
    }));
    const swift_version = parseSwiftCompilerVersion(target_info.compilerVersion) orelse std.process.fatal(
        "could not parse Apple Swift compiler version from: {s}",
        .{target_info.compilerVersion},
    );
    if (swift_version.order(min_swift_version) == .lt) {
        std.process.fatal(
            "Swift bridge objects require Swift {f} or newer for @c C interoperability; xcrun selected {s} ({f})",
            .{ min_swift_version, swiftc_path, swift_version },
        );
    }

    return .{
        .target_triple = target_triple,
        .swiftc_path = swiftc_path,
        .sdk_path = sdk_path,
        .runtime_library_paths = target_info.paths.runtimeLibraryPaths,
    };
}

fn addRuntimeLibraryPaths(b: *std.Build, module: *std.Build.Module, toolchain: Toolchain) void {
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ toolchain.sdk_path, "usr/lib/swift" }) });
    for (toolchain.runtime_library_paths) |path| {
        module.addLibraryPath(.{ .cwd_relative = path });
    }
}

fn trimCommandOutput(output: []const u8) []const u8 {
    return std.mem.trim(u8, output, " \t\r\n");
}

fn parseSwiftTargetInfo(b: *std.Build, output: []const u8) SwiftTargetInfo {
    return parseSwiftTargetInfoWithAllocator(b.allocator, output) catch |err| std.process.fatal(
        "could not parse `swiftc -print-target-info` JSON: {s}: {s}",
        .{ @errorName(err), trimCommandOutput(output) },
    );
}

fn parseSwiftTargetInfoWithAllocator(allocator: std.mem.Allocator, output: []const u8) !SwiftTargetInfo {
    return std.json.parseFromSliceLeaky(SwiftTargetInfo, allocator, output, .{
        .ignore_unknown_fields = true,
    });
}

fn parseSwiftCompilerVersion(output: []const u8) ?std.SemanticVersion {
    const marker = "Swift version ";
    const start = std.mem.indexOf(u8, output, marker) orelse return null;
    const tail = output[start + marker.len ..];
    const version_text = numericVersionPrefix(tail) orelse return null;
    return parseNumericVersion(version_text);
}

fn numericVersionPrefix(text: []const u8) ?[]const u8 {
    var end: usize = 0;
    while (end < text.len) : (end += 1) {
        switch (text[end]) {
            '0'...'9', '.' => {},
            else => break,
        }
    }
    if (end == 0) {
        return null;
    }
    return text[0..end];
}

fn parseNumericVersion(text: []const u8) ?std.SemanticVersion {
    var parts = std.mem.splitScalar(u8, text, '.');
    const major = parseVersionPart(parts.next() orelse return null) orelse return null;
    const minor = parseVersionPart(parts.next() orelse return null) orelse return null;
    const patch = if (parts.next()) |part| parseVersionPart(part) orelse return null else 0;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseVersionPart(text: []const u8) ?usize {
    if (text.len == 0) {
        return null;
    }
    for (text) |byte| {
        if (!std.ascii.isDigit(byte)) {
            return null;
        }
    }
    return std.fmt.parseInt(usize, text, 10) catch null;
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

test "Swift compiler version parser accepts Apple and upstream output" {
    const apple = parseSwiftCompilerVersion(
        "swift-driver version: 1.148.6 Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)",
    ).?;
    try std.testing.expectEqual(@as(usize, 6), apple.major);
    try std.testing.expectEqual(@as(usize, 3), apple.minor);
    try std.testing.expectEqual(@as(usize, 2), apple.patch);

    const upstream = parseSwiftCompilerVersion("Swift version 6.4-dev (LLVM abcdef)") orelse return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 6), upstream.major);
    try std.testing.expectEqual(@as(usize, 4), upstream.minor);
    try std.testing.expectEqual(@as(usize, 0), upstream.patch);

    try std.testing.expect(parseSwiftCompilerVersion("clang version 18.0.0") == null);
}

test "Swift target info parser keeps compiler version and runtime paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();

    const info = try parseSwiftTargetInfoWithAllocator(arena.allocator(),
        \\{
        \\  "compilerVersion": "Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)",
        \\  "target": { "triple": "arm64-apple-macosx26.0" },
        \\  "paths": {
        \\    "runtimeLibraryPaths": [
        \\      "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
        \\      "/usr/lib/swift"
        \\    ]
        \\  }
        \\}
    );
    try std.testing.expectEqualStrings(
        "Apple Swift version 6.3.2 (swiftlang-6.3.2.1.108 clang-2100.1.1.101)",
        info.compilerVersion,
    );
    try std.testing.expectEqual(@as(usize, 2), info.paths.runtimeLibraryPaths.len);
    try std.testing.expectEqualStrings(
        "/Applications/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift/macosx",
        info.paths.runtimeLibraryPaths[0],
    );
}
