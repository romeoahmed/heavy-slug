//! Backend-neutral render orchestration.

pub const backend_contract = @import("backend_contract.zig");
pub const glyph_store = @import("glyph_store.zig");
pub const glyph_batch = @import("glyph_batch.zig");

pub const renderer_core = @import("renderer_core.zig");

pub const BackendContract = backend_contract.BackendContract;
pub const GlyphBatch = glyph_batch.GlyphBatch;
pub const GlyphStore = glyph_store.GlyphStore;
pub const RendererOptions = renderer_core.RendererOptions;
pub const RendererCore = renderer_core.RendererCore;
pub const TextRun = renderer_core.TextRun;
pub const FontHandle = renderer_core.FontHandle;
pub const GlyphBlobRef = renderer_core.GlyphBlobRef;
pub const FrameToken = renderer_core.FrameToken;

test {
    _ = backend_contract;
    _ = glyph_store;
    _ = glyph_batch;
    _ = renderer_core;
}
