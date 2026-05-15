const renderer = @import("renderer.zig");

pub const Frame = renderer.Frame;
pub const Target = renderer.Target;
pub const FrameToken = renderer.FrameToken;

test "Metal frame API re-exports renderer frame types" {
    _ = Frame;
    _ = Target;
    _ = FrameToken;
}
