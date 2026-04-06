const std = @import("std");
const ft = @import("ft.zig");
const hb = @import("hb.zig");

/// Result of encoding a single glyph for GPU upload.
pub const EncodedGlyph = struct {
    /// Slug-format blob data. Owned by the blob — valid until blob.destroy().
    data: []const u8,
    /// Em-space bounding box from HarfBuzz.
    extents: hb.GlyphExtents,
    /// The underlying blob handle. Caller must call destroy() when done.
    blob: hb.Blob,

    pub fn destroy(self: EncodedGlyph) void {
        self.blob.destroy();
    }
};

/// Font context for text shaping and glyph encoding.
/// Holds an FT_Face + hb_font_t + reusable hb_gpu_draw_t.
pub const FontContext = struct {
    ft_face: ft.Face,
    hb_font: hb.Font,
    gpu_draw: hb.GpuDraw,

    /// Load a font from a file path at the given pixel size.
    pub fn init(ft_lib: ft.Library, path: [*:0]const u8, size_px: u32) !FontContext {
        const face = try ft.Face.init(ft_lib, path);
        errdefer face.deinit();

        try face.setPixelSizes(0, size_px);

        const font = try hb.Font.createFromFtFace(face.rawHandle());
        errdefer font.destroy();

        const gpu_draw = try hb.GpuDraw.create();

        return .{
            .ft_face = face,
            .hb_font = font,
            .gpu_draw = gpu_draw,
        };
    }

    pub fn deinit(self: *FontContext) void {
        self.gpu_draw.destroy();
        self.hb_font.destroy();
        self.ft_face.deinit();
        self.* = undefined;
    }

    /// Encode a single glyph into a Slug-format blob for GPU upload.
    /// The returned EncodedGlyph owns the blob — caller must call .destroy().
    pub fn encodeGlyph(self: *FontContext, glyph_id: u32) !EncodedGlyph {
        self.gpu_draw.drawGlyph(self.hb_font, glyph_id);
        const blob = try self.gpu_draw.encode();
        const extents = self.gpu_draw.getExtents();
        self.gpu_draw.reset();
        return .{
            .data = blob.getData(),
            .extents = extents,
            .blob = blob,
        };
    }

    /// Shape a UTF-8 string. Returns a buffer whose getGlyphInfos()/getGlyphPositions()
    /// contain the shaped results. Caller owns the returned buffer.
    /// Pass null for direction/script to let HarfBuzz auto-detect from the text.
    pub fn shapeText(
        self: *FontContext,
        text: []const u8,
        opt_dir: ?hb.Direction,
        opt_script: ?hb.Script,
    ) !hb.Buffer {
        const buf = try hb.Buffer.create();
        buf.addUtf8(text);
        if (opt_dir) |dir| buf.setDirection(dir);
        if (opt_script) |script| buf.setScript(script);
        if (opt_dir == null and opt_script == null) buf.guessSegmentProperties();
        hb.shape(self.hb_font, buf);
        return buf;
    }
};

const test_font_path: [*:0]const u8 = "C:/Windows/Fonts/segoeui.ttf";

test "FontContext: load font and encode glyph" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    var ctx = FontContext.init(ft_lib, test_font_path, 32) catch return;
    defer ctx.deinit();

    // Shape to get a valid glyph ID for 'A' (auto-detect direction/script)
    const buf = try ctx.shapeText("A", null, null);
    defer buf.destroy();
    const glyph_id = buf.getGlyphInfos()[0].codepoint;

    // Encode the glyph
    const encoded = try ctx.encodeGlyph(glyph_id);
    defer encoded.destroy();

    try std.testing.expect(encoded.data.len > 0);
    try std.testing.expect(encoded.extents.width != 0);
}

test "FontContext: shape multi-glyph string" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();

    var ctx = FontContext.init(ft_lib, test_font_path, 32) catch return;
    defer ctx.deinit();

    const buf = try ctx.shapeText("Hello", null, null);
    defer buf.destroy();
    const infos = buf.getGlyphInfos();
    try std.testing.expectEqual(@as(usize, 5), infos.len);

    const positions = buf.getGlyphPositions();
    try std.testing.expectEqual(@as(usize, 5), positions.len);
    // All glyphs should have positive horizontal advance
    for (positions) |pos| {
        try std.testing.expect(pos.x_advance > 0);
    }
}
