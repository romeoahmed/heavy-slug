const std = @import("std");

const log = std.log.scoped(.pool);

/// Byte range inside the pool.
pub const Allocation = struct {
    offset: u32,
    size: u32,
};

pub const Snapshot = struct {
    used_bytes: u32 = 0,
    free_bytes: u32 = 0,
    largest_free_block: u32 = 0,
    free_blocks: u32 = 0,
};

/// Free-list node with alignment-rounded offset and size.
const FreeBlock = struct {
    offset: u32,
    size: u32, // always aligned
};

/// Variable-size sub-allocator for a contiguous GPU-visible byte pool.
/// Uses bump allocation with an offset-sorted free-list for reuse of freed blocks.
/// Free list uses best-fit allocation and adjacent-block coalescing on free().
/// All offsets are aligned to `alignment` (must be power of 2).
pub const PoolAllocator = struct {
    allocator: std.mem.Allocator,
    capacity: u32,
    alignment: u32,
    cursor: u32,
    /// Free list kept sorted by ascending offset.
    free_blocks: std.ArrayList(FreeBlock),

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

    pub fn snapshot(self: *const PoolAllocator) Snapshot {
        var free_bytes: u32 = self.capacity - self.cursor;
        var largest_free_block: u32 = self.capacity - self.cursor;
        for (self.free_blocks.items) |block| {
            free_bytes += block.size;
            largest_free_block = @max(largest_free_block, block.size);
        }
        return .{
            .used_bytes = self.capacity - free_bytes,
            .free_bytes = free_bytes,
            .largest_free_block = largest_free_block,
            .free_blocks = @intCast(self.free_blocks.items.len),
        };
    }

    /// Allocate `size` bytes, using best-fit free blocks before bump allocation.
    pub fn alloc(self: *PoolAllocator, size: u32) ?Allocation {
        if (size == 0) return null;
        const aligned_size = alignAllocationSize(size, self.alignment) orelse return null;
        if (aligned_size > self.capacity) return null;

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
                self.free_blocks.items[i] = .{
                    .offset = block.offset + aligned_size,
                    .size = remaining,
                };
            } else {
                _ = self.free_blocks.orderedRemove(i);
            }
            return result;
        }

        if (aligned_size > self.capacity - self.cursor) return null;
        const result = Allocation{ .offset = self.cursor, .size = size };
        self.cursor += aligned_size;
        return result;
    }

    /// Return an allocation and coalesce adjacent free blocks.
    pub fn free(self: *PoolAllocator, allocation: Allocation) void {
        if (allocation.size == 0) return;

        const aligned_size = alignAllocationSize(allocation.size, self.alignment) orelse {
            log.warn("invalid free size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        };
        const allocation_end = std.math.add(u32, allocation.offset, aligned_size) catch {
            log.warn("invalid free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        };
        if (allocation.offset & (self.alignment - 1) != 0 or allocation_end > self.cursor) {
            log.warn("invalid free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        }

        if (allocation_end == self.cursor) {
            self.cursor = allocation.offset;
            self.reclaimTrailingFreeBlocks();
            return;
        }

        const insert_idx = self.findInsertPoint(allocation.offset);

        if (insert_idx > 0) {
            const prev = &self.free_blocks.items[insert_idx - 1];
            const prev_end = std.math.add(u32, prev.offset, prev.size) catch {
                log.warn("corrupt free block size {d} at offset {d}", .{ prev.size, prev.offset });
                return;
            };
            if (prev_end > allocation.offset) {
                log.warn("overlapping free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
                return;
            }
            if (prev_end == allocation.offset) {
                var merged_size = std.math.add(u32, prev.size, aligned_size) catch {
                    log.warn("free block size overflow at offset {d}", .{prev.offset});
                    return;
                };
                if (insert_idx < self.free_blocks.items.len) {
                    const merged_end = std.math.add(u32, prev.offset, merged_size) catch {
                        log.warn("free block end overflow at offset {d}", .{prev.offset});
                        return;
                    };
                    const next = self.free_blocks.items[insert_idx];
                    if (merged_end > next.offset) {
                        log.warn("overlapping free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
                        return;
                    }
                    if (merged_end == next.offset) {
                        merged_size = std.math.add(u32, merged_size, next.size) catch {
                            log.warn("free block size overflow at offset {d}", .{prev.offset});
                            return;
                        };
                        prev.size = merged_size;
                        _ = self.free_blocks.orderedRemove(insert_idx);
                    } else {
                        prev.size = merged_size;
                    }
                } else {
                    prev.size = merged_size;
                }
                self.reclaimTrailingFreeBlocks();
                return;
            }
        }

        if (insert_idx < self.free_blocks.items.len) {
            const next = &self.free_blocks.items[insert_idx];
            if (allocation_end > next.offset) {
                log.warn("overlapping free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
                return;
            }
            if (allocation_end == next.offset) {
                const merged_size = std.math.add(u32, next.size, aligned_size) catch {
                    log.warn("free block size overflow at offset {d}", .{allocation.offset});
                    return;
                };
                next.offset = allocation.offset;
                next.size = merged_size;
                self.reclaimTrailingFreeBlocks();
                return;
            }
        }

        self.free_blocks.insert(self.allocator, insert_idx, .{
            .offset = allocation.offset,
            .size = aligned_size,
        }) catch {
            log.warn("free-list insert OOM: leaked {d} bytes at offset {d}", .{ aligned_size, allocation.offset });
            return;
        };
        self.reclaimTrailingFreeBlocks();
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

    fn reclaimTrailingFreeBlocks(self: *PoolAllocator) void {
        while (self.free_blocks.items.len > 0) {
            const last = self.free_blocks.items[self.free_blocks.items.len - 1];
            const last_end = std.math.add(u32, last.offset, last.size) catch break;
            if (last_end != self.cursor) break;
            self.cursor = last.offset;
            _ = self.free_blocks.pop();
        }
    }

    fn alignAllocationSize(value: u32, alignment: u32) ?u32 {
        const mask = alignment - 1;
        const rounded = std.math.add(u32, value, mask) catch return null;
        return rounded & ~mask;
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

test "PoolAllocator: oversized allocation returns null without wrapping" {
    var pa = PoolAllocator.init(std.testing.allocator, 1024, 256);
    defer pa.deinit();

    try std.testing.expectEqual(@as(?Allocation, null), pa.alloc(std.math.maxInt(u32)));
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

test "PoolAllocator: snapshot reports used bytes and largest free block" {
    var pa = PoolAllocator.init(std.testing.allocator, 128, 16);
    defer pa.deinit();

    const a = pa.alloc(10).?;
    _ = pa.alloc(20).?;
    pa.free(a);

    const snap = pa.snapshot();
    try std.testing.expectEqual(@as(u32, 32), snap.used_bytes);
    try std.testing.expectEqual(@as(u32, 96), snap.free_bytes);
    try std.testing.expectEqual(@as(u32, 80), snap.largest_free_block);
    try std.testing.expectEqual(@as(u32, 1), snap.free_blocks);
}

test "PoolAllocator: free block splitting" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(48).?; // 48 bytes aligned = 48 bytes
    _ = pa.alloc(16); // tail guard so freeing a exercises the free-list path
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
    const freed = pa.alloc(32).?;
    pa.free(freed);
    pa.reset();

    const snap = pa.snapshot();
    try std.testing.expectEqual(@as(u32, 0), pa.cursor);
    try std.testing.expectEqual(@as(u32, 0), snap.used_bytes);
    try std.testing.expectEqual(@as(u32, 256), snap.free_bytes);
    try std.testing.expectEqual(@as(u32, 256), snap.largest_free_block);
    try std.testing.expectEqual(@as(u32, 0), snap.free_blocks);

    const a = pa.alloc(10).?;
    try std.testing.expectEqual(@as(u32, 0), a.offset);
}

test "PoolAllocator: best-fit selects smallest suitable block" {
    var pa = PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(64).?; // offset 0, aligned 64
    const b = pa.alloc(128).?; // offset 64, aligned 128
    _ = pa.alloc(16); // offset 192, guard — prevents b and c from coalescing
    const c = pa.alloc(32).?; // offset 208, aligned 32
    _ = pa.alloc(16); // tail guard: keeps c available for best-fit reuse
    pa.free(b); // free the 128-byte block: [{offset=64, size=128}]
    pa.free(c); // free the 32-byte block:  [{offset=64, size=128}, {offset=208, size=32}]

    const d = pa.alloc(30).?;
    try std.testing.expectEqual(c.offset, d.offset);

    _ = a;
}

test "PoolAllocator: freeing tail allocation rewinds cursor" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(16).?;
    const b = pa.alloc(24).?;
    pa.free(b);

    try std.testing.expectEqual(@as(u32, 16), pa.cursor);
    try std.testing.expectEqual(@as(usize, 0), pa.free_blocks.items.len);

    pa.free(a);
    try std.testing.expectEqual(@as(u32, 0), pa.cursor);
    try std.testing.expectEqual(@as(usize, 0), pa.free_blocks.items.len);
}

test "PoolAllocator: tail rewind absorbs adjacent free blocks" {
    var pa = PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(16).?;
    const b = pa.alloc(16).?;
    const c = pa.alloc(16).?;

    pa.free(a);
    pa.free(b);
    try std.testing.expectEqual(@as(u32, 48), pa.cursor);
    try std.testing.expectEqual(@as(usize, 1), pa.free_blocks.items.len);

    pa.free(c);
    try std.testing.expectEqual(@as(u32, 0), pa.cursor);
    try std.testing.expectEqual(@as(usize, 0), pa.free_blocks.items.len);
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
    pa.free(b);

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

    pa.free(c); // offset 32
    pa.free(a); // offset 0
    pa.free(b); // offset 16 — adjacent to both a and c, should coalesce all three

    const big = pa.alloc(48).?;
    try std.testing.expectEqual(@as(u32, 0), big.offset);
}
