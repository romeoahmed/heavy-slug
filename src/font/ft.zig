const std = @import("std");
const c = @cImport({
    @cInclude("ft2build.h");
    @cInclude("freetype/freetype.h");
});

pub const Error = error{
    InitFailed,
};

pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() Error!Library {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.InitFailed;
        return .{ .handle = lib };
    }

    pub fn deinit(self: Library) void {
        _ = c.FT_Done_FreeType(self.handle);
    }

    pub fn versionString(self: Library) struct { major: i32, minor: i32, patch: i32 } {
        var major: c.FT_Int = 0;
        var minor: c.FT_Int = 0;
        var patch: c.FT_Int = 0;
        c.FT_Library_Version(self.handle, &major, &minor, &patch);
        return .{ .major = major, .minor = minor, .patch = patch };
    }
};

pub const Face = struct {
    handle: c.FT_Face,

    /// Load a font face from a file path.
    pub fn init(lib: Library, path: [*:0]const u8) Error!Face {
        var face: c.FT_Face = null;
        if (c.FT_New_Face(lib.handle, path, 0, &face) != 0) return error.InitFailed;
        return .{ .handle = face };
    }

    pub fn deinit(self: Face) void {
        _ = c.FT_Done_Face(self.handle);
    }

    /// Set the pixel size for glyph loading. Pass 0 for width to auto-compute from height.
    pub fn setPixelSizes(self: Face, width: u32, height: u32) Error!void {
        if (c.FT_Set_Pixel_Sizes(self.handle, width, height) != 0) return error.InitFailed;
    }

    pub fn numGlyphs(self: Face) u32 {
        const n = self.handle.?.*.num_glyphs;
        return @intCast(n);
    }

    /// Raw FT_Face handle for cross-module interop (see Cross-Module @cImport Note).
    pub fn rawHandle(self: Face) *anyopaque {
        return @ptrCast(self.handle.?);
    }
};

const test_font_path: [*:0]const u8 = "C:/Windows/Fonts/segoeui.ttf";

test "Face: load system font and query glyph count" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path) catch return; // skip if font unavailable
    defer face.deinit();
    try std.testing.expect(face.numGlyphs() > 0);
}

test "Face: set pixel sizes" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path) catch return;
    defer face.deinit();
    try face.setPixelSizes(0, 32);
}

test "init and deinit FreeType library" {
    const lib = try Library.init();
    defer lib.deinit();

    const ver = lib.versionString();
    try std.testing.expectEqual(@as(i32, 2), ver.major);
    try std.testing.expect(ver.minor >= 14);
}
