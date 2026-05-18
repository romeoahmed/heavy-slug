//! Read-only validation and indexing for encoded coverage blobs.

const std = @import("std");
const format = @import("format.zig");

pub const Error = error{
    BlobTooSmall,
    BlobMisaligned,
    BadMagic,
    BadFractionBits,
    BadOffsets,
};

pub const BlobView = struct {
    words: []const u32,
    header: format.Header,

    pub fn initCoverageBlob(blob: format.CoverageBlob) Error!BlobView {
        return init(blob.bytes());
    }

    pub fn init(bytes: []const u8) Error!BlobView {
        if (bytes.len % @sizeOf(u32) != 0) return error.BlobMisaligned;
        if (bytes.len < @sizeOf(format.Header)) return error.BlobTooSmall;
        if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return error.BlobMisaligned;

        const aligned_bytes: []align(@alignOf(u32)) const u8 = @alignCast(bytes);
        const words = format.wordsFromBytes(aligned_bytes);
        const header = std.mem.bytesToValue(format.Header, aligned_bytes[0..@sizeOf(format.Header)]);
        if (header.magic_version != format.magic_version) return error.BadMagic;
        if (header.fraction_bits < format.min_fraction_bits or header.fraction_bits > format.max_fraction_bits) {
            return error.BadFractionBits;
        }
        if (header.word_count != words.len) return error.BadOffsets;
        if (header.curve_base_words != format.header_word_len) return error.BadOffsets;

        const curve_end = addMul(header.curve_base_words, header.curve_count, format.curve_word_len) orelse
            return error.BadOffsets;
        const band_end = addMul(header.band_base_words, header.band_count, format.band_word_len) orelse
            return error.BadOffsets;
        const id_end = std.math.add(u32, header.id_base_words, header.id_count) catch
            return error.BadOffsets;

        if (header.band_base_words != curve_end or header.id_base_words != band_end) return error.BadOffsets;
        if (id_end != header.word_count) return error.BadOffsets;

        return .{ .words = words, .header = header };
    }

    pub fn curve(self: BlobView, index: u32) format.Curve {
        std.debug.assert(index < self.header.curve_count);
        const off_words: usize = @intCast(self.header.curve_base_words + index * format.curve_word_len);
        const off_bytes = off_words * @sizeOf(u32);
        const bytes = std.mem.sliceAsBytes(self.words);
        return std.mem.bytesToValue(format.Curve, bytes[off_bytes..][0..@sizeOf(format.Curve)]);
    }

    pub fn band(self: BlobView, index: u32) format.Band {
        std.debug.assert(index < self.header.band_count);
        const off_words: usize = @intCast(self.header.band_base_words + index * format.band_word_len);
        const off_bytes = off_words * @sizeOf(u32);
        const bytes = std.mem.sliceAsBytes(self.words);
        return std.mem.bytesToValue(format.Band, bytes[off_bytes..][0..@sizeOf(format.Band)]);
    }

    pub fn curveId(self: BlobView, index: u32) u32 {
        std.debug.assert(index < self.header.id_count);
        return self.words[self.header.id_base_words + index];
    }
};

fn addMul(a: u32, b: u32, c: u32) ?u32 {
    const product = std.math.mul(u32, b, c) catch return null;
    return std.math.add(u32, a, product) catch null;
}

test "BlobView rejects short blobs" {
    try std.testing.expectError(Error.BlobTooSmall, BlobView.init(&.{}));
}

test "BlobView rejects misaligned word storage" {
    var bytes: [@sizeOf(format.Header) + 1]u8 align(@alignOf(u32)) = undefined;
    try std.testing.expectError(
        Error.BlobMisaligned,
        BlobView.init(bytes[1 .. @sizeOf(format.Header) + 1]),
    );
}

test "BlobView decodes v2 header and curve" {
    const total_words = format.header_word_len + format.curve_word_len;
    const words = try std.testing.allocator.alloc(u32, total_words);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = format.Header{
        .magic_version = format.magic_version,
        .fraction_bits = format.default_fraction_bits,
        .flags = 0,
        .fill_sign = 1,
        .curve_count = 1,
        .band_min = 0,
        .band_count = 0,
        .band_height_q = format.hbandHeightQ(format.default_fraction_bits),
        .id_count = 0,
        .word_count = total_words,
        .bounds_min_x_q = 0,
        .bounds_min_y_q = 0,
        .bounds_max_x_q = 4,
        .bounds_max_y_q = 4,
        .curve_base_words = format.header_word_len,
        .band_base_words = format.header_word_len + format.curve_word_len,
        .id_base_words = format.header_word_len + format.curve_word_len,
    };
    @memcpy(std.mem.sliceAsBytes(words)[0..@sizeOf(format.Header)], std.mem.asBytes(&header));

    const curve = format.Curve{
        .p0_x_q = 1,
        .p0_y_q = 2,
        .p1_x_q = 3,
        .p1_y_q = 4,
        .p2_x_q = 5,
        .p2_y_q = 6,
        .p3_x_q = 7,
        .p3_y_q = 8,
        .bbox_min_x_q = 1,
        .bbox_min_y_q = 2,
        .bbox_max_x_q = 7,
        .bbox_max_y_q = 8,
    };
    const off = @as(usize, format.header_word_len) * @sizeOf(u32);
    @memcpy(std.mem.sliceAsBytes(words)[off..][0..@sizeOf(format.Curve)], std.mem.asBytes(&curve));

    const view = try BlobView.init(std.mem.sliceAsBytes(words));
    try std.testing.expectEqual(@as(u32, 1), view.header.curveCount());
    try std.testing.expectEqual(@as(i32, 1), view.header.fillSign());
    try std.testing.expectEqual(@as(i32, 7), view.curve(0).p3_x_q);
}
