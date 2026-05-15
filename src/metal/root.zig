//! Metal 4 backend for heavy_slug.

pub const renderer = @import("renderer.zig");

pub const Context = renderer.Context;
pub const HostObjects = renderer.HostObjects;
pub const TextRenderer = renderer.TextRenderer;
pub const Renderer = renderer.TextRenderer;
pub const Options = renderer.Options;
pub const RendererOptions = renderer.Options;
pub const FontHandle = renderer.FontHandle;
pub const Stats = renderer.Stats;

test {
    _ = renderer;
}
