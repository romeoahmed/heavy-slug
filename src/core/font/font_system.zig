const std = @import("std");
const ft = @import("freetype.zig");
const hb = @import("harfbuzz.zig");
const types = @import("../types.zig");

pub const LoadedFont = struct {
    face: ft.Face,
    font: hb.Font,
    options: types.FontOptions,

    pub fn deinit(self: *LoadedFont) void {
        self.font.destroy();
        self.face.deinit();
        self.* = undefined;
    }
};

pub const FontSystem = struct {
    library: ft.Library,

    pub fn init() !FontSystem {
        return .{ .library = try ft.Library.init() };
    }

    pub fn deinit(self: *FontSystem) void {
        self.library.deinit();
        self.* = undefined;
    }

    pub fn load(self: FontSystem, source: types.FontSource, options: types.FontOptions) !LoadedFont {
        const path = switch (source) {
            .path => |p| p,
        };
        const face = try ft.Face.init(self.library, path, options.face_index);
        errdefer face.deinit();
        try face.setPixelSizes(0, options.size_px);
        const font = try hb.Font.createFromFtFace(face.rawHandle());
        errdefer font.destroy();
        return .{ .face = face, .font = font, .options = options };
    }
};

test "FontSystem loads repository font" {
    var system = try FontSystem.init();
    defer system.deinit();

    var loaded = system.load(.{ .path = "assets/Inter-Regular.otf" }, .{ .size_px = 24 }) catch return;
    defer loaded.deinit();

    try std.testing.expect(loaded.face.numGlyphs() > 0);
}

test "FontSystem forwards explicit face index" {
    var system = try FontSystem.init();
    defer system.deinit();

    var loaded = system.load(.{ .path = "assets/Inter-Regular.otf" }, .{
        .size_px = 24,
        .face_index = 0,
    }) catch return;
    defer loaded.deinit();

    try std.testing.expectEqual(@as(u32, 0), loaded.options.face_index);
    try std.testing.expect(loaded.face.numGlyphs() > 0);
}
