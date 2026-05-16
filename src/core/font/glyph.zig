//! Glyph outline encoding facade used by loaded fonts.

const std = @import("std");
const hb = @import("harfbuzz.zig");
const outline = @import("../outline/encode.zig");
const blob_mod = @import("../blob/format.zig");

/// Encoded glyph data plus metrics and debug counters.
pub const EncodedGlyph = struct {
    data: []const u8,
    extents: hb.GlyphExtents,
    blob: blob_mod.CoverageBlob,
    outline_segments: u32,
    regularized_spans: u32,

    pub fn destroy(self: EncodedGlyph) void {
        var blob = self.blob;
        blob.deinit();
    }
};

/// Reusable glyph encoder that owns the outline capture state.
pub const GlyphEncoder = struct {
    outline_encoder: outline.Encoder,

    pub fn init(allocator: std.mem.Allocator) !GlyphEncoder {
        return .{ .outline_encoder = try outline.Encoder.init(allocator) };
    }

    pub fn deinit(self: *GlyphEncoder) void {
        self.outline_encoder.deinit();
        self.* = undefined;
    }

    pub fn encodeGlyph(self: *GlyphEncoder, font: hb.Font, glyph_id: u32) !EncodedGlyph {
        const encoded = try self.outline_encoder.encodeGlyph(font, glyph_id);
        const bytes = encoded.blob.bytes();
        return .{
            .data = bytes,
            .extents = encoded.extents,
            .blob = encoded.blob,
            .outline_segments = encoded.outline_segments,
            .regularized_spans = encoded.regularized_spans,
        };
    }
};

const ft = @import("freetype.zig");
const shape = @import("shape.zig");
const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test "GlyphEncoder: captures native outlines and encodes CoverageBlob" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    const face = ft.Face.init(ft_lib, test_font_path, 0) catch return;
    defer face.deinit();
    try face.setPixelSizes(0, 32);

    const font = try hb.Font.createFromFtFace(face.rawHandle());
    defer font.destroy();

    var plan = try shape.ShapePlan.init();
    defer plan.deinit();
    const run = try plan.shape(font, "S", .{});
    const glyph_id = run.infos[0].codepoint;

    var encoder = try GlyphEncoder.init(std.testing.allocator);
    defer encoder.deinit();

    const encoded = try encoder.encodeGlyph(font, glyph_id);
    defer encoded.destroy();

    try std.testing.expect(encoded.data.len > 0);
    try std.testing.expect(encoder.outline_encoder.capture.stream.segments.items.len > 0);
    try std.testing.expect(encoder.outline_encoder.spans.items.len > 0);
}
