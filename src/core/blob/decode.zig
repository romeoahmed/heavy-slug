//! Read-only validation and indexing for encoded coverage blobs.

const std = @import("std");
const format = @import("format.zig");

pub const Error = error{
    BlobTooSmall,
    BlobMisaligned,
    BadMagic,
    BadFractionBits,
    BadHeader,
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
        if (bytes.len < format.header_word_len * @sizeOf(u32)) return error.BlobTooSmall;
        if (@intFromPtr(bytes.ptr) % @alignOf(u32) != 0) return error.BlobMisaligned;

        const aligned_bytes: []align(@alignOf(u32)) const u8 = @alignCast(bytes);
        const words = format.wordsFromBytes(aligned_bytes);
        const header = format.readHeader(words);

        try validateHeader(header, words.len);
        const view = BlobView{ .words = words, .header = header };
        try view.validateCurves();
        try view.validateCandidateIndex();
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
        return self.words[@as(usize, @intCast(self.header.id_base_words + index))];
    }

    fn validateCurves(self: BlobView) Error!void {
        var curve_index: u32 = 0;
        while (curve_index < self.header.curve_count) : (curve_index += 1) {
            const curve_value = self.curveUnchecked(curve_index);
            if (!curve_value.boundsValid()) return error.BadHeader;
            if (!curve_value.controlPointsInsideBounds()) return error.BadHeader;
            if (curve_value.bbox_min_x_q < self.header.bounds_min_x_q or
                curve_value.bbox_min_y_q < self.header.bounds_min_y_q or
                curve_value.bbox_max_x_q > self.header.bounds_max_x_q or
                curve_value.bbox_max_y_q > self.header.bounds_max_y_q)
            {
                return error.BadHeader;
            }
        }
    }

    fn validateCandidateIndex(self: BlobView) Error!void {
        var cursor: u32 = 0;
        var band_index: u32 = 0;
        while (band_index < self.header.band_count) : (band_index += 1) {
            const band_value = self.bandUnchecked(band_index);
            if (band_value.id_start != cursor) return error.BadOffsets;
            cursor = std.math.add(u32, cursor, band_value.id_count) catch return error.BadOffsets;
            if (cursor > self.header.id_count) return error.BadOffsets;
            try self.validateBandIdsSortedAndInRange(band_value);
        }
        if (cursor != self.header.id_count) return error.BadOffsets;
    }

    fn validateBandIdsSortedAndInRange(self: BlobView, band_value: format.Band) Error!void {
        var previous: u32 = 0;
        var have_previous = false;
        var local_index: u32 = 0;
        while (local_index < band_value.id_count) : (local_index += 1) {
            const curve_id = self.curveId(band_value.id_start + local_index);
            if (curve_id >= self.header.curve_count) return error.BadOffsets;
            if (have_previous and curve_id < previous) return error.BadOffsets;
            previous = curve_id;
            have_previous = true;
        }
    }

    fn curveUnchecked(self: BlobView, index: u32) format.Curve {
        return format.readCurve(
            self.words,
            self.header.curve_base_words + index * format.curve_word_len,
        );
    }

    fn bandUnchecked(self: BlobView, index: u32) format.Band {
        return format.readBand(
            self.words,
            self.header.band_base_words + index * format.band_word_len,
        );
    }
};

fn validateHeader(header: format.Header, actual_word_count: usize) Error!void {
    if (header.magic_version != format.magic_version) return error.BadMagic;
    if (header.fraction_bits < format.min_fraction_bits or header.fraction_bits > format.max_fraction_bits) {
        return error.BadFractionBits;
    }
    if (header.flags & ~format.supported_flags != 0) return error.BadHeader;
    if (header.fill_sign != -1 and header.fill_sign != 1) return error.BadHeader;
    if (header.band_height_q <= 0) return error.BadHeader;
    if (header.bounds_min_x_q > header.bounds_max_x_q or header.bounds_min_y_q > header.bounds_max_y_q) {
        return error.BadHeader;
    }
    if (@as(usize, @intCast(header.word_count)) != actual_word_count) return error.BadOffsets;

    const layout = format.Layout.init(header.curve_count, header.band_count, header.id_count) catch
        return error.BadOffsets;
    if (header.curve_base_words != layout.curve_base_words or
        header.band_base_words != layout.band_base_words or
        header.id_base_words != layout.id_base_words or
        header.word_count != layout.word_count)
    {
        return error.BadOffsets;
    }
}

test "BlobView rejects short blobs" {
    try std.testing.expectError(Error.BlobTooSmall, BlobView.init(&.{}));
}

test "BlobView rejects misaligned word storage" {
    var bytes: [@as(usize, format.header_word_len) * @sizeOf(u32) + 1]u8 align(@alignOf(u32)) = undefined;
    try std.testing.expectError(
        Error.BlobMisaligned,
        BlobView.init(bytes[1 .. @as(usize, format.header_word_len) * @sizeOf(u32) + 1]),
    );
}

test "BlobView decodes v3 header and curve" {
    const layout = try format.Layout.init(1, 0, 0);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 1,
        .word_count = layout.word_count,
    });
    format.writeHeader(words, header);

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
    format.writeCurve(words, header.curve_base_words, curve);

    const view = try BlobView.init(std.mem.sliceAsBytes(words));
    try std.testing.expectEqual(@as(u32, 1), view.header.curveCount());
    try std.testing.expectEqual(@as(i32, 1), view.header.fillSign());
    try std.testing.expectEqual(@as(i32, 7), view.curve(0).p3_x_q);
}

test "BlobView rejects invalid header fields" {
    const layout = try format.Layout.init(0, 0, 0);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    var header = testHeader(.{ .word_count = layout.word_count });
    header.flags = 1;
    format.writeHeader(words, header);
    try std.testing.expectError(error.BadHeader, BlobView.init(std.mem.sliceAsBytes(words)));

    header.flags = 0;
    header.fill_sign = 0;
    format.writeHeader(words, header);
    try std.testing.expectError(error.BadHeader, BlobView.init(std.mem.sliceAsBytes(words)));
}

test "BlobView rejects band candidate ranges outside the CSR table" {
    const layout = try format.Layout.init(1, 1, 1);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 1,
        .band_count = 1,
        .id_count = 1,
        .word_count = layout.word_count,
    });
    format.writeHeader(words, header);
    format.writeCurve(words, header.curve_base_words, testCurve());
    format.writeBand(words, header.band_base_words, .{
        .id_start = 1,
        .id_count = 1,
    });

    try std.testing.expectError(error.BadOffsets, BlobView.init(std.mem.sliceAsBytes(words)));
}

test "BlobView rejects candidate curve ids outside the curve table" {
    const layout = try format.Layout.init(1, 1, 1);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 1,
        .band_count = 1,
        .id_count = 1,
        .word_count = layout.word_count,
    });
    format.writeHeader(words, header);
    format.writeCurve(words, header.curve_base_words, testCurve());
    format.writeBand(words, header.band_base_words, .{
        .id_start = 0,
        .id_count = 1,
    });
    words[header.id_base_words] = 7;

    try std.testing.expectError(error.BadOffsets, BlobView.init(std.mem.sliceAsBytes(words)));
}

test "BlobView rejects unsorted per-band curve ids" {
    const layout = try format.Layout.init(2, 1, 2);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 2,
        .band_count = 1,
        .id_count = 2,
        .word_count = layout.word_count,
    });
    format.writeHeader(words, header);
    format.writeCurve(words, header.curve_base_words, testCurve());
    format.writeCurve(words, header.curve_base_words + format.curve_word_len, testCurve());
    format.writeBand(words, header.band_base_words, .{ .id_start = 0, .id_count = 2 });
    words[header.id_base_words] = 1;
    words[header.id_base_words + 1] = 0;

    try std.testing.expectError(error.BadOffsets, BlobView.init(std.mem.sliceAsBytes(words)));
}

test "BlobView rejects curves whose controls escape encoded bounds" {
    const layout = try format.Layout.init(1, 0, 0);
    const words = try std.testing.allocator.alloc(u32, layout.word_count);
    defer std.testing.allocator.free(words);
    @memset(words, 0);

    const header = testHeader(.{
        .curve_count = 1,
        .word_count = layout.word_count,
    });
    format.writeHeader(words, header);
    var curve = testCurve();
    curve.p3_x_q = 9;
    format.writeCurve(words, header.curve_base_words, curve);

    try std.testing.expectError(error.BadHeader, BlobView.init(std.mem.sliceAsBytes(words)));
}

const TestHeaderOverrides = struct {
    curve_count: u32 = 0,
    band_count: u32 = 0,
    id_count: u32 = 0,
    word_count: u32,
};

fn testHeader(overrides: TestHeaderOverrides) format.Header {
    const layout = format.Layout.init(overrides.curve_count, overrides.band_count, overrides.id_count) catch unreachable;
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
        .bounds_max_x_q = 8,
        .bounds_max_y_q = 8,
        .curve_base_words = layout.curve_base_words,
        .band_base_words = layout.band_base_words,
        .id_base_words = layout.id_base_words,
    };
}

fn testCurve() format.Curve {
    return .{
        .p0_x_q = 1,
        .p0_y_q = 1,
        .p1_x_q = 2,
        .p1_y_q = 2,
        .p2_x_q = 3,
        .p2_y_q = 3,
        .p3_x_q = 4,
        .p3_y_q = 4,
        .bbox_min_x_q = 1,
        .bbox_min_y_q = 1,
        .bbox_max_x_q = 4,
        .bbox_max_y_q = 4,
    };
}
