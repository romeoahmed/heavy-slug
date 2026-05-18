//! Coverage blob format, encoder, decoder, and reference helpers.

pub const format = @import("format.zig");
pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const hband = @import("hband.zig");
pub const reference = @import("reference.zig");

pub const Header = format.Header;
pub const Curve = format.Curve;
pub const Band = format.Band;
pub const CoverageBlob = format.CoverageBlob;
pub const BlobView = decode.BlobView;

test {
    _ = format;
    _ = decode;
    _ = encode;
    _ = hband;
    _ = reference;
}
