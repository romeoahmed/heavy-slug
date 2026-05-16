//! Core text rendering orchestration shared by all GPU backends.

const std = @import("std");
const cache_mod = @import("../cache/glyph_cache.zig");
const pool_mod = @import("../cache/byte_pool.zig");
const blob_format = @import("../blob/format.zig");
const font_mod = @import("../font/root.zig");
const glyph_store_mod = @import("glyph_store.zig");
const backend_contract = @import("backend_contract.zig");
const text_batch_mod = @import("text_batch.zig");
const core_types = @import("../types.zig");
const units = @import("../units.zig");
const hb = font_mod.hb;
const pga = @import("../../math/pga.zig");

pub const GlyphRef = cache_mod.GlyphRef;

pub const Error = error{
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
};

pub const RendererOptions = struct {
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    min_storage_alignment: u32 = 256,
};

pub const TextRun = struct {
    font: core_types.FontHandle,
    text: []const u8,
    transform: core_types.Transform = .identity,
    color: core_types.Color = .black,
    fill_rule: core_types.FillRule = .non_zero,
};

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    runs_shaped: u32 = 0,
    glyphs_shaped: u32 = 0,
    commands_written: u32 = 0,
    empty_glyphs_skipped: u32 = 0,
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    glyphs_encoded: u32 = 0,
    outline_segments: u32 = 0,
    regularized_spans: u32 = 0,
    blob_bytes_uploaded: u64 = 0,
    evictions: u32 = 0,
    retirements_queued: u32 = 0,
    retirements_completed: u32 = 0,
    pool_alloc_failures: u32 = 0,
    glyphs_submitted: u32 = 0,
    pool: pool_mod.Snapshot = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This(), comptime scope: anytype) void {
        std.log.scoped(scope).debug(
            "core stats: runs={d} shaped={d} commands={d} empty={d} hits={d} misses={d} encoded={d} spans={d} upload_bytes={d} evictions={d} retire_q={d} retire_done={d} pool_used={d} pool_free={d} largest_free={d} free_blocks={d}",
            .{
                self.runs_shaped,
                self.glyphs_shaped,
                self.commands_written,
                self.empty_glyphs_skipped,
                self.cache_hits,
                self.cache_misses,
                self.glyphs_encoded,
                self.regularized_spans,
                self.blob_bytes_uploaded,
                self.evictions,
                self.retirements_queued,
                self.retirements_completed,
                self.pool.used_bytes,
                self.pool.free_bytes,
                self.pool.largest_free_block,
                self.pool.free_blocks,
            },
        );
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This(), comptime _: anytype) void {}
};

pub const FontHandle = core_types.FontHandle;
pub const FrameToken = glyph_store_mod.FrameToken;

const FontEntry = struct {
    loaded: font_mod.LoadedFont,
    variation_key: u64,
};

const CachedGlyph = struct {
    ref: GlyphRef,
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

pub fn emBoxFromBlobBounds(blob: blob_format.CoverageBlob) cache_mod.EmBox {
    std.debug.assert(blob.texels.len >= blob_format.header_len);
    const bounds = blob.texels[0];
    return .{
        .x_min = units.blobUnitsToPixels(bounds.r),
        .y_min = units.blobUnitsToPixels(bounds.g),
        .x_max = units.blobUnitsToPixels(bounds.b),
        .y_max = units.blobUnitsToPixels(bounds.a),
    };
}

pub fn motorToEm(motor: pga.Motor) pga.Motor {
    return units.motorPixelsToHb26p6(motor);
}

pub fn projectionToEm(proj: [4][4]f32) [4][4]f32 {
    return units.projectionPixelsToHb26p6(proj);
}

pub const RendererCore = struct {
    store: glyph_store_mod.GlyphStore,
    font_system: font_mod.FontSystem,
    fonts: std.AutoHashMap(u32, *FontEntry),
    next_font_id: u32,
    max_glyphs_per_frame: u32,
    shape_plan: font_mod.ShapePlan,
    stats: Stats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: RendererOptions) !RendererCore {
        var store = try glyph_store_mod.GlyphStore.init(allocator, options);
        errdefer store.deinit();

        var font_system = try font_mod.FontSystem.init(allocator);
        errdefer font_system.deinit();

        var shape_plan = try font_mod.ShapePlan.init();
        errdefer shape_plan.deinit();

        return .{
            .store = store,
            .font_system = font_system,
            .fonts = std.AutoHashMap(u32, *FontEntry).init(allocator),
            .next_font_id = 0,
            .max_glyphs_per_frame = options.max_glyphs_per_frame,
            .shape_plan = shape_plan,
            .stats = .{},
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *RendererCore) void {
        var font_it = self.fonts.valueIterator();
        while (font_it.next()) |entry_ptr| {
            entry_ptr.*.loaded.deinit();
            self.allocator.destroy(entry_ptr.*);
        }
        self.fonts.deinit();
        self.shape_plan.deinit();
        self.font_system.deinit();
        self.store.deinit();
        self.* = undefined;
    }

    pub fn loadFont(
        self: *RendererCore,
        source: core_types.FontSource,
        options: core_types.FontOptions,
    ) !FontHandle {
        const entry = try self.allocator.create(FontEntry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .loaded = try self.font_system.load(source, options),
            .variation_key = options.variation_key,
        };
        errdefer entry.loaded.deinit();

        const id = self.next_font_id;
        try self.fonts.put(id, entry);
        self.next_font_id += 1;
        return .{ .id = id };
    }

    pub fn unloadFont(self: *RendererCore, handle: FontHandle) !void {
        const evicted = try self.store.glyph_cache.removeFont(self.allocator, handle.id);
        defer if (evicted.len > 0) self.allocator.free(evicted);
        for (evicted) |entry| {
            if (try self.store.deferEvicted(entry)) {
                if (@import("builtin").mode == .Debug) self.stats.retirements_queued += 1;
            }
        }

        if (self.fonts.fetchRemove(handle.id)) |removed| {
            removed.value.loaded.deinit();
            self.allocator.destroy(removed.value);
        }
    }

    pub fn beginFrame(self: *RendererCore, completed_token: FrameToken, backend: anytype) void {
        comptime backend_contract.BackendContract(@TypeOf(backend));
        self.stats.reset();
        const retired = self.store.beginFrame(completed_token, backend);
        if (@import("builtin").mode == .Debug) {
            self.stats.retirements_completed += retired;
            self.stats.pool = self.store.poolSnapshot();
        }
    }

    pub fn setRetireAfterToken(self: *RendererCore, token: FrameToken) void {
        self.store.setRetireAfterToken(token);
    }

    pub fn retireCompleted(self: *RendererCore, completed_token: FrameToken, backend: anytype) void {
        comptime backend_contract.BackendContract(@TypeOf(backend));
        const retired = self.store.retireCompleted(completed_token, backend);
        if (@import("builtin").mode == .Debug) {
            self.stats.retirements_completed += retired;
            self.stats.pool = self.store.poolSnapshot();
        }
    }

    pub fn poolSnapshot(self: *const RendererCore) pool_mod.Snapshot {
        return self.store.poolSnapshot();
    }

    pub fn appendRun(
        self: *RendererCore,
        backend: anytype,
        batch: anytype,
        run: TextRun,
    ) !void {
        comptime backend_contract.BackendContract(@TypeOf(backend));
        comptime {
            const ExpectedBatch = *text_batch_mod.TextBatch(backend_contract.CommandType(@TypeOf(backend)));
            if (@TypeOf(batch) != ExpectedBatch) {
                @compileError("RendererCore.appendRun requires *TextBatch(Backend.Command)");
            }
        }
        const font = run.font;
        const font_entry = self.fonts.get(font.id) orelse return Error.ShapingFailed;

        const shaped = font_entry.loaded.shape(self.shape_plan, run.text, .{}) catch return Error.ShapingFailed;
        const infos = shaped.infos;
        const positions = shaped.positions;
        if (@import("builtin").mode == .Debug) {
            self.stats.runs_shaped += 1;
            self.stats.glyphs_shaped += @intCast(infos.len);
        }
        const em_motor = motorToEm(run.transform.toMotor());
        const em_translation = em_motor.translationComposer();
        const color = run.color.rgba;
        const flags = run.fill_rule.commandFlags();
        const start_batch_len = batch.len;
        errdefer {
            batch.len = start_batch_len;
        }

        var pen_x: f32 = 0;
        var pen_y: f32 = 0;

        for (infos, positions) |info, pos| {
            const glyph_x = pen_x + @as(f32, @floatFromInt(pos.x_offset));
            const glyph_y = pen_y + @as(f32, @floatFromInt(pos.y_offset));
            const glyph_motor = em_translation.compose(glyph_x, glyph_y);

            const cache_key = cache_mod.CacheKey{
                .font_id = font.id,
                .glyph_id = info.codepoint,
                .variation_key = font_entry.variation_key,
            };
            const cached_glyph = if (self.store.glyph_cache.lookup(cache_key)) |entry| blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_hits += 1;
                break :blk CachedGlyph{ .ref = entry.slot, .em_box = entry.em_box };
            } else blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_misses += 1;
                break :blk try self.ensureGlyphCached(backend, font_entry, cache_key);
            };

            if (!cached_glyph.ref.isEmpty()) {
                try batch.append(.{
                    .motor = glyph_motor.m,
                    .color = color,
                    .em_x_min = cached_glyph.em_box.x_min,
                    .em_y_min = cached_glyph.em_box.y_min,
                    .em_x_max = cached_glyph.em_box.x_max,
                    .em_y_max = cached_glyph.em_box.y_max,
                    .glyph_ref = cached_glyph.ref.value,
                    .flags = flags,
                });
                if (@import("builtin").mode == .Debug) self.stats.commands_written += 1;
            } else {
                if (@import("builtin").mode == .Debug) self.stats.empty_glyphs_skipped += 1;
            }

            pen_x += @as(f32, @floatFromInt(pos.x_advance));
            pen_y += @as(f32, @floatFromInt(pos.y_advance));
        }
    }

    fn ensureGlyphCached(
        self: *RendererCore,
        backend: anytype,
        font_entry: *FontEntry,
        cache_key: cache_mod.CacheKey,
    ) !CachedGlyph {
        const encoded = font_entry.loaded.encodeGlyph(cache_key.glyph_id) catch
            return Error.ShapingFailed;
        defer encoded.destroy();
        if (@import("builtin").mode == .Debug) {
            self.stats.glyphs_encoded += 1;
            self.stats.outline_segments += encoded.outline_segments;
            self.stats.regularized_spans += encoded.regularized_spans;
        }

        if (self.store.glyph_cache.cold_count >= self.store.glyph_cache.cold_capacity) {
            if (self.store.glyph_cache.evictLruNotUsedInFrame(self.store.glyph_cache.current_frame)) |evicted| {
                if (@import("builtin").mode == .Debug) self.stats.evictions += 1;
                if (try self.store.deferEvicted(evicted)) {
                    if (@import("builtin").mode == .Debug) self.stats.retirements_queued += 1;
                }
            } else return Error.PoolExhausted;
        }

        if (encoded.data.len == 0) {
            const extent_box = emBoxFromExtents(encoded.extents);
            try self.store.glyph_cache.insertCold(cache_key, GlyphRef.empty, .{ .offset = 0, .size = 0 }, extent_box);
            return .{ .ref = GlyphRef.empty, .em_box = extent_box };
        }

        const em_box = emBoxFromBlobBounds(encoded.blob);
        const pool_alloc = self.store.pool_alloc.alloc(@intCast(encoded.data.len)) orelse {
            if (@import("builtin").mode == .Debug) self.stats.pool_alloc_failures += 1;
            return Error.PoolExhausted;
        };
        errdefer self.store.pool_alloc.free(pool_alloc);

        const glyph_ref = try backend.uploadBlob(pool_alloc, encoded.data);
        errdefer backend.retireBlob(glyph_ref);
        if (@import("builtin").mode == .Debug) {
            self.stats.blob_bytes_uploaded += encoded.data.len;
            self.stats.pool = self.store.poolSnapshot();
        }

        try self.store.glyph_cache.insertCold(cache_key, glyph_ref, pool_alloc, em_box);
        return .{ .ref = glyph_ref, .em_box = em_box };
    }
};

const TestCommand = extern struct {
    motor: [4]f32,
    color: [4]f32,
    em_x_min: f32,
    em_y_min: f32,
    em_x_max: f32,
    em_y_max: f32,
    glyph_ref: u32,
    flags: u32,
    _pad: [2]u32 = .{ 0, 0 },
};

const FakeBackend = struct {
    pub const GlyphRef = cache_mod.GlyphRef;
    pub const FrameToken = glyph_store_mod.FrameToken;
    pub const Command = TestCommand;

    pool: []u8,
    next_ref: u32 = 0,
    releases: u32 = 0,

    pub fn uploadBlob(self: *FakeBackend, allocation: pool_mod.Allocation, data: []const u8) !cache_mod.GlyphRef {
        @memcpy(self.pool[allocation.offset..][0..data.len], data);
        self.next_ref += 1;
        return cache_mod.GlyphRef.from(allocation.offset);
    }

    pub fn retireBlob(self: *FakeBackend, _: cache_mod.GlyphRef) void {
        self.releases += 1;
    }
};

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";

test "render: FakeBackend satisfies backend contract" {
    backend_contract.BackendContract(FakeBackend);
    backend_contract.BackendContract(*FakeBackend);
    try std.testing.expect(true);
}

fn texelAt(bytes: []const u8, offset: u32) blob_format.Texel {
    const start: usize = @intCast(offset);
    return std.mem.bytesToValue(blob_format.Texel, bytes[start..][0..@sizeOf(blob_format.Texel)]);
}

test "RendererOptions mirrors current default capacities" {
    const opts = RendererOptions{};
    try std.testing.expectEqual(@as(u32, 16_384), opts.max_glyphs_per_frame);
}

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

test "render: emBoxFromBlobBounds uses encoded curve bounds" {
    const texels = try std.testing.allocator.alloc(blob_format.Texel, blob_format.header_len);
    defer std.testing.allocator.free(texels);
    texels[0] = .{ .r = -4, .g = -2, .b = 12, .a = 18 };
    texels[1] = .{ .r = 1, .g = 1, .b = 0, .a = 0 };

    const blob = blob_format.CoverageBlob.init(std.testing.allocator, texels);
    const em_box = emBoxFromBlobBounds(blob);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), em_box.x_min, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), em_box.y_min, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), em_box.x_max, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), em_box.y_max, 1.0e-6);
}

test "render: RendererCore appends shaped glyph commands and caches blobs" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 16 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [16]TestCommand = undefined;
    var batch = text_batch_mod.TextBatch(TestCommand).init(&commands);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "Hi",
        .transform = core_types.Transform.translation(10, 20),
        .color = .white,
    });

    try std.testing.expect(batch.count() > 0);
    try std.testing.expect(backend.next_ref > 0);
    try std.testing.expect(commands[0].glyph_ref != GlyphRef.empty.value);
    try std.testing.expect(commands[0].motor[2] != 0);

    const meta = texelAt(&pool, commands[0].glyph_ref + @sizeOf(blob_format.Texel));
    try std.testing.expect(meta.r > 0);
    try std.testing.expect(meta.a > 0);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.runs_shaped);
        try std.testing.expect(core.stats.glyphs_shaped >= batch.count());
        try std.testing.expectEqual(batch.count(), core.stats.commands_written);
        try std.testing.expect(core.stats.cache_misses > 0);
        try std.testing.expect(core.stats.glyphs_encoded > 0);
        try std.testing.expect(core.stats.outline_segments > 0);
        try std.testing.expect(core.stats.regularized_spans > 0);
        try std.testing.expect(core.stats.blob_bytes_uploaded > 0);
        try std.testing.expect(core.stats.pool.used_bytes > 0);
    }

    const refs_after_first = backend.next_ref;
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "Hi",
        .transform = core_types.Transform.translation(10, 20),
        .color = .white,
    });
    try std.testing.expectEqual(refs_after_first, backend.next_ref);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expect(core.stats.cache_hits > 0);
        try std.testing.expectEqual(batch.count(), core.stats.commands_written);
    }
}

test "render: RendererCore skips empty glyph commands while preserving cache entry" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [4]TestCommand = undefined;
    var batch = text_batch_mod.TextBatch(TestCommand).init(&commands);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = " ",
        .color = .white,
    });

    try std.testing.expectEqual(@as(u32, 0), batch.count());
    try std.testing.expectEqual(@as(u32, 0), backend.next_ref);
    try std.testing.expect(core.store.glyph_cache.count() > 0);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.runs_shaped);
        try std.testing.expect(core.stats.empty_glyphs_skipped > 0);
        try std.testing.expect(core.stats.glyphs_encoded > 0);
        try std.testing.expectEqual(@as(u64, 0), core.stats.blob_bytes_uploaded);
    }
}

test "render: RendererCore enforces command capacity after skipping empty glyphs" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 1 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [1]TestCommand = undefined;
    var batch = text_batch_mod.TextBatch(TestCommand).init(&commands);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try std.testing.expectError(
        Error.GlyphCapacityExceeded,
        core.appendRun(&backend, &batch, .{
            .font = font,
            .text = "HH",
            .color = .white,
        }),
    );
    try std.testing.expectEqual(@as(u32, 0), batch.count());
}

test "render: RendererCore writes fill-rule flags into glyph commands" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [4]TestCommand = undefined;
    var batch = text_batch_mod.TextBatch(TestCommand).init(&commands);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "A",
        .color = .white,
        .fill_rule = .even_odd,
    });

    try std.testing.expect(batch.count() > 0);
    try std.testing.expectEqual(core_types.FillRule.even_odd.commandFlags(), commands[0].flags);
}

test "render: RendererCore defers evicted glyph retirement until frame token completes" {
    var core = try RendererCore.init(std.testing.allocator, .{
        .max_glyphs_per_frame = 4,
        .hot_slab_count = 0,
        .cold_lru_count = 1,
    });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [4]TestCommand = undefined;
    var batch = text_batch_mod.TextBatch(TestCommand).init(&commands);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.setRetireAfterToken(7);
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "A",
        .color = .white,
    });

    core.setRetireAfterToken(7);
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "B",
        .color = .white,
    });

    try std.testing.expectEqual(@as(u32, 0), backend.releases);
    try std.testing.expectEqual(@as(usize, 1), core.store.retirements.entries.items.len);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.evictions);
        try std.testing.expectEqual(@as(u32, 1), core.stats.retirements_queued);
    }

    core.retireCompleted(6, &backend);
    try std.testing.expectEqual(@as(u32, 0), backend.releases);

    core.retireCompleted(7, &backend);
    try std.testing.expectEqual(@as(u32, 1), backend.releases);
    try std.testing.expectEqual(@as(usize, 0), core.store.retirements.entries.items.len);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.retirements_completed);
    }
}

test "render: RendererCore unloadFont removes handle and defers cached glyph retirement" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var commands: [4]TestCommand = undefined;
    var batch = text_batch_mod.TextBatch(TestCommand).init(&commands);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "A",
        .color = .white,
    });
    try std.testing.expect(backend.next_ref > 0);
    try std.testing.expect(core.store.glyph_cache.count() > 0);

    core.setRetireAfterToken(9);
    try core.unloadFont(font);

    try std.testing.expectEqual(@as(?*FontEntry, null), core.fonts.get(font.id));
    try std.testing.expectEqual(@as(u32, 0), core.store.glyph_cache.count());
    try std.testing.expectEqual(@as(u32, 0), backend.releases);
    try std.testing.expect(core.store.retirements.entries.items.len > 0);

    try std.testing.expectError(Error.ShapingFailed, core.appendRun(&backend, &batch, .{
        .font = font,
        .text = "A",
        .color = .white,
    }));

    core.retireCompleted(8, &backend);
    try std.testing.expectEqual(@as(u32, 0), backend.releases);

    core.retireCompleted(9, &backend);
    try std.testing.expectEqual(@as(u32, 1), backend.releases);
    try std.testing.expectEqual(@as(usize, 0), core.store.retirements.entries.items.len);
}
