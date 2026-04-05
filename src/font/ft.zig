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

test "init and deinit FreeType library" {
    const lib = try Library.init();
    defer lib.deinit();

    const ver = lib.versionString();
    try std.testing.expectEqual(@as(i32, 2), ver.major);
    try std.testing.expect(ver.minor >= 14);
}
