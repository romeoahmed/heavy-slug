//! Glyph cache, byte pool, and deferred retirement utilities.

pub const glyph_cache = @import("glyph_cache.zig");
pub const byte_pool = @import("byte_pool.zig");
pub const retirement = @import("retirement.zig");

pub const GlyphCache = glyph_cache.GlyphCache;
pub const GlyphBlobRef = glyph_cache.GlyphBlobRef;
pub const CacheKey = glyph_cache.CacheKey;
pub const CacheEntry = glyph_cache.CacheEntry;
pub const CacheTier = glyph_cache.CacheTier;
pub const EmBox = glyph_cache.EmBox;
pub const EvictedEntry = glyph_cache.EvictedEntry;
pub const PoolAllocator = byte_pool.PoolAllocator;
pub const Allocation = byte_pool.Allocation;
pub const DeferredRetirementQueue = retirement.DeferredRetirementQueue;

test {
    _ = glyph_cache;
    _ = byte_pool;
    _ = retirement;
}
