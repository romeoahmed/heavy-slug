//! FreeType and HarfBuzz lifetime management for loaded fonts.

const std = @import("std");
const ft = @import("freetype.zig");
const hb = @import("harfbuzz.zig");
const glyph = @import("glyph.zig");
const shape_mod = @import("shape.zig");
const types = @import("../types.zig");

pub const LoadedFont = struct {
    allocator: std.mem.Allocator,
    face: ft.Face,
    font: hb.Font,
    encoder: glyph.GlyphEncoder,
    options: types.FontOptions,
    owned_font_data: []u8 = &.{},

    pub fn deinit(self: *LoadedFont) void {
        self.encoder.deinit();
        self.font.deinit();
        self.face.deinit();
        if (self.owned_font_data.len != 0) self.allocator.free(self.owned_font_data);
        self.* = undefined;
    }

    pub fn shape(
        self: *const LoadedFont,
        plan: *shape_mod.ShapePlan,
        text: []const u8,
        props: shape_mod.SegmentProperties,
    ) !shape_mod.ShapedRun {
        return plan.shape(self.font, text, props);
    }

    pub fn encodeGlyph(self: *LoadedFont, glyph_id: u32, fraction_bits: u8) !glyph.EncodedGlyph {
        return self.encoder.encodeGlyph(self.font, glyph_id, fraction_bits);
    }

    pub fn glyphCount(self: LoadedFont) u32 {
        return self.face.glyphCount();
    }
};

pub const FontSystem = struct {
    allocator: std.mem.Allocator,
    library: ft.Library,

    pub fn init(allocator: std.mem.Allocator) !FontSystem {
        return .{
            .allocator = allocator,
            .library = try ft.Library.init(),
        };
    }

    pub fn deinit(self: *FontSystem) void {
        self.library.deinit();
        self.* = undefined;
    }

    pub fn load(self: *const FontSystem, source: types.FontSource, options: types.FontOptions) !LoadedFont {
        const pixel_size = ft.PixelSize{ .height = options.size_px };
        try pixel_size.validate();

        var owned_font_data: []u8 = &.{};
        errdefer if (owned_font_data.len != 0) self.allocator.free(owned_font_data);

        const face = try switch (source) {
            .path => |path| self.library.openPath(path, options.face_index),
            .memory => |bytes| blk: {
                owned_font_data = try self.allocator.dupe(u8, bytes);
                break :blk try self.library.openMemory(owned_font_data, options.face_index);
            },
        };
        errdefer face.deinit();
        try face.setPixelSize(pixel_size);

        const font = try hb.Font.fromFreeTypeFace(face);
        errdefer font.deinit();

        var encoder = try glyph.GlyphEncoder.init(self.allocator);
        errdefer encoder.deinit();

        return .{
            .allocator = self.allocator,
            .face = face,
            .font = font,
            .encoder = encoder,
            .options = options,
            .owned_font_data = owned_font_data,
        };
    }
};

test "FontSystem loads repository font" {
    var system = try FontSystem.init(std.testing.allocator);
    defer system.deinit();

    var loaded = system.load(.{ .path = "assets/NotoSansJP-Regular.otf" }, .{ .size_px = 24 }) catch return;
    defer loaded.deinit();

    try std.testing.expect(loaded.glyphCount() > 0);
}

test "FontSystem shapes and encodes through explicit plan" {
    var system = try FontSystem.init(std.testing.allocator);
    defer system.deinit();

    var loaded = system.load(.{ .path = "assets/NotoSansJP-Regular.otf" }, .{
        .size_px = 24,
        .face_index = 0,
    }) catch return;
    defer loaded.deinit();

    var plan = try shape_mod.ShapePlan.init();
    defer plan.deinit();

    const run = try loaded.shape(&plan, "A", .{});
    try std.testing.expectEqual(@as(usize, 1), run.infos.len);

    const encoded = try loaded.encodeGlyph(run.infos[0].codepoint, @import("../blob/format.zig").default_fraction_bits);
    defer encoded.deinit();
    try std.testing.expect(encoded.data.len > 0);
}

test "FontSystem rejects invalid memory font source without leaking its copy" {
    var system = try FontSystem.init(std.testing.allocator);
    defer system.deinit();

    try std.testing.expectError(
        error.FreeTypeFaceOpenFailed,
        system.load(.{ .memory = "not a font" }, .{ .size_px = 24 }),
    );
}
