//! Unit conversions between pixels, HarfBuzz 26.6 coordinates, and blob units.

const std = @import("std");
const pga = @import("../math/pga.zig");

pub const hb_subpixels_per_pixel: f32 = 64.0;
pub const blob_units_per_pixel: f32 = 4.0;

pub fn hb26p6ToPixels(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / hb_subpixels_per_pixel;
}

pub fn pixelsToHb26p6(value: f32) i32 {
    return @intFromFloat(@round(value * hb_subpixels_per_pixel));
}

pub fn pixelsToBlobUnits(value: f32) i16 {
    return @intFromFloat(@round(value * blob_units_per_pixel));
}

pub fn blobUnitsToPixels(value: i16) f32 {
    return @as(f32, @floatFromInt(value)) / blob_units_per_pixel;
}

pub fn motorPixelsToHb26p6(motor: pga.Motor) pga.Motor {
    return .{ .m = .{
        motor.m[0],
        motor.m[1],
        motor.m[2] * hb_subpixels_per_pixel,
        motor.m[3] * hb_subpixels_per_pixel,
    } };
}

pub fn projectionPixelsToHb26p6(proj: [4][4]f32) [4][4]f32 {
    var result = proj;
    for (0..4) |j| {
        result[0][j] /= hb_subpixels_per_pixel;
        result[1][j] /= hb_subpixels_per_pixel;
    }
    return result;
}

test "26.6 conversions round trip common pixel values" {
    const values = [_]f32{ 0, 0.25, 1, 12.5, -4.75 };
    for (values) |value| {
        const fixed = pixelsToHb26p6(value);
        try std.testing.expectApproxEqAbs(value, hb26p6ToPixels(fixed), 1.0 / hb_subpixels_per_pixel);
    }
}

test "blob unit conversions use quarter-pixel grid" {
    try std.testing.expectEqual(@as(i16, 5), pixelsToBlobUnits(1.25));
    try std.testing.expectEqual(@as(f32, 1.25), blobUnitsToPixels(5));
}

test "projectionPixelsToHb26p6 scales only x and y columns" {
    const proj = [4][4]f32{
        .{ 64, 128, 192, 256 },
        .{ -64, -128, -192, -256 },
        .{ 1, 2, 3, 4 },
        .{ 5, 6, 7, 8 },
    };
    const em = projectionPixelsToHb26p6(proj);
    try std.testing.expectEqual(@as(f32, 1), em[0][0]);
    try std.testing.expectEqual(@as(f32, -1), em[1][0]);
    try std.testing.expectEqual(@as(f32, 3), em[2][2]);
    try std.testing.expectEqual(@as(f32, 8), em[3][3]);
}
