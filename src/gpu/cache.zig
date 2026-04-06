const std = @import("std");
const pool_mod = @import("pool.zig");

pub const CacheKey = struct {
    font_id: u32,
    glyph_id: u32,
};

pub const Tier = enum { hot, cold };

pub const CacheEntry = struct {
    slot: u32,
    pool_alloc: pool_mod.Allocation,
    tier: Tier,
    last_frame: u32,
    consecutive_frames: u8,
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

    pub fn init(
        allocator: std.mem.Allocator,
        hot_capacity: u32,
        cold_capacity: u32,
        promote_frames: u8,
    ) GlyphCache {
        return .{
            .map = std.AutoHashMap(CacheKey, CacheEntry).init(allocator),
            .hot_count = 0,
            .cold_count = 0,
            .hot_capacity = hot_capacity,
            .cold_capacity = cold_capacity,
            .current_frame = 0,
            .promote_frames = promote_frames,
        };
    }

    pub fn deinit(self: *GlyphCache) void {
        self.map.deinit();
        self.* = undefined;
    }

    pub fn count(self: *const GlyphCache) u32 {
        return self.hot_count + self.cold_count;
    }

    /// Insert a glyph into the hot tier. Caller must ensure hot tier has capacity.
    pub fn insertHot(
        self: *GlyphCache,
        key: CacheKey,
        slot: u32,
        pool_alloc: pool_mod.Allocation,
    ) !void {
        std.debug.assert(self.hot_count < self.hot_capacity);
        try self.map.put(key, .{
            .slot = slot,
            .pool_alloc = pool_alloc,
            .tier = .hot,
            .last_frame = self.current_frame,
            .consecutive_frames = 1,
        });
        self.hot_count += 1;
    }

    /// Insert a glyph into the cold tier. Caller must ensure cold tier has capacity
    /// (evict first if full).
    pub fn insertCold(
        self: *GlyphCache,
        key: CacheKey,
        slot: u32,
        pool_alloc: pool_mod.Allocation,
    ) !void {
        std.debug.assert(self.cold_count < self.cold_capacity);
        try self.map.put(key, .{
            .slot = slot,
            .pool_alloc = pool_alloc,
            .tier = .cold,
            .last_frame = self.current_frame,
            .consecutive_frames = 1,
        });
        self.cold_count += 1;
    }

    /// Look up a cached glyph. On hit, updates frame tracking for LRU and promotion.
    /// Returns a mutable pointer into the map — valid until next map mutation.
    pub fn lookup(self: *GlyphCache, key: CacheKey) ?*CacheEntry {
        const entry = self.map.getPtr(key) orelse return null;
        // Update consecutive-frame tracking
        if (entry.last_frame == self.current_frame) {
            // Already counted this frame — no-op
        } else if (self.current_frame > 0 and entry.last_frame == self.current_frame - 1) {
            entry.consecutive_frames +|= 1; // saturating add (u8)
        } else {
            entry.consecutive_frames = 1; // gap in usage — reset streak
        }
        entry.last_frame = self.current_frame;
        return entry;
    }
};

test "GlyphCache: init and deinit" {
    var cache = GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();
    try std.testing.expectEqual(@as(u32, 0), cache.count());
}

test "GlyphCache: insert hot and lookup" {
    var cache = GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertHot(key, 0, .{ .offset = 0, .size = 128 });

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(Tier.hot, entry.tier);
    try std.testing.expectEqual(@as(u32, 0), entry.slot);
}

test "GlyphCache: insert cold and lookup" {
    var cache = GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    const key = CacheKey{ .font_id = 1, .glyph_id = 65 };
    try cache.insertCold(key, 5, .{ .offset = 64, .size = 200 });

    const entry = cache.lookup(key).?;
    try std.testing.expectEqual(Tier.cold, entry.tier);
    try std.testing.expectEqual(@as(u32, 5), entry.slot);
}

test "GlyphCache: lookup miss returns null" {
    var cache = GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    try std.testing.expectEqual(
        @as(?*CacheEntry, null),
        cache.lookup(.{ .font_id = 1, .glyph_id = 99 }),
    );
}

test "GlyphCache: count tracks hot and cold" {
    var cache = GlyphCache.init(std.testing.allocator, 4, 8, 3);
    defer cache.deinit();

    try cache.insertHot(.{ .font_id = 1, .glyph_id = 1 }, 0, .{ .offset = 0, .size = 64 });
    try cache.insertCold(.{ .font_id = 1, .glyph_id = 2 }, 1, .{ .offset = 64, .size = 64 });

    try std.testing.expectEqual(@as(u32, 2), cache.count());
    try std.testing.expectEqual(@as(u32, 1), cache.hot_count);
    try std.testing.expectEqual(@as(u32, 1), cache.cold_count);
}
