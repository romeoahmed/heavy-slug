//! Backend-neutral GPU ABI provenance.
//!
//! CPU-visible shader structs are generated from `slangc -reflection-json`.
//! This module intentionally describes the contract, not the generated structs:
//! backend modules import the generated `gpu_structs` module produced by the
//! build graph.

const std = @import("std");

pub const Source = enum {
    slang_reflection,
};

pub const LayoutPolicy = enum {
    reflection_generated_extern_structs,
};

pub const source: Source = .slang_reflection;
pub const layout_policy: LayoutPolicy = .reflection_generated_extern_structs;

pub const RequiredStruct = enum {
    GlyphInstance,
    GlyphMeshlet,
    FrameParams,
};

pub const RequiredConstant = enum {
    kMeshThreadCount,
    kMeshOutputVertices,
    kMeshOutputPrimitives,
    kMaxMergedCandidateBands,
};

pub const required_structs = [_]RequiredStruct{
    .GlyphInstance,
    .GlyphMeshlet,
    .FrameParams,
};

pub const required_constants = [_]RequiredConstant{
    .kMeshThreadCount,
    .kMeshOutputVertices,
    .kMeshOutputPrimitives,
    .kMaxMergedCandidateBands,
};

test "GPU ABI is reflection-generated and lists the CPU visible structs" {
    try std.testing.expectEqual(Source.slang_reflection, source);
    try std.testing.expectEqual(LayoutPolicy.reflection_generated_extern_structs, layout_policy);
    try std.testing.expectEqual(@as(usize, 3), required_structs.len);
    try std.testing.expectEqual(@as(usize, 4), required_constants.len);
}
