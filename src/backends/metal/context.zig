//! Context type re-export for the Metal backend.

const renderer = @import("renderer.zig");

pub const Context = renderer.Context;
pub const HostObjects = renderer.HostObjects;
