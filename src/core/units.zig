//! Unit conversions between pixels and HarfBuzz 26.6 coordinates.

const std = @import("std");

pub const hb_subpixels_per_pixel: f32 = 64.0;
pub const hb_subpixels_per_pixel_f64: f64 = 64.0;

pub fn hb26p6ToPixels(value: i32) f32 {
    return @as(f32, @floatFromInt(value)) / hb_subpixels_per_pixel;
}

pub fn hb26p6ToPixelsI64(value: i64) f64 {
    return @as(f64, @floatFromInt(value)) / hb_subpixels_per_pixel_f64;
}

pub fn hb26p6ToPixels64(value: i32) f64 {
    return @as(f64, @floatFromInt(value)) / hb_subpixels_per_pixel_f64;
}

pub fn pixelsToHb26p6(value: f32) i32 {
    return @intFromFloat(@round(value * hb_subpixels_per_pixel));
}

pub fn pixelsToHb26p6F64(value: f64) i32 {
    return @intFromFloat(@round(value * hb_subpixels_per_pixel_f64));
}

test "26.6 conversions round trip common pixel values" {
    const values = [_]f32{ 0, 0.25, 1, 12.5, -4.75 };
    for (values) |value| {
        const fixed = pixelsToHb26p6(value);
        try std.testing.expectApproxEqAbs(value, hb26p6ToPixels(fixed), 1.0 / hb_subpixels_per_pixel);
    }
}

test "26.6 f64 conversions preserve subpixel values" {
    try std.testing.expectEqual(@as(i32, 80), pixelsToHb26p6F64(1.25));
    try std.testing.expectApproxEqAbs(@as(f64, 1.25), hb26p6ToPixels64(80), 1.0 / hb_subpixels_per_pixel_f64);
    try std.testing.expectApproxEqAbs(@as(f64, 1_000_000.25), hb26p6ToPixelsI64(64_000_016), 1.0 / hb_subpixels_per_pixel_f64);
}
