//! Metal 4 backend for heavy_slug.

pub const renderer = @import("renderer.zig");

pub const Context = renderer.Context;
pub const TextRenderer = renderer.TextRenderer;
pub const Renderer = renderer.TextRenderer;
pub const RendererOptions = renderer.InitOptions;
pub const FontHandle = renderer.FontHandle;
pub const Stats = renderer.Stats;

test {
    _ = renderer;
}
