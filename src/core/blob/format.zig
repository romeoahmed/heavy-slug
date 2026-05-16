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

pub const CoverageBlob = struct {
    allocator: std.mem.Allocator,
    texels: []Texel,

    pub fn empty(allocator: std.mem.Allocator) CoverageBlob {
        return .{ .allocator = allocator, .texels = &.{} };
    }

    pub fn init(allocator: std.mem.Allocator, texels: []Texel) CoverageBlob {
        return .{ .allocator = allocator, .texels = texels };
    }

    pub fn deinit(self: *CoverageBlob) void {
        if (self.texels.len != 0) self.allocator.free(self.texels);
        self.* = undefined;
    }

    pub fn bytes(self: CoverageBlob) []align(@alignOf(Texel)) const u8 {
        return std.mem.sliceAsBytes(self.texels);
    }

    pub fn len(self: CoverageBlob) usize {
        return self.bytes().len;
    }
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

test "CoverageBlob owns texel storage and exposes upload bytes" {
    const texels = try std.testing.allocator.alloc(Texel, 2);
    texels[0] = .{ .r = 0, .g = 0, .b = 1, .a = 1 };
    texels[1] = .{ .r = 1, .g = 1, .b = 0, .a = 0 };

    var blob = CoverageBlob.init(std.testing.allocator, texels);
    defer blob.deinit();

    try std.testing.expectEqual(@as(usize, 2), blob.texels.len);
    try std.testing.expectEqual(@as(usize, 16), blob.len());
}
