//! Vulkan 1.4 / SPIR-V 1.6 mesh-shader backend for heavy_slug.

pub const vk = @import("vulkan");
pub const bindings = @import("bindings.zig");
pub const chains = @import("chains.zig");
pub const context = @import("context.zig");
pub const draw_plan = @import("draw_plan.zig");
pub const memory = @import("memory.zig");
pub const requirements = @import("requirements.zig");
pub const shader_program = @import("shader_program.zig");
pub const renderer = @import("renderer.zig");

pub const Context = context.Context;
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
pub const DrawTextResult = renderer.DrawTextResult;
pub const SubmitResult = renderer.SubmitResult;
pub const Stats = renderer.Stats;
pub const shader_stats_enabled = renderer.shader_stats_enabled;

pub const required_api_version = context.required_api_version;
pub const required_device_extensions = context.Context.required_device_extensions;

test {
    _ = bindings;
    _ = chains;
    _ = context;
    _ = draw_plan;
    _ = memory;
    _ = requirements;
    _ = shader_program;
    _ = renderer;
}
