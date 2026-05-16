//! Backend-neutral glyph cache, byte pool, and deferred retirement state.

const std = @import("std");
const cache_mod = @import("../cache/glyph_cache.zig");
const pool_mod = @import("../cache/byte_pool.zig");
const retirement_mod = @import("../cache/retirement.zig");
const core_render = @import("renderer_core.zig");

pub const FrameToken = u64;
pub const GlyphBlobRef = cache_mod.GlyphBlobRef;

pub const RetiredGlyph = struct {
    blob_ref: GlyphBlobRef,
    pool_alloc: pool_mod.Allocation,
};

const RetirementQueue = retirement_mod.DeferredRetirementQueue(FrameToken, RetiredGlyph);

pub const GlyphStore = struct {
    glyph_cache: cache_mod.GlyphCache,
    pool_alloc: pool_mod.PoolAllocator,
    retirements: RetirementQueue,
    retire_after_token: FrameToken,

    pub fn init(allocator: std.mem.Allocator, options: core_render.RendererOptions) !GlyphStore {
        var glyph_cache = try cache_mod.GlyphCache.init(
            allocator,
            options.hot_slab_count,
            options.cold_lru_count,
            options.promote_frames,
        );
        errdefer glyph_cache.deinit();
        const total_cache_capacity = options.hot_slab_count + options.cold_lru_count;
        try glyph_cache.map.ensureTotalCapacity(total_cache_capacity);

        var pool_alloc = pool_mod.PoolAllocator.init(
            allocator,
            options.pool_buffer_size,
            options.min_storage_alignment,
        );
        errdefer pool_alloc.deinit();
        try pool_alloc.free_blocks.ensureTotalCapacity(allocator, total_cache_capacity);

        var retirements = RetirementQueue.init(allocator);
        errdefer retirements.deinit();
        try retirements.entries.ensureTotalCapacity(allocator, total_cache_capacity);

        return .{
            .glyph_cache = glyph_cache,
            .pool_alloc = pool_alloc,
            .retirements = retirements,
            .retire_after_token = 0,
        };
    }

    pub fn deinit(self: *GlyphStore) void {
        self.retirements.deinit();
        self.pool_alloc.deinit();
        self.glyph_cache.deinit();
        self.* = undefined;
    }

    pub fn beginFrame(self: *GlyphStore, completed_token: FrameToken, backend: anytype) u32 {
        const retired = self.retireCompleted(completed_token, backend);
        self.glyph_cache.advanceFrame();
        return retired;
    }

    pub fn setRetireAfterToken(self: *GlyphStore, token: FrameToken) void {
        self.retire_after_token = token;
    }

    pub fn retireCompleted(self: *GlyphStore, completed_token: FrameToken, backend: anytype) u32 {
        const Retiree = struct {
            store: *GlyphStore,
            backend: @TypeOf(backend),

            pub fn retire(retiree: *@This(), retired: RetiredGlyph) void {
                if (!retired.blob_ref.isEmpty()) retiree.backend.retireBlob(retired.blob_ref);
                if (retired.pool_alloc.size > 0) retiree.store.pool_alloc.free(retired.pool_alloc);
            }
        };

        var retiree = Retiree{ .store = self, .backend = backend };
        return self.retirements.retireCompleted(completed_token, &retiree);
    }

    pub fn deferEvicted(self: *GlyphStore, evicted: cache_mod.EvictedEntry) !bool {
        if (evicted.blob_ref.isEmpty() and evicted.pool_alloc.size == 0) return false;
        try self.retirements.push(self.retire_after_token, .{
            .blob_ref = evicted.blob_ref,
            .pool_alloc = evicted.pool_alloc,
        });
        return true;
    }

    pub fn poolSnapshot(self: *const GlyphStore) pool_mod.Snapshot {
        return self.pool_alloc.snapshot();
    }
};

test "GlyphStore defers evicted resources until completed token" {
    var store = try GlyphStore.init(std.testing.allocator, .{ .hot_slab_count = 0, .cold_lru_count = 1 });
    defer store.deinit();

    const Retiree = struct {
        releases: u32 = 0,

        pub fn retireBlob(self: *@This(), _: GlyphBlobRef) void {
            self.releases += 1;
        }
    };
    var retiree = Retiree{};

    try std.testing.expect(try store.deferEvicted(.{
        .key = .{ .font_id = 1, .glyph_id = 1 },
        .blob_ref = GlyphBlobRef.from(9),
        .pool_alloc = .{ .offset = 0, .size = 0 },
    }));
    const retired = store.retireCompleted(0, &retiree);
    try std.testing.expectEqual(@as(u32, 1), retiree.releases);
    try std.testing.expectEqual(@as(u32, 1), retired);
}
