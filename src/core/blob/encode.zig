const outline_encode = @import("../outline/encode.zig");
const hb = @import("../font/harfbuzz.zig");

pub const Cubic = outline_encode.Cubic;
pub const Error = outline_encode.Error;

pub fn curves(allocator: @import("std").mem.Allocator, source_curves: []const Cubic) Error!hb.Blob {
    return outline_encode.encodeCurves(allocator, source_curves);
}
