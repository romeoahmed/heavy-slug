//! Borrowed per-frame glyph and meshlet storage.

const std = @import("std");

pub fn FrameBatch(comptime GlyphInstance: type, comptime GlyphMeshlet: type) type {
    return struct {
        const Self = @This();
        pub const GlyphInstanceType = GlyphInstance;
        pub const GlyphMeshletType = GlyphMeshlet;

        glyphs: []GlyphInstance,
        meshlets: []GlyphMeshlet,
        glyph_len: u32 = 0,
        meshlet_len: u32 = 0,
        submitted: bool = false,

        pub fn init(glyphs: []GlyphInstance, meshlets: []GlyphMeshlet) Self {
            return .{ .glyphs = glyphs, .meshlets = meshlets };
        }

        pub fn reset(self: *Self) void {
            self.glyph_len = 0;
            self.meshlet_len = 0;
            self.submitted = false;
        }

        pub fn appendGlyph(self: *Self, glyph: GlyphInstance) !u32 {
            if (self.submitted) return error.FrameAlreadySubmitted;
            if (self.glyph_len >= self.glyphs.len) return error.GlyphCapacityExceeded;
            const index = self.glyph_len;
            self.glyphs[index] = glyph;
            self.glyph_len += 1;
            return index;
        }

        pub fn appendMeshlet(self: *Self, meshlet: GlyphMeshlet) !void {
            if (self.submitted) return error.FrameAlreadySubmitted;
            if (self.meshlet_len >= self.meshlets.len) return error.MeshletCapacityExceeded;
            self.meshlets[self.meshlet_len] = meshlet;
            self.meshlet_len += 1;
        }

        pub fn rollback(self: *Self, glyph_len: u32, meshlet_len: u32) void {
            std.debug.assert(glyph_len <= self.glyph_len);
            std.debug.assert(meshlet_len <= self.meshlet_len);
            self.glyph_len = glyph_len;
            self.meshlet_len = meshlet_len;
        }

        pub fn glyphSlice(self: *const Self) []const GlyphInstance {
            return self.glyphs[0..self.glyph_len];
        }

        pub fn meshletSlice(self: *const Self) []const GlyphMeshlet {
            return self.meshlets[0..self.meshlet_len];
        }

        pub fn glyphCount(self: *const Self) u32 {
            return self.glyph_len;
        }

        pub fn meshletCount(self: *const Self) u32 {
            return self.meshlet_len;
        }

        pub fn markSubmitted(self: *Self) void {
            self.submitted = true;
        }
    };
}

test "FrameBatch writes glyph and meshlet streams independently" {
    const TestGlyph = extern struct { value: u32 };
    const TestMeshlet = extern struct { glyph_index: u32 };
    var glyphs: [1]TestGlyph = undefined;
    var meshlets: [2]TestMeshlet = undefined;
    var batch = FrameBatch(TestGlyph, TestMeshlet).init(&glyphs, &meshlets);

    const glyph_index = try batch.appendGlyph(.{ .value = 7 });
    try batch.appendMeshlet(.{ .glyph_index = glyph_index });
    try batch.appendMeshlet(.{ .glyph_index = glyph_index });

    try std.testing.expectEqual(@as(u32, 1), batch.glyphCount());
    try std.testing.expectEqual(@as(u32, 2), batch.meshletCount());
    try std.testing.expectEqual(@as(u32, 7), batch.glyphSlice()[0].value);
    try std.testing.expectEqual(@as(u32, 0), batch.meshletSlice()[1].glyph_index);
    try std.testing.expectError(error.MeshletCapacityExceeded, batch.appendMeshlet(.{ .glyph_index = glyph_index }));
}

test "FrameBatch rollback restores both stream lengths" {
    const TestGlyph = extern struct { value: u32 };
    const TestMeshlet = extern struct { glyph_index: u32 };
    var glyphs: [2]TestGlyph = undefined;
    var meshlets: [2]TestMeshlet = undefined;
    var batch = FrameBatch(TestGlyph, TestMeshlet).init(&glyphs, &meshlets);

    try std.testing.expectEqual(@as(u32, 0), try batch.appendGlyph(.{ .value = 1 }));
    try batch.appendMeshlet(.{ .glyph_index = 0 });
    const glyph_mark = batch.glyphCount();
    const meshlet_mark = batch.meshletCount();

    try std.testing.expectEqual(@as(u32, 1), try batch.appendGlyph(.{ .value = 2 }));
    try batch.appendMeshlet(.{ .glyph_index = 1 });
    batch.rollback(glyph_mark, meshlet_mark);

    try std.testing.expectEqual(@as(u32, 1), batch.glyphCount());
    try std.testing.expectEqual(@as(u32, 1), batch.meshletCount());
    try std.testing.expectEqual(@as(u32, 1), batch.glyphSlice()[0].value);
}
