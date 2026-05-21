//! Pure client-side Wayland titlebar label layout and bitmap drawing.

const std = @import("std");
const demo_title = @import("demo_title");

pub const margin: f64 = 16;
pub const gap_to_controls: f64 = 12;
pub const glyph_width: i32 = 5;
pub const glyph_height: i32 = 7;
pub const glyph_spacing: i32 = 1;
pub const pixel_size: f64 = 2;

pub const Layout = struct {
    left: i32,
    top: i32,
    right: i32,
    glyph_px: i32,
};

pub fn layout(width: i32, height: i32, close_button_left: i32, scale: f64, title: []const u8) ?Layout {
    if (width <= 0 or height <= 0 or title.len == 0) return null;

    const glyph_px = @max(roundPositiveToI32(pixel_size * scale), 1);
    const text_width = pixelWidth(title, glyph_px) orelse return null;
    if (text_width <= 0) return null;

    const left_bound = @min(roundPositiveToI32(margin * scale), width);
    const right_bound = @max(@min(close_button_left - roundPositiveToI32(gap_to_controls * scale), width), 0);
    const available_width = right_bound - left_bound;
    if (available_width <= 0) return null;

    const fitted_width = @min(text_width, available_width);
    const centered_left = @divTrunc(width - text_width, 2);
    const left = clampI32(centered_left, left_bound, right_bound - fitted_width);
    const text_height = glyph_height * glyph_px;
    return .{
        .left = left,
        .top = @max(@divTrunc(height - text_height, 2), 0),
        .right = right_bound,
        .glyph_px = glyph_px,
    };
}

pub fn pixelWidth(title: []const u8, glyph_px: i32) ?i32 {
    if (glyph_px <= 0) return null;
    var codepoints = (demo_title.view(title) catch return null).iterator();
    var width: i32 = 0;
    while (codepoints.nextCodepoint()) |codepoint| {
        _ = glyphRows(codepoint) orelse return null;
        if (width > 0) width += glyph_spacing * glyph_px;
        width += glyph_width * glyph_px;
    }
    return width;
}

pub fn paint(pixels: []u32, stride: usize, title: []const u8, title_layout: Layout, color: u32) void {
    if (title_layout.glyph_px <= 0 or title_layout.left >= title_layout.right) return;
    if (pixelWidth(title, title_layout.glyph_px) == null) return;

    var pen_x = title_layout.left;
    var first = true;
    var codepoints = (demo_title.view(title) catch return).iterator();
    while (codepoints.nextCodepoint()) |codepoint| {
        const rows = glyphRows(codepoint) orelse return;
        if (!first) pen_x += glyph_spacing * title_layout.glyph_px;
        first = false;
        if (pen_x >= title_layout.right) break;

        for (rows, 0..) |row_bits, row_index| {
            for (0..@as(usize, @intCast(glyph_width))) |column_index| {
                const column: i32 = @intCast(column_index);
                const shift: u3 = @intCast(glyph_width - 1 - column);
                if ((row_bits & (@as(u8, 1) << shift)) == 0) continue;
                paintSolidRect(
                    pixels,
                    stride,
                    pen_x + column * title_layout.glyph_px,
                    title_layout.top + @as(i32, @intCast(row_index)) * title_layout.glyph_px,
                    title_layout.glyph_px,
                    title_layout.glyph_px,
                    title_layout.right,
                    color,
                );
            }
        }

        pen_x += glyph_width * title_layout.glyph_px;
    }
}

// Tiny ASCII CSD title font keeps the direct Wayland demo independent of GTK/Pango/Cairo.
// Non-ASCII titles remain exact in xdg-shell metadata and are intentionally
// omitted from the client-drawn headerbar instead of being byte-garbled.
pub fn glyphRows(codepoint: u21) ?[7]u8 {
    if (codepoint < ' ' or codepoint > '~') return null;

    return switch (codepoint) {
        ' ' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b00000 },
        '-' => .{ 0b00000, 0b00000, 0b00000, 0b11110, 0b00000, 0b00000, 0b00000 },
        '.' => .{ 0b00000, 0b00000, 0b00000, 0b00000, 0b00000, 0b01100, 0b01100 },
        ':' => .{ 0b00000, 0b01100, 0b01100, 0b00000, 0b01100, 0b01100, 0b00000 },
        '/' => .{ 0b00001, 0b00010, 0b00010, 0b00100, 0b01000, 0b01000, 0b10000 },
        '0' => .{ 0b01110, 0b10001, 0b10011, 0b10101, 0b11001, 0b10001, 0b01110 },
        '1' => .{ 0b00100, 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        '2' => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b01000, 0b11111 },
        '3' => .{ 0b11110, 0b00001, 0b00001, 0b01110, 0b00001, 0b00001, 0b11110 },
        '4' => .{ 0b00010, 0b00110, 0b01010, 0b10010, 0b11111, 0b00010, 0b00010 },
        '5' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b00001, 0b00001, 0b11110 },
        '6' => .{ 0b00110, 0b01000, 0b10000, 0b11110, 0b10001, 0b10001, 0b01110 },
        '7' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b01000, 0b01000 },
        '8' => .{ 0b01110, 0b10001, 0b10001, 0b01110, 0b10001, 0b10001, 0b01110 },
        '9' => .{ 0b01110, 0b10001, 0b10001, 0b01111, 0b00001, 0b00010, 0b01100 },
        'a' => .{ 0b00000, 0b00000, 0b01110, 0b00001, 0b01111, 0b10001, 0b01111 },
        'b' => .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b11110 },
        'c' => .{ 0b00000, 0b00000, 0b01110, 0b10000, 0b10000, 0b10000, 0b01110 },
        'd' => .{ 0b00001, 0b00001, 0b01101, 0b10011, 0b10001, 0b10001, 0b01111 },
        'e' => .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b11111, 0b10000, 0b01110 },
        'f' => .{ 0b00110, 0b01001, 0b01000, 0b11100, 0b01000, 0b01000, 0b01000 },
        'g' => .{ 0b00000, 0b01111, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 },
        'h' => .{ 0b10000, 0b10000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
        'i' => .{ 0b00100, 0b00000, 0b01100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'j' => .{ 0b00010, 0b00000, 0b00110, 0b00010, 0b00010, 0b10010, 0b01100 },
        'k' => .{ 0b10000, 0b10000, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010 },
        'l' => .{ 0b01100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b01110 },
        'm' => .{ 0b00000, 0b00000, 0b11010, 0b10101, 0b10101, 0b10101, 0b10101 },
        'n' => .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10001, 0b10001, 0b10001 },
        'o' => .{ 0b00000, 0b00000, 0b01110, 0b10001, 0b10001, 0b10001, 0b01110 },
        'p' => .{ 0b00000, 0b00000, 0b11110, 0b10001, 0b11110, 0b10000, 0b10000 },
        'q' => .{ 0b00000, 0b00000, 0b01111, 0b10001, 0b01111, 0b00001, 0b00001 },
        'r' => .{ 0b00000, 0b00000, 0b10110, 0b11001, 0b10000, 0b10000, 0b10000 },
        's' => .{ 0b00000, 0b00000, 0b01111, 0b10000, 0b01110, 0b00001, 0b11110 },
        't' => .{ 0b01000, 0b01000, 0b11100, 0b01000, 0b01000, 0b01001, 0b00110 },
        'u' => .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b10011, 0b01101 },
        'v' => .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'w' => .{ 0b00000, 0b00000, 0b10001, 0b10101, 0b10101, 0b10101, 0b01010 },
        'x' => .{ 0b00000, 0b00000, 0b10001, 0b01010, 0b00100, 0b01010, 0b10001 },
        'y' => .{ 0b00000, 0b00000, 0b10001, 0b10001, 0b01111, 0b00001, 0b01110 },
        'z' => .{ 0b00000, 0b00000, 0b11111, 0b00010, 0b00100, 0b01000, 0b11111 },
        'A' => .{ 0b01110, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'B' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10001, 0b10001, 0b11110 },
        'C' => .{ 0b01111, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b01111 },
        'D' => .{ 0b11110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b11110 },
        'E' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b11111 },
        'F' => .{ 0b11111, 0b10000, 0b10000, 0b11110, 0b10000, 0b10000, 0b10000 },
        'G' => .{ 0b01111, 0b10000, 0b10000, 0b10111, 0b10001, 0b10001, 0b01111 },
        'H' => .{ 0b10001, 0b10001, 0b10001, 0b11111, 0b10001, 0b10001, 0b10001 },
        'I' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b11111 },
        'J' => .{ 0b00111, 0b00010, 0b00010, 0b00010, 0b00010, 0b10010, 0b01100 },
        'K' => .{ 0b10001, 0b10010, 0b10100, 0b11000, 0b10100, 0b10010, 0b10001 },
        'L' => .{ 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b10000, 0b11111 },
        'M' => .{ 0b10001, 0b11011, 0b10101, 0b10101, 0b10001, 0b10001, 0b10001 },
        'N' => .{ 0b10001, 0b11001, 0b10101, 0b10011, 0b10001, 0b10001, 0b10001 },
        'O' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'P' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10000, 0b10000, 0b10000 },
        'Q' => .{ 0b01110, 0b10001, 0b10001, 0b10001, 0b10101, 0b10010, 0b01101 },
        'R' => .{ 0b11110, 0b10001, 0b10001, 0b11110, 0b10100, 0b10010, 0b10001 },
        'S' => .{ 0b01111, 0b10000, 0b10000, 0b01110, 0b00001, 0b00001, 0b11110 },
        'T' => .{ 0b11111, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'U' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01110 },
        'V' => .{ 0b10001, 0b10001, 0b10001, 0b10001, 0b10001, 0b01010, 0b00100 },
        'W' => .{ 0b10001, 0b10001, 0b10001, 0b10101, 0b10101, 0b11011, 0b10001 },
        'X' => .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b01010, 0b10001 },
        'Y' => .{ 0b10001, 0b01010, 0b00100, 0b00100, 0b00100, 0b00100, 0b00100 },
        'Z' => .{ 0b11111, 0b00001, 0b00010, 0b00100, 0b01000, 0b10000, 0b11111 },
        else => .{ 0b01110, 0b10001, 0b00001, 0b00010, 0b00100, 0b00000, 0b00100 },
    };
}

fn paintSolidRect(
    pixels: []u32,
    stride: usize,
    left: i32,
    top: i32,
    width: i32,
    height: i32,
    clip_right: i32,
    color: u32,
) void {
    if (width <= 0 or height <= 0 or stride == 0) return;

    const buffer_width: i32 = @intCast(stride);
    const buffer_height: i32 = @intCast(pixels.len / stride);
    const right = @min(@min(left + width, clip_right), buffer_width);
    const bottom = @min(top + height, buffer_height);
    const left_u: usize = @intCast(@max(left, 0));
    const top_u: usize = @intCast(@max(top, 0));
    const right_u: usize = @intCast(@max(right, 0));
    const bottom_u: usize = @intCast(@max(bottom, 0));
    if (left_u >= right_u or top_u >= bottom_u) return;

    for (top_u..bottom_u) |y| {
        @memset(pixels[y * stride + left_u .. y * stride + right_u], color);
    }
}

fn clampI32(value: i32, lower: i32, upper: i32) i32 {
    if (upper <= lower) return lower;
    return @min(@max(value, lower), upper);
}

fn roundPositiveToI32(value: f64) i32 {
    return @intFromFloat(@floor(@max(value, 0) + 0.5));
}

test "Wayland title: layout stays centered and avoids controls" {
    const title_layout = layout(640, 48, 600, 1.0, "heavy-slug Vulkan demo").?;

    const expected_gap = roundPositiveToI32(gap_to_controls);
    try std.testing.expect(title_layout.left > roundPositiveToI32(margin));
    try std.testing.expect(title_layout.right <= 600 - expected_gap);
    try std.testing.expect(title_layout.top > 0);
    try std.testing.expectEqual(@as(i32, 2), title_layout.glyph_px);

    const narrow = layout(128, 48, 88, 1.0, "heavy-slug Vulkan demo").?;
    try std.testing.expect(narrow.left >= roundPositiveToI32(margin));
    try std.testing.expect(narrow.left < narrow.right);
    try std.testing.expect(narrow.right <= 88 - expected_gap);
}

test "Wayland title: renderer clips without touching control pixels" {
    var pixels = [_]u32{0} ** (96 * 24);
    const title_layout = Layout{
        .left = 4,
        .top = 4,
        .right = 64,
        .glyph_px = 2,
    };

    paint(pixels[0..], 96, "heavy-slug Vulkan demo", title_layout, 0xffffffff);

    var painted: usize = 0;
    var painted_after_clip: usize = 0;
    for (pixels, 0..) |pixel, index| {
        if (pixel == 0) continue;
        painted += 1;
        if (index % 96 >= @as(usize, @intCast(title_layout.right))) painted_after_clip += 1;
    }
    try std.testing.expect(painted > 0);
    try std.testing.expectEqual(@as(usize, 0), painted_after_clip);
}

test "Wayland title: renderer is UTF-8 scalar based" {
    try std.testing.expect((pixelWidth("heavy-slug Vulkan demo", 2) orelse 0) > 0);
    try std.testing.expect(glyphRows('h') != null);
    try std.testing.expect(glyphRows('H') != null);
    try std.testing.expect(glyphRows(0x1f) == null);
    try std.testing.expect(glyphRows(0x65e5) == null);
    try std.testing.expectEqual(@as(?i32, null), pixelWidth("日本語", 2));

    var pixels = [_]u32{0} ** (96 * 24);
    paint(pixels[0..], 96, "日本語", .{
        .left = 4,
        .top = 4,
        .right = 64,
        .glyph_px = 2,
    }, 0xffffffff);
    for (pixels) |pixel| {
        try std.testing.expectEqual(@as(u32, 0), pixel);
    }
}
