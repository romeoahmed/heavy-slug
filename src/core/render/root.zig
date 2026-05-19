//! Backend-neutral render orchestration.

pub const backend_contract = @import("backend_contract.zig");
pub const glyph_store = @import("glyph_store.zig");
pub const frame_batch = @import("frame_batch.zig");
pub const mesh_plan = @import("mesh_plan.zig");
pub const options = @import("options.zig");

pub const renderer_core = @import("renderer_core.zig");

pub const checkBackend = backend_contract.checkBackend;
pub const FrameBatch = frame_batch.FrameBatch;
pub const GlyphStore = glyph_store.GlyphStore;
pub const RendererOptions = options.RendererOptions;
pub const RendererOptionsError = options.Error;
pub const RendererCore = renderer_core.RendererCore;
pub const TextRun = renderer_core.TextRun;
pub const FontHandle = renderer_core.FontHandle;
pub const GlyphBlobRef = renderer_core.GlyphBlobRef;
pub const FrameToken = renderer_core.FrameToken;

test {
    _ = backend_contract;
    _ = glyph_store;
    _ = frame_batch;
    _ = mesh_plan;
    _ = renderer_core;
}
