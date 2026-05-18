//! Shared Objective-C++ compiler policy for Metal/Cocoa bridge sources.

const std = @import("std");

pub fn flags(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    extra: []const []const u8,
) []const []const u8 {
    const base = [_][]const u8{
        "-std=c++23",
        "-fobjc-arc",
        "-fno-exceptions",
        "-fno-cxx-exceptions",
        "-fno-objc-exceptions",
        "-fno-objc-arc-exceptions",
        "-fno-rtti",
        "-Wall",
        "-Wextra",
        "-Wpedantic",
        "-Wconversion",
        "-Wsign-conversion",
        "-Wshadow",
        "-Wformat=2",
        "-Wundef",
        "-Wnon-virtual-dtor",
        "-Woverloaded-virtual",
        "-Wimplicit-fallthrough",
        "-Wextra-semi",
        "-Wnewline-eof",
        "-Werror",
    };

    const result = b.allocator.alloc([]const u8, base.len + 1 + extra.len) catch
        @panic("failed to allocate Objective-C++ compiler flags");

    var index: usize = 0;
    for (base) |flag| {
        result[index] = flag;
        index += 1;
    }
    result[index] = optimizeFlag(optimize);
    index += 1;
    for (extra) |flag| {
        result[index] = flag;
        index += 1;
    }
    return result;
}

fn optimizeFlag(optimize: std.builtin.OptimizeMode) []const u8 {
    return switch (optimize) {
        .Debug => "-O0",
        .ReleaseSafe, .ReleaseFast => "-O3",
        .ReleaseSmall => "-Os",
    };
}
