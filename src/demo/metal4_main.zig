//! macOS Metal 4 demo entry point.
//!
//! The build graph selects this target for macOS demo builds so the Vulkan
//! SPIR-V path remains Windows/Linux-only. The Metal renderer implementation
//! will live behind this entry point.

const std = @import("std");

pub fn main() !void {
    std.debug.print(
        "heavy-slug Metal 4 demo backend is selected, but the Metal renderer is not implemented yet.\n",
        .{},
    );
}
