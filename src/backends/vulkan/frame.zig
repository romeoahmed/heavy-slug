//! Frame type re-exports for the Vulkan backend.

const renderer = @import("renderer.zig");

pub const Frame = renderer.Frame;
pub const Target = renderer.Target;
pub const FrameToken = renderer.FrameToken;
