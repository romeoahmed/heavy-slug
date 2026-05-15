//! Vulkan SPIR-V 1.6 backend for heavy_slug.

pub const vk = @import("vulkan");
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
pub const Options = renderer.Options;
pub const RendererOptions = renderer.Options;
pub const FontHandle = renderer.FontHandle;
pub const FrameToken = renderer.FrameToken;
pub const Stats = renderer.Stats;

pub const required_device_extensions = Context.required_device_extensions;

test {
    _ = context;
    _ = descriptors;
    _ = frame;
    _ = glyph_store;
    _ = pipeline;
    _ = renderer;
}
