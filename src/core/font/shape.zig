const std = @import("std");
const hb = @import("harfbuzz.zig");

pub const SegmentProperties = struct {
    direction: ?hb.Direction = null,
    script: ?hb.Script = null,
};

pub const ShapedRun = struct {
    buffer: hb.Buffer,

    pub fn destroy(self: ShapedRun) void {
        self.buffer.destroy();
    }

    pub fn infos(self: ShapedRun) []const hb.Buffer.GlyphInfo {
        return self.buffer.getGlyphInfos();
    }

    pub fn positions(self: ShapedRun) []const hb.Buffer.GlyphPosition {
        return self.buffer.getGlyphPositions();
    }
};

pub fn shapeText(font: hb.Font, text: []const u8, props: SegmentProperties) !ShapedRun {
    const buffer = try hb.Buffer.create();
    errdefer buffer.destroy();

    buffer.addUtf8(text);
    if (props.direction) |direction| buffer.setDirection(direction);
    if (props.script) |script| buffer.setScript(script);
    if (props.direction == null and props.script == null) buffer.guessSegmentProperties();
    hb.shape(font, buffer);

    return .{ .buffer = buffer };
}

test "shape: creates an empty run for empty text" {
    const ft = @import("freetype.zig");
    const font_path: [*:0]const u8 = "assets/Inter-Regular.otf";
    const lib = try ft.Library.init();
    defer lib.deinit();
    const face = ft.Face.init(lib, font_path, 0) catch return;
    defer face.deinit();
    try face.setPixelSizes(0, 24);

    const font = try hb.Font.createFromFtFace(face.rawHandle());
    defer font.destroy();

    const run = try shapeText(font, "", .{});
    defer run.destroy();
    try std.testing.expectEqual(@as(usize, 0), run.infos().len);
}
