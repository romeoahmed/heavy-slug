const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
    @cInclude("hb.h");
    @cInclude("hb-ft.h");
    @cInclude("hb-gpu.h");
});
const ft = @import("ft.zig");

pub const Error = error{
    BufferCreateFailed,
    AllocationFailed,
};

/// Zig-native wrapper for hb_direction_t.
pub const Direction = enum(c_uint) {
    invalid = c.HB_DIRECTION_INVALID,
    ltr = c.HB_DIRECTION_LTR,
    rtl = c.HB_DIRECTION_RTL,
    ttb = c.HB_DIRECTION_TTB,
    btt = c.HB_DIRECTION_BTT,
};

/// Zig-native wrapper for hb_script_t. Covers commonly used scripts;
/// callers can @enumFromInt for any HB_SCRIPT_* value not listed here.
pub const Script = enum(c_uint) {
    common = c.HB_SCRIPT_COMMON,
    inherited = c.HB_SCRIPT_INHERITED,
    latin = c.HB_SCRIPT_LATIN,
    arabic = c.HB_SCRIPT_ARABIC,
    hebrew = c.HB_SCRIPT_HEBREW,
    han = c.HB_SCRIPT_HAN,
    hiragana = c.HB_SCRIPT_HIRAGANA,
    katakana = c.HB_SCRIPT_KATAKANA,
    hangul = c.HB_SCRIPT_HANGUL,
    devanagari = c.HB_SCRIPT_DEVANAGARI,
    cyrillic = c.HB_SCRIPT_CYRILLIC,
    greek = c.HB_SCRIPT_GREEK,
    thai = c.HB_SCRIPT_THAI,
    _,
};

pub const Buffer = struct {
    handle: *c.hb_buffer_t,

    pub const GlyphInfo = c.hb_glyph_info_t;
    pub const GlyphPosition = c.hb_glyph_position_t;

    pub fn create() Error!Buffer {
        const buf = c.hb_buffer_create() orelse return error.BufferCreateFailed;
        if (c.hb_buffer_allocation_successful(buf) == 0) {
            c.hb_buffer_destroy(buf);
            return error.AllocationFailed;
        }
        return .{ .handle = buf };
    }

    pub fn destroy(self: Buffer) void {
        c.hb_buffer_destroy(self.handle);
    }

    pub fn addUtf8(self: Buffer, text: []const u8) void {
        c.hb_buffer_add_utf8(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    pub fn getLength(self: Buffer) u32 {
        return c.hb_buffer_get_length(self.handle);
    }

    pub fn setDirection(self: Buffer, dir: Direction) void {
        c.hb_buffer_set_direction(self.handle, @intFromEnum(dir));
    }

    pub fn setScript(self: Buffer, script: Script) void {
        c.hb_buffer_set_script(self.handle, @intFromEnum(script));
    }

    /// Let HarfBuzz infer direction, script, and language from buffer contents.
    pub fn guessSegmentProperties(self: Buffer) void {
        c.hb_buffer_guess_segment_properties(self.handle);
    }

    /// Get shaped glyph info array. Valid until buffer is modified.
    pub fn getGlyphInfos(self: Buffer) []const GlyphInfo {
        var len: c_uint = 0;
        const ptr = c.hb_buffer_get_glyph_infos(self.handle, &len);
        if (len == 0) return &.{};
        return @as([*]const GlyphInfo, @ptrCast(ptr))[0..len];
    }

    /// Get shaped glyph position array. Valid until buffer is modified.
    pub fn getGlyphPositions(self: Buffer) []const GlyphPosition {
        var len: c_uint = 0;
        const ptr = c.hb_buffer_get_glyph_positions(self.handle, &len);
        if (len == 0) return &.{};
        return @as([*]const GlyphPosition, @ptrCast(ptr))[0..len];
    }
};

pub const Font = struct {
    handle: *c.hb_font_t,

    /// Create a HarfBuzz font from a raw FT_Face handle.
    /// Uses hb_ft_font_create_referenced — HarfBuzz takes a reference to the face,
    /// so the caller must keep the FT_Face alive for the lifetime of this Font.
    pub fn createFromFtFace(ft_face_raw: *anyopaque) !Font {
        const ft_face: c.FT_Face = @ptrCast(@alignCast(ft_face_raw));
        const hb_font = c.hb_ft_font_create_referenced(ft_face) orelse return error.AllocationFailed;
        return .{ .handle = hb_font };
    }

    pub fn destroy(self: Font) void {
        c.hb_font_destroy(self.handle);
    }
};

/// Shape text in `buf` using `font`. After calling, use
/// buf.getGlyphInfos() and buf.getGlyphPositions() to read results.
pub fn shape(font: Font, buf: Buffer) void {
    c.hb_shape(font.handle, buf.handle, null, 0);
}

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test "create and destroy HarfBuzz buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
}

test "add UTF-8 text to buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.addUtf8("hello");
    try std.testing.expectEqual(@as(u32, 5), buf.getLength());
}

test "set direction and script" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    buf.addUtf8("test");
    try std.testing.expectEqual(@as(u32, 4), buf.getLength());
}

test "Font: create from FT_Face and shape text" {
    // Load FreeType face
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();
    const ft_face = ft.Face.init(ft_lib, test_font_path) catch return;
    defer ft_face.deinit();
    try ft_face.setPixelSizes(0, 32);

    // Create HarfBuzz font
    const font = try Font.createFromFtFace(ft_face.rawHandle());
    defer font.destroy();

    // Shape "AB"
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    buf.addUtf8("AB");
    shape(font, buf);

    // Verify shaping produced 2 glyphs with valid info
    const infos = buf.getGlyphInfos();
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expect(infos[0].codepoint != 0);
    try std.testing.expect(infos[1].codepoint != 0);

    const positions = buf.getGlyphPositions();
    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expect(positions[0].x_advance > 0);
}

pub const GlyphExtents = c.hb_glyph_extents_t;

pub const Blob = struct {
    handle: *c.hb_blob_t,

    /// Get the raw blob data as a byte slice.
    pub fn getData(self: Blob) []const u8 {
        var len: c_uint = 0;
        const ptr = c.hb_blob_get_data(self.handle, &len);
        if (len == 0) return &.{};
        return @as([*]const u8, @ptrCast(ptr))[0..len];
    }

    pub fn getLength(self: Blob) u32 {
        return c.hb_blob_get_length(self.handle);
    }

    pub fn destroy(self: Blob) void {
        c.hb_blob_destroy(self.handle);
    }
};

pub const GpuDraw = struct {
    handle: *c.hb_gpu_draw_t,

    pub fn create() !GpuDraw {
        const draw = c.hb_gpu_draw_create_or_fail() orelse return error.AllocationFailed;
        return .{ .handle = draw };
    }

    pub fn destroy(self: GpuDraw) void {
        c.hb_gpu_draw_destroy(self.handle);
    }

    /// Draw a glyph outline into this GpuDraw context.
    pub fn drawGlyph(self: GpuDraw, font: Font, glyph_id: u32) void {
        c.hb_gpu_draw_glyph(self.handle, font.handle, glyph_id);
    }

    /// Encode the accumulated drawing into a Slug-format blob.
    pub fn encode(self: GpuDraw) !Blob {
        const blob = c.hb_gpu_draw_encode(self.handle) orelse return error.AllocationFailed;
        return .{ .handle = blob };
    }

    /// Get the bounding box extents of the drawn glyph.
    pub fn getExtents(self: GpuDraw) GlyphExtents {
        var extents: GlyphExtents = undefined;
        c.hb_gpu_draw_get_extents(self.handle, &extents);
        return extents;
    }

    /// Reset for encoding the next glyph. Reuse the same GpuDraw object.
    pub fn reset(self: GpuDraw) void {
        c.hb_gpu_draw_reset(self.handle);
    }
};

test "GpuDraw: encode glyph produces non-empty blob" {
    // Load font
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();
    const ft_face = ft.Face.init(ft_lib, test_font_path) catch return;
    defer ft_face.deinit();
    try ft_face.setPixelSizes(0, 32);

    const font = try Font.createFromFtFace(ft_face.rawHandle());
    defer font.destroy();

    // Shape to get a valid glyph ID
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    buf.addUtf8("A");
    shape(font, buf);
    const glyph_id = buf.getGlyphInfos()[0].codepoint;

    // Encode the glyph
    const draw = try GpuDraw.create();
    defer draw.destroy();
    draw.drawGlyph(font, glyph_id);

    const blob = try draw.encode();
    defer blob.destroy();

    // Blob should have data (the Slug-encoded glyph)
    try std.testing.expect(blob.getLength() > 0);
    try std.testing.expect(blob.getData().len > 0);

    // Extents should have non-zero dimensions for 'A'
    const extents = draw.getExtents();
    try std.testing.expect(extents.width != 0);
    try std.testing.expect(extents.height != 0);
}
