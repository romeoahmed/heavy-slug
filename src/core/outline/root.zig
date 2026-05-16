pub const stream = @import("stream.zig");
pub const regularize = @import("regularize.zig");
pub const area = @import("area.zig");
pub const encode = @import("encode.zig");

pub const Point = stream.Point;
pub const Segment = stream.Segment;
pub const OutlineStream = stream.OutlineStream;
pub const RegularizedCubicSpan = regularize.RegularizedCubicSpan;
pub const CubicSpan = regularize.CubicSpan;
pub const Cubic = encode.Cubic;

test {
    _ = stream;
    _ = regularize;
    _ = area;
    _ = encode;
}
