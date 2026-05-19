const std = @import("std");
pub const c = @import("heavy_slug_c");

pub const Error = error{
    FreeTypeLibraryInitFailed,
    FreeTypeFaceOpenFailed,
    FreeTypeInvalidFaceIndex,
    FreeTypeFontDataTooLong,
    FreeTypeInvalidPixelSize,
    FreeTypeSizeSetFailed,
};

pub const Version = struct {
    major: i32,
    minor: i32,
    patch: i32,

    pub fn atLeast(self: Version, major: i32, minor: i32, patch: i32) bool {
        if (self.major != major) return self.major > major;
        if (self.minor != minor) return self.minor > minor;
        return self.patch >= patch;
    }
};

pub const PixelSize = struct {
    width: u32 = 0,
    height: u32,

    pub fn validate(self: PixelSize) Error!void {
        if (self.width == 0 and self.height == 0) return error.FreeTypeInvalidPixelSize;
        _ = try ftUInt(self.width);
        _ = try ftUInt(self.height);
    }
};

pub const Library = struct {
    handle: c.FT_Library,

    pub fn init() Error!Library {
        var lib: c.FT_Library = null;
        if (c.FT_Init_FreeType(&lib) != 0 or lib == null) return error.FreeTypeLibraryInitFailed;
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

    pub fn openPath(self: Library, path: [*:0]const u8, face_index: u32) Error!Face {
        return Face.openPath(self, path, face_index);
    }

    pub fn openMemory(self: Library, data: []const u8, face_index: u32) Error!Face {
        return Face.openMemory(self, data, face_index);
    }
};

pub const Face = struct {
    handle: c.FT_Face,

    pub fn init(lib: Library, path: [*:0]const u8, face_index: u32) Error!Face {
        return openPath(lib, path, face_index);
    }

    pub fn openPath(lib: Library, path: [*:0]const u8, face_index: u32) Error!Face {
        var face: c.FT_Face = null;
        const ft_face_index = try ftLong(face_index);
        if (c.FT_New_Face(lib.handle, path, ft_face_index, &face) != 0 or face == null) {
            return error.FreeTypeFaceOpenFailed;
        }
        return .{ .handle = face };
    }

    pub fn openMemory(lib: Library, data: []const u8, face_index: u32) Error!Face {
        var face: c.FT_Face = null;
        const byte_count = std.math.cast(c.FT_Long, data.len) orelse return error.FreeTypeFontDataTooLong;
        const ft_face_index = try ftLong(face_index);
        if (c.FT_New_Memory_Face(lib.handle, data.ptr, byte_count, ft_face_index, &face) != 0 or face == null) {
            return error.FreeTypeFaceOpenFailed;
        }
        return .{ .handle = face };
    }

    pub fn deinit(self: Face) void {
        _ = c.FT_Done_Face(self.handle);
    }

    pub fn setPixelSize(self: Face, pixel_size: PixelSize) Error!void {
        try pixel_size.validate();
        if (c.FT_Set_Pixel_Sizes(
            self.handle,
            try ftUInt(pixel_size.width),
            try ftUInt(pixel_size.height),
        ) != 0) return error.FreeTypeSizeSetFailed;
    }

    pub fn setPixelSizes(self: Face, width: u32, height: u32) Error!void {
        return self.setPixelSize(.{ .width = width, .height = height });
    }

    pub fn isSized(self: Face) bool {
        const size = self.handle.?.*.size;
        if (size == null) return false;
        const metrics = size.*.metrics;
        return metrics.x_ppem != 0 or metrics.y_ppem != 0;
    }

    pub fn glyphCount(self: Face) u32 {
        const n = self.handle.?.*.num_glyphs;
        if (n <= 0) return 0;
        return @intCast(n);
    }

    pub fn numGlyphs(self: Face) u32 {
        return self.glyphCount();
    }

    pub fn unitsPerEm(self: Face) u16 {
        return @intCast(self.handle.?.*.units_per_EM);
    }

    pub fn familyName(self: Face) ?[:0]const u8 {
        return spanOptionalCString(self.handle.?.*.family_name);
    }

    pub fn styleName(self: Face) ?[:0]const u8 {
        return spanOptionalCString(self.handle.?.*.style_name);
    }
};

fn ftLong(value: u32) Error!c.FT_Long {
    return std.math.cast(c.FT_Long, value) orelse error.FreeTypeInvalidFaceIndex;
}

fn ftUInt(value: u32) Error!c.FT_UInt {
    return std.math.cast(c.FT_UInt, value) orelse error.FreeTypeInvalidPixelSize;
}

fn spanOptionalCString(ptr: [*c]const u8) ?[:0]const u8 {
    if (ptr == null) return null;
    return std.mem.span(ptr);
}

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test "Face: load repository font and query face metadata" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path, 0) catch return;
    defer face.deinit();

    try std.testing.expect(face.glyphCount() > 0);
    try std.testing.expect(face.unitsPerEm() > 0);
    try std.testing.expect(face.familyName() != null);
}

test "Face: set pixel size through validated value" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = try lib.openPath(test_font_path, 0);
    defer face.deinit();

    try std.testing.expect(!face.isSized());
    try face.setPixelSize(.{ .height = 32 });
    try std.testing.expect(face.isSized());
}

test "Face: rejects invalid memory font data" {
    const lib = try Library.init();
    defer lib.deinit();

    try std.testing.expectError(error.FreeTypeFaceOpenFailed, lib.openMemory("not a font", 0));
}

test "Face: rejects zero pixel dimensions" {
    const lib = try Library.init();
    defer lib.deinit();
    const face = Face.init(lib, test_font_path, 0) catch return;
    defer face.deinit();
    try std.testing.expectError(error.FreeTypeInvalidPixelSize, face.setPixelSize(.{ .height = 0 }));
}

test "Library: reports FreeType runtime version" {
    const lib = try Library.init();
    defer lib.deinit();

    const ver = lib.version();
    try std.testing.expect(ver.atLeast(2, 14, 3));
}
