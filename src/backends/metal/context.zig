//! Context type re-export for the Metal backend.

const renderer = @import("renderer.zig");

pub const Context = renderer.Context;
pub const HostObjects = renderer.HostObjects;

test "Metal context API re-exports renderer context types" {
    _ = Context;
    _ = HostObjects;
}
