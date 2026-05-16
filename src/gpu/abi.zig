//! Marker for the generated GPU ABI source.

pub const Source = enum {
    slang_reflection,
};

pub const source: Source = .slang_reflection;

test "GPU ABI source is reflection-generated" {
    try @import("std").testing.expectEqual(Source.slang_reflection, source);
}
