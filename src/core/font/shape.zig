//! Reusable HarfBuzz shaping plan.

const std = @import("std");
const hb = @import("harfbuzz.zig");

pub const SegmentProperties = struct {
    direction: ?hb.Direction = null,
    script: ?hb.Script = null,
    language: ?hb.Language = null,
    guess_missing: bool = true,

    fn apply(self: SegmentProperties, buffer: hb.Buffer) void {
        if (self.direction) |direction| buffer.setDirection(direction);
        if (self.script) |script| buffer.setScript(script);
        if (self.language) |language| buffer.setLanguage(language);
        if (self.guess_missing) buffer.guessSegmentProperties();
    }
};

pub const ShapedRun = struct {
    infos: []const hb.Buffer.GlyphInfo,
    positions: []const hb.Buffer.GlyphPosition,
};

pub const ShapePlan = struct {
    buffer: hb.Buffer,

    pub fn init() !ShapePlan {
        return .{ .buffer = try hb.Buffer.init() };
    }

    pub fn deinit(self: *ShapePlan) void {
        self.buffer.deinit();
        self.* = undefined;
    }

    pub fn shape(self: *ShapePlan, font: hb.Font, text: []const u8, props: SegmentProperties) !ShapedRun {
        self.buffer.reset();
        try self.buffer.addUtf8(text);
        props.apply(self.buffer);
        try hb.shape(font, self.buffer);

        return .{
            .infos = self.buffer.glyphInfos(),
            .positions = self.buffer.glyphPositions(),
        };
    }
};

test "ShapePlan: creates an empty run for empty text" {
    const ft = @import("freetype.zig");
    const font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";
    const lib = try ft.Library.init();
    defer lib.deinit();
    const face = ft.Face.init(lib, font_path, 0) catch return;
    defer face.deinit();
    try face.setPixelSizes(0, 24);

    const font = try hb.Font.fromFace(face);
    defer font.deinit();

    var plan = try ShapePlan.init();
    defer plan.deinit();
    const run = try plan.shape(font, "", .{});
    try std.testing.expectEqual(@as(usize, 0), run.infos.len);
}

test "ShapePlan: reuses one HarfBuzz buffer for repeated shaping" {
    const ft = @import("freetype.zig");
    const font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";
    const lib = try ft.Library.init();
    defer lib.deinit();
    const face = ft.Face.init(lib, font_path, 0) catch return;
    defer face.deinit();
    try face.setPixelSizes(0, 24);

    const font = try hb.Font.fromFace(face);
    defer font.deinit();

    var plan = try ShapePlan.init();
    defer plan.deinit();
    const a = try plan.shape(font, "A", .{ .direction = .ltr, .script = .latin });
    try std.testing.expectEqual(@as(usize, 1), a.infos.len);
    const b = try plan.shape(font, "AB", .{ .direction = .ltr, .script = .latin });
    try std.testing.expectEqual(@as(usize, 2), b.infos.len);
}

test "ShapePlan: guesses missing segment fields after explicit direction" {
    const ft = @import("freetype.zig");
    const font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";
    const lib = try ft.Library.init();
    defer lib.deinit();
    const face = ft.Face.init(lib, font_path, 0) catch return;
    defer face.deinit();
    try face.setPixelSizes(0, 24);

    const font = try hb.Font.fromFace(face);
    defer font.deinit();

    var plan = try ShapePlan.init();
    defer plan.deinit();
    const run = try plan.shape(font, "A", .{ .direction = .ltr });

    try std.testing.expectEqual(@as(usize, 1), run.infos.len);
    try std.testing.expectEqual(hb.Direction.ltr, plan.buffer.direction());
    try std.testing.expectEqual(hb.Script.latin, plan.buffer.script());
}
