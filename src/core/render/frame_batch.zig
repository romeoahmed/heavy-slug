//! Borrowed per-frame glyph and meshlet storage.

const std = @import("std");

pub fn FrameBatch(comptime GlyphInstance: type, comptime GlyphMeshlet: type) type {
    return struct {
        const Self = @This();
        pub const Glyph = GlyphInstance;
        pub const Meshlet = GlyphMeshlet;

        glyphs: []GlyphInstance,
        meshlets: []GlyphMeshlet,
        glyph_count: u32 = 0,
        meshlet_count: u32 = 0,
        submitted: bool = false,

        pub fn init(glyphs: []GlyphInstance, meshlets: []GlyphMeshlet) Self {
            return .{ .glyphs = glyphs, .meshlets = meshlets };
        }

        pub fn reset(self: *Self) void {
            self.glyph_count = 0;
            self.meshlet_count = 0;
            self.submitted = false;
        }

        pub fn appendGlyph(self: *Self, glyph: GlyphInstance) !u32 {
            if (self.submitted) return error.FrameAlreadySubmitted;
            if (self.glyph_count >= self.glyphs.len) return error.GlyphCapacityExceeded;
            const index = self.glyph_count;
            self.glyphs[index] = glyph;
            self.glyph_count += 1;
            return index;
        }

        pub fn appendMeshlet(self: *Self, meshlet: GlyphMeshlet) !void {
            if (self.submitted) return error.FrameAlreadySubmitted;
            if (self.meshlet_count >= self.meshlets.len) return error.MeshletCapacityExceeded;
            self.meshlets[self.meshlet_count] = meshlet;
            self.meshlet_count += 1;
        }

        pub fn rollback(self: *Self, glyph_count: u32, meshlet_count: u32) void {
            std.debug.assert(glyph_count <= self.glyph_count);
            std.debug.assert(meshlet_count <= self.meshlet_count);
            self.glyph_count = glyph_count;
            self.meshlet_count = meshlet_count;
        }

        pub fn glyphSlice(self: *const Self) []const GlyphInstance {
            return self.glyphs[0..self.glyph_count];
        }

        pub fn meshletSlice(self: *const Self) []const GlyphMeshlet {
            return self.meshlets[0..self.meshlet_count];
        }

        pub fn glyphCount(self: *const Self) u32 {
            return self.glyph_count;
        }

        pub fn meshletCount(self: *const Self) u32 {
            return self.meshlet_count;
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
