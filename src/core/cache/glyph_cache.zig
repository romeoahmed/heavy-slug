const std = @import("std");
const pool_mod = @import("byte_pool.zig");

pub const GlyphBlobRef = packed struct(u32) {
    value: u32,

    pub const empty: GlyphBlobRef = .{ .value = std.math.maxInt(u32) };

    pub fn from(value: u32) GlyphBlobRef {
        return .{ .value = value };
    }

    pub fn isEmpty(self: GlyphBlobRef) bool {
        return self.value == empty.value;
    }
};

pub const CacheKey = struct {
    font_id: u32,
    glyph_id: u32,
    precision_bits: u8 = 0,
    _pad: [3]u8 = .{ 0, 0, 0 },
    /// Hash of variation-axis coordinates. Zero means the font's default instance.
    variation_key: u64 = 0,
};

pub const CacheTier = enum { hot, cold };

/// Pre-computed em-space bounding box (float, ready for GlyphInstance).
pub const EmBox = struct {
    x_min: f32,
    y_min: f32,
    x_max: f32,
    y_max: f32,
};

pub const FixedBounds = extern struct {
    x_min: i32,
    y_min: i32,
    x_max: i32,
    y_max: i32,
};

pub const BandMeshInfo = struct {
    candidate_count: u32,
    max_x_q: i32,
};

pub const MeshMetadata = struct {
    curve_count: u32 = 0,
    band_min: i32 = 0,
    band_count: u32 = 0,
    band_height_q: i32 = 1,
    bands: []BandMeshInfo = &.{},

    pub fn empty() MeshMetadata {
        return .{};
    }

    pub fn deinit(self: *MeshMetadata, allocator: std.mem.Allocator) void {
        if (self.bands.len != 0) allocator.free(self.bands);
        self.* = .{};
    }
};

pub const CacheEntry = struct {
    blob_ref: GlyphBlobRef,
    pool_alloc: pool_mod.Allocation,
    tier: CacheTier,
    last_frame: u32,
    consecutive_frames: u8,
    em_box: EmBox,
    bounds_q: FixedBounds,
    precision_bits: u8,
    mesh_metadata: MeshMetadata = .{},
    lru_idx: u32 = LRU_NONE, // index into GlyphCache.lru_nodes; LRU_NONE for hot entries
};

const LRU_SENTINEL_HEAD: u32 = 0; // MRU end
const LRU_SENTINEL_TAIL: u32 = 1; // LRU end
const LRU_NONE: u32 = std.math.maxInt(u32);
const LruNode = struct {
    key: CacheKey,
    prev: u32,
    next: u32,
};

/// Backend resource and pool allocation returned when an entry leaves the cache.
pub const EvictedEntry = struct {
    key: CacheKey,
    blob_ref: GlyphBlobRef,
    pool_alloc: pool_mod.Allocation,
};

/// Two-tier glyph cache mapping a glyph key to a backend `GlyphBlobRef` and pool allocation.
///
/// - **Hot tier**: frequently used glyphs, evicted only on font unload.
/// - **Cold tier**: LRU eviction when full, promotion to hot after `promote_frames`
///   consecutive frames of use.
///
/// This is metadata only; backends own the GPU objects referenced by `GlyphBlobRef`.
pub const GlyphCache = struct {
    map: std.AutoHashMap(CacheKey, CacheEntry),
    hot_count: u32,
    cold_count: u32,
    hot_capacity: u32,
    cold_capacity: u32,
    current_frame: u32,
    promote_frames: u8,
    frame_promotions: u32,
    allocator: std.mem.Allocator,
    lru_nodes: []LruNode,
    lru_free_head: u32,

    /// Wrapping frame age: how many frames ago was `frame` relative to `current`.
    /// Handles u32 overflow correctly via wrapping subtraction.
    fn frameAge(current: u32, frame: u32) u32 {
        return current -% frame;
    }

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

    fn promoteCold(self: *GlyphCache, entry: *CacheEntry) void {
        std.debug.assert(entry.tier == .cold);
        std.debug.assert(self.hot_count < self.hot_capacity);

        self.lruUnlink(entry.lru_idx);
        self.lruFree(entry.lru_idx);
        entry.lru_idx = LRU_NONE;
        entry.tier = .hot;
        entry.consecutive_frames = 0;
        self.hot_count += 1;
        self.cold_count -= 1;
        self.frame_promotions += 1;
    }

    pub fn init(
        allocator: std.mem.Allocator,
        hot_capacity: u32,
        cold_capacity: u32,
        promote_frames: u8,
    ) !GlyphCache {
        if (cold_capacity > std.math.maxInt(u32) - 2) return error.CacheCapacityTooLarge;
        const node_count: usize = @as(usize, cold_capacity) + 2; // 2 sentinels + cold_capacity user nodes
        const lru_nodes = try allocator.alloc(LruNode, node_count);

        // Sentinels: HEAD <-> TAIL
        lru_nodes[LRU_SENTINEL_HEAD] = .{ .key = undefined, .prev = LRU_NONE, .next = LRU_SENTINEL_TAIL };
        lru_nodes[LRU_SENTINEL_TAIL] = .{ .key = undefined, .prev = LRU_SENTINEL_HEAD, .next = LRU_NONE };

        // Build free list from indices 2..node_count-1
        var free_head: u32 = LRU_NONE;
        if (cold_capacity > 0) {
            var i = cold_capacity + 2;
            while (i > 2) {
                i -= 1;
                lru_nodes[i] = .{ .key = undefined, .prev = LRU_NONE, .next = free_head };
                free_head = i;
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
            .frame_promotions = 0,
            .lru_nodes = lru_nodes,
            .lru_free_head = free_head,
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        var it = self.map.valueIterator();
        while (it.next()) |entry| {
            entry.mesh_metadata.deinit(self.allocator);
        }
        self.allocator.free(self.lru_nodes);
        self.map.deinit();
        self.* = undefined;
    }

    pub fn reserveEntries(self: *GlyphCache, capacity: u32) !void {
        try self.map.ensureTotalCapacity(capacity);
    }

    pub fn count(self: *const GlyphCache) u32 {
        return self.hot_count + self.cold_count;
    }

    /// Insert a glyph into the hot tier. The key must be absent and capacity available.
    pub fn insertHot(
        self: *GlyphCache,
        key: CacheKey,
        blob_ref: GlyphBlobRef,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
    ) !void {
        return self.insertHotWithBounds(key, blob_ref, pool_alloc, em_box, fixedBoundsFromEmBox(em_box));
    }

    pub fn insertHotWithBounds(
        self: *GlyphCache,
        key: CacheKey,
        blob_ref: GlyphBlobRef,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
        bounds_q: FixedBounds,
    ) !void {
        return self.insertHotWithMetadata(key, blob_ref, pool_alloc, em_box, bounds_q, .empty());
    }

    /// Takes ownership of `mesh_metadata`.
    pub fn insertHotWithMetadata(
        self: *GlyphCache,
        key: CacheKey,
        blob_ref: GlyphBlobRef,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
        bounds_q: FixedBounds,
        mesh_metadata: MeshMetadata,
    ) !void {
        std.debug.assert(self.hot_count < self.hot_capacity);
        std.debug.assert(!self.map.contains(key));
        var metadata = mesh_metadata;
        errdefer metadata.deinit(self.allocator);
        try self.map.put(key, .{
            .blob_ref = blob_ref,
            .pool_alloc = pool_alloc,
            .tier = .hot,
            .last_frame = self.current_frame,
            .consecutive_frames = 1,
            .em_box = em_box,
            .bounds_q = bounds_q,
            .precision_bits = key.precision_bits,
            .mesh_metadata = metadata,
        });
        self.hot_count += 1;
    }

    /// Insert a glyph into the cold tier. The key must be absent and capacity available.
    pub fn insertCold(
        self: *GlyphCache,
        key: CacheKey,
        blob_ref: GlyphBlobRef,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
    ) !void {
        return self.insertColdWithBounds(key, blob_ref, pool_alloc, em_box, fixedBoundsFromEmBox(em_box));
    }

    pub fn insertColdWithBounds(
        self: *GlyphCache,
        key: CacheKey,
        blob_ref: GlyphBlobRef,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
        bounds_q: FixedBounds,
    ) !void {
        return self.insertColdWithMetadata(key, blob_ref, pool_alloc, em_box, bounds_q, .empty());
    }

    /// Takes ownership of `mesh_metadata`.
    pub fn insertColdWithMetadata(
        self: *GlyphCache,
        key: CacheKey,
        blob_ref: GlyphBlobRef,
        pool_alloc: pool_mod.Allocation,
        em_box: EmBox,
        bounds_q: FixedBounds,
        mesh_metadata: MeshMetadata,
    ) !void {
        std.debug.assert(self.cold_count < self.cold_capacity);
        std.debug.assert(!self.map.contains(key));

        var metadata = mesh_metadata;
        errdefer metadata.deinit(self.allocator);

        const lru_idx = self.lruAlloc();
        self.lru_nodes[lru_idx].key = key;
        self.lruLinkAfter(LRU_SENTINEL_HEAD, lru_idx);
        errdefer {
            self.lruUnlink(lru_idx);
            self.lruFree(lru_idx);
        }

        try self.map.put(key, .{
            .blob_ref = blob_ref,
            .pool_alloc = pool_alloc,
            .tier = .cold,
            .last_frame = self.current_frame,
            .consecutive_frames = 1,
            .em_box = em_box,
            .bounds_q = bounds_q,
            .precision_bits = key.precision_bits,
            .mesh_metadata = metadata,
            .lru_idx = lru_idx,
        });
        self.cold_count += 1;
    }

    /// Look up a cached glyph. On hit, updates frame tracking for LRU and promotion.
    /// Returns a mutable pointer into the map — valid until next map mutation.
    pub fn lookup(self: *GlyphCache, key: CacheKey) ?*CacheEntry {
        const entry = self.map.getPtr(key) orelse return null;

        // Same-frame dedup: skip LRU touch and consecutive-frame logic
        if (entry.last_frame == self.current_frame) return entry;

        // Update consecutive-frame tracking
        if (frameAge(self.current_frame, entry.last_frame) == 1) {
            entry.consecutive_frames +|= 1; // saturating add (u8)
        } else {
            entry.consecutive_frames = 1; // gap in usage — reset streak
        }
        entry.last_frame = self.current_frame;

        // Move cold entry to MRU position in LRU list
        if (entry.tier == .cold) {
            if (entry.consecutive_frames >= self.promote_frames and self.hot_count < self.hot_capacity) {
                self.promoteCold(entry);
            } else {
                self.lruTouch(entry.lru_idx);
            }
        }
        return entry;
    }

    /// Advance the frame counter. Promotion happens synchronously in lookup().
    pub fn advanceFrame(self: *GlyphCache) void {
        self.current_frame +%= 1;
        self.frame_promotions = 0;
    }

    /// Evict the least-recently-used cold entry. O(1) via DLL tail pop.
    /// Returns the evicted entry's key, `GlyphBlobRef`, and pool allocation.
    pub fn evictLru(self: *GlyphCache) ?EvictedEntry {
        if (self.cold_count == 0) return null;

        // The LRU entry is immediately before the TAIL sentinel
        const lru_idx = self.lru_nodes[LRU_SENTINEL_TAIL].prev;
        std.debug.assert(lru_idx != LRU_SENTINEL_HEAD);

        return self.evictColdNode(lru_idx);
    }

    pub fn evictLruNotUsedInFrame(self: *GlyphCache, protected_frame: u32) ?EvictedEntry {
        if (self.cold_count == 0) return null;

        var idx = self.lru_nodes[LRU_SENTINEL_TAIL].prev;
        while (idx != LRU_SENTINEL_HEAD) {
            const key = self.lru_nodes[idx].key;
            const entry = self.map.get(key) orelse unreachable;
            if (entry.last_frame != protected_frame) return self.evictColdNode(idx);
            idx = self.lru_nodes[idx].prev;
        }

        return null;
    }

    fn evictColdNode(self: *GlyphCache, lru_idx: u32) EvictedEntry {
        const key = self.lru_nodes[lru_idx].key;
        self.lruUnlink(lru_idx);
        self.lruFree(lru_idx);

        const removed = self.map.fetchRemove(key) orelse unreachable;
        self.cold_count -= 1;
        var metadata = removed.value.mesh_metadata;
        metadata.deinit(self.allocator);

        return .{
            .key = key,
            .blob_ref = removed.value.blob_ref,
            .pool_alloc = removed.value.pool_alloc,
        };
    }

    /// Remove all cache entries for the given font_id.
    /// Returns caller-owned evicted entries; free the slice with the same allocator.
    pub fn removeFont(self: *GlyphCache, allocator: std.mem.Allocator, font_id: u32) ![]EvictedEntry {
        // Collect keys first; the hash map cannot be mutated during iteration.
        var to_remove: std.ArrayList(CacheKey) = .empty;
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
            // Safe: no map mutation occurs between collecting keys and removing them.
            const removed = self.map.fetchRemove(key).?;
            var metadata = removed.value.mesh_metadata;
            metadata.deinit(self.allocator);
            if (removed.value.tier == .hot) {
                self.hot_count -= 1;
            } else {
                self.lruUnlink(removed.value.lru_idx);
                self.lruFree(removed.value.lru_idx);
                self.cold_count -= 1;
            }
            evicted[i] = .{
                .key = key,
                .blob_ref = removed.value.blob_ref,
                .pool_alloc = removed.value.pool_alloc,
            };
        }
        return evicted;
    }
};

fn fixedBoundsFromEmBox(em_box: EmBox) FixedBounds {
    return .{
        .x_min = @intFromFloat(@floor(em_box.x_min)),
        .y_min = @intFromFloat(@floor(em_box.y_min)),
        .x_max = @intFromFloat(@ceil(em_box.x_max)),
        .y_max = @intFromFloat(@ceil(em_box.y_max)),
    };
}

fn testBlobRef(value: u32) GlyphBlobRef {
    return GlyphBlobRef.from(value);
}

test "GlyphBlobRef is a typed 32-bit backend resource reference" {
    const blob_ref = GlyphBlobRef.from(42);
    try std.testing.expectEqual(@as(usize, 4), @sizeOf(GlyphBlobRef));
    try std.testing.expectEqual(@as(u32, 42), blob_ref.value);
    try std.testing.expect(!blob_ref.isEmpty());
    try std.testing.expect(GlyphBlobRef.empty.isEmpty());
}

test "GlyphCache: insert and lookup track tiers, counts, and full keys" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const default_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const variation_box = EmBox{ .x_min = -1, .y_min = -2, .x_max = 10, .y_max = 12 };
    const hot_key = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const default_key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    const variation_key = CacheKey{ .font_id = 1, .glyph_id = 65, .variation_key = 7 };

    try cache.insertHot(hot_key, testBlobRef(0), .{ .offset = 0, .size = 64 }, default_box);
    try cache.insertCold(default_key, testBlobRef(1), .{ .offset = 64, .size = 64 }, default_box);
    try cache.insertCold(variation_key, testBlobRef(2), .{ .offset = 128, .size = 64 }, variation_box);

    try std.testing.expectEqual(@as(u32, 3), cache.count());
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 2), cache.cold_count);
    try std.testing.expectEqual(@as(?*CacheEntry, null), cache.lookup(.{ .font_id = 1, .glyph_id = 99 }));

    const hot = cache.lookup(hot_key).?;
    try std.testing.expectEqual(CacheTier.hot, hot.tier);
    try std.testing.expectEqual(testBlobRef(0), hot.blob_ref);

    const default_entry = cache.lookup(default_key).?;
    try std.testing.expectEqual(CacheTier.cold, default_entry.tier);
    try std.testing.expectEqual(testBlobRef(1), default_entry.blob_ref);
    try std.testing.expectEqual(@as(f32, 1), default_entry.em_box.x_max);

    const variation_entry = cache.lookup(variation_key).?;
    try std.testing.expectEqual(testBlobRef(2), variation_entry.blob_ref);
    try std.testing.expectEqual(@as(f32, -1), variation_entry.em_box.x_min);
    try std.testing.expectEqual(@as(f32, 12), variation_entry.em_box.y_max);
}

test "GlyphCache: cached mesh metadata is owned by cache entries" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 4, 3);
    defer cache.deinit();

    const bands = try std.testing.allocator.alloc(BandMeshInfo, 2);
    bands[0] = .{ .candidate_count = 3, .max_x_q = 10 };
    bands[1] = .{ .candidate_count = 0, .max_x_q = -2147483647 };

    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    const box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    try cache.insertColdWithMetadata(
        key,
        testBlobRef(1),
        .{ .offset = 0, .size = 64 },
        box,
        fixedBoundsFromEmBox(box),
        .{
            .curve_count = 7,
            .band_min = -1,
            .band_count = 2,
            .band_height_q = 16,
            .bands = bands,
        },
    );

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u32, 7), entry.mesh_metadata.curve_count);
    try std.testing.expectEqual(@as(i32, -1), entry.mesh_metadata.band_min);
    try std.testing.expectEqual(@as(u32, 2), entry.mesh_metadata.band_count);
    try std.testing.expectEqual(@as(u32, 3), entry.mesh_metadata.bands[0].candidate_count);
}

test "GlyphCache: evict LRU cold entry" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 2, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key1 = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key2 = CacheKey{ .font_id = 1, .glyph_id = 2 };

    try cache.insertCold(key1, testBlobRef(10), .{ .offset = 0, .size = 64 }, dummy_box);
    cache.current_frame = 1; // advance manually for insertion ordering
    try cache.insertCold(key2, testBlobRef(11), .{ .offset = 64, .size = 64 }, dummy_box);

    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key1, evicted.key);
    try std.testing.expectEqual(testBlobRef(10), evicted.blob_ref);
    try std.testing.expectEqual(@as(u32, 1), cache.cold_count);
}

test "GlyphCache: evict returns null when no cold entries" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    try cache.insertHot(.{ .font_id = 1, .glyph_id = 1 }, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);

    try std.testing.expectEqual(@as(?EvictedEntry, null), cache.evictLru());
}

test "GlyphCache: evict prefers least recently used" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 4, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key_a = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_b = CacheKey{ .font_id = 1, .glyph_id = 2 };
    const key_c = CacheKey{ .font_id = 1, .glyph_id = 3 };

    try cache.insertCold(key_a, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(key_b, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);
    try cache.insertCold(key_c, testBlobRef(2), .{ .offset = 128, .size = 64 }, dummy_box);

    cache.current_frame = 5;
    _ = cache.lookup(key_a);

    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key_b, evicted.key);
}

test "GlyphCache: consecutive frame tracking" {
    var cache = try GlyphCache.init(std.testing.allocator, 0, 8, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);

    var entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 1), entry.consecutive_frames);

    cache.advanceFrame();
    entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 2), entry.consecutive_frames);

    cache.advanceFrame();
    entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 3), entry.consecutive_frames);

    cache.advanceFrame();
    cache.advanceFrame();
    entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 1), entry.consecutive_frames); // reset after gap
}

test "GlyphCache: cold promoted to hot when lookup reaches frame threshold" {
    var cache = try GlyphCache.init(std.testing.allocator, 4, 8, 3); // promote after 3 frames
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    cache.advanceFrame(); // frame 1
    _ = cache.lookup(key); // consecutive = 2

    cache.advanceFrame(); // frame 2
    _ = cache.lookup(key); // consecutive = 3, promotion happens immediately

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(CacheTier.hot, entry.tier);
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 0), cache.cold_count);
    try std.testing.expectEqual(@as(u32, 1), cache.frame_promotions);
}

test "GlyphCache: promotion skipped when hot tier full" {
    var cache = try GlyphCache.init(std.testing.allocator, 1, 8, 2); // hot capacity = 1
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    try cache.insertHot(.{ .font_id = 1, .glyph_id = 1 }, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);

    const cold_key = CacheKey{ .font_id = 1, .glyph_id = 2 };
    try cache.insertCold(cold_key, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);

    cache.advanceFrame();
    _ = cache.lookup(cold_key);
    cache.advanceFrame();
    _ = cache.lookup(cold_key);
    cache.advanceFrame(); // threshold was reached, but hot is full

    const entry = cache.lookup(cold_key).?;
    try std.testing.expectEqual(CacheTier.cold, entry.tier); // stays cold
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 1), cache.cold_count);
}

test "GlyphCache: removeFont evicts all entries for a font" {
    var gc = try GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer gc.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    try gc.insertHot(.{ .font_id = 1, .glyph_id = 65 }, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try gc.insertCold(.{ .font_id = 1, .glyph_id = 66 }, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);
    try gc.insertHot(.{ .font_id = 2, .glyph_id = 65 }, testBlobRef(2), .{ .offset = 128, .size = 64 }, dummy_box);
    try std.testing.expectEqual(@as(u32, 3), gc.count());

    const evicted = try gc.removeFont(std.testing.allocator, 1);
    defer std.testing.allocator.free(evicted);

    try std.testing.expectEqual(@as(usize, 2), evicted.len);
    const has_slot_0 = for (evicted) |e| {
        if (e.blob_ref.value == 0) break true;
    } else false;
    const has_slot_1 = for (evicted) |e| {
        if (e.blob_ref.value == 1) break true;
    } else false;
    try std.testing.expect(has_slot_0);
    try std.testing.expect(has_slot_1);
    try std.testing.expectEqual(@as(u32, 1), gc.count()); // only font 2 remains
    try std.testing.expectEqual(@as(u32, 1), gc.hot_count); // font 2's hot entry
    try std.testing.expectEqual(@as(u32, 0), gc.cold_count); // font 1's cold entry removed

    try std.testing.expect(gc.lookup(.{ .font_id = 2, .glyph_id = 65 }) != null);
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
    try cache.insertCold(key, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);

    _ = cache.lookup(key);
    _ = cache.lookup(key);
    _ = cache.lookup(key);

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(@as(u8, 1), entry.consecutive_frames); // still 1
}

test "GlyphCache: frame counter overflow does not break LRU" {
    // At 60fps, current_frame (u32) overflows in ~2.3 years.
    // Wrapping subtraction must be used so older frames still sort correctly.
    const allocator = std.testing.allocator;
    var cache = try GlyphCache.init(allocator, 4, 4, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 64, .y_max = 64 };
    const key_old = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_new = CacheKey{ .font_id = 1, .glyph_id = 2 };

    cache.current_frame = std.math.maxInt(u32) - 2;
    try cache.insertCold(key_old, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);

    cache.advanceFrame(); // maxInt - 1
    cache.advanceFrame(); // maxInt
    cache.advanceFrame(); // wraps to 0
    try cache.insertCold(key_new, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);

    // key_old (inserted at maxInt-2) must be evicted as the oldest.
    // With correct wrapping, its age = 0 -% (maxInt-2) = 3 (wrapping sub), which is > key_new's age of 0.
    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key_old, evicted.key);
}

test "GlyphCache: eviction order matches access recency" {
    var cache = try GlyphCache.init(std.testing.allocator, 0, 4, 3);
    defer cache.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 1 }, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 2 }, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 3 }, testBlobRef(2), .{ .offset = 128, .size = 64 }, dummy_box);
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 4 }, testBlobRef(3), .{ .offset = 192, .size = 64 }, dummy_box);

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

    try cache.insertCold(key_a, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(key_b, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);
    try cache.insertCold(key_c, testBlobRef(2), .{ .offset = 128, .size = 64 }, dummy_box);

    cache.advanceFrame();
    _ = cache.lookup(key_a);

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

    try cache.insertCold(key_a, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try cache.insertCold(key_b, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);

    cache.advanceFrame();
    _ = cache.lookup(key_a);
    cache.advanceFrame();

    const evicted = cache.evictLru().?;
    try std.testing.expectEqual(key_b, evicted.key);
    try std.testing.expectEqual(@as(?EvictedEntry, null), cache.evictLru());
}

test "GlyphCache: promotion is not capped by a fixed per-frame queue" {
    var cache_inst = try GlyphCache.init(std.testing.allocator, 80, 80, 2);
    defer cache_inst.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    var glyph_id: u32 = 0;
    while (glyph_id < 80) : (glyph_id += 1) {
        const key = CacheKey{ .font_id = 1, .glyph_id = glyph_id };
        try cache_inst.insertCold(key, testBlobRef(glyph_id), .{ .offset = glyph_id * 64, .size = 64 }, dummy_box);
    }

    cache_inst.advanceFrame();
    glyph_id = 0;
    while (glyph_id < 80) : (glyph_id += 1) {
        _ = cache_inst.lookup(.{ .font_id = 1, .glyph_id = glyph_id });
    }

    try std.testing.expectEqual(@as(u32, 80), cache_inst.hot_count);
    try std.testing.expectEqual(@as(u32, 0), cache_inst.cold_count);
    try std.testing.expectEqual(CacheTier.hot, cache_inst.lookup(.{ .font_id = 1, .glyph_id = 79 }).?.tier);
}

test "GlyphCache: same-frame lookups skip LRU touch" {
    // Same-frame duplicate lookups must not disturb eviction order.
    var cache_inst = try GlyphCache.init(std.testing.allocator, 0, 3, 3);
    defer cache_inst.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key_a = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_b = CacheKey{ .font_id = 1, .glyph_id = 2 };
    const key_c = CacheKey{ .font_id = 1, .glyph_id = 3 };

    try cache_inst.insertCold(key_a, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try cache_inst.insertCold(key_b, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);
    try cache_inst.insertCold(key_c, testBlobRef(2), .{ .offset = 128, .size = 64 }, dummy_box);

    cache_inst.advanceFrame();

    _ = cache_inst.lookup(key_a);

    _ = cache_inst.lookup(key_a);

    try std.testing.expectEqual(key_b, cache_inst.evictLru().?.key);
    try std.testing.expectEqual(key_c, cache_inst.evictLru().?.key);
    try std.testing.expectEqual(key_a, cache_inst.evictLru().?.key);
}

test "GlyphCache: evictLruNotUsedInFrame protects current frame entries" {
    var cache_inst = try GlyphCache.init(std.testing.allocator, 0, 3, 3);
    defer cache_inst.deinit();

    const dummy_box = EmBox{ .x_min = 0, .y_min = 0, .x_max = 1, .y_max = 1 };
    const key_a = CacheKey{ .font_id = 1, .glyph_id = 1 };
    const key_b = CacheKey{ .font_id = 1, .glyph_id = 2 };
    const key_c = CacheKey{ .font_id = 1, .glyph_id = 3 };

    try cache_inst.insertCold(key_a, testBlobRef(0), .{ .offset = 0, .size = 64 }, dummy_box);
    try cache_inst.insertCold(key_b, testBlobRef(1), .{ .offset = 64, .size = 64 }, dummy_box);
    try cache_inst.insertCold(key_c, testBlobRef(2), .{ .offset = 128, .size = 64 }, dummy_box);

    cache_inst.advanceFrame();
    _ = cache_inst.lookup(key_a);
    _ = cache_inst.lookup(key_b);

    const evicted = cache_inst.evictLruNotUsedInFrame(cache_inst.current_frame).?;
    try std.testing.expectEqual(key_c, evicted.key);

    _ = cache_inst.lookup(key_a);
    _ = cache_inst.lookup(key_b);
    try std.testing.expectEqual(@as(?EvictedEntry, null), cache_inst.evictLruNotUsedInFrame(cache_inst.current_frame));
}
