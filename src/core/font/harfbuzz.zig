const std = @import("std");
const ft = @import("freetype.zig");
pub const c = ft.c;

pub const Error = error{
    HarfBuzzBufferCreateFailed,
    HarfBuzzAllocationFailed,
    HarfBuzzFontCreateFailed,
    HarfBuzzFaceNotSized,
    HarfBuzzTextTooLong,
    HarfBuzzLanguageTagTooLong,
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

pub const ClusterLevel = enum(c_uint) {
    monotone_graphemes = c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_GRAPHEMES,
    monotone_characters = c.HB_BUFFER_CLUSTER_LEVEL_MONOTONE_CHARACTERS,
    characters = c.HB_BUFFER_CLUSTER_LEVEL_CHARACTERS,
};

pub const Language = struct {
    handle: c.hb_language_t,

    pub fn fromBytes(tag: []const u8) Error!Language {
        const tag_len = std.math.cast(c_int, tag.len) orelse return error.HarfBuzzLanguageTagTooLong;
        return .{ .handle = c.hb_language_from_string(tag.ptr, tag_len) };
    }
};

pub const Buffer = struct {
    handle: *c.hb_buffer_t,

    pub const GlyphInfo = c.hb_glyph_info_t;
    pub const GlyphPosition = c.hb_glyph_position_t;

    pub fn init() Error!Buffer {
        const buf = c.hb_buffer_create() orelse return error.HarfBuzzBufferCreateFailed;
        if (c.hb_buffer_allocation_successful(buf) == 0) {
            c.hb_buffer_destroy(buf);
            return error.HarfBuzzAllocationFailed;
        }
        const buffer = Buffer{ .handle = buf };
        buffer.setClusterLevel(.monotone_graphemes);
        return buffer;
    }

    pub fn deinit(self: Buffer) void {
        c.hb_buffer_destroy(self.handle);
    }

    pub fn addUtf8(self: Buffer, text: []const u8) Error!void {
        const byte_len = std.math.cast(c_int, text.len) orelse return error.HarfBuzzTextTooLong;
        c.hb_buffer_add_utf8(
            self.handle,
            text.ptr,
            byte_len,
            0,
            byte_len,
        );
        try self.ensureAllocated();
    }

    pub fn len(self: Buffer) usize {
        return @intCast(c.hb_buffer_get_length(self.handle));
    }

    pub fn setDirection(self: Buffer, dir: Direction) void {
        c.hb_buffer_set_direction(self.handle, @intFromEnum(dir));
    }

    pub fn direction(self: Buffer) Direction {
        return @enumFromInt(c.hb_buffer_get_direction(self.handle));
    }

    pub fn setScript(self: Buffer, script_tag: Script) void {
        c.hb_buffer_set_script(self.handle, @intFromEnum(script_tag));
    }

    pub fn script(self: Buffer) Script {
        return @enumFromInt(c.hb_buffer_get_script(self.handle));
    }

    pub fn setLanguage(self: Buffer, language: Language) void {
        c.hb_buffer_set_language(self.handle, language.handle);
    }

    pub fn setClusterLevel(self: Buffer, level: ClusterLevel) void {
        c.hb_buffer_set_cluster_level(self.handle, @intFromEnum(level));
    }

    /// Let HarfBuzz infer missing direction, script, and language from buffer contents.
    pub fn guessSegmentProperties(self: Buffer) void {
        c.hb_buffer_guess_segment_properties(self.handle);
    }

    /// Get shaped glyph info array. Valid until buffer is modified.
    pub fn glyphInfos(self: Buffer) []const GlyphInfo {
        var glyph_count: c_uint = 0;
        const ptr = c.hb_buffer_get_glyph_infos(self.handle, &glyph_count);
        if (glyph_count == 0) return &.{};
        return @as([*]const GlyphInfo, @ptrCast(ptr))[0..glyph_count];
    }

    /// Get shaped glyph position array. Valid until buffer is modified.
    pub fn glyphPositions(self: Buffer) []const GlyphPosition {
        var glyph_count: c_uint = 0;
        const ptr = c.hb_buffer_get_glyph_positions(self.handle, &glyph_count);
        if (glyph_count == 0) return &.{};
        return @as([*]const GlyphPosition, @ptrCast(ptr))[0..glyph_count];
    }

    /// Reset buffer content and segment properties for reuse.
    pub fn reset(self: Buffer) void {
        c.hb_buffer_reset(self.handle);
        self.setClusterLevel(.monotone_graphemes);
    }

    fn ensureAllocated(self: Buffer) Error!void {
        if (c.hb_buffer_allocation_successful(self.handle) == 0) {
            return error.HarfBuzzAllocationFailed;
        }
    }
};

pub const Font = struct {
    handle: *c.hb_font_t,

    /// Create a HarfBuzz font from a sized FreeType face.
    /// hb_ft_font_create_referenced takes its own FT_Face reference; the
    /// wrapper still destroys the hb_font before its owning Face for clarity.
    pub fn fromFace(face: ft.Face) Error!Font {
        return fromFreeTypeFace(face);
    }

    pub fn fromFreeTypeFace(face: ft.Face) Error!Font {
        if (!face.isSized()) return error.HarfBuzzFaceNotSized;
        const hb_font = c.hb_ft_font_create_referenced(face.handle) orelse return error.HarfBuzzFontCreateFailed;
        return .{ .handle = hb_font };
    }

    pub fn deinit(self: Font) void {
        c.hb_font_destroy(self.handle);
    }
};

/// Shape text in `buf` using `font`. After calling, use
/// buf.glyphInfos() and buf.glyphPositions() to read results.
pub fn shape(font: Font, buf: Buffer) Error!void {
    c.hb_shape(font.handle, buf.handle, null, 0);
    try buf.ensureAllocated();
}

const test_font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";

test "init and deinit HarfBuzz buffer" {
    const buf = try Buffer.init();
    defer buf.deinit();
}

test "add UTF-8 text to buffer" {
    const buf = try Buffer.init();
    defer buf.deinit();
    try buf.addUtf8("hello");
    try std.testing.expectEqual(@as(usize, 5), buf.len());
}

test "set direction and script" {
    const buf = try Buffer.init();
    defer buf.deinit();
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    try buf.addUtf8("test");
    try std.testing.expectEqual(@as(usize, 4), buf.len());
}

test "Buffer: guessing fills missing script while preserving explicit direction" {
    const buf = try Buffer.init();
    defer buf.deinit();

    try buf.addUtf8("Hello");
    buf.setDirection(.ltr);
    buf.guessSegmentProperties();

    try std.testing.expectEqual(Direction.ltr, buf.direction());
    try std.testing.expectEqual(Script.latin, buf.script());
}

test "Font: create from sized FreeType face and shape text" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();
    const ft_face = ft.Face.init(ft_lib, test_font_path, 0) catch return;
    defer ft_face.deinit();
    try ft_face.setPixelSizes(0, 32);

    const font = try Font.fromFace(ft_face);
    defer font.deinit();

    const buf = try Buffer.init();
    defer buf.deinit();
    buf.setDirection(.ltr);
    buf.setScript(.latin);
    try buf.addUtf8("AB");
    try shape(font, buf);

    const infos = buf.glyphInfos();
    try std.testing.expectEqual(@as(usize, 2), infos.len);
    try std.testing.expect(infos[0].codepoint != 0);
    try std.testing.expect(infos[1].codepoint != 0);

    const positions = buf.glyphPositions();
    try std.testing.expectEqual(@as(usize, 2), positions.len);
    try std.testing.expect(positions[0].x_advance > 0);
}

test "Font: rejects unsized FreeType face" {
    const ft_lib = try ft.Library.init();
    defer ft_lib.deinit();
    const ft_face = ft.Face.init(ft_lib, test_font_path, 0) catch return;
    defer ft_face.deinit();

    try std.testing.expectError(error.HarfBuzzFaceNotSized, Font.fromFace(ft_face));
}

pub const GlyphExtents = c.hb_glyph_extents_t;

pub const Blob = struct {
    handle: *c.hb_blob_t,

    /// Get the raw blob data as a byte slice.
    pub fn data(self: Blob) []const u8 {
        var byte_count: c_uint = 0;
        const ptr = c.hb_blob_get_data(self.handle, &byte_count);
        if (byte_count == 0) return &.{};
        return @as([*]const u8, @ptrCast(ptr))[0..byte_count];
    }

    pub fn len(self: Blob) usize {
        return @intCast(c.hb_blob_get_length(self.handle));
    }

    pub fn deinit(self: Blob) void {
        c.hb_blob_destroy(self.handle);
    }
};

test "Buffer.reset clears contents" {
    const buf = try Buffer.init();
    defer buf.deinit();
    try buf.addUtf8("hello");
    try std.testing.expectEqual(@as(usize, 5), buf.len());
    buf.reset();
    try std.testing.expectEqual(@as(usize, 0), buf.len());
}
