//! Metal 4 backend for heavy_slug.

pub const context = @import("context.zig");
pub const renderer = @import("renderer.zig");

pub const Context = context.Context;
pub const Host = context.Host;
pub const Renderer = renderer.Renderer;
pub const Frame = renderer.Frame;
pub const Target = renderer.Target;
pub const RendererOptions = renderer.RendererOptions;
pub const FontHandle = renderer.FontHandle;
pub const GlyphBlobRef = Renderer.GlyphBlobRef;
pub const FrameToken = renderer.FrameToken;
pub const Stats = renderer.Stats;
pub const shader_stats_enabled = renderer.shader_stats_enabled;

test {
    _ = context;
    _ = renderer;
}
