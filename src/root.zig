//! heavy_slug — GPU text rendering library.
const std = @import("std");

pub const ft = @import("font/ft.zig");
pub const hb = @import("font/hb.zig");
pub const glyph = @import("font/glyph.zig");
pub const pga = @import("math/pga.zig");
pub const gpu_context = @import("gpu/context.zig");
pub const descriptors = @import("gpu/descriptors.zig");
pub const pool = @import("gpu/pool.zig");
pub const cache = @import("gpu/cache.zig");
pub const pipeline = @import("gpu/pipeline.zig");
pub const renderer = @import("gpu/renderer.zig");
pub const layout = @import("gpu/layout.zig");

test {
    _ = ft;
    _ = hb;
    _ = glyph;
    _ = pga;
    _ = gpu_context;
    _ = descriptors;
    _ = pool;
    _ = cache;
    _ = pipeline;
    _ = renderer;
    _ = layout;
}
