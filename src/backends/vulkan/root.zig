//! Vulkan SPIR-V 1.6 backend for heavy_slug.

pub const vk = @import("vulkan");
pub const context = @import("context.zig");
pub const descriptors = @import("descriptors.zig");
pub const pipeline = @import("pipeline.zig");
pub const renderer = @import("renderer.zig");

pub const Context = context.VulkanContext;
pub const DeviceDispatch = context.DeviceDispatch;
pub const InstanceDispatch = context.InstanceDispatch;
pub const FeatureError = context.FeatureError;
pub const TextRenderer = renderer.TextRenderer;
pub const Renderer = renderer.TextRenderer;
pub const Frame = renderer.Frame;
pub const Target = renderer.Target;
pub const Options = renderer.Options;
pub const RendererOptions = renderer.Options;
pub const FontHandle = renderer.FontHandle;
pub const Stats = renderer.Stats;

pub const required_device_extensions = Context.required_device_extensions;

test {
    _ = context;
    _ = descriptors;
    _ = pipeline;
    _ = renderer;
}
