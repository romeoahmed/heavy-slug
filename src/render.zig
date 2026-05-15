const std = @import("std");
const cache_mod = @import("cache/glyph.zig");
const pool_mod = @import("cache/pool.zig");
const font_mod = @import("font/root.zig");
const glyph_mod = @import("font/glyph.zig");
const hb = font_mod.hb;
const ft = font_mod.ft;
const pga = @import("math/pga.zig");

pub const empty_glyph_ref = std.math.maxInt(u32);

pub const Error = error{
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
};

pub const Options = struct {
    max_glyph_descriptors: u32 = 65_536,
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    min_storage_alignment: u32 = 256,
};

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    evictions: u32 = 0,
    glyphs_submitted: u32 = 0,
    pool_free_blocks: u32 = 0,

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This(), comptime scope: anytype) void {
        std.log.scoped(scope).debug(
            "frame stats: hits={d} misses={d} evictions={d} glyphs={d} free_blocks={d}",
            .{ self.cache_hits, self.cache_misses, self.evictions, self.glyphs_submitted, self.pool_free_blocks },
        );
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This(), comptime _: anytype) void {}
};

pub const FontHandle = struct {
    id: u32,
};

const FontEntry = struct {
    ctx: glyph_mod.FontContext,
};

const CachedGlyph = struct {
    ref: u32,
    em_box: cache_mod.EmBox,
};

pub fn emBoxFromExtents(ext: hb.GlyphExtents) cache_mod.EmBox {
    const x0: f32 = @floatFromInt(ext.x_bearing);
    const y0: f32 = @floatFromInt(ext.y_bearing);
    const x1 = x0 + @as(f32, @floatFromInt(ext.width));
    const y1 = y0 + @as(f32, @floatFromInt(ext.height));
    return .{
        .x_min = @min(x0, x1),
        .y_min = @min(y0, y1),
        .x_max = @max(x0, x1),
        .y_max = @max(y0, y1),
    };
}

pub fn motorToEm(motor: pga.Motor) pga.Motor {
    return .{ .m = .{
        motor.m[0],
        motor.m[1],
        motor.m[2] * 64.0,
        motor.m[3] * 64.0,
    } };
}

pub fn projectionToEm(proj: [4][4]f32) [4][4]f32 {
    var result = proj;
    for (0..4) |j| {
        result[0][j] /= 64.0;
        result[1][j] /= 64.0;
    }
    return result;
}

pub const TextCore = struct {
    glyph_cache: cache_mod.GlyphCache,
    pool_alloc: pool_mod.PoolAllocator,
    ft_library: ft.Library,
    fonts: std.AutoHashMap(u32, *FontEntry),
    next_font_id: u32,
    glyph_count: u32,
    flush_base: u32,
    max_glyphs_per_frame: u32,
    shape_buffer: hb.Buffer,
    stats: Stats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: Options) !TextCore {
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

        const ft_library = try ft.Library.init();
        errdefer ft_library.deinit();

        const shape_buffer = try hb.Buffer.create();
        errdefer shape_buffer.destroy();

        return .{
            .glyph_cache = glyph_cache,
            .pool_alloc = pool_alloc,
            .ft_library = ft_library,
            .fonts = std.AutoHashMap(u32, *FontEntry).init(allocator),
            .next_font_id = 0,
            .glyph_count = 0,
            .flush_base = 0,
            .max_glyphs_per_frame = options.max_glyphs_per_frame,
            .shape_buffer = shape_buffer,
            .stats = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *TextCore) void {
        var font_it = self.fonts.valueIterator();
        while (font_it.next()) |entry_ptr| {
            entry_ptr.*.ctx.deinit();
            self.allocator.destroy(entry_ptr.*);
        }
        self.fonts.deinit();
        self.shape_buffer.destroy();
        self.ft_library.deinit();
        self.pool_alloc.deinit();
        self.glyph_cache.deinit();
        self.* = undefined;
    }

    pub fn loadFont(self: *TextCore, path: [*:0]const u8, size_px: u32) !FontHandle {
        const entry = try self.allocator.create(FontEntry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{ .ctx = try glyph_mod.FontContext.init(self.ft_library, path, size_px) };
        errdefer entry.ctx.deinit();

        const id = self.next_font_id;
        try self.fonts.put(id, entry);
        self.next_font_id += 1;
        return .{ .id = id };
    }

    pub fn unloadFont(self: *TextCore, backend: anytype, handle: FontHandle) void {
        const evicted = self.glyph_cache.removeFont(self.allocator, handle.id) catch &.{};
        for (evicted) |entry| self.releaseEvicted(backend, entry);
        if (evicted.len > 0) self.allocator.free(evicted);

        if (self.fonts.fetchRemove(handle.id)) |removed| {
            removed.value.ctx.deinit();
            self.allocator.destroy(removed.value);
        }
    }

    pub fn begin(self: *TextCore) void {
        self.glyph_count = 0;
        self.flush_base = 0;
        self.glyph_cache.advanceFrame();
        self.stats.reset();
    }

    pub fn passCount(self: *const TextCore) u32 {
        return self.glyph_count - self.flush_base;
    }

    pub fn finishPass(self: *TextCore) void {
        self.flush_base = self.glyph_count;
    }

    pub fn appendText(
        self: *TextCore,
        backend: anytype,
        comptime Command: type,
        commands: [*]Command,
        font: FontHandle,
        text: []const u8,
        motor: pga.Motor,
        color: [4]f32,
    ) !void {
        const font_entry = self.fonts.get(font.id) orelse return Error.ShapingFailed;

        self.shape_buffer.reset();
        self.shape_buffer.addUtf8(text);
        self.shape_buffer.guessSegmentProperties();
        hb.shape(font_entry.ctx.hb_font, self.shape_buffer);

        const infos = self.shape_buffer.getGlyphInfos();
        const positions = self.shape_buffer.getGlyphPositions();
        const em_motor = motorToEm(motor);
        const start_count = self.glyph_count;
        errdefer self.glyph_count = start_count;

        var pen_x: f32 = 0;
        var pen_y: f32 = 0;

        for (infos, positions) |info, pos| {
            const glyph_x = pen_x + @as(f32, @floatFromInt(pos.x_offset));
            const glyph_y = pen_y + @as(f32, @floatFromInt(pos.y_offset));
            const glyph_motor = em_motor.composeTranslation(glyph_x, glyph_y);

            const cache_key = cache_mod.CacheKey{
                .font_id = font.id,
                .glyph_id = info.codepoint,
            };
            const cached_glyph = if (self.glyph_cache.lookup(cache_key)) |entry| blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_hits += 1;
                break :blk CachedGlyph{ .ref = entry.slot, .em_box = entry.em_box };
            } else blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_misses += 1;
                break :blk try self.ensureGlyphCached(backend, font_entry, cache_key);
            };

            if (cached_glyph.ref != empty_glyph_ref) {
                if (self.glyph_count >= self.max_glyphs_per_frame) return Error.GlyphCapacityExceeded;
                commands[self.glyph_count] = .{
                    .motor = glyph_motor.m,
                    .color = color,
                    .em_x_min = cached_glyph.em_box.x_min,
                    .em_y_min = cached_glyph.em_box.y_min,
                    .em_x_max = cached_glyph.em_box.x_max,
                    .em_y_max = cached_glyph.em_box.y_max,
                    .descriptor_index = cached_glyph.ref,
                    .flags = 0,
                };
                self.glyph_count += 1;
            }

            pen_x += @as(f32, @floatFromInt(pos.x_advance));
            pen_y += @as(f32, @floatFromInt(pos.y_advance));
        }
    }

    fn ensureGlyphCached(
        self: *TextCore,
        backend: anytype,
        font_entry: *FontEntry,
        cache_key: cache_mod.CacheKey,
    ) !CachedGlyph {
        const encoded = font_entry.ctx.encodeGlyph(cache_key.glyph_id) catch
            return Error.ShapingFailed;
        defer encoded.destroy();

        const em_box = emBoxFromExtents(encoded.extents);

        if (self.glyph_cache.cold_count >= self.glyph_cache.cold_capacity) {
            if (self.glyph_cache.evictLruNotUsedInFrame(self.glyph_cache.current_frame)) |evicted| {
                if (@import("builtin").mode == .Debug) self.stats.evictions += 1;
                self.releaseEvicted(backend, evicted);
            } else return Error.PoolExhausted;
        }

        if (encoded.data.len == 0) {
            try self.glyph_cache.insertCold(cache_key, empty_glyph_ref, .{ .offset = 0, .size = 0 }, em_box);
            return .{ .ref = empty_glyph_ref, .em_box = em_box };
        }

        const pool_alloc = self.pool_alloc.alloc(@intCast(encoded.data.len)) orelse
            return Error.PoolExhausted;
        errdefer self.pool_alloc.free(pool_alloc);

        const glyph_ref = try backend.uploadGlyphBlob(pool_alloc, encoded.data);
        errdefer backend.releaseGlyphRef(glyph_ref);

        try self.glyph_cache.insertCold(cache_key, glyph_ref, pool_alloc, em_box);
        return .{ .ref = glyph_ref, .em_box = em_box };
    }

    fn releaseEvicted(self: *TextCore, backend: anytype, evicted: cache_mod.EvictedEntry) void {
        if (evicted.slot != empty_glyph_ref) backend.releaseGlyphRef(evicted.slot);
        if (evicted.pool_alloc.size > 0) self.pool_alloc.free(evicted.pool_alloc);
    }
};

const TestCommand = extern struct {
    motor: [4]f32,
    color: [4]f32,
    em_x_min: f32,
    em_y_min: f32,
    em_x_max: f32,
    em_y_max: f32,
    descriptor_index: u32,
    flags: u32,
    _pad: [2]u32 = .{ 0, 0 },
};

const FakeBackend = struct {
    pool: []u8,
    next_ref: u32 = 0,
    releases: u32 = 0,

    fn uploadGlyphBlob(self: *FakeBackend, allocation: pool_mod.Allocation, data: []const u8) !u32 {
        @memcpy(self.pool[allocation.offset..][0..data.len], data);
        const ref = self.next_ref;
        self.next_ref += 1;
        return ref;
    }

    fn releaseGlyphRef(self: *FakeBackend, _: u32) void {
        self.releases += 1;
    }
};

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test "render: projectionToEm scales x and y rows only" {
    const proj = [4][4]f32{
        .{ 64, 128, 192, 256 },
        .{ -64, -128, -192, -256 },
        .{ 1, 2, 3, 4 },
        .{ 5, 6, 7, 8 },
    };
    const em = projectionToEm(proj);
    try std.testing.expectEqual(@as(f32, 1), em[0][0]);
    try std.testing.expectEqual(@as(f32, -1), em[1][0]);
    try std.testing.expectEqual(@as(f32, 3), em[2][2]);
    try std.testing.expectEqual(@as(f32, 8), em[3][3]);
}

test "render: TextCore appends shaped glyph commands and caches blobs" {
    var core = try TextCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 16 });
    defer core.deinit();

    var pool: [4096]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [16]TestCommand = undefined;

    const font = try core.loadFont(test_font_path, 24);
    core.begin();
    try core.appendText(&backend, TestCommand, &commands, font, "Hi", pga.Motor.fromTranslation(10, 20), .{ 1, 1, 1, 1 });

    try std.testing.expect(core.glyph_count > 0);
    try std.testing.expect(backend.next_ref > 0);
    try std.testing.expect(commands[0].descriptor_index != empty_glyph_ref);
    try std.testing.expect(commands[0].motor[2] != 0);

    const refs_after_first = backend.next_ref;
    try core.appendText(&backend, TestCommand, &commands, font, "Hi", pga.Motor.fromTranslation(10, 20), .{ 1, 1, 1, 1 });
    try std.testing.expectEqual(refs_after_first, backend.next_ref);
}

test "render: TextCore skips empty glyph commands while preserving cache entry" {
    var core = try TextCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [4096]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [4]TestCommand = undefined;

    const font = try core.loadFont(test_font_path, 24);
    core.begin();
    try core.appendText(&backend, TestCommand, &commands, font, " ", pga.Motor.fromTranslation(0, 0), .{ 1, 1, 1, 1 });

    try std.testing.expectEqual(@as(u32, 0), core.glyph_count);
    try std.testing.expectEqual(@as(u32, 0), backend.next_ref);
    try std.testing.expect(core.glyph_cache.count() > 0);
}

test "render: TextCore enforces command capacity after skipping empty glyphs" {
    var core = try TextCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 1 });
    defer core.deinit();

    var pool: [4096]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [1]TestCommand = undefined;

    const font = try core.loadFont(test_font_path, 24);
    core.begin();
    try std.testing.expectError(
        Error.GlyphCapacityExceeded,
        core.appendText(&backend, TestCommand, &commands, font, "HH", pga.Motor.fromTranslation(0, 0), .{ 1, 1, 1, 1 }),
    );
    try std.testing.expectEqual(@as(u32, 0), core.glyph_count);
}
