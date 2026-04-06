const std = @import("std");

/// Per-glyph draw command uploaded to GPU each frame (spec §10.1).
/// 64 bytes, tightly packed for storage buffer access.
pub const GlyphCommand = extern struct {
    motor: [4]f32,           // offset  0: PGA Motor [s, e12, e01, e02]
    color: [4]f32,           // offset 16: RGBA
    em_x_min: f32,           // offset 32
    em_y_min: f32,           // offset 36
    em_x_max: f32,           // offset 40
    em_y_max: f32,           // offset 44
    descriptor_index: u32,   // offset 48: index into glyph_blobs[] descriptor array
    flags: u32,              // offset 52: bit 0 = even-odd fill (0 = nonzero winding)
    _pad: [2]u32 = .{ 0, 0 }, // offset 56: align to 64 bytes
};

comptime {
    std.debug.assert(@sizeOf(GlyphCommand) == 64);
    std.debug.assert(@offsetOf(GlyphCommand, "motor") == 0);
    std.debug.assert(@offsetOf(GlyphCommand, "color") == 16);
    std.debug.assert(@offsetOf(GlyphCommand, "em_x_min") == 32);
    std.debug.assert(@offsetOf(GlyphCommand, "em_y_min") == 36);
    std.debug.assert(@offsetOf(GlyphCommand, "em_x_max") == 40);
    std.debug.assert(@offsetOf(GlyphCommand, "em_y_max") == 44);
    std.debug.assert(@offsetOf(GlyphCommand, "descriptor_index") == 48);
    std.debug.assert(@offsetOf(GlyphCommand, "flags") == 52);
    std.debug.assert(@offsetOf(GlyphCommand, "_pad") == 56);
}

test "GlyphCommand is 64 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(GlyphCommand));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(GlyphCommand, "descriptor_index"));
}

/// Per-frame push constants (spec §6.3). 80 bytes, within Vulkan's
/// guaranteed 128-byte minimum push constant range.
pub const PushConstants = extern struct {
    proj: [4][4]f32,        // offset  0: column-major projection matrix
    viewport_dim: [2]f32,   // offset 64: viewport width, height in pixels
    glyph_count: u32,       // offset 72: number of glyphs this frame
    _pad: u32 = 0,          // offset 76: align to 80 bytes
};

comptime {
    std.debug.assert(@sizeOf(PushConstants) == 80);
    std.debug.assert(@offsetOf(PushConstants, "proj") == 0);
    std.debug.assert(@offsetOf(PushConstants, "viewport_dim") == 64);
    std.debug.assert(@offsetOf(PushConstants, "glyph_count") == 72);
    std.debug.assert(@offsetOf(PushConstants, "_pad") == 76);
}

test "PushConstants is 80 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(PushConstants));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(PushConstants, "glyph_count"));
}

/// Stack-based free-list for descriptor slot indices.
/// Manages indices 0..capacity-1. O(1) alloc/free.
pub const SlotAllocator = struct {
    /// Stack of free slot indices. stack[0..count] are available.
    stack: []u32,
    count: u32,
    capacity: u32,

    /// Initialize with all slots free (indices 0..capacity-1 on the stack).
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !SlotAllocator {
        const stack = try allocator.alloc(u32, capacity);
        // Fill stack with indices 0..capacity-1 (index 0 at top for first alloc)
        for (stack, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }
        return .{
            .stack = stack,
            .count = capacity,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *SlotAllocator, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
        self.* = undefined;
    }

    /// Allocate a free slot index. Returns null if all slots are in use.
    pub fn alloc(self: *SlotAllocator) ?u32 {
        if (self.count == 0) return null;
        self.count -= 1;
        return self.stack[self.count];
    }

    /// Return a slot index to the free list.
    pub fn free(self: *SlotAllocator, slot: u32) void {
        std.debug.assert(slot < self.capacity);
        std.debug.assert(self.count < self.capacity);
        self.stack[self.count] = slot;
        self.count += 1;
    }
};

test "SlotAllocator: init populates all slots" {
    var sa = try SlotAllocator.init(std.testing.allocator, 4);
    defer sa.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), sa.count);
    try std.testing.expectEqual(@as(u32, 4), sa.capacity);
}

test "SlotAllocator: alloc returns indices, free returns them" {
    var sa = try SlotAllocator.init(std.testing.allocator, 4);
    defer sa.deinit(std.testing.allocator);

    // Allocate all 4 slots
    const a = sa.alloc().?;
    const b = sa.alloc().?;
    const c = sa.alloc().?;
    const d = sa.alloc().?;
    try std.testing.expectEqual(@as(u32, 0), sa.count);

    // All indices should be distinct and < capacity
    var seen = [_]bool{false} ** 4;
    for ([_]u32{ a, b, c, d }) |idx| {
        try std.testing.expect(idx < 4);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }

    // Alloc when empty returns null
    try std.testing.expectEqual(@as(?u32, null), sa.alloc());

    // Free one, re-alloc succeeds
    sa.free(b);
    try std.testing.expectEqual(@as(u32, 1), sa.count);
    const e = sa.alloc().?;
    try std.testing.expectEqual(b, e);
}

test "SlotAllocator: free and re-alloc cycle" {
    var sa = try SlotAllocator.init(std.testing.allocator, 2);
    defer sa.deinit(std.testing.allocator);

    const x = sa.alloc().?;
    sa.free(x);
    const y = sa.alloc().?;
    try std.testing.expectEqual(x, y);
}
