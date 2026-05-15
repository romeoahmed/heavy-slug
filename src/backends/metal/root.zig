//! Metal 4 backend for heavy_slug.

pub const context = @import("context.zig");
pub const frame = @import("frame.zig");
pub const glyph_store = @import("glyph_store.zig");
pub const renderer = @import("renderer.zig");

pub const Context = renderer.Context;
pub const HostObjects = renderer.HostObjects;
pub const Renderer = renderer.Renderer;
pub const Frame = renderer.Frame;
pub const Target = renderer.Target;
pub const Options = renderer.Options;
pub const RendererOptions = renderer.Options;
pub const FontHandle = renderer.FontHandle;
pub const FrameToken = renderer.FrameToken;
pub const Stats = renderer.Stats;

test {
    _ = context;
    _ = frame;
    _ = glyph_store;
    _ = renderer;
}
