//! Vulkan 1.4 / SPIR-V 1.6 mesh-shader backend for heavy_slug.

pub const vk = @import("vulkan");
pub const chains = @import("chains.zig");
pub const context = @import("context.zig");
pub const descriptors = @import("descriptors.zig");
pub const frame = @import("frame.zig");
pub const glyph_store = @import("glyph_store.zig");
pub const pipeline = @import("pipeline.zig");
pub const renderer = @import("renderer.zig");

pub const Context = context.VulkanContext;
pub const DeviceDispatch = context.DeviceDispatch;
pub const InstanceDispatch = context.InstanceDispatch;
pub const FeatureError = context.FeatureError;
pub const Renderer = renderer.Renderer;
pub const Frame = renderer.Frame;
pub const Target = renderer.Target;
pub const RendererOptions = renderer.RendererOptions;
pub const FontHandle = renderer.FontHandle;
pub const GlyphBlobRef = Renderer.GlyphBlobRef;
pub const FrameToken = renderer.FrameToken;
pub const Stats = renderer.Stats;
pub const shader_stats_enabled = renderer.shader_stats_enabled;

pub const required_api_version = context.required_api_version;
pub const required_device_extensions = Context.required_device_extensions;

test {
    _ = chains;
    _ = context;
    _ = descriptors;
    _ = frame;
    _ = glyph_store;
    _ = pipeline;
    _ = renderer;
}
