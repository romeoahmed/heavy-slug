const std = @import("std");
const pool_mod = @import("pool.zig");

pub const CacheKey = struct {
    font_id: u32,
    glyph_id: u32,
};

const Tier = enum { hot, cold };

/// Pre-computed em-space bounding box (float, ready for GlyphCommand).
pub const EmBox = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
};

pub const CacheEntry = struct {
    slot: u32,
    pool_alloc: pool_mod.Allocation,
    tier: Tier,
    last_frame: u32,
    consecutive_frames: u8,
    em_box: EmBox,
    lru_idx: u32 = LRU_NONE, // index into GlyphCache.lru_nodes; LRU_NONE for hot entries
};

// --- LRU doubly-linked list (index-based) ---

const LRU_SENTINEL_HEAD: u32 = 0; // MRU end
const LRU_SENTINEL_TAIL: u32 = 1; // LRU end
const LRU_NONE: u32 = std.math.maxInt(u32);

const LruNode = struct {
    key: CacheKey,
    prev: u32,
    next: u32,
};

/// Returned when an entry is evicted from the cache.
/// The caller is responsible for freeing the descriptor slot and pool allocation.
pub const EvictedEntry = struct {
    key: CacheKey,
    slot: u32,
    pool_alloc: pool_mod.Allocation,
};

/// Two-tier glyph cache mapping (font_id, glyph_id) to descriptor slot + pool allocation.
///
/// - **Hot tier**: frequently used glyphs, evicted only on font unload.
/// - **Cold tier**: LRU eviction when full, promotion to hot after `promote_frames`
///   consecutive frames of use.
///
/// This is a pure metadata tracker — it does not own Vulkan resources.
pub const GlyphCache = struct {
    map: std.AutoHashMap(CacheKey, CacheEntry),
    hot_count: u32,
    cold_count: u32,
    hot_capacity: u32,
    cold_capacity: u32,
    current_frame: u32,
    promote_frames: u8,
    allocator: std.mem.Allocator,
    lru_nodes: []LruNode,
    lru_free_head: u32,

    /// Wrapping frame age: how many frames ago was `frame` relative to `current`.
    /// Handles u32 overflow correctly via wrapping subtraction.
    fn frameAge(current: u32, frame: u32) u32 {
        return current -% frame;
    }

    // --- LRU list helpers (O(1) each) ---

    fn lruAlloc(self: *GlyphCache) u32 {
        const idx = self.lru_free_head;
        std.debug.assert(idx != LRU_NONE);
        self.lru_free_head = self.lru_nodes[idx].next;
        return idx;
    }

    fn lruFree(self: *GlyphCache, idx: u32) void {
        self.lru_nodes[idx] = .{ .key = undefined, .prev = LRU_NONE, .next = self.lru_free_head };
        self.lru_free_head = idx;
    }

    fn lruUnlink(self: *GlyphCache, idx: u32) void {
        const node = self.lru_nodes[idx];
        self.lru_nodes[node.prev].next = node.next;
        self.lru_nodes[node.next].prev = node.prev;
    }

    fn lruLinkAfter(self: *GlyphCache, after: u32, idx: u32) void {
        const old_next = self.lru_nodes[after].next;
        self.lru_nodes[idx].prev = after;
        self.lru_nodes[idx].next = old_next;
        self.lru_nodes[after].next = idx;
        self.lru_nodes[old_next].prev = idx;
    }

    fn lruTouch(self: *GlyphCache, idx: u32) void {
        self.lruUnlink(idx);
        self.lruLinkAfter(LRU_SENTINEL_HEAD, idx);
    }

    pub fn init(
        allocator: std.mem.Allocator,
        hot_capacity: u32,
        cold_capacity: u32,
        promote_frames: u8,
    ) !GlyphCache {
        const node_count = cold_capacity + 2; // 2 sentinels + cold_capacity user nodes
        const lru_nodes = try allocator.alloc(LruNode, node_count);

        // Sentinels: HEAD <-> TAIL
        lru_nodes[LRU_SENTINEL_HEAD] = .{ .key = undefined, .prev = LRU_NONE, .next = LRU_SENTINEL_TAIL };
        lru_nodes[LRU_SENTINEL_TAIL] = .{ .key = undefined, .prev = LRU_SENTINEL_HEAD, .next = LRU_NONE };

        // Build free list from indices 2..node_count-1
        var free_head: u32 = LRU_NONE;
        if (cold_capacity > 0) {
            var i: u32 = node_count - 1;
            while (i >= 2) : (i -= 1) {
                lru_nodes[i] = .{ .key = undefined, .prev = LRU_NONE, .next = free_head };
                free_head = i;
                if (i == 2) break;
            }
        }

        return .{
            .allocator = allocator,
            .map = std.AutoHashMap(CacheKey, CacheEntry).init(allocator),
            .hot_count = 0,
            .cold_count = 0,
            .hot_capacity = hot_capacity,
            .cold_capacity = cold_capacity,
            .current_frame = 0,
            .promote_frames = promote_frames,
            .lru_nodes = lru_nodes,
            .lru_free_head = free_head,
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        self.allocator.free(self.lru_nodes);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const GlyphCache) u32 {
        return self.hot_count + self.cold_count;
    }

    /// Insert a glyph into the hot tier. Caller must ensure hot tier has capacity.
    /// Caller must ensure key is not already present (lookup first).
    pub fn insertHot(
        self: *GlyphCache,
        key: CacheKey,
        slot: u32,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
    ) !void {
        std.debug.assert(self.hot_count < self.hot_capacity);
        std.debug.assert(!self.map.contains(key));
        try self.map.put(key, .{
            .slot = slot,
            .pool_alloc = pool_alloc,
            .tier = .hot,
            .last_frame = self.current_frame,
            .consecutive_frames = 1,
            .em_box = em_box,
        });
        self.hot_count += 1;
    }

    /// Insert a glyph into the cold tier. Caller must ensure cold tier has capacity
    /// (evict first if full). Caller must ensure key is not already present (lookup first).
    pub fn insertCold(
        self: *GlyphCache,
        key: CacheKey,
        slot: u32,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
    ) !void {
        std.debug.assert(self.cold_count < self.cold_capacity);
        std.debug.assert(!self.map.contains(key));

        const lru_idx = self.lruAlloc();
        self.lru_nodes[lru_idx].key = key;
        self.lruLinkAfter(LRU_SENTINEL_HEAD, lru_idx);
        errdefer {
            self.lruUnlink(lru_idx);
            self.lruFree(lru_idx);
        }

        try self.map.put(key, .{
            .slot = slot,
            .pool_alloc = pool_alloc,
            .tier = .cold,
            .last_frame = self.current_frame,
            .consecutive_frames = 1,
            .em_box = em_box,
            .lru_idx = lru_idx,
        });
        self.cold_count += 1;
    }

    /// Look up a cached glyph. On hit, updates frame tracking for LRU and promotion.
    /// Returns a mutable pointer into the map — valid until next map mutation.
    pub fn lookup(self: *GlyphCache, key: CacheKey) ?*CacheEntry {
        const entry = self.map.getPtr(key) orelse return null;
        // Update consecutive-frame tracking
        if (entry.last_frame != self.current_frame) {
            if (frameAge(self.current_frame, entry.last_frame) == 1) {
                entry.consecutive_frames +|= 1; // saturating add (u8)
            } else {
                entry.consecutive_frames = 1; // gap in usage — reset streak
            }
        }
        entry.last_frame = self.current_frame;
        // Move cold entry to MRU position in LRU list
        if (entry.tier == .cold) {
            self.lruTouch(entry.lru_idx);
        }
        return entry;
    }

    /// Advance the frame counter. Promotes cold entries that have been used for
    /// `promote_frames` consecutive frames into the hot tier (if hot has capacity).
    pub fn advanceFrame(self: *GlyphCache) void {
        self.current_frame +%= 1;

        if (self.hot_count >= self.hot_capacity) return;

        // Only mutate value_ptr fields in-place — do NOT call map.put/remove here.
        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.tier == .cold and
                entry.value_ptr.consecutive_frames >= self.promote_frames)
            {
                self.lruUnlink(entry.value_ptr.lru_idx);
                self.lruFree(entry.value_ptr.lru_idx);
                entry.value_ptr.lru_idx = LRU_NONE;
                entry.value_ptr.tier = .hot;
                entry.value_ptr.consecutive_frames = 0;
                self.hot_count += 1;
                self.cold_count -= 1;
                if (self.hot_count >= self.hot_capacity) break;
            }
        }
    }

    /// Evict the least-recently-used cold entry. O(1) via DLL tail pop.
    /// Returns the evicted entry's key, slot, and pool allocation so the
    /// caller can free Vulkan resources. Returns null if no cold entries.
    pub fn evictLru(self: *GlyphCache) ?EvictedEntry {
        if (self.cold_count == 0) return null;

        // The LRU entry is immediately before the TAIL sentinel
        const lru_idx = self.lru_nodes[LRU_SENTINEL_TAIL].prev;
        std.debug.assert(lru_idx != LRU_SENTINEL_HEAD);

        const key = self.lru_nodes[lru_idx].key;
        self.lruUnlink(lru_idx);
        self.lruFree(lru_idx);

        const removed = self.map.fetchRemove(key) orelse unreachable;
        self.cold_count -= 1;

        return .{
            .key = key,
            .slot = removed.value.slot,
            .pool_alloc = removed.value.pool_alloc,
        };
    }

    /// Remove all cache entries for the given font_id.
    /// Returns a caller-owned slice of evicted entries so the caller can
    /// free descriptor slots and pool allocations. Caller must free the
    /// returned slice with the same allocator.
    pub fn removeFont(self: *GlyphCache, allocator: std.mem.Allocator, font_id: u32) ![]EvictedEntry {
        // Collect keys to remove (can't remove during iteration)
        var to_remove: std.ArrayListUnmanaged(CacheKey) = .empty;
        defer to_remove.deinit(allocator);

        var it = self.map.iterator();
        while (it.next()) |entry| {
            if (entry.key_ptr.font_id == font_id) {
                try to_remove.append(allocator, entry.key_ptr.*);
            }
        }

        if (to_remove.items.len == 0) return &.{};

        const evicted = try allocator.alloc(EvictedEntry, to_remove.items.len);
        for (to_remove.items, 0..) |key, i| {
            // Safe: key was observed during iteration above and the map is not mutated between passes.
            const removed = self.map.fetchRemove(key).?;
            if (removed.value.tier == .hot) {
                self.hot_count -= 1;
            } else {
                self.lruUnlink(removed.value.lru_idx);
                self.lruFree(removed.value.lru_idx);
                self.cold_count -= 1;
            }
            evicted[i] = .{
                .key = key,
                .slot = removed.value.slot,
                .pool_alloc = removed.value.pool_alloc,
            };
        }
        return evicted;
    }
};

test "GlyphCache: init and deinit" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "GlyphCache: insert hot and lookup" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertHot(key, 0, .{ .offset = 0, .size = 128 }, dummy_box);

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(Tier.hot, entry.tier);
    try std.testing.expectEqual(@as(u32, 0), entry.slot);
}

test "GlyphCache: insert cold and lookup" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, 5, .{ .offset = 64, .size = 200 }, dummy_box);

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(Tier.cold, entry.tier);
    try std.testing.expectEqual(@as(u32, 5), entry.slot);
}

test "GlyphCache: lookup miss returns null" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    try std.testing.expectEqual(
        @as(?*CacheEntry, null),
        cache.lookup(.{ .font_id = 1, .glyph_id = 99 }),
    );
}

test "GlyphCache: count tracks hot and cold" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    try cache.insertHot(.{ .font_id = 1, .glyph_id = 1 }, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 2 }, 1, .{ .offset = 64, .size = 64 }, dummy_box);

    try std.testing.expectEqual(@as(u32, 2), cache.count());
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 1), cache.cold_count);
}

test "GlyphCache: evict LRU cold entry" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 2, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key1 = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key2 = CacheKey{ .font_id = 1, .glyph_id = 2 };

    try cache.insertCold(key1, 10, .{ .offset = 0, .size = 64 }, dummy_box);
    cache.current_frame = 1; // advance manually for insertion ordering
    try cache.insertCold(key2, 11, .{ .offset = 64, .size = 64 }, dummy_box);

    // key1 was inserted at frame 0 (older), key2 at frame 1
    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key1, evicted.key);
    try std.testing.expectEqual(@as(u32, 10), evicted.slot);
    try std.testing.expectEqual(@as(u32, 1), cache.cold_count);
}

test "GlyphCache: evict returns null when no cold entries" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    // Only hot entries
    try cache.insertHot(.{ .font_id = 1, .glyph_id = 1 }, 0, .{ .offset = 0, .size = 64 }, dummy_box);

    try std.testing.expectEqual(@as(?EvictedEntry, null), cache.evictLru());
}

test "GlyphCache: evict prefers least recently used" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 4, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key_a = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_b = CacheKey{ .font_id = 1, .glyph_id = 2 };
    const key_c = CacheKey{ .font_id = 1, .glyph_id = 3 };

    try cache.insertCold(key_a, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(key_b, 1, .{ .offset = 64, .size = 64 }, dummy_box);
    try cache.insertCold(key_c, 2, .{ .offset = 128, .size = 64 }, dummy_box);

    // Touch key_a at frame 5 — it becomes most recently used
    cache.current_frame = 5;
    _ = cache.lookup(key_a);

    // key_b and key_c are untouched; B was inserted before C so B is LRU
    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key_b, evicted.key);
}

test "GlyphCache: consecutive frame tracking" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, 0, .{ .offset = 0, .size = 64 }, dummy_box);

    // Frame 0: insert set consecutive = 1
    var entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 1), entry.consecutive_frames);

    // Frame 1: consecutive should increment to 2
    cache.advanceFrame();
    entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 2), entry.consecutive_frames);

    // Frame 2: consecutive should increment to 3
    cache.advanceFrame();
    entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 3), entry.consecutive_frames);

    // Skip frame 3 (no lookup), advance to frame 4
    cache.advanceFrame();
    cache.advanceFrame();
    entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 1), entry.consecutive_frames); // reset after gap
}

test "GlyphCache: cold promoted to hot after consecutive frames" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3); // promote after 3 frames
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    // Frame 0: insert → consecutive = 1

    cache.advanceFrame(); // frame 1
    _ = cache.lookup(key); // consecutive = 2

    cache.advanceFrame(); // frame 2
    _ = cache.lookup(key); // consecutive = 3 (>= promote_frames)

    cache.advanceFrame(); // frame 3: promotion happens here

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(Tier.hot, entry.tier);
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 0), cache.cold_count);
}

test "GlyphCache: promotion skipped when hot tier full" {
    var cache = try GlyphCache.init(std.testing.allocator, 1, 8, 2); // hot capacity = 1
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    // Fill hot tier
    try cache.insertHot(.{ .font_id = 1, .glyph_id = 1 }, 0, .{ .offset = 0, .size = 64 }, dummy_box);

    // Add cold entry and use for 2 consecutive frames
    const cold_key = CacheKey{ .font_id = 1, .glyph_id = 2 };
    try cache.insertCold(cold_key, 1, .{ .offset = 64, .size = 64 }, dummy_box);

    cache.advanceFrame();
    _ = cache.lookup(cold_key);
    cache.advanceFrame();
    _ = cache.lookup(cold_key);
    cache.advanceFrame(); // would promote, but hot is full

    const entry = cache.lookup(cold_key).?;
    try std.testing.expectEqual(Tier.cold, entry.tier); // stays cold
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 1), cache.cold_count);
}

test "GlyphCache: removeFont evicts all entries for a font" {
    var gc = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer gc.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    // Insert entries for two fonts
    try gc.insertHot(.{ .font_id = 1, .glyph_id = 65 }, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 66 }, 1, .{ .offset = 64, .size = 64 }, dummy_box);
    try gc.insertHot(.{ .font_id = 2, .glyph_id = 65 }, 2, .{ .offset = 128, .size = 64 }, dummy_box);
    try std.testing.expectEqual(@as(u32, 3), gc.count());

    // Remove font 1
    const evicted = try gc.removeFont(std.testing.allocator, 1);
    defer std.testing.allocator.free(evicted);

    try std.testing.expectEqual(@as(usize, 2), evicted.len);
    // Verify the evicted entries contain the correct slots
    const has_slot_0 = for (evicted) |e| {
        if (e.slot == 0) break true;
    } else false;
    const has_slot_1 = for (evicted) |e| {
        if (e.slot == 1) break true;
    } else false;
    try std.testing.expect(has_slot_0);
    try std.testing.expect(has_slot_1);
    try std.testing.expectEqual(@as(u32, 1), gc.count()); // only font 2 remains
    try std.testing.expectEqual(@as(u32, 1), gc.hot_count); // font 2's hot entry
    try std.testing.expectEqual(@as(u32, 0), gc.cold_count); // font 1's cold entry removed

    // Font 2 entry still accessible
    try std.testing.expect(gc.lookup(.{ .font_id = 2, .glyph_id = 65 }) != null);
    // Font 1 entries gone
    try std.testing.expect(gc.lookup(.{ .font_id = 1, .glyph_id = 65 }) == null);
    try std.testing.expect(gc.lookup(.{ .font_id = 1, .glyph_id = 66 }) == null);
}

test "GlyphCache: removeFont on unknown font_id returns empty slice" {
    var gc = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer gc.deinit();

    const evicted = try gc.removeFont(std.testing.allocator, 99);
    defer std.testing.allocator.free(evicted);
    try std.testing.expectEqual(@as(usize, 0), evicted.len);
    try std.testing.expectEqual(@as(u32, 0), gc.count());
}

test "GlyphCache: duplicate lookup in same frame does not double-count" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, 0, .{ .offset = 0, .size = 64 }, dummy_box);

    // Multiple lookups in the same frame
    _ = cache.lookup(key);
    _ = cache.lookup(key);
    _ = cache.lookup(key);

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 1), entry.consecutive_frames); // still 1
}

test "CacheEntry has em_box field" {
    const entry = CacheEntry{
        .slot = 0,
        .pool_alloc = .{ .offset = 0, .size = 64 },
        .tier = .cold,
        .last_frame = 0,
        .consecutive_frames = 1,
        .em_box = .{ .x_min = -1.0, .y_min = -2.0, .x_max = 10.0, .y_max = 12.0 },
    };
    try std.testing.expectEqual(@as(f32, -1.0), entry.em_box.x_min);
    try std.testing.expectEqual(@as(f32, 12.0), entry.em_box.y_max);
}

test "GlyphCache: frame counter overflow does not break LRU" {
    // At 60fps, current_frame (u32) overflows in ~2.3 years.
    // Wrapping subtraction must be used so older frames still sort correctly.
    const allocator = std.testing.allocator;
    // Minimal cache: 4 hot slots, 4 cold slots, promote after 3 frames
    var cache = try GlyphCache.init(allocator, 4, 4, 3);
    defer cache.deinit();

    // We'll use dummy EmBox and pool allocation values
    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 64, .y_max = 64 };
    const key_old = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_new = CacheKey{ .font_id = 1, .glyph_id = 2 };

    // Simulate near-overflow: set frame to maxInt - 2
    cache.current_frame = std.math.maxInt(u32) - 2;
    try cache.insertCold(key_old, 0, .{ .offset = 0, .size = 64 }, dummy_box);

    // Advance past overflow
    cache.advanceFrame(); // maxInt - 1
    cache.advanceFrame(); // maxInt
    cache.advanceFrame(); // wraps to 0
    try cache.insertCold(key_new, 1, .{ .offset = 64, .size = 64 }, dummy_box);

    // key_old (inserted at maxInt-2) must be evicted as the oldest.
    // With correct wrapping, its age = 0 -% (maxInt-2) = 3 (wrapping sub), which is > key_new's age of 0.
    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key_old, evicted.key);
}

test "GlyphCache: eviction order matches access recency" {
    var cache = try GlyphCache.init(std.testing.allocator, 0, 4, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    // Insert A, B, C, D
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 1 }, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 2 }, 1, .{ .offset = 64, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 3 }, 2, .{ .offset = 128, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 4 }, 3, .{ .offset = 192, .size = 64 }, dummy_box);

    // Evict all — should come out in insertion order (FIFO when no accesses)
    try std.testing.expectEqual(@as(u32, 1), cache.evictLru().?.key.glyph_id);
    try std.testing.expectEqual(@as(u32, 2), cache.evictLru().?.key.glyph_id);
    try std.testing.expectEqual(@as(u32, 3), cache.evictLru().?.key.glyph_id);
    try std.testing.expectEqual(@as(u32, 4), cache.evictLru().?.key.glyph_id);
    try std.testing.expectEqual(@as(?EvictedEntry, null), cache.evictLru());
}

test "GlyphCache: access moves entry to MRU end" {
    var cache = try GlyphCache.init(std.testing.allocator, 0, 3, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key_a = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_b = CacheKey{ .font_id = 1, .glyph_id = 2 };
    const key_c = CacheKey{ .font_id = 1, .glyph_id = 3 };

    try cache.insertCold(key_a, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(key_b, 1, .{ .offset = 64, .size = 64 }, dummy_box);
    try cache.insertCold(key_c, 2, .{ .offset = 128, .size = 64 }, dummy_box);

    // Touch A — moves to MRU
    _ = cache.lookup(key_a);

    // Evict: B (LRU), then C, then A (MRU)
    try std.testing.expectEqual(key_b, cache.evictLru().?.key);
    try std.testing.expectEqual(key_c, cache.evictLru().?.key);
    try std.testing.expectEqual(key_a, cache.evictLru().?.key);
}

test "GlyphCache: promoted entry not returned by evictLru" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 4, 2);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key_a = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_b = CacheKey{ .font_id = 1, .glyph_id = 2 };

    try cache.insertCold(key_a, 0, .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(key_b, 1, .{ .offset = 64, .size = 64 }, dummy_box);

    // Use key_a for 2 consecutive frames to trigger promotion
    cache.advanceFrame();
    _ = cache.lookup(key_a);
    cache.advanceFrame(); // promotes key_a to hot

    // key_a is now hot; evicting should return key_b only
    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key_b, evicted.key);
    try std.testing.expectEqual(@as(?EvictedEntry, null), cache.evictLru());
}
