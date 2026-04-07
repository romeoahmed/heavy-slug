//! CPU/GPU layout validation. Imports auto-generated constants from
//! tools/layout_gen (via gpu_layout module) and asserts they match
//! the Zig extern structs in descriptors.zig.
//! This file is checked in; the gpu_layout module it imports is generated at build time.

const std = @import("std");
const descriptors = @import("descriptors.zig");
const gpu = @import("gpu_layout");

// -- GlyphCommand: 64 bytes --
comptime {
    std.debug.assert(@sizeOf(descriptors.GlyphCommand) == gpu.GlyphCommand_size);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "motor") == gpu.GlyphCommand_motor_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "color") == gpu.GlyphCommand_color_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "em_x_min") == gpu.GlyphCommand_em_x_min_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "em_y_min") == gpu.GlyphCommand_em_y_min_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "em_x_max") == gpu.GlyphCommand_em_x_max_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "em_y_max") == gpu.GlyphCommand_em_y_max_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "descriptor_index") == gpu.GlyphCommand_descriptor_index_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "flags") == gpu.GlyphCommand_flags_offset);
    std.debug.assert(@offsetOf(descriptors.GlyphCommand, "_pad") == gpu.GlyphCommand__pad_offset);
}

// -- PushConstants: 80 bytes --
comptime {
    std.debug.assert(@sizeOf(descriptors.PushConstants) == gpu.PushConstants_size);
    std.debug.assert(@offsetOf(descriptors.PushConstants, "proj") == gpu.PushConstants_proj_offset);
    std.debug.assert(@offsetOf(descriptors.PushConstants, "viewport_dim") == gpu.PushConstants_viewport_dim_offset);
    std.debug.assert(@offsetOf(descriptors.PushConstants, "glyph_count") == gpu.PushConstants_glyph_count_offset);
    std.debug.assert(@offsetOf(descriptors.PushConstants, "_pad") == gpu.PushConstants__pad_offset);
}

test "layout.zig: GPU struct layouts match slangc reflection" {
    // Comptime blocks above already validated all offsets at compile time.
    // This test exists so `zig build test` reports layout validation ran.
    // If we reach here, CPU and GPU struct layouts are in agreement.
}
