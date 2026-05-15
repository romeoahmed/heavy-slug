const std = @import("std");

pub const version: i16 = 3;
pub const header_len: u32 = 4;
pub const curve_texel_len: u32 = 3;
pub const curve_ids_per_texel: u32 = 4;
pub const units_per_pixel: f32 = 4.0;

pub const Texel = extern struct {
    r: i16,
    g: i16,
    b: i16,
    a: i16,
};

pub const Header = struct {
    bounds: Texel,
    curves: Texel,
    bands: Texel,
    ids: Texel,

    pub fn curveCount(self: Header) u32 {
        return @intCast(@max(self.curves.r, 0));
    }

    pub fn blobVersion(self: Header) i16 {
        return self.curves.g;
    }
};

pub fn texelsFromBytes(bytes: []align(@alignOf(Texel)) const u8) []const Texel {
    if (bytes.len == 0) return &.{};
    std.debug.assert(bytes.len % @sizeOf(Texel) == 0);
    return std.mem.bytesAsSlice(Texel, bytes);
}

test "Coverage blob texel layout is stable" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Texel));
    try std.testing.expectEqual(@as(usize, 2), @alignOf(Texel));
}
