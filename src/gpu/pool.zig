const std = @import("std");

/// A sub-allocation within the pool: byte offset and size.
pub const Allocation = struct {
    offset: u32,
    size: u32,
};

/// Variable-size sub-allocator for a contiguous byte pool (e.g. a large VkBuffer).
/// Uses bump allocation with a free-list for reuse of freed blocks.
/// All offsets are aligned to `alignment` (must be power of 2).
pub const PoolAllocator = struct {
    allocator: std.mem.Allocator,
    capacity: u32,
    alignment: u32,
    cursor: u32,
    /// Reserved for free-list reuse (`free()`/`reset()`). Not populated by bump-only alloc.
    free_blocks: std.ArrayList(Allocation),

    pub fn init(allocator: std.mem.Allocator, capacity: u32, alignment: u32) PoolAllocator {
        std.debug.assert(capacity > 0);
        std.debug.assert(alignment > 0 and (alignment & (alignment - 1)) == 0);
        return .{
            .allocator = allocator,
            .capacity = capacity,
            .alignment = alignment,
            .cursor = 0,
            .free_blocks = .empty,
        };
    }

    pub fn deinit(self: *PoolAllocator) void {
        self.free_blocks.deinit(self.allocator);
        self.* = undefined;
    }

    /// Allocate `size` bytes from the pool. Returns null if the pool is full.
    /// Searches the free list first (first-fit), then falls back to bump allocation.
    pub fn alloc(self: *PoolAllocator, size: u32) ?Allocation {
        if (size == 0) return null;
        const aligned_size = alignUp(size, self.alignment);

        // First-fit search of free list
        for (self.free_blocks.items, 0..) |block, i| {
            if (block.size >= aligned_size) {
                const result = Allocation{ .offset = block.offset, .size = size };
                const remaining = block.size - aligned_size;
                if (remaining >= self.alignment) {
                    self.free_blocks.items[i] = .{
                        .offset = block.offset + aligned_size,
                        .size = remaining,
                    };
                } else {
                    _ = self.free_blocks.swapRemove(i);
                }
                return result;
            }
        }

        // Bump allocate
        if (self.cursor + aligned_size > self.capacity) return null;
        const result = Allocation{ .offset = self.cursor, .size = size };
        self.cursor += aligned_size;
        return result;
    }

    /// Return an allocation to the free list for future reuse.
    pub fn free(self: *PoolAllocator, allocation: Allocation) void {
        const aligned_size = alignUp(allocation.size, self.alignment);
        self.free_blocks.append(self.allocator, .{
            .offset = allocation.offset,
            .size = aligned_size,
        }) catch return; // silently drop if free-list append OOMs (pool space leaked, not corrupted)
    }

    /// Reset the pool to empty. All prior allocations become invalid.
    pub fn reset(self: *PoolAllocator) void {
        self.cursor = 0;
        self.free_blocks.clearRetainingCapacity();
    }

    fn alignUp(value: u32, alignment: u32) u32 {
        const mask = alignment - 1;
        return (value + mask) & ~mask;
    }
};

test "PoolAllocator: bump allocation returns aligned offsets" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(10).?;
    try std.testing.expectEqual(@as(u32, 0), a.offset);
    try std.testing.expectEqual(@as(u32, 10), a.size);

    const b = pa.alloc(20).?;
    try std.testing.expectEqual(@as(u32, 16), b.offset);
    try std.testing.expectEqual(@as(u32, 20), b.size);
}

test "PoolAllocator: returns null when full" {
    var pa = PoolAllocator.init(std.testing.allocator, 32, 16);
    defer pa.deinit();

    _ = pa.alloc(20).?; // consumes 32 aligned bytes
    try std.testing.expectEqual(@as(?Allocation, null), pa.alloc(1));
}

test "PoolAllocator: zero-size alloc returns null" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    try std.testing.expectEqual(@as(?Allocation, null), pa.alloc(0));
}

test "PoolAllocator: free and reuse" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(10).?;
    _ = pa.alloc(20);
    pa.free(a);

    const c = pa.alloc(8).?;
    try std.testing.expectEqual(@as(u32, 0), c.offset); // reused freed block
}

test "PoolAllocator: free block splitting" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(48).?; // 48 bytes aligned = 48 bytes
    pa.free(a); // free list: {offset=0, size=48}

    const b = pa.alloc(16).?;
    try std.testing.expectEqual(@as(u32, 0), b.offset); // takes first 16 from 48-byte block

    const c = pa.alloc(16).?;
    try std.testing.expectEqual(@as(u32, 16), c.offset); // takes next 16 from remaining 32
}

test "PoolAllocator: reset clears all state" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    _ = pa.alloc(100);
    pa.reset();
    try std.testing.expectEqual(@as(u32, 0), pa.cursor);

    const a = pa.alloc(10).?;
    try std.testing.expectEqual(@as(u32, 0), a.offset);
}
