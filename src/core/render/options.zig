//! Renderer configuration shared by backend-neutral core state.

const std = @import("std");
const blob_format = @import("../blob/format.zig");
const core_types = @import("../types.zig");
const mesh_limits = @import("../../gpu/mesh_limits.zig");

pub const Error = error{
    CacheCapacityTooLarge,
    FrameCapacityTooLarge,
    InvalidRendererOptions,
};

pub const RendererOptions = struct {
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    min_storage_alignment: u32 = 256,
    precision_policy: core_types.PrecisionPolicy = .{},

    pub fn validate(self: RendererOptions) Error!void {
        if (self.max_glyphs_per_frame == 0) return error.InvalidRendererOptions;
        _ = try mesh_limits.checkedMaxMeshletsForGlyphCapacity(self.max_glyphs_per_frame);
        if (self.promote_frames == 0) return error.InvalidRendererOptions;
        if (self.hot_slab_count == 0 and self.cold_lru_count == 0) return error.InvalidRendererOptions;
        _ = try self.cacheCapacity();

        if (self.pool_buffer_size == 0) return error.InvalidRendererOptions;
        if (!isPowerOfTwo(self.min_storage_alignment)) return error.InvalidRendererOptions;
        if (self.min_storage_alignment > self.pool_buffer_size) return error.InvalidRendererOptions;
        if (self.pool_buffer_size & (self.min_storage_alignment - 1) != 0) return error.InvalidRendererOptions;

        try validatePrecisionPolicy(self.precision_policy);
    }

    pub fn cacheCapacity(self: RendererOptions) Error!u32 {
        return std.math.add(u32, self.hot_slab_count, self.cold_lru_count) catch
            error.CacheCapacityTooLarge;
    }
};

fn validatePrecisionPolicy(policy: core_types.PrecisionPolicy) Error!void {
    if (!std.math.isFinite(policy.target_error_px) or policy.target_error_px <= 0) {
        return error.InvalidRendererOptions;
    }
    if (!std.math.isFinite(policy.max_condition_number) or policy.max_condition_number <= 0) {
        return error.InvalidRendererOptions;
    }
    if (policy.min_fraction_bits > policy.max_fraction_bits) return error.InvalidRendererOptions;
    if (policy.min_fraction_bits < blob_format.min_fraction_bits) return error.InvalidRendererOptions;
    if (policy.max_fraction_bits > blob_format.max_fraction_bits) return error.InvalidRendererOptions;
}

fn isPowerOfTwo(value: u32) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

test "RendererOptions validates current defaults" {
    const opts = RendererOptions{};
    try opts.validate();
    try std.testing.expectEqual(@as(u32, 12_288), try opts.cacheCapacity());
}

test "RendererOptions rejects invalid capacity and alignment contracts" {
    try std.testing.expectError(
        error.InvalidRendererOptions,
        (RendererOptions{ .hot_slab_count = 0, .cold_lru_count = 0 }).validate(),
    );
    try std.testing.expectError(
        error.CacheCapacityTooLarge,
        (RendererOptions{
            .hot_slab_count = std.math.maxInt(u32),
            .cold_lru_count = 1,
        }).validate(),
    );
    try std.testing.expectError(
        error.FrameCapacityTooLarge,
        (RendererOptions{ .max_glyphs_per_frame = std.math.maxInt(u32) }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRendererOptions,
        (RendererOptions{ .min_storage_alignment = 192 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRendererOptions,
        (RendererOptions{ .pool_buffer_size = 128, .min_storage_alignment = 256 }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRendererOptions,
        (RendererOptions{ .pool_buffer_size = 384, .min_storage_alignment = 256 }).validate(),
    );
}

test "RendererOptions rejects precision policies unsupported by the blob format" {
    try std.testing.expectError(
        error.InvalidRendererOptions,
        (RendererOptions{
            .precision_policy = .{ .min_fraction_bits = blob_format.min_fraction_bits - 1 },
        }).validate(),
    );
    try std.testing.expectError(
        error.InvalidRendererOptions,
        (RendererOptions{
            .precision_policy = .{ .max_fraction_bits = blob_format.max_fraction_bits + 1 },
        }).validate(),
    );
}
