const std = @import("std");
const format = @import("format.zig");

pub const Error = error{
    BlobTooSmall,
    BlobMisaligned,
    UnsupportedBlobVersion,
};

pub const BlobView = struct {
    texels: []const format.Texel,
    header: format.Header,

    pub fn init(bytes: []const u8) Error!BlobView {
        if (bytes.len % @sizeOf(format.Texel) != 0) return error.BlobMisaligned;
        if (bytes.len < format.header_len * @sizeOf(format.Texel)) return error.BlobTooSmall;
        if (@intFromPtr(bytes.ptr) % @alignOf(format.Texel) != 0) return error.BlobMisaligned;

        const aligned_bytes: []align(@alignOf(format.Texel)) const u8 = @alignCast(bytes);
        const texels = format.texelsFromBytes(aligned_bytes);
        const header = format.Header{
            .bounds = texels[0],
            .curves = texels[1],
            .bands = texels[2],
            .ids = texels[3],
        };
        if (header.blobVersion() != format.version) {
            return error.UnsupportedBlobVersion;
        }
        return .{ .texels = texels, .header = header };
    }

    pub fn curveTexels(self: BlobView, index: u32) []const format.Texel {
        const base: usize = @intCast(self.header.curves.a);
        const off = base + @as(usize, index) * format.curve_texel_len;
        return self.texels[off..][0..format.curve_texel_len];
    }
};

test "BlobView rejects short blobs" {
    try std.testing.expectError(Error.BlobTooSmall, BlobView.init(&.{}));
}

test "BlobView decodes header" {
    const texels = [_]format.Texel{
        .{ .r = 0, .g = 0, .b = 4, .a = 4 },
        .{ .r = 1, .g = format.version, .b = 1, .a = format.header_len },
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .{ .r = 0, .g = 0, .b = 1, .a = 1 },
        .{ .r = 2, .g = 2, .b = 3, .a = 3 },
        .{ .r = 0, .g = 3, .b = 0, .a = 3 },
    };
    const view = try BlobView.init(std.mem.sliceAsBytes(&texels));
    try std.testing.expectEqual(@as(u32, 1), view.header.curveCount());
    try std.testing.expectEqual(@as(usize, 3), view.curveTexels(0).len);
}

test "BlobView rejects unsupported blob versions" {
    const texels = [_]format.Texel{
        .{ .r = 0, .g = 0, .b = 4, .a = 4 },
        .{ .r = 1, .g = format.version + 1, .b = 1, .a = format.header_len },
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
        .{ .r = 0, .g = 0, .b = 0, .a = 0 },
    };
    try std.testing.expectError(Error.UnsupportedBlobVersion, BlobView.init(std.mem.sliceAsBytes(&texels)));
}
