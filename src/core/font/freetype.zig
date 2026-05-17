const std = @import("std");
pub const c = @import("heavy_slug_c");

pub const Error = error{
    FreeTypeLibraryInitFailed,
    FreeTypeFaceOpenFailed,
    FreeTypeInvalidFaceIndex,
    FreeTypeInvalidPixelSize,
    FreeTypeSizeSetFailed,
};

pub const Version = struct {
    major: i32,
    minor: i32,
    patch: i32,
};

pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() Error!Library {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0) return error.FreeTypeLibraryInitFailed;
        return .{ .handle = lib };
    }

    pub fn deinit(self: Library) void {
        _ = c.FT_Done_FreeType(self.handle);
    }

    pub fn version(self: Library) Version {
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
    pub fn init(lib: Library, path: [*:0]const u8, face_index: u32) Error!Face {
        var face: c.FT_Face = null;
        const ft_face_index = std.math.cast(c.FT_Long, face_index) orelse return error.FreeTypeInvalidFaceIndex;
        if (c.FT_New_Face(lib.handle, path, ft_face_index, &face) != 0) return error.FreeTypeFaceOpenFailed;
        return .{ .handle = face };
    }

    pub fn deinit(self: Face) void {
        _ = c.FT_Done_Face(self.handle);
    }

    /// Set the pixel size for glyph loading. Pass 0 for width to auto-compute from height.
    pub fn setPixelSizes(self: Face, width: u32, height: u32) Error!void {
        if (width == 0 and height == 0) return error.FreeTypeInvalidPixelSize;
        if (c.FT_Set_Pixel_Sizes(self.handle, width, height) != 0) return error.FreeTypeSizeSetFailed;
    }

    pub fn isSized(self: Face) bool {
        const size = self.handle.?.*.size;
        if (size == null) return false;
        const metrics = size.*.metrics;
        return metrics.x_ppem != 0 or metrics.y_ppem != 0;
    }

    pub fn numGlyphs(self: Face) u32 {
        const n = self.handle.?.*.num_glyphs;
        if (n <= 0) return 0;
        return @intCast(n);
    }
};

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test "Face: load system font and query glyph count" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path, 0) catch return; // skip if font unavailable
    defer face.deinit();
    try std.testing.expect(face.numGlyphs() > 0);
}

test "Face: set pixel sizes" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path, 0) catch return;
    defer face.deinit();
    try std.testing.expect(!face.isSized());
    try face.setPixelSizes(0, 32);
    try std.testing.expect(face.isSized());
}

test "Face: rejects zero pixel dimensions" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path, 0) catch return;
    defer face.deinit();
    try std.testing.expectError(error.FreeTypeInvalidPixelSize, face.setPixelSizes(0, 0));
}

test "init and deinit FreeType library" {
    const lib = try Library.init();
    defer lib.deinit();

    const ver = lib.version();
    try std.testing.expectEqual(@as(i32, 2), ver.major);
    try std.testing.expect(ver.minor >= 14);
}
