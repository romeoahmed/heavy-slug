//! Coverage blob storage layout shared by the CPU encoder and GPU shaders.

const std = @import("std");

pub const magic_version: u32 = 0x32425348; // "HSB2", little-endian.
pub const min_fraction_bits: u8 = 12;
pub const max_fraction_bits: u8 = 24;
pub const default_fraction_bits: u8 = 18;
pub const hband_height_local: f64 = 4.0;
pub const exact_f32_int_radius: i32 = 1 << 24;

pub const flags_none: u32 = 0;

pub const Header = extern struct {
    magic_version: u32,
    fraction_bits: u32,
    flags: u32,
    fill_sign: i32,
    curve_count: u32,
    band_min: i32,
    band_count: u32,
    band_height_q: i32,
    id_count: u32,
    word_count: u32,
    bounds_min_x_q: i32,
    bounds_min_y_q: i32,
    bounds_max_x_q: i32,
    bounds_max_y_q: i32,
    curve_base_words: u32,
    band_base_words: u32,
    id_base_words: u32,

    pub fn curveCount(self: Header) u32 {
        return self.curve_count;
    }

    pub fn fillSign(self: Header) i32 {
        return if (self.fill_sign < 0) -1 else 1;
    }

    pub fn bandMin(self: Header) i32 {
        return self.band_min;
    }

    pub fn bandCount(self: Header) u32 {
        return self.band_count;
    }

    pub fn curveBase(self: Header) u32 {
        return self.curve_base_words;
    }

    pub fn bandBase(self: Header) u32 {
        return self.band_base_words;
    }

    pub fn idBase(self: Header) u32 {
        return self.id_base_words;
    }

    pub fn scale(self: Header) f64 {
        return scaleForFractionBits(@intCast(self.fraction_bits));
    }
};

pub const Curve = extern struct {
    p0_x_q: i32,
    p0_y_q: i32,
    p1_x_q: i32,
    p1_y_q: i32,
    p2_x_q: i32,
    p2_y_q: i32,
    p3_x_q: i32,
    p3_y_q: i32,
    bbox_min_x_q: i32,
    bbox_min_y_q: i32,
    bbox_max_x_q: i32,
    bbox_max_y_q: i32,
};

pub const Band = extern struct {
    id_start: u32,
    id_count: u32,
};

pub const header_word_len: u32 = @divExact(@sizeOf(Header), @sizeOf(u32));
pub const curve_word_len: u32 = @divExact(@sizeOf(Curve), @sizeOf(u32));
pub const band_word_len: u32 = @divExact(@sizeOf(Band), @sizeOf(u32));

/// Owned 32-bit word buffer ready to upload as bytes.
pub const CoverageBlob = struct {
    allocator: std.mem.Allocator,
    words: []u32,

    pub fn empty(allocator: std.mem.Allocator) CoverageBlob {
        return .{ .allocator = allocator, .words = &.{} };
    }

    pub fn init(allocator: std.mem.Allocator, words: []u32) CoverageBlob {
        return .{ .allocator = allocator, .words = words };
    }

    pub fn deinit(self: *CoverageBlob) void {
        if (self.words.len != 0) self.allocator.free(self.words);
        self.* = undefined;
    }

    pub fn bytes(self: CoverageBlob) []align(@alignOf(u32)) const u8 {
        return std.mem.sliceAsBytes(self.words);
    }

    pub fn len(self: CoverageBlob) usize {
        return self.bytes().len;
    }
};

pub fn wordsFromBytes(bytes: []align(@alignOf(u32)) const u8) []const u32 {
    if (bytes.len == 0) return &.{};
    std.debug.assert(bytes.len % @sizeOf(u32) == 0);
    return std.mem.bytesAsSlice(u32, bytes);
}

pub fn scaleForFractionBits(fraction_bits: u8) f64 {
    std.debug.assert(fraction_bits <= max_fraction_bits);
    const scale: u32 = @as(u32, 1) << @intCast(fraction_bits);
    return @floatFromInt(scale);
}

pub fn hbandHeightQ(fraction_bits: u8) i32 {
    return @intFromFloat(@round(hband_height_local * scaleForFractionBits(fraction_bits)));
}

pub fn dequantize(value: i32, fraction_bits: u8) f64 {
    return @as(f64, @floatFromInt(value)) / scaleForFractionBits(fraction_bits);
}

test "Coverage blob v2 word layout is stable" {
    try std.testing.expectEqual(@as(usize, 4), @alignOf(Header));
    try std.testing.expectEqual(@as(usize, 68), @sizeOf(Header));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Curve));
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Band));
    try std.testing.expectEqual(@as(u32, 17), header_word_len);
    try std.testing.expectEqual(@as(u32, 12), curve_word_len);
    try std.testing.expectEqual(@as(u32, 2), band_word_len);
}

test "CoverageBlob owns word storage and exposes upload bytes" {
    const words = try std.testing.allocator.alloc(u32, 4);
    words[0] = magic_version;
    words[1] = default_fraction_bits;
    words[2] = 0;
    words[3] = 0;

    var blob = CoverageBlob.init(std.testing.allocator, words);
    defer blob.deinit();

    try std.testing.expectEqual(@as(usize, 4), blob.words.len);
    try std.testing.expectEqual(@as(usize, 16), blob.len());
}
