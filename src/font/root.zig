//! Font shaping and glyph outline encoding.

pub const ft = @import("ft.zig");
pub const hb = @import("hb.zig");
pub const glyph = @import("glyph.zig");
pub const outline = @import("outline.zig");

pub const Library = ft.Library;
pub const Face = ft.Face;
pub const Buffer = hb.Buffer;
pub const FontContext = glyph.FontContext;
pub const EncodedGlyph = glyph.EncodedGlyph;

test {
    _ = ft;
    _ = hb;
    _ = glyph;
    _ = outline;
}
