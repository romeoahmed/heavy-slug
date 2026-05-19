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

        const view = BlobView{ .words = words, .header = header };
        try view.validateTables();
        return view;
    }

    pub fn curve(self: BlobView, index: u32) format.Curve {
        std.debug.assert(index < self.header.curve_count);
        return self.curveUnchecked(index);
    }

    pub fn band(self: BlobView, index: u32) format.Band {
        std.debug.assert(index < self.header.band_count);
        return self.bandUnchecked(index);
    }

    pub fn curveId(self: BlobView, index: u32) u32 {
        std.debug.assert(index < self.header.id_count);
        return self.words[self.header.id_base_words + index];
    }

    fn validateTables(self: BlobView) Error!void {
        var band_index: u32 = 0;
        while (band_index < self.header.band_count) : (band_index += 1) {
            const band_value = self.bandUnchecked(band_index);
            const id_end = std.math.add(u32, band_value.id_start, band_value.id_count) catch
                return error.BadOffsets;
            if (id_end > self.header.id_count) return error.BadOffsets;
        }

        const id_start: usize = @intCast(self.header.id_base_words);
        const id_end: usize = id_start + @as(usize, @intCast(self.header.id_count));
        for (self.words[id_start..id_end]) |curve_id| {
            if (curve_id >= self.header.curve_count) return error.BadOffsets;
        }
    }

    fn curveUnchecked(self: BlobView, index: u32) format.Curve {
        return self.readValue(
            format.Curve,
            self.header.curve_base_words + index * format.curve_word_len,
        );
    }

    fn bandUnchecked(self: BlobView, index: u32) format.Band {
        return self.readValue(
            format.Band,
            self.header.band_base_words + index * format.band_word_len,
        );
    }

    fn readValue(self: BlobView, comptime T: type, word_offset: u32) T {
        const off_words: usize = @intCast(word_offset);
        const off_bytes = off_words * @sizeOf(u32);
        const bytes = std.mem.sliceAsBytes(self.words);
        return std.mem.bytesToValue(T, bytes[off_bytes..][0..@sizeOf(T)]);
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

test "BlobView rejects band candidate ranges outside the id table" {
    const total_words = format.header_word_len + format.curve_word_len + format.band_word_len + 1;
    const words = try std.testing.allocator.alloc(u32, total_words);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 1,
        .band_count = 1,
        .id_count = 1,
        .word_count = total_words,
    });
    writeTestValue(words, 0, header);
    writeTestValue(words, header.band_base_words, format.Band{
        .id_start = 1,
        .id_count = 1,
    });

    try std.testing.expectError(error.BadOffsets, BlobView.init(std.mem.sliceAsBytes(words)));
}

test "BlobView rejects candidate curve ids outside the curve table" {
    const total_words = format.header_word_len + format.curve_word_len + format.band_word_len + 1;
    const words = try std.testing.allocator.alloc(u32, total_words);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 1,
        .band_count = 1,
        .id_count = 1,
        .word_count = total_words,
    });
    writeTestValue(words, 0, header);
    writeTestValue(words, header.band_base_words, format.Band{
        .id_start = 0,
        .id_count = 1,
    });
    words[header.id_base_words] = 7;

    try std.testing.expectError(error.BadOffsets, BlobView.init(std.mem.sliceAsBytes(words)));
}

const TestHeaderOverrides = struct {
    curve_count: u32 = 0,
    band_count: u32 = 0,
    id_count: u32 = 0,
    word_count: u32,
};

fn testHeader(overrides: TestHeaderOverrides) format.Header {
    const curve_base = format.header_word_len;
    const band_base = curve_base + overrides.curve_count * format.curve_word_len;
    const id_base = band_base + overrides.band_count * format.band_word_len;
    return .{
        .magic_version = format.magic_version,
        .fraction_bits = format.default_fraction_bits,
        .flags = 0,
        .fill_sign = 1,
        .curve_count = overrides.curve_count,
        .band_min = 0,
        .band_count = overrides.band_count,
        .band_height_q = format.hbandHeightQ(format.default_fraction_bits),
        .id_count = overrides.id_count,
        .word_count = overrides.word_count,
        .bounds_min_x_q = 0,
        .bounds_min_y_q = 0,
        .bounds_max_x_q = 0,
        .bounds_max_y_q = 0,
        .curve_base_words = curve_base,
        .band_base_words = band_base,
        .id_base_words = id_base,
    };
}

fn writeTestValue(words: []u32, word_offset: u32, value: anytype) void {
    const start = @as(usize, @intCast(word_offset)) * @sizeOf(u32);
    @memcpy(
        std.mem.sliceAsBytes(words)[start..][0..@sizeOf(@TypeOf(value))],
        std.mem.asBytes(&value),
    );
}
