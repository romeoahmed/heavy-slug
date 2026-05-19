//! Font loading, shaping, and glyph encoding.

pub const freetype = @import("freetype.zig");
pub const harfbuzz = @import("harfbuzz.zig");
pub const glyph = @import("glyph.zig");
pub const shape = @import("shape.zig");
pub const font_system = @import("font_system.zig");

pub const FreeTypeLibrary = freetype.Library;
pub const FreeTypeFace = freetype.Face;
pub const FreeTypePixelSize = freetype.PixelSize;
pub const HarfBuzzBuffer = harfbuzz.Buffer;
pub const HarfBuzzFont = harfbuzz.Font;
pub const HarfBuzzLanguage = harfbuzz.Language;
pub const GlyphEncoder = glyph.GlyphEncoder;
pub const EncodedGlyph = glyph.EncodedGlyph;
pub const FontSystem = font_system.FontSystem;
pub const LoadedFont = font_system.LoadedFont;
pub const ShapePlan = shape.ShapePlan;
pub const ShapedRun = shape.ShapedRun;

pub const ft = freetype;
pub const hb = harfbuzz;

test {
    _ = freetype;
    _ = harfbuzz;
    _ = glyph;
    _ = shape;
    _ = font_system;
}
