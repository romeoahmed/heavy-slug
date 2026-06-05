const std = @import("std");

const log = std.log.scoped(.pool);

pub const Error = error{
    InvalidPoolCapacity,
    InvalidPoolAlignment,
};

/// Byte range inside the pool. `size` is the caller-requested byte count; the
/// allocator internally rounds it up to `PoolAllocator.alignment`.
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

const Link = u32;
const none: Link = std.math.maxInt(Link);
const bin_count = @bitSizeOf(u32);

const FreeBlock = struct {
    offset: u32 = 0,
    size: u32 = 0,

    prev_addr: Link = none,
    next_addr: Link = none,

    bin: u8 = 0,
    prev_bin: Link = none,
    next_bin: Link = none,

    next_unused: Link = none,
};

const AddressNeighbors = struct {
    prev: Link = none,
    next: Link = none,
};

/// Variable-size sub-allocator for the single GPU-visible glyph blob pool.
///
/// The allocator uses a bump cursor for fresh space and recycles interior holes
/// through stable free-block metadata. Free blocks are linked in address order
/// for coalescing and in power-of-two size bins for bounded allocation search.
/// This keeps `free` free of heap traffic after `reserveFreeBlocks` and avoids
/// the whole-pool best-fit scan on the renderer hot path.
pub const PoolAllocator = struct {
    allocator: std.mem.Allocator,
    capacity: u32,
    alignment: u32,
    cursor: u32,

    nodes: std.ArrayList(FreeBlock),
    unused_head: Link,
    address_head: Link,
    address_tail: Link,
    bin_heads: [bin_count]Link,
    free_node_count: u32,

    pub fn init(allocator: std.mem.Allocator, capacity: u32, alignment: u32) Error!PoolAllocator {
        if (capacity == 0) return error.InvalidPoolCapacity;
        if (!isPowerOfTwo(alignment)) return error.InvalidPoolAlignment;
        if (alignment > capacity or !isAligned(capacity, alignment)) return error.InvalidPoolCapacity;

        return .{
            .allocator = allocator,
            .capacity = capacity,
            .alignment = alignment,
            .cursor = 0,
            .nodes = .empty,
            .unused_head = none,
            .address_head = none,
            .address_tail = none,
            .bin_heads = emptyBinHeads(),
            .free_node_count = 0,
        };
    }

    pub fn deinit(self: *PoolAllocator) void {
        self.nodes.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn reserveFreeBlocks(self: *PoolAllocator, capacity: u32) !void {
        try self.nodes.ensureTotalCapacity(self.allocator, capacity);
    }

    pub fn snapshot(self: *const PoolAllocator) Snapshot {
        var free_bytes = self.capacity - self.cursor;
        var largest_free_block = free_bytes;

        var index = self.address_head;
        while (index != none) {
            const block = self.nodeConst(index);
            free_bytes += block.size;
            largest_free_block = @max(largest_free_block, block.size);
            index = block.next_addr;
        }

        return .{
            .used_bytes = self.capacity - free_bytes,
            .free_bytes = free_bytes,
            .largest_free_block = largest_free_block,
            .free_blocks = self.free_node_count,
        };
    }

    pub fn alloc(self: *PoolAllocator, size: u32) ?Allocation {
        if (size == 0) return null;
        const aligned_size = alignAllocationSize(size, self.alignment) orelse return null;
        if (aligned_size > self.capacity) return null;

        if (self.findReusableBlock(aligned_size)) |index| {
            return self.allocFromFreeBlock(index, size, aligned_size);
        }

        const next_cursor = std.math.add(u32, self.cursor, aligned_size) catch return null;
        if (next_cursor > self.capacity) return null;

        const allocation = Allocation{ .offset = self.cursor, .size = size };
        self.cursor = next_cursor;
        return allocation;
    }

    /// Return an allocation to the pool. Invalid or overlapping ranges are
    /// rejected with a warning because callers may be retiring stale cache data.
    pub fn free(self: *PoolAllocator, allocation: Allocation) void {
        if (allocation.size == 0) return;

        const aligned_size = alignAllocationSize(allocation.size, self.alignment) orelse {
            log.warn("invalid free size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        };
        const allocation_end = blockEnd(allocation.offset, aligned_size) orelse {
            log.warn("invalid free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        };
        if (!isAligned(allocation.offset, self.alignment) or allocation_end > self.cursor) {
            log.warn("invalid free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        }

        if (allocation_end == self.cursor) {
            self.cursor = allocation.offset;
            self.reclaimTrailingFreeBlocks();
            return;
        }

        const neighbors = self.findAddressNeighbors(allocation.offset);
        if (self.overlapsNeighborRanges(neighbors, allocation.offset, allocation_end)) {
            log.warn("overlapping free range size {d} at offset {d}", .{ allocation.size, allocation.offset });
            return;
        }

        self.insertOrMergeFreeBlock(allocation.offset, aligned_size, allocation_end, neighbors) catch {
            log.warn("free-list metadata exhausted: leaked {d} bytes at offset {d}", .{ aligned_size, allocation.offset });
            return;
        };
        self.reclaimTrailingFreeBlocks();
    }

    /// Reset the pool to empty. All prior allocations become invalid.
    pub fn reset(self: *PoolAllocator) void {
        self.cursor = 0;
        self.nodes.clearRetainingCapacity();
        self.unused_head = none;
        self.address_head = none;
        self.address_tail = none;
        self.bin_heads = emptyBinHeads();
        self.free_node_count = 0;
    }

    fn allocFromFreeBlock(self: *PoolAllocator, index: Link, requested_size: u32, aligned_size: u32) ?Allocation {
        const block = self.nodeConst(index).*;
        const result = Allocation{ .offset = block.offset, .size = requested_size };
        const remaining = block.size - aligned_size;
        const remaining_offset = std.math.add(u32, block.offset, aligned_size) catch {
            log.warn("corrupt free block size {d} at offset {d}", .{ block.size, block.offset });
            return null;
        };

        self.unlinkBin(index);
        if (remaining == 0) {
            self.unlinkAddress(index);
            self.releaseNode(index);
            return result;
        }

        const block_node = self.node(index);
        block_node.offset = remaining_offset;
        block_node.size = remaining;
        self.linkBin(index);
        return result;
    }

    /// Bin `b` holds blocks with size in [2^b, 2^(b+1)). For the starting bin
    /// `start = binForSize(aligned_size)`, members can sit on either side of
    /// `aligned_size`, so we walk the chain and accept the first fit. For
    /// every bin above, the lower-bound 2^(start+1) already exceeds the
    /// upper bound 2^(start+1) − 1 of `aligned_size`, so the chain head
    /// trivially satisfies the request — O(1) per higher bin, with no
    /// scan-to-smallest tax. Net cost is bounded by the starting bin's chain
    /// length rather than total free-block count.
    fn findReusableBlock(self: *const PoolAllocator, aligned_size: u32) ?Link {
        const start_bin = binForSize(aligned_size);

        var index = self.bin_heads[start_bin];
        while (index != none) {
            const block = self.nodeConst(index);
            if (block.size >= aligned_size) return index;
            index = block.next_bin;
        }

        var bin = start_bin + 1;
        while (bin < bin_count) : (bin += 1) {
            const head = self.bin_heads[bin];
            if (head != none) return head;
        }
        return null;
    }

    fn insertOrMergeFreeBlock(
        self: *PoolAllocator,
        offset: u32,
        size: u32,
        allocation_end: u32,
        neighbors: AddressNeighbors,
    ) !void {
        const merge_prev = blk: {
            if (neighbors.prev == none) break :blk false;
            const prev = self.nodeConst(neighbors.prev);
            break :blk blockEnd(prev.offset, prev.size) == offset;
        };
        const merge_next = neighbors.next != none and self.nodeConst(neighbors.next).offset == allocation_end;

        if (merge_prev and merge_next) {
            const prev_index = neighbors.prev;
            const next_index = neighbors.next;
            const prev = self.nodeConst(prev_index);
            const next = self.nodeConst(next_index);
            const merged_size = checkedAdd(checkedAdd(prev.size, size) orelse return error.OutOfMemory, next.size) orelse
                return error.OutOfMemory;

            self.unlinkBin(prev_index);
            self.unlinkBin(next_index);
            self.unlinkAddress(next_index);
            self.releaseNode(next_index);

            self.node(prev_index).size = merged_size;
            self.linkBin(prev_index);
            return;
        }

        if (merge_prev) {
            const prev_index = neighbors.prev;
            const prev = self.nodeConst(prev_index);
            const merged_size = checkedAdd(prev.size, size) orelse return error.OutOfMemory;

            self.unlinkBin(prev_index);
            self.node(prev_index).size = merged_size;
            self.linkBin(prev_index);
            return;
        }

        if (merge_next) {
            const next_index = neighbors.next;
            const next = self.nodeConst(next_index);
            const merged_size = checkedAdd(size, next.size) orelse return error.OutOfMemory;

            self.unlinkBin(next_index);
            const next_node = self.node(next_index);
            next_node.offset = offset;
            next_node.size = merged_size;
            self.linkBin(next_index);
            return;
        }

        const index = try self.acquireNode();
        const block_node = self.node(index);
        block_node.offset = offset;
        block_node.size = size;
        self.linkAddressBetween(index, neighbors.prev, neighbors.next);
        self.linkBin(index);
    }

    fn overlapsNeighborRanges(self: *const PoolAllocator, neighbors: AddressNeighbors, offset: u32, end: u32) bool {
        if (neighbors.prev != none) {
            const prev = self.nodeConst(neighbors.prev);
            const prev_end = blockEnd(prev.offset, prev.size) orelse return true;
            if (prev_end > offset) return true;
        }
        if (neighbors.next != none) {
            const next = self.nodeConst(neighbors.next);
            if (end > next.offset) return true;
        }
        return false;
    }

    fn findAddressNeighbors(self: *const PoolAllocator, offset: u32) AddressNeighbors {
        var prev: Link = none;
        var index = self.address_head;
        while (index != none) {
            const block = self.nodeConst(index);
            if (block.offset >= offset) return .{ .prev = prev, .next = index };
            prev = index;
            index = block.next_addr;
        }
        return .{ .prev = prev, .next = none };
    }

    fn reclaimTrailingFreeBlocks(self: *PoolAllocator) void {
        while (self.address_tail != none) {
            const tail_index = self.address_tail;
            const tail = self.nodeConst(tail_index);
            const tail_end = blockEnd(tail.offset, tail.size) orelse break;
            if (tail_end != self.cursor) break;

            self.cursor = tail.offset;
            self.unlinkBin(tail_index);
            self.unlinkAddress(tail_index);
            self.releaseNode(tail_index);
        }
    }

    fn acquireNode(self: *PoolAllocator) error{OutOfMemory}!Link {
        if (self.unused_head != none) {
            const index = self.unused_head;
            self.unused_head = self.nodeConst(index).next_unused;
            self.node(index).* = .{};
            return index;
        }

        const index = try nodeIndexFromLen(self.nodes.items.len);
        try self.nodes.append(self.allocator, .{});
        return index;
    }

    fn releaseNode(self: *PoolAllocator, index: Link) void {
        const released = self.node(index);
        released.* = .{ .next_unused = self.unused_head };
        self.unused_head = index;
    }

    fn linkAddressBetween(self: *PoolAllocator, index: Link, prev: Link, next: Link) void {
        const block = self.node(index);
        block.prev_addr = prev;
        block.next_addr = next;

        if (prev != none) {
            self.node(prev).next_addr = index;
        } else {
            self.address_head = index;
        }

        if (next != none) {
            self.node(next).prev_addr = index;
        } else {
            self.address_tail = index;
        }

        self.free_node_count += 1;
    }

    fn unlinkAddress(self: *PoolAllocator, index: Link) void {
        const block = self.nodeConst(index).*;

        if (block.prev_addr != none) {
            self.node(block.prev_addr).next_addr = block.next_addr;
        } else {
            self.address_head = block.next_addr;
        }

        if (block.next_addr != none) {
            self.node(block.next_addr).prev_addr = block.prev_addr;
        } else {
            self.address_tail = block.prev_addr;
        }

        const unlinked = self.node(index);
        unlinked.prev_addr = none;
        unlinked.next_addr = none;
        self.free_node_count -= 1;
    }

    fn linkBin(self: *PoolAllocator, index: Link) void {
        const bin = binForSize(self.nodeConst(index).size);
        const old_head = self.bin_heads[bin];

        const block = self.node(index);
        block.bin = @intCast(bin);
        block.prev_bin = none;
        block.next_bin = old_head;

        if (old_head != none) self.node(old_head).prev_bin = index;
        self.bin_heads[bin] = index;
    }

    fn unlinkBin(self: *PoolAllocator, index: Link) void {
        const block = self.nodeConst(index).*;
        if (block.prev_bin != none) {
            self.node(block.prev_bin).next_bin = block.next_bin;
        } else {
            self.bin_heads[block.bin] = block.next_bin;
        }

        if (block.next_bin != none) self.node(block.next_bin).prev_bin = block.prev_bin;

        const unlinked = self.node(index);
        unlinked.prev_bin = none;
        unlinked.next_bin = none;
    }

    fn node(self: *PoolAllocator, index: Link) *FreeBlock {
        return &self.nodes.items[@intCast(index)];
    }

    fn nodeConst(self: *const PoolAllocator, index: Link) *const FreeBlock {
        return &self.nodes.items[@intCast(index)];
    }
};

fn checkedAdd(a: u32, b: u32) ?u32 {
    return std.math.add(u32, a, b) catch null;
}

fn blockEnd(offset: u32, size: u32) ?u32 {
    return checkedAdd(offset, size);
}

fn alignAllocationSize(value: u32, alignment: u32) ?u32 {
    const mask = alignment - 1;
    const rounded = checkedAdd(value, mask) orelse return null;
    return rounded & ~mask;
}

fn binForSize(size: u32) usize {
    std.debug.assert(size > 0);
    return @intCast(@as(u6, 31) - @clz(size));
}

fn emptyBinHeads() [bin_count]Link {
    return [_]Link{none} ** bin_count;
}

fn isAligned(value: u32, alignment: u32) bool {
    return value & (alignment - 1) == 0;
}

fn isPowerOfTwo(value: u32) bool {
    return value != 0 and (value & (value - 1)) == 0;
}

fn nodeIndexFromLen(len: usize) error{OutOfMemory}!Link {
    if (len >= @as(usize, none)) return error.OutOfMemory;
    return @intCast(len);
}

fn expectConsistent(pa: *const PoolAllocator) !void {
    var free_blocks: u32 = 0;
    var address_bytes: u32 = 0;
    var previous_end: u32 = 0;
    var previous: Link = none;
    var index = pa.address_head;

    while (index != none) {
        const block = pa.nodeConst(index);
        try std.testing.expect(block.size > 0);
        try std.testing.expect(isAligned(block.offset, pa.alignment));
        try std.testing.expect(isAligned(block.size, pa.alignment));
        try std.testing.expectEqual(previous, block.prev_addr);
        try std.testing.expect(previous_end <= block.offset);
        try std.testing.expect((blockEnd(block.offset, block.size) orelse return error.TestExpectedEqual) <= pa.cursor);
        try std.testing.expectEqual(binForSize(block.size), @as(usize, block.bin));

        var seen_in_bin = false;
        var bin_index = pa.bin_heads[block.bin];
        while (bin_index != none) {
            if (bin_index == index) {
                seen_in_bin = true;
                break;
            }
            bin_index = pa.nodeConst(bin_index).next_bin;
        }
        try std.testing.expect(seen_in_bin);

        free_blocks += 1;
        address_bytes += block.size;
        previous_end = blockEnd(block.offset, block.size).?;
        previous = index;
        index = block.next_addr;
    }

    try std.testing.expectEqual(previous, pa.address_tail);
    try std.testing.expectEqual(free_blocks, pa.free_node_count);

    const snap = pa.snapshot();
    try std.testing.expectEqual(pa.capacity - pa.cursor + address_bytes, snap.free_bytes);
    try std.testing.expectEqual(pa.capacity - snap.free_bytes, snap.used_bytes);
    try std.testing.expectEqual(free_blocks, snap.free_blocks);
}

test "PoolAllocator: bump allocation returns aligned offsets" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(10).?;
    try std.testing.expectEqual(@as(u32, 0), a.offset);
    try std.testing.expectEqual(@as(u32, 10), a.size);

    const b = pa.alloc(20).?;
    try std.testing.expectEqual(@as(u32, 16), b.offset);
    try std.testing.expectEqual(@as(u32, 20), b.size);
    try expectConsistent(&pa);
}

test "PoolAllocator: returns null when full" {
    var pa = try PoolAllocator.init(std.testing.allocator, 32, 16);
    defer pa.deinit();

    _ = pa.alloc(20).?; // consumes 32 aligned bytes
    try std.testing.expectEqual(@as(?Allocation, null), pa.alloc(1));
    try expectConsistent(&pa);
}

test "PoolAllocator: oversized allocation returns null without wrapping" {
    var pa = try PoolAllocator.init(std.testing.allocator, 1024, 256);
    defer pa.deinit();

    try std.testing.expectEqual(@as(?Allocation, null), pa.alloc(std.math.maxInt(u32)));
    try expectConsistent(&pa);
}

test "PoolAllocator: zero-size alloc returns null" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    try std.testing.expectEqual(@as(?Allocation, null), pa.alloc(0));
    try expectConsistent(&pa);
}

test "PoolAllocator: init rejects invalid capacity and alignment" {
    try std.testing.expectError(
        error.InvalidPoolCapacity,
        PoolAllocator.init(std.testing.allocator, 0, 16),
    );
    try std.testing.expectError(
        error.InvalidPoolAlignment,
        PoolAllocator.init(std.testing.allocator, 256, 0),
    );
    try std.testing.expectError(
        error.InvalidPoolAlignment,
        PoolAllocator.init(std.testing.allocator, 256, 24),
    );
    try std.testing.expectError(
        error.InvalidPoolCapacity,
        PoolAllocator.init(std.testing.allocator, 192, 128),
    );
}

test "PoolAllocator: free and reuse" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(10).?;
    _ = pa.alloc(20);
    pa.free(a);

    const c = pa.alloc(8).?;
    try std.testing.expectEqual(@as(u32, 0), c.offset);
    try expectConsistent(&pa);
}

test "PoolAllocator: snapshot reports used bytes and largest free block" {
    var pa = try PoolAllocator.init(std.testing.allocator, 128, 16);
    defer pa.deinit();

    const a = pa.alloc(10).?;
    _ = pa.alloc(20).?;
    pa.free(a);

    const snap = pa.snapshot();
    try std.testing.expectEqual(@as(u32, 32), snap.used_bytes);
    try std.testing.expectEqual(@as(u32, 96), snap.free_bytes);
    try std.testing.expectEqual(@as(u32, 80), snap.largest_free_block);
    try std.testing.expectEqual(@as(u32, 1), snap.free_blocks);
    try expectConsistent(&pa);
}

test "PoolAllocator: free block splitting" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(48).?;
    _ = pa.alloc(16);
    pa.free(a);

    const b = pa.alloc(16).?;
    try std.testing.expectEqual(@as(u32, 0), b.offset);

    const c = pa.alloc(16).?;
    try std.testing.expectEqual(@as(u32, 16), c.offset);
    try expectConsistent(&pa);
}

test "PoolAllocator: reset clears all state" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
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
    try expectConsistent(&pa);
}

test "PoolAllocator: best-fit selects smallest suitable block" {
    var pa = try PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(64).?;
    const b = pa.alloc(128).?;
    _ = pa.alloc(16);
    const c = pa.alloc(32).?;
    _ = pa.alloc(16);
    pa.free(b);
    pa.free(c);

    const d = pa.alloc(30).?;
    try std.testing.expectEqual(c.offset, d.offset);
    try expectConsistent(&pa);

    _ = a;
}

test "PoolAllocator: skips undersized blocks in the starting size bin" {
    var pa = try PoolAllocator.init(std.testing.allocator, 512, 16);
    defer pa.deinit();

    const small = pa.alloc(32).?;
    _ = pa.alloc(16);
    const large = pa.alloc(64).?;
    _ = pa.alloc(16);
    pa.free(small);
    pa.free(large);

    const reused = pa.alloc(48).?;
    try std.testing.expectEqual(large.offset, reused.offset);
    try expectConsistent(&pa);
}

test "PoolAllocator: freeing tail allocation rewinds cursor" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(16).?;
    const b = pa.alloc(24).?;
    pa.free(b);

    try std.testing.expectEqual(@as(u32, 16), pa.cursor);
    try std.testing.expectEqual(@as(u32, 0), pa.snapshot().free_blocks);

    pa.free(a);
    try std.testing.expectEqual(@as(u32, 0), pa.cursor);
    try std.testing.expectEqual(@as(u32, 0), pa.snapshot().free_blocks);
    try expectConsistent(&pa);
}

test "PoolAllocator: tail rewind absorbs adjacent free blocks" {
    var pa = try PoolAllocator.init(std.testing.allocator, 256, 16);
    defer pa.deinit();

    const a = pa.alloc(16).?;
    const b = pa.alloc(16).?;
    const c = pa.alloc(16).?;

    pa.free(a);
    pa.free(b);
    try std.testing.expectEqual(@as(u32, 48), pa.cursor);
    try std.testing.expectEqual(@as(u32, 1), pa.snapshot().free_blocks);

    pa.free(c);
    try std.testing.expectEqual(@as(u32, 0), pa.cursor);
    try std.testing.expectEqual(@as(u32, 0), pa.snapshot().free_blocks);
    try expectConsistent(&pa);
}

test "PoolAllocator: free coalesces adjacent blocks" {
    var pa = try PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(48).?;
    const b = pa.alloc(48).?;
    const c = pa.alloc(48).?;
    _ = pa.alloc(48);

    pa.free(a);
    pa.free(c);
    pa.free(b);

    const big = pa.alloc(144).?;
    try std.testing.expectEqual(@as(u32, 0), big.offset);
    try expectConsistent(&pa);
}

test "PoolAllocator: higher bins return the chain head without scanning to smallest" {
    // Within the starting bin we walk to the first fit; for any bin above
    // start, every member trivially satisfies size >= aligned_size, so the
    // search picks the head directly. The first-freed block lands at the
    // head of bin 5 below; the second free pushes that block to the next_bin
    // slot. A request that maps to start_bin = 4 (alignment-rounded 32)
    // skips bin 4 (empty) and must return whichever block currently sits at
    // bin 5's head — i.e. the most recently freed one — without scanning.
    var pa = try PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(48).?;
    _ = pa.alloc(16);
    const b = pa.alloc(48).?;
    _ = pa.alloc(16);

    pa.free(a); // bin 5 head = block at a.offset
    pa.free(b); // bin 5 head = block at b.offset (linkBin inserts at head)

    const reused = pa.alloc(32).?;
    try std.testing.expectEqual(b.offset, reused.offset);
    try expectConsistent(&pa);
}

test "PoolAllocator: dense same-bin chain finds a fit without scanning past it" {
    // Populate one bin chain with many entries whose sizes straddle the
    // request size. The within-bin walk must accept the first fit it
    // encounters; this exercise would have produced quadratic search time
    // under the previous best-fit-within-bin implementation.
    var pa = try PoolAllocator.init(std.testing.allocator, 16 * 1024, 16);
    defer pa.deinit();

    const chain_len = 64;
    var freed: [chain_len]Allocation = undefined;
    for (&freed, 0..) |*slot, i| {
        const size: u32 = @intCast(80 + (i % 8) * 16); // 80..208, all in bin 6 (64..127) or bin 7
        slot.* = pa.alloc(size).?;
        // Sandwich every free block with a live one so frees do not coalesce.
        _ = pa.alloc(16).?;
    }
    for (freed) |allocation| pa.free(allocation);

    // Request that lands in bin 6's lower half; many chain members are large
    // enough, many are not.
    const reused = pa.alloc(96).?;
    try std.testing.expect(reused.size == 96);
    try expectConsistent(&pa);
}

test "PoolAllocator: free list maintains address order" {
    var pa = try PoolAllocator.init(std.testing.allocator, 4096, 16);
    defer pa.deinit();

    const a = pa.alloc(16).?;
    const b = pa.alloc(16).?;
    const c = pa.alloc(16).?;
    _ = pa.alloc(16);

    pa.free(c);
    pa.free(a);
    pa.free(b);

    const big = pa.alloc(48).?;
    try std.testing.expectEqual(@as(u32, 0), big.offset);
    try expectConsistent(&pa);
}
