//! Outline capture, regularization, and analysis helpers.

pub const stream = @import("stream.zig");
pub const geometry = @import("geometry.zig");
pub const regularize = @import("regularize.zig");
pub const area = @import("area.zig");
pub const encode = @import("encode.zig");

pub const Point = stream.Point;
pub const Segment = stream.Segment;
pub const OutlineStream = stream.OutlineStream;
pub const RegularizedCubicSpan = regularize.RegularizedCubicSpan;

test {
    _ = stream;
    _ = geometry;
    _ = regularize;
    _ = area;
    _ = encode;
}
