//! Window-title validation and platform string encoders for native demos.

const std = @import("std");

pub const Error = error{
    EmptyWindowTitle,
    InvalidWindowTitle,
};

pub fn validate(title: []const u8) Error!void {
    if (title.len == 0) return error.EmptyWindowTitle;
    if (std.mem.indexOfScalar(u8, title, 0) != null) return error.InvalidWindowTitle;
    if (!std.unicode.utf8ValidateSlice(title)) return error.InvalidWindowTitle;
}

pub fn allocUtf8Z(allocator: std.mem.Allocator, title: []const u8) (Error || std.mem.Allocator.Error)![:0]u8 {
    try validate(title);
    return allocator.dupeZ(u8, title);
}

pub fn allocUtf16LeZ(allocator: std.mem.Allocator, title: []const u8) (Error || std.mem.Allocator.Error)![:0]u16 {
    try validate(title);
    return std.unicode.utf8ToUtf16LeAllocZ(allocator, title) catch |err| switch (err) {
        error.InvalidUtf8 => error.InvalidWindowTitle,
        error.OutOfMemory => error.OutOfMemory,
    };
}

pub fn view(title: []const u8) Error!std.unicode.Utf8View {
    try validate(title);
    return std.unicode.Utf8View.initUnchecked(title);
}

test "demo title validation rejects ambiguous platform strings" {
    try validate("heavy-slug Vulkan demo");
    try validate("heavy-slug 日本語");

    try std.testing.expectError(error.EmptyWindowTitle, validate(""));
    try std.testing.expectError(error.InvalidWindowTitle, validate("heavy\x00slug"));
    try std.testing.expectError(error.InvalidWindowTitle, validate("\xff"));
}

test "demo title encoders produce sentinel-terminated platform strings" {
    const utf8 = try allocUtf8Z(std.testing.allocator, "heavy-slug 日本語");
    defer std.testing.allocator.free(utf8);
    try std.testing.expectEqual(@as(u8, 0), utf8[utf8.len]);
    try std.testing.expectEqualStrings("heavy-slug 日本語", utf8);

    const utf16 = try allocUtf16LeZ(std.testing.allocator, "heavy-slug 日本語");
    defer std.testing.allocator.free(utf16);
    try std.testing.expectEqual(@as(u16, 0), utf16[utf16.len]);
    try std.testing.expect(std.mem.indexOfScalar(u16, utf16, 0) == null);
}
