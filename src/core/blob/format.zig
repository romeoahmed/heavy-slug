//! Explicit 32-bit coverage blob ABI shared by CPU encoders and GPU shaders.

const std = @import("std");
const protocol = @import("../protocol.zig");

pub const ProtocolVersion = protocol.ProtocolVersion;

pub const protocol_magic: u32 = protocol.magicWord("HSBL");
pub const protocol_version = ProtocolVersion.init(4, 0);
pub const protocol_version_word: u32 = protocol_version.word();
pub const min_fraction_bits: u8 = 12;
pub const max_fraction_bits: u8 = 24;
pub const default_fraction_bits: u8 = 18;
pub const hband_height_local: f64 = 4.0;
pub const exact_f32_int_radius: i32 = 1 << 24;

pub const flags_none: u32 = 0;
pub const supported_flags: u32 = flags_none;

pub const HeaderWord = enum(u32) {
    protocol_magic = 0,
    protocol_version = 1,
    fraction_bits = 2,
    flags = 3,
    fill_sign = 4,
    curve_count = 5,
    band_min = 6,
    band_count = 7,
    band_height_q = 8,
    id_count = 9,
    word_count = 10,
    bounds_min_x_q = 11,
    bounds_min_y_q = 12,
    bounds_max_x_q = 13,
    bounds_max_y_q = 14,
    curve_base_words = 15,
    band_base_words = 16,
    id_base_words = 17,
};

pub const CurveWord = enum(u32) {
    p0_x_q = 0,
    p0_y_q = 1,
    p1_x_q = 2,
    p1_y_q = 3,
    p2_x_q = 4,
    p2_y_q = 5,
    p3_x_q = 6,
    p3_y_q = 7,
    bbox_min_x_q = 8,
    bbox_min_y_q = 9,
    bbox_max_x_q = 10,
    bbox_max_y_q = 11,
};

pub const BandWord = enum(u32) {
    id_start = 0,
    id_count = 1,
};

pub const header_word_len: u32 = 18;
pub const curve_word_len: u32 = 12;
pub const band_word_len: u32 = 2;

pub const Header = struct {
    protocol_magic: u32,
    protocol_version: u32,
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

pub const Curve = struct {
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

    pub fn boundsValid(self: Curve) bool {
        return self.bbox_min_x_q <= self.bbox_max_x_q and
            self.bbox_min_y_q <= self.bbox_max_y_q;
    }

    pub fn controlPointsInsideBounds(self: Curve) bool {
        return xInside(self, self.p0_x_q) and xInside(self, self.p1_x_q) and
            xInside(self, self.p2_x_q) and xInside(self, self.p3_x_q) and
            yInside(self, self.p0_y_q) and yInside(self, self.p1_y_q) and
            yInside(self, self.p2_y_q) and yInside(self, self.p3_y_q);
    }

    fn xInside(self: Curve, x: i32) bool {
        return x >= self.bbox_min_x_q and x <= self.bbox_max_x_q;
    }

    fn yInside(self: Curve, y: i32) bool {
        return y >= self.bbox_min_y_q and y <= self.bbox_max_y_q;
    }
};

pub const Band = struct {
    id_start: u32,
    id_count: u32,
};

pub const Layout = struct {
    curve_base_words: u32,
    band_base_words: u32,
    id_base_words: u32,
    word_count: u32,

    pub fn init(curve_count: u32, band_count: u32, id_count: u32) error{BlobOffsetOverflow}!Layout {
        const curve_base = header_word_len;
        const band_base = try addMulU32(curve_base, curve_count, curve_word_len);
        const id_base = try addMulU32(band_base, band_count, band_word_len);
        const word_count = try addU32(id_base, id_count);
        return .{
            .curve_base_words = curve_base,
            .band_base_words = band_base,
            .id_base_words = id_base,
            .word_count = word_count,
        };
    }
};

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

pub fn writeHeader(words: []u32, header: Header) void {
    std.debug.assert(words.len >= header_word_len);
    words[headerIndex(.protocol_magic)] = header.protocol_magic;
    words[headerIndex(.protocol_version)] = header.protocol_version;
    words[headerIndex(.fraction_bits)] = header.fraction_bits;
    words[headerIndex(.flags)] = header.flags;
    words[headerIndex(.fill_sign)] = i32Word(header.fill_sign);
    words[headerIndex(.curve_count)] = header.curve_count;
    words[headerIndex(.band_min)] = i32Word(header.band_min);
    words[headerIndex(.band_count)] = header.band_count;
    words[headerIndex(.band_height_q)] = i32Word(header.band_height_q);
    words[headerIndex(.id_count)] = header.id_count;
    words[headerIndex(.word_count)] = header.word_count;
    words[headerIndex(.bounds_min_x_q)] = i32Word(header.bounds_min_x_q);
    words[headerIndex(.bounds_min_y_q)] = i32Word(header.bounds_min_y_q);
    words[headerIndex(.bounds_max_x_q)] = i32Word(header.bounds_max_x_q);
    words[headerIndex(.bounds_max_y_q)] = i32Word(header.bounds_max_y_q);
    words[headerIndex(.curve_base_words)] = header.curve_base_words;
    words[headerIndex(.band_base_words)] = header.band_base_words;
    words[headerIndex(.id_base_words)] = header.id_base_words;
}

pub fn readHeader(words: []const u32) Header {
    std.debug.assert(words.len >= header_word_len);
    return .{
        .protocol_magic = words[headerIndex(.protocol_magic)],
        .protocol_version = words[headerIndex(.protocol_version)],
        .fraction_bits = words[headerIndex(.fraction_bits)],
        .flags = words[headerIndex(.flags)],
        .fill_sign = wordI32(words[headerIndex(.fill_sign)]),
        .curve_count = words[headerIndex(.curve_count)],
        .band_min = wordI32(words[headerIndex(.band_min)]),
        .band_count = words[headerIndex(.band_count)],
        .band_height_q = wordI32(words[headerIndex(.band_height_q)]),
        .id_count = words[headerIndex(.id_count)],
        .word_count = words[headerIndex(.word_count)],
        .bounds_min_x_q = wordI32(words[headerIndex(.bounds_min_x_q)]),
        .bounds_min_y_q = wordI32(words[headerIndex(.bounds_min_y_q)]),
        .bounds_max_x_q = wordI32(words[headerIndex(.bounds_max_x_q)]),
        .bounds_max_y_q = wordI32(words[headerIndex(.bounds_max_y_q)]),
        .curve_base_words = words[headerIndex(.curve_base_words)],
        .band_base_words = words[headerIndex(.band_base_words)],
        .id_base_words = words[headerIndex(.id_base_words)],
    };
}

pub fn writeCurve(words: []u32, word_offset: u32, curve: Curve) void {
    const off: usize = @intCast(word_offset);
    std.debug.assert(words.len >= off + curve_word_len);
    words[off + curveIndex(.p0_x_q)] = i32Word(curve.p0_x_q);
    words[off + curveIndex(.p0_y_q)] = i32Word(curve.p0_y_q);
    words[off + curveIndex(.p1_x_q)] = i32Word(curve.p1_x_q);
    words[off + curveIndex(.p1_y_q)] = i32Word(curve.p1_y_q);
    words[off + curveIndex(.p2_x_q)] = i32Word(curve.p2_x_q);
    words[off + curveIndex(.p2_y_q)] = i32Word(curve.p2_y_q);
    words[off + curveIndex(.p3_x_q)] = i32Word(curve.p3_x_q);
    words[off + curveIndex(.p3_y_q)] = i32Word(curve.p3_y_q);
    words[off + curveIndex(.bbox_min_x_q)] = i32Word(curve.bbox_min_x_q);
    words[off + curveIndex(.bbox_min_y_q)] = i32Word(curve.bbox_min_y_q);
    words[off + curveIndex(.bbox_max_x_q)] = i32Word(curve.bbox_max_x_q);
    words[off + curveIndex(.bbox_max_y_q)] = i32Word(curve.bbox_max_y_q);
}

pub fn readCurve(words: []const u32, word_offset: u32) Curve {
    const off: usize = @intCast(word_offset);
    std.debug.assert(words.len >= off + curve_word_len);
    return .{
        .p0_x_q = wordI32(words[off + curveIndex(.p0_x_q)]),
        .p0_y_q = wordI32(words[off + curveIndex(.p0_y_q)]),
        .p1_x_q = wordI32(words[off + curveIndex(.p1_x_q)]),
        .p1_y_q = wordI32(words[off + curveIndex(.p1_y_q)]),
        .p2_x_q = wordI32(words[off + curveIndex(.p2_x_q)]),
        .p2_y_q = wordI32(words[off + curveIndex(.p2_y_q)]),
        .p3_x_q = wordI32(words[off + curveIndex(.p3_x_q)]),
        .p3_y_q = wordI32(words[off + curveIndex(.p3_y_q)]),
        .bbox_min_x_q = wordI32(words[off + curveIndex(.bbox_min_x_q)]),
        .bbox_min_y_q = wordI32(words[off + curveIndex(.bbox_min_y_q)]),
        .bbox_max_x_q = wordI32(words[off + curveIndex(.bbox_max_x_q)]),
        .bbox_max_y_q = wordI32(words[off + curveIndex(.bbox_max_y_q)]),
    };
}

pub fn writeBand(words: []u32, word_offset: u32, band: Band) void {
    const off: usize = @intCast(word_offset);
    std.debug.assert(words.len >= off + band_word_len);
    words[off + bandIndex(.id_start)] = band.id_start;
    words[off + bandIndex(.id_count)] = band.id_count;
}

pub fn readBand(words: []const u32, word_offset: u32) Band {
    const off: usize = @intCast(word_offset);
    std.debug.assert(words.len >= off + band_word_len);
    return .{
        .id_start = words[off + bandIndex(.id_start)],
        .id_count = words[off + bandIndex(.id_count)],
    };
}

pub fn wordsFromBytes(bytes: []align(@alignOf(u32)) const u8) []const u32 {
    if (bytes.len == 0) return &.{};
    std.debug.assert(bytes.len % @sizeOf(u32) == 0);
    return std.mem.bytesAsSlice(u32, bytes);
}

pub fn validateFractionBits(fraction_bits: u8) error{PrecisionUnsupported}!void {
    if (!isSupportedFractionBits(fraction_bits)) return error.PrecisionUnsupported;
}

pub fn isSupportedFractionBits(fraction_bits: u8) bool {
    return fraction_bits >= min_fraction_bits and fraction_bits <= max_fraction_bits;
}

pub fn scaleForFractionBits(fraction_bits: u8) f64 {
    std.debug.assert(isSupportedFractionBits(fraction_bits));
    return std.math.ldexp(@as(f64, 1.0), @as(i32, fraction_bits));
}

pub fn hbandHeightQ(fraction_bits: u8) i32 {
    const q = @round(hband_height_local * scaleForFractionBits(fraction_bits));
    std.debug.assert(q > 0 and q <= @as(f64, @floatFromInt(std.math.maxInt(i32))));
    return @intFromFloat(q);
}

pub fn dequantize(value: i32, fraction_bits: u8) f64 {
    return @as(f64, @floatFromInt(value)) / scaleForFractionBits(fraction_bits);
}

fn headerIndex(comptime word: HeaderWord) usize {
    return @intCast(@intFromEnum(word));
}

fn curveIndex(comptime word: CurveWord) usize {
    return @intCast(@intFromEnum(word));
}

fn bandIndex(comptime word: BandWord) usize {
    return @intCast(@intFromEnum(word));
}

fn i32Word(value: i32) u32 {
    return @bitCast(value);
}

fn wordI32(value: u32) i32 {
    return @bitCast(value);
}

fn addU32(a: u32, b: u32) error{BlobOffsetOverflow}!u32 {
    return std.math.add(u32, a, b) catch error.BlobOffsetOverflow;
}

fn addMulU32(a: u32, b: u32, c: u32) error{BlobOffsetOverflow}!u32 {
    const product = std.math.mul(u32, b, c) catch return error.BlobOffsetOverflow;
    return addU32(a, product);
}

test "Coverage blob v4 word layout is explicit and stable" {
    try std.testing.expectEqual(@as(u32, 18), header_word_len);
    try std.testing.expectEqual(@as(u32, 12), curve_word_len);
    try std.testing.expectEqual(@as(u32, 2), band_word_len);
    try std.testing.expectEqual(@as(u32, 0), @intFromEnum(HeaderWord.protocol_magic));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(HeaderWord.protocol_version));
    try std.testing.expectEqual(@as(u32, 17), @intFromEnum(HeaderWord.id_base_words));
    try std.testing.expectEqual(@as(u32, 11), @intFromEnum(CurveWord.bbox_max_y_q));
    try std.testing.expectEqual(@as(u32, 1), @intFromEnum(BandWord.id_count));
    try std.testing.expectEqual(protocol.magicWord("HSBL"), protocol_magic);
    try std.testing.expectEqual(ProtocolVersion.init(4, 0).word(), protocol_version_word);
}

test "CoverageBlob owns word storage and exposes upload bytes" {
    const words = try std.testing.allocator.alloc(u32, 4);
    words[0] = protocol_magic;
    words[1] = protocol_version_word;
    words[2] = 0;
    words[3] = 0;

    var blob = CoverageBlob.init(std.testing.allocator, words);
    defer blob.deinit();

    try std.testing.expectEqual(@as(usize, 4), blob.words.len);
    try std.testing.expectEqual(@as(usize, 16), blob.len());
}

test "Coverage blob layout uses checked word arithmetic" {
    const layout = try Layout.init(3, 2, 5);
    try std.testing.expectEqual(header_word_len, layout.curve_base_words);
    try std.testing.expectEqual(header_word_len + 3 * curve_word_len, layout.band_base_words);
    try std.testing.expectEqual(layout.band_base_words + 2 * band_word_len, layout.id_base_words);
    try std.testing.expectEqual(layout.id_base_words + 5, layout.word_count);

    try std.testing.expectError(error.BlobOffsetOverflow, Layout.init(std.math.maxInt(u32), 0, 0));
}

test "Coverage blob header, curve, and band round-trip by word offset" {
    const layout = try Layout.init(1, 1, 1);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = Header{
        .protocol_magic = protocol_magic,
        .protocol_version = protocol_version_word,
        .fraction_bits = default_fraction_bits,
        .flags = flags_none,
        .fill_sign = -1,
        .curve_count = 1,
        .band_min = -2,
        .band_count = 1,
        .band_height_q = hbandHeightQ(default_fraction_bits),
        .id_count = 1,
        .word_count = layout.word_count,
        .bounds_min_x_q = -3,
        .bounds_min_y_q = -4,
        .bounds_max_x_q = 5,
        .bounds_max_y_q = 6,
        .curve_base_words = layout.curve_base_words,
        .band_base_words = layout.band_base_words,
        .id_base_words = layout.id_base_words,
    };
    writeHeader(words, header);
    try std.testing.expectEqual(header, readHeader(words));

    const curve = Curve{
        .p0_x_q = -1,
        .p0_y_q = -2,
        .p1_x_q = 3,
        .p1_y_q = 4,
        .p2_x_q = 5,
        .p2_y_q = 6,
        .p3_x_q = 7,
        .p3_y_q = 8,
        .bbox_min_x_q = -1,
        .bbox_min_y_q = -2,
        .bbox_max_x_q = 7,
        .bbox_max_y_q = 8,
    };
    writeCurve(words, layout.curve_base_words, curve);
    try std.testing.expectEqual(curve, readCurve(words, layout.curve_base_words));

    const band = Band{ .id_start = 0, .id_count = 1 };
    writeBand(words, layout.band_base_words, band);
    try std.testing.expectEqual(band, readBand(words, layout.band_base_words));
}
