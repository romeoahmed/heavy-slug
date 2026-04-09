//! CPU/GPU layout validation. Imports auto-generated constants from
//! tools/layout_gen (via gpu_layout module) and asserts they match
//! the Zig extern structs in descriptors.zig.
//! This file is checked in; the gpu_layout module it imports is generated at build time.

const std = @import("std");
const descriptors = @import("descriptors.zig");
const gpu = @import("gpu_layout");

// -- GlyphCommand: 64 bytes --
comptime {
    if (@sizeOf(descriptors.GlyphCommand) != gpu.GlyphCommand_size)
        @compileError("GlyphCommand size mismatch: Slang struct changed without updating Zig extern");
    if (@offsetOf(descriptors.GlyphCommand, "motor") != gpu.GlyphCommand_motor_offset)
        @compileError("GlyphCommand.motor offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "color") != gpu.GlyphCommand_color_offset)
        @compileError("GlyphCommand.color offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "em_x_min") != gpu.GlyphCommand_em_x_min_offset)
        @compileError("GlyphCommand.em_x_min offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "em_y_min") != gpu.GlyphCommand_em_y_min_offset)
        @compileError("GlyphCommand.em_y_min offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "em_x_max") != gpu.GlyphCommand_em_x_max_offset)
        @compileError("GlyphCommand.em_x_max offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "em_y_max") != gpu.GlyphCommand_em_y_max_offset)
        @compileError("GlyphCommand.em_y_max offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "descriptor_index") != gpu.GlyphCommand_descriptor_index_offset)
        @compileError("GlyphCommand.descriptor_index offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "flags") != gpu.GlyphCommand_flags_offset)
        @compileError("GlyphCommand.flags offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.GlyphCommand, "_pad") != gpu.GlyphCommand__pad_offset)
        @compileError("GlyphCommand._pad offset mismatch: accidental padding change shifted subsequent fields");
}

// -- PushConstants: 80 bytes --
comptime {
    if (@sizeOf(descriptors.PushConstants) != gpu.PushConstants_size)
        @compileError("PushConstants size mismatch: Slang struct changed without updating Zig extern");
    if (@offsetOf(descriptors.PushConstants, "proj") != gpu.PushConstants_proj_offset)
        @compileError("PushConstants.proj offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.PushConstants, "viewport_dim") != gpu.PushConstants_viewport_dim_offset)
        @compileError("PushConstants.viewport_dim offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.PushConstants, "glyph_count") != gpu.PushConstants_glyph_count_offset)
        @compileError("PushConstants.glyph_count offset mismatch: Slang struct layout changed");
    if (@offsetOf(descriptors.PushConstants, "glyph_base") != gpu.PushConstants_glyph_base_offset)
        @compileError("PushConstants.glyph_base offset mismatch: Slang struct layout changed");
}

test "layout.zig: GPU struct layouts match slangc reflection" {
    // Comptime blocks above already validated all offsets at compile time.
    // This test exists so `zig build test` reports layout validation ran.
    // If we reach here, CPU and GPU struct layouts are in agreement.
}
