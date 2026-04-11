const std = @import("std");

const log = std.log.scoped(.pool);

/// A sub-allocation within the pool: byte offset and size.
pub const Allocation = struct {
    offset: u32,
    size: u32,
};

/// Internal free-list node: offset and size are always alignment-rounded.
const FreeBlock = struct {
    offset: u32,
    size: u32, // always aligned
};

/// Variable-size sub-allocator for a contiguous byte pool (e.g. a large VkBuffer).
/// Uses bump allocation with an offset-sorted free-list for reuse of freed blocks.
/// Free list uses best-fit allocation and adjacent-block coalescing on free().
/// All offsets are aligned to `alignment` (must be power of 2).
pub const PoolAllocator = struct {
    allocator: std.mem.Allocator,
    capacity: u32,
    alignment: u32,
    cursor: u32,
    /// Offset-sorted free list. Sorted ascending by offset at all times.
    free_blocks: std.ArrayListUnmanaged(FreeBlock),

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
    /// Searches the free list first (best-fit), then falls back to bump allocation.
    pub fn alloc(self: *PoolAllocator, size: u32) ?Allocation {
        if (size == 0) return null;
        const aligned_size = alignUp(size, self.alignment);

        // Best-fit search of sorted free list
        var best_idx: ?usize = null;
        var best_waste: u32 = std.math.maxInt(u32);
        for (self.free_blocks.items, 0..) |block, i| {
            if (block.size >= aligned_size) {
                const waste = block.size - aligned_size;
                if (waste < best_waste) {
                    best_waste = waste;
                    best_idx = i;
                    if (waste == 0) break; // perfect fit
                }
            }
        }

        if (best_idx) |i| {
            const block = self.free_blocks.items[i];
            const result = Allocation{ .offset = block.offset, .size = size };
            const remaining = block.size - aligned_size;
            if (remaining > 0) {
                // Shrink block in-place (offset increases, stays sorted)
                self.free_blocks.items[i] = .{
                    .offset = block.offset + aligned_size,
                    .size = remaining,
                };
            } else {
                // Remove block, preserving sort order
                _ = self.free_blocks.orderedRemove(i);
            }
            return result;
        }

        // Bump allocate
        if (self.cursor + aligned_size > self.capacity) return null;
        const result = Allocation{ .offset = self.cursor, .size = size };
        self.cursor += aligned_size;
        return result;
    }

    /// Return an allocation to the free list for future reuse.
    /// Coalesces with adjacent free blocks to prevent fragmentation.
    pub fn free(self: *PoolAllocator, allocation: Allocation) void {
        const aligned_size = alignUp(allocation.size, self.alignment);
        var new_offset = allocation.offset;
        var new_size = aligned_size;

        // Binary search for insertion point (sorted by offset ascending)
        const insert_idx = self.findInsertPoint(new_offset);

        // Try coalesce with predecessor
        if (insert_idx > 0) {
            const prev = &self.free_blocks.items[insert_idx - 1];
            if (prev.offset + prev.size == new_offset) {
                // Merge into predecessor
                new_offset = prev.offset;
                new_size += prev.size;
                _ = self.free_blocks.orderedRemove(insert_idx - 1);
                // insert_idx shifted down by 1; try coalesce with what is now at (insert_idx - 1)
                const succ_idx = insert_idx - 1;
                if (succ_idx < self.free_blocks.items.len) {
                    const next = &self.free_blocks.items[succ_idx];
                    if (new_offset + new_size == next.offset) {
                        new_size += next.size;
                        _ = self.free_blocks.orderedRemove(succ_idx);
                    }
                }
                self.free_blocks.insert(self.allocator, succ_idx, .{
                    .offset = new_offset,
                    .size = new_size,
                }) catch {
                    log.warn("free-list insert OOM: leaked {d} bytes at offset {d}", .{ new_size, new_offset });
                };
                return;
            }
        }

        // Try coalesce with successor only
        if (insert_idx < self.free_blocks.items.len) {
            const next = &self.free_blocks.items[insert_idx];
            if (new_offset + new_size == next.offset) {
                next.offset = new_offset;
                next.size += new_size;
                return;
            }
        }

        // No coalescing: insert at sorted position
        self.free_blocks.insert(self.allocator, insert_idx, .{
            .offset = new_offset,
            .size = new_size,
        }) catch {
            log.warn("free-list insert OOM: leaked {d} bytes at offset {d}", .{ new_size, new_offset });
        };
    }

    /// Reset the pool to empty. All prior allocations become invalid.
    pub fn reset(self: *PoolAllocator) void {
        self.cursor = 0;
        self.free_blocks.clearRetainingCapacity();
    }

    /// Binary search for the insertion point in the offset-sorted free list.
    fn findInsertPoint(self: *const PoolAllocator, offset: u32) usize {
        var lo: usize = 0;
        var hi: usize = self.free_blocks.items.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (self.free_blocks.items[mid].offset < offset) {
                lo = mid + 1;
            } else {
                hi = mid;
            }
        }
        return lo;
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

test "PoolAllocator: best-fit selects smallest suitable block" {
    var pa = PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    // Allocate blocks with a guard between b and c to prevent coalescing
    const a = pa.alloc(64).?; // offset 0, aligned 64
    const b = pa.alloc(128).?; // offset 64, aligned 128
    _ = pa.alloc(16); // offset 192, guard — prevents b and c from coalescing
    const c = pa.alloc(32).?; // offset 208, aligned 32
    pa.free(b); // free the 128-byte block: [{offset=64, size=128}]
    pa.free(c); // free the 32-byte block:  [{offset=64, size=128}, {offset=208, size=32}]

    // Request 30 bytes: should pick the 32-byte block (best fit), not the 128-byte block
    const d = pa.alloc(30).?;
    try std.testing.expectEqual(c.offset, d.offset);

    _ = a;
}

test "PoolAllocator: free coalesces adjacent blocks" {
    var pa = PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(48).?; // offset 0, aligned 48
    const b = pa.alloc(48).?; // offset 48, aligned 48
    const c = pa.alloc(48).?; // offset 96, aligned 48
    _ = pa.alloc(48); // offset 144, guard block to prevent bump reclaim

    pa.free(a);
    pa.free(c);
    // Free list: [a @ 0, size 48] and [c @ 96, size 48] — not adjacent

    pa.free(b);
    // b @ 48, size 48 is adjacent to a (0+48=48) and c (48+48=96)
    // After coalescing: single block [0, size 144]

    // Verify: can allocate 144 bytes from the coalesced block
    const big = pa.alloc(144).?;
    try std.testing.expectEqual(@as(u32, 0), big.offset);
}

test "PoolAllocator: free list maintains sorted order" {
    var pa = PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(16).?; // offset 0
    const b = pa.alloc(16).?; // offset 16
    const c = pa.alloc(16).?; // offset 32
    _ = pa.alloc(16); // offset 48, guard

    // Free in reverse order
    pa.free(c); // offset 32
    pa.free(a); // offset 0
    pa.free(b); // offset 16 — adjacent to both a and c, should coalesce all three

    // Single coalesced block of 48 bytes at offset 0
    const big = pa.alloc(48).?;
    try std.testing.expectEqual(@as(u32, 0), big.offset);
}
