//! heavy_slug — GPU text rendering library.

const std = @import("std");
const ft = @import("font/ft.zig");
const hb = @import("font/hb.zig");
const glyph = @import("font/glyph.zig");
pub const pga = @import("math/pga.zig");
pub const gpu_context = @import("gpu/context.zig");
const descriptors = @import("gpu/descriptors.zig");
const pool = @import("gpu/pool.zig");
const cache = @import("gpu/cache.zig");
const pipeline = @import("gpu/pipeline.zig");
pub const renderer = @import("gpu/renderer.zig");

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

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
}
