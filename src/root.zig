//! heavy_slug — GPU text rendering library.
const std = @import("std");

pub const ft = @import("font/ft.zig");
pub const hb = @import("font/hb.zig");
pub const glyph = @import("font/glyph.zig");
pub const pga = @import("math/pga.zig");
pub const gpu_context = @import("gpu/context.zig");
pub const descriptors = @import("gpu/descriptors.zig");
pub const pool = @import("gpu/pool.zig");

test {
    _ = ft;
    _ = hb;
    _ = glyph;
    _ = pga;
    _ = gpu_context;
    _ = descriptors;
    _ = pool;
}
