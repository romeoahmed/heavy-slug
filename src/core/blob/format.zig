const std = @import("std");

pub const header_len: u32 = 2;
pub const curve_texel_len: u32 = 3;
pub const curve_ids_per_texel: u32 = 4;
pub const units_per_pixel: f32 = 4.0;
pub const hband_height_pixels: f32 = 4.0;
pub const hband_height_units: i16 = @intFromFloat(hband_height_pixels * units_per_pixel);

pub const Texel = extern struct {
    r: i16,
    g: i16,
    b: i16,
    a: i16,
};

pub const Header = struct {
    bounds: Texel,
    meta: Texel,

    pub fn curveCount(self: Header) u32 {
        return @intCast(@max(self.meta.r, 0));
    }

    pub fn fillSign(self: Header) i16 {
        return if (self.meta.g < 0) -1 else 1;
    }

    pub fn bandMin(self: Header) i32 {
        return self.meta.b;
    }

    pub fn bandCount(self: Header) u32 {
        return @intCast(@max(self.meta.a, 0));
    }

    pub fn curveBase(_: Header) u32 {
        return header_len;
    }

    pub fn bandBase(self: Header) u32 {
        return header_len + self.curveCount() * curve_texel_len;
    }

    pub fn idBase(self: Header) u32 {
        return self.bandBase() + self.bandCount();
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
