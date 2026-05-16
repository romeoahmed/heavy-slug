//! Borrowed per-frame glyph instance storage.

pub fn GlyphBatch(comptime GlyphInstance: type) type {
    return struct {
        const Self = @This();

        glyphs: []GlyphInstance,
        len: u32 = 0,
        submitted: bool = false,

        pub fn init(glyphs: []GlyphInstance) Self {
            return .{ .glyphs = glyphs };
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.submitted = false;
        }

        pub fn append(self: *Self, glyph: GlyphInstance) !void {
            if (self.submitted) return error.FrameAlreadySubmitted;
            if (self.len >= self.glyphs.len) return error.GlyphCapacityExceeded;
            self.glyphs[self.len] = glyph;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const GlyphInstance {
            return self.glyphs[0..self.len];
        }

        pub fn count(self: *const Self) u32 {
            return self.len;
        }

        pub fn markSubmitted(self: *Self) void {
            self.submitted = true;
        }
    };
}

const std = @import("std");

test "GlyphBatch writes into borrowed glyph storage" {
    const TestGlyph = extern struct { value: u32 };
    var storage: [2]TestGlyph = undefined;
    var batch = GlyphBatch(TestGlyph).init(&storage);

    try batch.append(.{ .value = 1 });
    try batch.append(.{ .value = 2 });
    try std.testing.expectError(error.GlyphCapacityExceeded, batch.append(.{ .value = 3 }));
    try std.testing.expectEqual(@as(u32, 2), batch.count());
    try std.testing.expectEqual(@as(u32, 1), batch.slice()[0].value);
}

test "GlyphBatch rejects appends after submit" {
    const TestGlyph = extern struct { value: u32 };
    var storage: [2]TestGlyph = undefined;
    var batch = GlyphBatch(TestGlyph).init(&storage);

    try batch.append(.{ .value = 1 });
    batch.markSubmitted();
    try std.testing.expectError(error.FrameAlreadySubmitted, batch.append(.{ .value = 2 }));
    try std.testing.expectEqual(@as(usize, 1), batch.slice().len);
}

test "GlyphBatch reset allows reuse after submit" {
    const TestGlyph = extern struct { value: u32 };
    var storage: [2]TestGlyph = undefined;
    var batch = GlyphBatch(TestGlyph).init(&storage);

    try batch.append(.{ .value = 1 });
    batch.markSubmitted();
    batch.reset();
    try batch.append(.{ .value = 2 });

    try std.testing.expectEqual(@as(u32, 1), batch.count());
    try std.testing.expectEqual(@as(u32, 2), batch.slice()[0].value);
}
