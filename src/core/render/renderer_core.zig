//! Core text rendering orchestration shared by all GPU backends.

const std = @import("std");
const cache_mod = @import("../cache/glyph_cache.zig");
const pool_mod = @import("../cache/byte_pool.zig");
const blob_format = @import("../blob/format.zig");
const blob_decode = @import("../blob/decode.zig");
const font_mod = @import("../font/root.zig");
const glyph_store_mod = @import("glyph_store.zig");
const backend_contract = @import("backend_contract.zig");
const glyph_batch_mod = @import("glyph_batch.zig");
const core_types = @import("../types.zig");
const units = @import("../units.zig");
const mesh_limits = @import("../../gpu/mesh_limits.zig");
const hb = font_mod.hb;

pub const GlyphBlobRef = cache_mod.GlyphBlobRef;

pub const Error = error{
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
    InvalidFrameView,
    InvalidTransform,
    PrecisionUnsupported,
    TextPositionOverflow,
    MeshletCapacityExceeded,
};

pub const RendererOptions = struct {
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    min_storage_alignment: u32 = 256,
    precision_policy: core_types.PrecisionPolicy = .{},
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
    instances_written: u32 = 0,
    meshlets_written: u32 = 0,
    empty_glyphs_skipped: u32 = 0,
    cpu_culled: u32 = 0,
    invalid_affine: u32 = 0,
    precision_insufficient: u32 = 0,
    tier_promotions: u32 = 0,
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
    instances_submitted: u32 = 0,
    meshlets_submitted: u32 = 0,
    pool: pool_mod.Snapshot = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This(), comptime scope: anytype) void {
        std.log.scoped(scope).debug(
            "core stats: runs={d} shaped={d} instances={d} meshlets={d} empty={d} cpu_culled={d} invalid_affine={d} precision_insufficient={d} tier_promotions={d} hits={d} misses={d} encoded={d} spans={d} upload_bytes={d} evictions={d} retire_q={d} retire_done={d} pool_used={d} pool_free={d} largest_free={d} free_blocks={d}",
            .{
                self.runs_shaped,
                self.glyphs_shaped,
                self.instances_written,
                self.meshlets_written,
                self.empty_glyphs_skipped,
                self.cpu_culled,
                self.invalid_affine,
                self.precision_insufficient,
                self.tier_promotions,
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
    blob_ref: GlyphBlobRef,
    em_box: cache_mod.EmBox,
    bounds_q: cache_mod.FixedBounds,
    precision_bits: u8,
    mesh_metadata: cache_mod.MeshMetadata,
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
    const view = blob_decode.BlobView.initCoverageBlob(blob) catch unreachable;
    const header = view.header;
    const fraction_bits: u8 = @intCast(header.fraction_bits);
    return .{
        .x_min = @floatCast(blob_format.dequantize(header.bounds_min_x_q, fraction_bits)),
        .y_min = @floatCast(blob_format.dequantize(header.bounds_min_y_q, fraction_bits)),
        .x_max = @floatCast(blob_format.dequantize(header.bounds_max_x_q, fraction_bits)),
        .y_max = @floatCast(blob_format.dequantize(header.bounds_max_y_q, fraction_bits)),
    };
}

pub fn fixedBoundsFromBlob(blob: blob_format.CoverageBlob) cache_mod.FixedBounds {
    const view = blob_decode.BlobView.initCoverageBlob(blob) catch unreachable;
    const header = view.header;
    return .{
        .x_min = header.bounds_min_x_q,
        .y_min = header.bounds_min_y_q,
        .x_max = header.bounds_max_x_q,
        .y_max = header.bounds_max_y_q,
    };
}

pub const RendererCore = struct {
    store: glyph_store_mod.GlyphStore,
    font_system: font_mod.FontSystem,
    fonts: std.AutoHashMap(u32, *FontEntry),
    next_font_id: u32,
    max_glyphs_per_frame: u32,
    precision_policy: core_types.PrecisionPolicy,
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
            .precision_policy = options.precision_policy,
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
        view: core_types.FrameView2D,
        run: TextRun,
    ) !void {
        comptime backend_contract.BackendContract(@TypeOf(backend));
        comptime {
            const ExpectedBatch = *glyph_batch_mod.FrameBatch(
                backend_contract.GlyphInstanceType(@TypeOf(backend)),
                backend_contract.GlyphMeshletType(@TypeOf(backend)),
            );
            if (@TypeOf(batch) != ExpectedBatch) {
                @compileError("RendererCore.appendRun requires *FrameBatch(Backend.GlyphInstance, Backend.GlyphMeshlet)");
            }
        }
        if (!view.isFinite()) return Error.InvalidFrameView;
        const font = run.font;
        const font_entry = self.fonts.get(font.id) orelse return Error.ShapingFailed;

        const shaped = font_entry.loaded.shape(self.shape_plan, run.text, .{}) catch return Error.ShapingFailed;
        const infos = shaped.infos;
        const positions = shaped.positions;
        if (@import("builtin").mode == .Debug) {
            self.stats.runs_shaped += 1;
            self.stats.glyphs_shaped += @intCast(infos.len);
        }
        const run_screen_from_text = core_types.Affine2D64.compose(view.screen_from_world, run.transform);
        const color = run.color.rgba;
        const flags = run.fill_rule.shaderFlags();
        const start_glyph_len = batch.glyph_len;
        const start_meshlet_len = batch.meshlet_len;
        errdefer {
            batch.rollback(start_glyph_len, start_meshlet_len);
        }

        var pen_x: i64 = 0;
        var pen_y: i64 = 0;

        for (infos, positions) |info, pos| {
            const glyph_x_hb = std.math.add(i64, pen_x, pos.x_offset) catch return Error.TextPositionOverflow;
            const glyph_y_hb = std.math.add(i64, pen_y, pos.y_offset) catch return Error.TextPositionOverflow;
            const glyph_x = units.hb26p6ToPixelsI64(glyph_x_hb);
            const glyph_y = units.hb26p6ToPixelsI64(glyph_y_hb);
            const screen_from_glyph_pixels = run_screen_from_text.translate(glyph_x, glyph_y);
            const screen_from_local = screen_from_glyph_pixels.linearScaled(1.0 / units.hb_subpixels_per_pixel_f64);
            const local_from_screen = screen_from_local.inverse() orelse {
                if (@import("builtin").mode == .Debug) self.stats.invalid_affine += 1;
                try advancePen(&pen_x, &pen_y, pos);
                continue;
            };
            const precision_bits = self.precision_policy.selectFractionBits(screen_from_local) catch |err| switch (err) {
                error.PrecisionUnsupported => {
                    if (@import("builtin").mode == .Debug) self.stats.precision_insufficient += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                },
                else => {
                    if (@import("builtin").mode == .Debug) self.stats.invalid_affine += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                },
            };

            const cache_key = cache_mod.CacheKey{
                .font_id = font.id,
                .glyph_id = info.codepoint,
                .precision_bits = precision_bits,
                .variation_key = font_entry.variation_key,
            };
            const frame_promotions_before = if (@import("builtin").mode == .Debug)
                self.store.glyph_cache.frame_promotions
            else
                0;
            const cached_glyph = if (self.store.glyph_cache.lookup(cache_key)) |entry| blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_hits += 1;
                if (@import("builtin").mode == .Debug) {
                    self.stats.tier_promotions += self.store.glyph_cache.frame_promotions - frame_promotions_before;
                }
                break :blk CachedGlyph{
                    .blob_ref = entry.blob_ref,
                    .em_box = entry.em_box,
                    .bounds_q = entry.bounds_q,
                    .precision_bits = entry.precision_bits,
                    .mesh_metadata = entry.mesh_metadata,
                };
            } else blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_misses += 1;
                break :blk self.ensureGlyphCached(backend, font_entry, cache_key, precision_bits) catch |err| switch (err) {
                    Error.PrecisionUnsupported => {
                        if (@import("builtin").mode == .Debug) self.stats.precision_insufficient += 1;
                        try advancePen(&pen_x, &pen_y, pos);
                        continue;
                    },
                    else => return err,
                };
            };

            if (!cached_glyph.blob_ref.isEmpty()) {
                const local_bounds = localRectFromFixed(cached_glyph.bounds_q, cached_glyph.precision_bits);
                const screen_bounds = screen_from_local.transformRect(local_bounds);
                if (!screen_bounds.isFinite() or screen_bounds.isEmpty()) {
                    if (@import("builtin").mode == .Debug) self.stats.invalid_affine += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                }
                if (!screen_bounds.intersects(inflatedViewportRect(view, 1.0))) {
                    if (@import("builtin").mode == .Debug) self.stats.cpu_culled += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                }

                const glyph_anchor_q = chooseGlyphAnchorQ(
                    cached_glyph.bounds_q,
                    cached_glyph.precision_bits,
                    local_from_screen,
                    .{
                        view.viewport_width * 0.5,
                        view.viewport_height * 0.5,
                    },
                );
                const anchor_local = localPointFromFixed(glyph_anchor_q, cached_glyph.precision_bits);
                const screen_anchor = screen_from_local.apply(anchor_local);
                const screen_anchor_px = castPoint2F32(screen_anchor) orelse {
                    if (@import("builtin").mode == .Debug) self.stats.invalid_affine += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                };
                const screen_from_local_2x2 = castAffineLinear2x2F32(screen_from_local) orelse {
                    if (@import("builtin").mode == .Debug) self.stats.invalid_affine += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                };
                const local_from_screen_2x2 = castAffineLinear2x2F32(local_from_screen) orelse {
                    if (@import("builtin").mode == .Debug) self.stats.invalid_affine += 1;
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                };

                const GlyphInstance = backend_contract.GlyphInstanceType(@TypeOf(backend));
                const glyph_payload: GlyphInstance = .{
                    .color = color,
                    .blob_ref = cached_glyph.blob_ref.value,
                    .flags = flags,
                    .precision_bits = cached_glyph.precision_bits,
                    .chart_flags = 0,
                    .local_bounds_q = .{
                        cached_glyph.bounds_q.x_min,
                        cached_glyph.bounds_q.y_min,
                        cached_glyph.bounds_q.x_max,
                        cached_glyph.bounds_q.y_max,
                    },
                    .glyph_anchor_q = glyph_anchor_q,
                    .screen_anchor_px = screen_anchor_px,
                    .screen_from_local_2x2 = screen_from_local_2x2,
                    .local_from_screen_2x2 = local_from_screen_2x2,
                };

                const glyph_mark = batch.glyph_len;
                const meshlet_mark = batch.meshlet_len;
                const glyph_index = try batch.appendGlyph(glyph_payload);
                try appendGlyphMeshlets(
                    batch,
                    glyph_payload,
                    glyph_index,
                    cached_glyph.mesh_metadata,
                    cached_glyph.bounds_q,
                    cached_glyph.precision_bits,
                    local_from_screen,
                    view,
                    screen_bounds,
                );
                if (batch.meshlet_len == meshlet_mark) {
                    batch.rollback(glyph_mark, meshlet_mark);
                    if (@import("builtin").mode == .Debug) self.stats.cpu_culled += 1;
                } else if (@import("builtin").mode == .Debug) {
                    self.stats.instances_written += 1;
                    self.stats.meshlets_written += batch.meshlet_len - meshlet_mark;
                }
            } else {
                if (@import("builtin").mode == .Debug) self.stats.empty_glyphs_skipped += 1;
            }

            try advancePen(&pen_x, &pen_y, pos);
        }
    }

    fn ensureGlyphCached(
        self: *RendererCore,
        backend: anytype,
        font_entry: *FontEntry,
        cache_key: cache_mod.CacheKey,
        precision_bits: u8,
    ) !CachedGlyph {
        const encoded = font_entry.loaded.encodeGlyph(cache_key.glyph_id, precision_bits) catch |err| switch (err) {
            error.PrecisionUnsupported, error.GlyphTooLarge, error.GlyphOffsetOverflow => return Error.PrecisionUnsupported,
            else => return Error.ShapingFailed,
        };
        defer encoded.deinit();
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
            const empty_bounds = cache_mod.FixedBounds{ .x_min = 0, .y_min = 0, .x_max = 0, .y_max = 0 };
            try self.store.glyph_cache.insertColdWithBounds(cache_key, GlyphBlobRef.empty, .{ .offset = 0, .size = 0 }, extent_box, empty_bounds);
            return .{
                .blob_ref = GlyphBlobRef.empty,
                .em_box = extent_box,
                .bounds_q = empty_bounds,
                .precision_bits = precision_bits,
                .mesh_metadata = .empty(),
            };
        }

        const em_box = emBoxFromBlobBounds(encoded.blob);
        const bounds_q = fixedBoundsFromBlob(encoded.blob);
        var mesh_metadata = try meshMetadataFromBlob(self.allocator, encoded.blob);
        var owns_mesh_metadata = true;
        errdefer if (owns_mesh_metadata) mesh_metadata.deinit(self.allocator);
        const pool_alloc = self.store.pool_alloc.alloc(@intCast(encoded.data.len)) orelse {
            if (@import("builtin").mode == .Debug) self.stats.pool_alloc_failures += 1;
            return Error.PoolExhausted;
        };
        errdefer self.store.pool_alloc.free(pool_alloc);

        const blob_ref = try backend.uploadBlob(pool_alloc, encoded.data);
        errdefer backend.retireBlob(blob_ref);
        if (@import("builtin").mode == .Debug) {
            self.stats.blob_bytes_uploaded += encoded.data.len;
            self.stats.pool = self.store.poolSnapshot();
        }

        owns_mesh_metadata = false;
        try self.store.glyph_cache.insertColdWithMetadata(cache_key, blob_ref, pool_alloc, em_box, bounds_q, mesh_metadata);
        return .{
            .blob_ref = blob_ref,
            .em_box = em_box,
            .bounds_q = bounds_q,
            .precision_bits = precision_bits,
            .mesh_metadata = mesh_metadata,
        };
    }
};

const target_meshlet_extent_px: f64 = 96.0;
const no_bounds_max_q: i32 = -2147483647;

fn meshMetadataFromBlob(allocator: std.mem.Allocator, blob: blob_format.CoverageBlob) !cache_mod.MeshMetadata {
    const view = try blob_decode.BlobView.initCoverageBlob(blob);
    const header = view.header;
    if (header.band_count == 0) {
        return .{
            .curve_count = header.curve_count,
            .band_min = header.band_min,
            .band_count = 0,
            .band_height_q = header.band_height_q,
            .bands = &.{},
        };
    }

    const bands = try allocator.alloc(cache_mod.BandMeshInfo, header.band_count);
    errdefer allocator.free(bands);

    for (bands, 0..) |*out, band_index| {
        const band = view.band(@intCast(band_index));
        var max_x_q = no_bounds_max_q;
        var i: u32 = 0;
        while (i < band.id_count) : (i += 1) {
            const curve_index = view.curveId(band.id_start + i);
            if (curve_index < header.curve_count) {
                const curve = view.curve(curve_index);
                max_x_q = @max(max_x_q, curve.bbox_max_x_q);
            }
        }
        out.* = .{
            .candidate_count = band.id_count,
            .max_x_q = max_x_q,
        };
    }

    return .{
        .curve_count = header.curve_count,
        .band_min = header.band_min,
        .band_count = header.band_count,
        .band_height_q = header.band_height_q,
        .bands = bands,
    };
}

fn appendGlyphMeshlets(
    batch: anytype,
    glyph: anytype,
    glyph_index: u32,
    mesh_metadata: cache_mod.MeshMetadata,
    bounds: cache_mod.FixedBounds,
    precision_bits: u8,
    local_from_screen: core_types.Affine2D64,
    view: core_types.FrameView2D,
    screen_bounds: core_types.Rect64,
) !void {
    const Batch = @typeInfo(@TypeOf(batch)).pointer.child;
    const GlyphMeshlet = Batch.GlyphMeshletType;

    if (mesh_metadata.curve_count == 0 or mesh_metadata.band_count == 0) return;

    const visible_extent = visiblePixelExtent(screen_bounds, view);
    const requested_slices = subdivisionCount(visible_extent);
    const effective_slices = @min(requested_slices, @max(mesh_metadata.band_count, 1));

    var slice_index: u32 = 0;
    while (slice_index < effective_slices) : (slice_index += 1) {
        const band_start = @as(u32, @intCast((@as(u64, slice_index) * mesh_metadata.band_count) / effective_slices));
        const band_end = @as(u32, @intCast((@as(u64, slice_index + 1) * mesh_metadata.band_count) / effective_slices));
        if (band_end <= band_start) continue;

        var candidate_count: u32 = 0;
        var max_x_q = no_bounds_max_q;
        var band_index = band_start;
        while (band_index < band_end) : (band_index += 1) {
            const info = mesh_metadata.bands[band_index];
            candidate_count +|= info.candidate_count;
            max_x_q = @max(max_x_q, info.max_x_q);
        }
        if (candidate_count == 0) continue;

        const dilate_q = localPixelDilationQ(glyph, precision_bits);
        const viewport_q = viewportLocalBoundsQ(glyph, precision_bits, local_from_screen, view);
        var y_min_q = @max(
            @max(bounds.y_min, saturatingSubQ(viewport_q[1], dilate_q[1])),
            bandEdgeQ(mesh_metadata.band_min, band_start, mesh_metadata.band_height_q),
        );
        var y_max_q = @min(
            @min(bounds.y_max, saturatingAddQ(viewport_q[3], dilate_q[1])),
            bandEdgeQ(mesh_metadata.band_min, band_end, mesh_metadata.band_height_q),
        );

        if (band_start == 0) y_min_q = saturatingSubQ(y_min_q, dilate_q[1]);
        if (band_end == mesh_metadata.band_count) y_max_q = saturatingAddQ(y_max_q, dilate_q[1]);

        const rect_min_q = [2]i32{
            @max(bounds.x_min, saturatingSubQ(viewport_q[0], dilate_q[0])),
            y_min_q,
        };
        const rect_max_x_base = @min(bounds.x_max, max_x_q);
        const rect_max_q = [2]i32{
            @min(saturatingAddQ(rect_max_x_base, dilate_q[0]), saturatingAddQ(viewport_q[2], dilate_q[0])),
            y_max_q,
        };

        if (rect_max_q[0] <= rect_min_q[0] or rect_max_q[1] <= rect_min_q[1]) continue;

        const mesh_anchor_q = [2]i32{
            midpointQ(rect_min_q[0], rect_max_q[0]),
            midpointQ(rect_min_q[1], rect_max_q[1]),
        };
        const mesh_screen_anchor = glyphLocalQToScreenF64(glyph, precision_bits, mesh_anchor_q);
        const mesh_screen_anchor_px = castPoint2F32(mesh_screen_anchor) orelse continue;

        const meshlet: GlyphMeshlet = .{
            .glyph_index = glyph_index,
            .band_start = band_start,
            .band_end = band_end,
            .rect_min_q = rect_min_q,
            .rect_max_q = rect_max_q,
            .mesh_anchor_q = mesh_anchor_q,
            .screen_anchor_px = mesh_screen_anchor_px,
            .local_from_screen_2x2 = glyph.local_from_screen_2x2,
        };
        try batch.appendMeshlet(meshlet);
    }
}

fn visiblePixelExtent(screen_bounds: core_types.Rect64, view: core_types.FrameView2D) [2]f64 {
    const min_x = @max(screen_bounds.x_min, 0.0);
    const min_y = @max(screen_bounds.y_min, 0.0);
    const max_x = @min(screen_bounds.x_max, view.viewport_width);
    const max_y = @min(screen_bounds.y_max, view.viewport_height);
    return .{ @max(max_x - min_x, 0.0), @max(max_y - min_y, 0.0) };
}

fn subdivisionCount(visible_extent: [2]f64) u32 {
    const max_extent = @max(visible_extent[0], visible_extent[1]);
    var count: u32 = @intFromFloat(@ceil(max_extent / target_meshlet_extent_px));
    if (max_extent >= 16.0) count = @max(count, 4);
    return std.math.clamp(count, 1, mesh_limits.max_subdivisions_per_glyph);
}

fn localPixelDilationQ(glyph: anytype, precision_bits: u8) [2]i32 {
    const scale = std.math.ldexp(@as(f64, 1.0), precision_bits);
    const m = glyph.local_from_screen_2x2;
    const radius_x = (@abs(@as(f64, m[0])) + @abs(@as(f64, m[2]))) * 0.5;
    const radius_y = (@abs(@as(f64, m[1])) + @abs(@as(f64, m[3]))) * 0.5;
    return .{
        boundedQFromFloat(radius_x * scale, true),
        boundedQFromFloat(radius_y * scale, true),
    };
}

fn viewportLocalBoundsQ(
    glyph: anytype,
    precision_bits: u8,
    local_from_screen: core_types.Affine2D64,
    view: core_types.FrameView2D,
) [4]i32 {
    const s0 = [2]f64{ 0.0, 0.0 };
    const s1 = [2]f64{ view.viewport_width, 0.0 };
    const s2 = [2]f64{ view.viewport_width, view.viewport_height };
    const s3 = [2]f64{ 0.0, view.viewport_height };

    const min_x = @min(
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 0, false), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 0, false)),
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 0, false), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 0, false)),
    );
    const max_x = @max(
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 0, true), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 0, true)),
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 0, true), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 0, true)),
    );
    const min_y = @min(
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 1, false), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 1, false)),
        @min(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 1, false), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 1, false)),
    );
    const max_y = @max(
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s0, 1, true), localScreenToQ(glyph, precision_bits, local_from_screen, s1, 1, true)),
        @max(localScreenToQ(glyph, precision_bits, local_from_screen, s2, 1, true), localScreenToQ(glyph, precision_bits, local_from_screen, s3, 1, true)),
    );
    return .{ min_x, min_y, max_x, max_y };
}

fn localScreenToQ(
    glyph: anytype,
    precision_bits: u8,
    local_from_screen: core_types.Affine2D64,
    screen: [2]f64,
    axis: u1,
    upper: bool,
) i32 {
    const anchor_screen = [2]f64{
        @floatCast(glyph.screen_anchor_px[0]),
        @floatCast(glyph.screen_anchor_px[1]),
    };
    const local_delta = local_from_screen.applyVector(.{
        screen[0] - anchor_screen[0],
        screen[1] - anchor_screen[1],
    });
    const scale = std.math.ldexp(@as(f64, 1.0), precision_bits);
    const anchor = glyph.glyph_anchor_q[axis];
    const delta_q = boundedQFromFloat(local_delta[axis] * scale, upper);
    return saturatingAddQ(anchor, delta_q);
}

fn glyphLocalQToScreenF64(glyph: anytype, precision_bits: u8, local_q: [2]i32) [2]f64 {
    const inv_scale = std.math.ldexp(@as(f64, 1.0), -@as(i32, precision_bits));
    const dx = @as(f64, @floatFromInt(saturatingSubQ(local_q[0], glyph.glyph_anchor_q[0]))) * inv_scale;
    const dy = @as(f64, @floatFromInt(saturatingSubQ(local_q[1], glyph.glyph_anchor_q[1]))) * inv_scale;
    const m = glyph.screen_from_local_2x2;
    return .{
        @as(f64, glyph.screen_anchor_px[0]) + @as(f64, m[0]) * dx + @as(f64, m[2]) * dy,
        @as(f64, glyph.screen_anchor_px[1]) + @as(f64, m[1]) * dx + @as(f64, m[3]) * dy,
    };
}

fn bandEdgeQ(band_min: i32, band_offset: u32, band_height_q: i32) i32 {
    const band = @as(i64, band_min) + @as(i64, band_offset);
    const product = std.math.mul(i64, band, band_height_q) catch {
        if ((band < 0) == (band_height_q > 0)) return std.math.minInt(i32);
        return std.math.maxInt(i32);
    };
    return clampI64ToI32(product);
}

fn midpointQ(lo: i32, hi: i32) i32 {
    if ((lo < 0) != (hi < 0)) return @intCast(@divTrunc(@as(i64, lo) + @as(i64, hi), 2));
    return lo + @divTrunc(hi - lo, 2);
}

fn boundedQFromFloat(value: f64, upper: bool) i32 {
    if (!std.math.isFinite(value)) {
        return if (upper) std.math.maxInt(i32) else std.math.minInt(i32);
    }
    const rounded = if (upper) @ceil(value) else @floor(value);
    if (rounded <= @as(f64, @floatFromInt(std.math.minInt(i32)))) return std.math.minInt(i32);
    if (rounded >= @as(f64, @floatFromInt(std.math.maxInt(i32)))) return std.math.maxInt(i32);
    return @intFromFloat(rounded);
}

fn saturatingAddQ(a: i32, b: i32) i32 {
    return clampI64ToI32(@as(i64, a) + @as(i64, b));
}

fn saturatingSubQ(a: i32, b: i32) i32 {
    return clampI64ToI32(@as(i64, a) - @as(i64, b));
}

fn clampI64ToI32(value: i64) i32 {
    if (value <= std.math.minInt(i32)) return std.math.minInt(i32);
    if (value >= std.math.maxInt(i32)) return std.math.maxInt(i32);
    return @intCast(value);
}

fn localRectFromFixed(bounds: cache_mod.FixedBounds, precision_bits: u8) core_types.Rect64 {
    return .{
        .x_min = blob_format.dequantize(bounds.x_min, precision_bits),
        .y_min = blob_format.dequantize(bounds.y_min, precision_bits),
        .x_max = blob_format.dequantize(bounds.x_max, precision_bits),
        .y_max = blob_format.dequantize(bounds.y_max, precision_bits),
    };
}

fn advancePen(pen_x: *i64, pen_y: *i64, pos: anytype) Error!void {
    pen_x.* = std.math.add(i64, pen_x.*, pos.x_advance) catch return Error.TextPositionOverflow;
    pen_y.* = std.math.add(i64, pen_y.*, pos.y_advance) catch return Error.TextPositionOverflow;
}

fn localPointFromFixed(point_q: [2]i32, precision_bits: u8) [2]f64 {
    return .{
        blob_format.dequantize(point_q[0], precision_bits),
        blob_format.dequantize(point_q[1], precision_bits),
    };
}

fn inflatedViewportRect(view: core_types.FrameView2D, guard_px: f64) core_types.Rect64 {
    return .{
        .x_min = -guard_px,
        .y_min = -guard_px,
        .x_max = view.viewport_width + guard_px,
        .y_max = view.viewport_height + guard_px,
    };
}

fn chooseGlyphAnchorQ(
    bounds: cache_mod.FixedBounds,
    precision_bits: u8,
    local_from_screen: core_types.Affine2D64,
    screen_point: [2]f64,
) [2]i32 {
    const local = local_from_screen.apply(screen_point);
    const scale = blob_format.scaleForFractionBits(precision_bits);
    const x_q = quantizeClamp(local[0], scale, bounds.x_min, bounds.x_max);
    const y_q = quantizeClamp(local[1], scale, bounds.y_min, bounds.y_max);
    return .{ x_q, y_q };
}

fn quantizeClamp(value: f64, scale: f64, lo: i32, hi: i32) i32 {
    if (!std.math.isFinite(value)) {
        const midpoint = @as(i64, lo) + @divTrunc(@as(i64, hi) - @as(i64, lo), 2);
        return @intCast(midpoint);
    }
    const q_f = std.math.round(value * scale);
    if (q_f <= @as(f64, @floatFromInt(lo))) return lo;
    if (q_f >= @as(f64, @floatFromInt(hi))) return hi;
    return @intFromFloat(q_f);
}

const max_f32_f64: f64 = 3.4028234663852885981170418348451692544e38;

fn castF32Finite(value: f64) ?f32 {
    if (!std.math.isFinite(value) or @abs(value) > max_f32_f64) return null;
    const out: f32 = @floatCast(value);
    return if (std.math.isFinite(out)) out else null;
}

fn castPoint2F32(point: [2]f64) ?[2]f32 {
    return .{
        castF32Finite(point[0]) orelse return null,
        castF32Finite(point[1]) orelse return null,
    };
}

fn castAffineLinear2x2F32(transform: core_types.Affine2D64) ?[4]f32 {
    return .{
        castF32Finite(transform.xx) orelse return null,
        castF32Finite(transform.xy) orelse return null,
        castF32Finite(transform.yx) orelse return null,
        castF32Finite(transform.yy) orelse return null,
    };
}

const TestGlyphInstance = extern struct {
    color: [4]f32,
    blob_ref: u32,
    flags: u32,
    precision_bits: u32,
    chart_flags: u32,
    local_bounds_q: [4]i32,
    glyph_anchor_q: [2]i32,
    screen_anchor_px: [2]f32,
    screen_from_local_2x2: [4]f32,
    local_from_screen_2x2: [4]f32,
};

const TestGlyphMeshlet = extern struct {
    glyph_index: u32,
    band_start: u32,
    band_end: u32,
    _pad0: u32 = 0,
    rect_min_q: [2]i32,
    rect_max_q: [2]i32,
    mesh_anchor_q: [2]i32,
    screen_anchor_px: [2]f32,
    local_from_screen_2x2: [4]f32,
};

test "render: viewport local bounds invert screen corners without double translation" {
    const screen_from_local = core_types.Affine2D64.init(2, 0, 0, 4, 100, 200);
    const local_from_screen = screen_from_local.inverse().?;
    const glyph_anchor_q = [2]i32{ 8, -12 };
    const screen_anchor = screen_from_local.apply(.{
        @as(f64, @floatFromInt(glyph_anchor_q[0])),
        @as(f64, @floatFromInt(glyph_anchor_q[1])),
    });

    var glyph = std.mem.zeroes(TestGlyphInstance);
    glyph.precision_bits = 0;
    glyph.glyph_anchor_q = glyph_anchor_q;
    glyph.screen_anchor_px = .{
        @floatCast(screen_anchor[0]),
        @floatCast(screen_anchor[1]),
    };

    const bounds = viewportLocalBoundsQ(
        glyph,
        @intCast(glyph.precision_bits),
        local_from_screen,
        core_types.FrameView2D.identity(1280, 720),
    );

    try std.testing.expectEqual(@as(i32, -50), bounds[0]);
    try std.testing.expectEqual(@as(i32, -50), bounds[1]);
    try std.testing.expectEqual(@as(i32, 590), bounds[2]);
    try std.testing.expectEqual(@as(i32, 130), bounds[3]);
}

const FakeBackend = struct {
    pub const GlyphBlobRef = cache_mod.GlyphBlobRef;
    pub const FrameToken = glyph_store_mod.FrameToken;
    pub const GlyphInstance = TestGlyphInstance;
    pub const GlyphMeshlet = TestGlyphMeshlet;

    pool: []u8,
    next_ref: u32 = 0,
    releases: u32 = 0,

    pub fn uploadBlob(self: *FakeBackend, allocation: pool_mod.Allocation, data: []const u8) !cache_mod.GlyphBlobRef {
        @memcpy(self.pool[allocation.offset..][0..data.len], data);
        self.next_ref += 1;
        return cache_mod.GlyphBlobRef.from(allocation.offset);
    }

    pub fn retireBlob(self: *FakeBackend, _: cache_mod.GlyphBlobRef) void {
        self.releases += 1;
    }
};

const test_font_path: [*:0]const u8 = "assets/Inter-Regular.otf";
const test_view = core_types.FrameView2D.identity(1280, 720);

test "render: FakeBackend satisfies backend contract" {
    backend_contract.BackendContract(FakeBackend);
    backend_contract.BackendContract(*FakeBackend);
    try std.testing.expect(true);
}

test "RendererOptions mirrors current default capacities" {
    const opts = RendererOptions{};
    try std.testing.expectEqual(@as(u32, 16_384), opts.max_glyphs_per_frame);
}

test "render: emBoxFromBlobBounds uses encoded curve bounds" {
    const blob_encode = @import("../blob/encode.zig");
    const regularize = @import("../outline/regularize.zig");
    var blob = try blob_encode.curves(std.testing.allocator, &.{
        regularize.lineAsCubic(.{ .x = -1.0, .y = -0.5 }, .{ .x = 3.0, .y = 4.5 }),
    }, blob_format.default_fraction_bits);
    defer blob.deinit();

    const em_box = emBoxFromBlobBounds(blob);
    try std.testing.expectApproxEqAbs(@as(f32, -1.0), em_box.x_min, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, -0.5), em_box.y_min, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 3.0), em_box.x_max, 1.0e-6);
    try std.testing.expectApproxEqAbs(@as(f32, 4.5), em_box.y_max, 1.0e-6);
}

test "render: RendererCore appends shaped glyph instances and caches blobs" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 16 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [16]TestGlyphInstance = undefined;
    var meshlets: [16 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "Hi",
        .transform = core_types.Transform.translation(10, 20),
        .color = .white,
    });

    try std.testing.expect(batch.glyphCount() > 0);
    try std.testing.expect(batch.meshletCount() > 0);
    try std.testing.expect(backend.next_ref > 0);
    try std.testing.expect(glyphs[0].blob_ref != GlyphBlobRef.empty.value);
    try std.testing.expect(glyphs[0].precision_bits >= blob_format.min_fraction_bits);
    try std.testing.expect(glyphs[0].local_bounds_q[2] > glyphs[0].local_bounds_q[0]);
    try std.testing.expect(std.math.isFinite(glyphs[0].screen_anchor_px[0]));
    try std.testing.expect(meshlets[0].glyph_index < batch.glyphCount());
    try std.testing.expect(meshlets[0].band_end > meshlets[0].band_start);
    try std.testing.expect(meshlets[0].rect_max_q[0] > meshlets[0].rect_min_q[0]);
    try std.testing.expect(meshlets[0].rect_max_q[1] > meshlets[0].rect_min_q[1]);
    try std.testing.expect(std.math.isFinite(meshlets[0].screen_anchor_px[0]));
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.runs_shaped);
        try std.testing.expect(core.stats.glyphs_shaped >= batch.glyphCount());
        try std.testing.expectEqual(batch.glyphCount(), core.stats.instances_written);
        try std.testing.expectEqual(batch.meshletCount(), core.stats.meshlets_written);
        try std.testing.expect(core.stats.cache_misses > 0);
        try std.testing.expect(core.stats.glyphs_encoded > 0);
        try std.testing.expect(core.stats.outline_segments > 0);
        try std.testing.expect(core.stats.regularized_spans > 0);
        try std.testing.expect(core.stats.blob_bytes_uploaded > 0);
        try std.testing.expect(core.stats.pool.used_bytes > 0);
    }

    const refs_after_first = backend.next_ref;
    try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "Hi",
        .transform = core_types.Transform.translation(10, 20),
        .color = .white,
    });
    try std.testing.expectEqual(refs_after_first, backend.next_ref);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expect(core.stats.cache_hits > 0);
        try std.testing.expectEqual(batch.glyphCount(), core.stats.instances_written);
    }
}

test "render: RendererCore skips empty glyph instances while preserving cache entry" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = " ",
        .color = .white,
    });

    try std.testing.expectEqual(@as(u32, 0), batch.glyphCount());
    try std.testing.expectEqual(@as(u32, 0), batch.meshletCount());
    try std.testing.expectEqual(@as(u32, 0), backend.next_ref);
    try std.testing.expect(core.store.glyph_cache.count() > 0);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.runs_shaped);
        try std.testing.expect(core.stats.empty_glyphs_skipped > 0);
        try std.testing.expect(core.stats.glyphs_encoded > 0);
        try std.testing.expectEqual(@as(u64, 0), core.stats.blob_bytes_uploaded);
    }
}

test "render: RendererCore enforces instance capacity after skipping empty glyphs" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 1 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [1]TestGlyphInstance = undefined;
    var meshlets: [1 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try std.testing.expectError(
        Error.GlyphCapacityExceeded,
        core.appendRun(&backend, &batch, test_view, .{
            .font = font,
            .text = "HH",
            .color = .white,
        }),
    );
    try std.testing.expectEqual(@as(u32, 0), batch.glyphCount());
    try std.testing.expectEqual(@as(u32, 0), batch.meshletCount());
}

test "render: RendererCore writes fill-rule flags into glyph instances" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "A",
        .color = .white,
        .fill_rule = .even_odd,
    });

    try std.testing.expect(batch.glyphCount() > 0);
    try std.testing.expect(batch.meshletCount() > 0);
    try std.testing.expectEqual(core_types.FillRule.even_odd.shaderFlags(), glyphs[0].flags);
}

test "render: RendererCore emits finite chart payload after large pan cancellation" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    const world = core_types.Affine2D64.translation(-1.0e12, -1.0e12);
    const run_transform = core_types.Transform.translation(1.0e12 + 32.0, 1.0e12 + 48.0);
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, core_types.FrameView2D.init(1280, 720, world), .{
        .font = font,
        .text = "A",
        .transform = run_transform,
        .color = .white,
    });

    try std.testing.expect(batch.glyphCount() > 0);
    try std.testing.expect(batch.meshletCount() > 0);
    try std.testing.expect(std.math.isFinite(glyphs[0].screen_anchor_px[0]));
    try std.testing.expect(std.math.isFinite(glyphs[0].screen_anchor_px[1]));
    try std.testing.expect(@abs(glyphs[0].screen_anchor_px[0]) < 4096);
    try std.testing.expect(@abs(glyphs[0].screen_anchor_px[1]) < 4096);
}

test "render: RendererCore reports unsupported precision instead of emitting unstable payload" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "A",
        .transform = core_types.Transform.scale(1.0e12, 1.0e12),
        .color = .white,
    });

    try std.testing.expectEqual(@as(u32, 0), batch.glyphCount());
    try std.testing.expectEqual(@as(u32, 0), batch.meshletCount());
    if (@import("builtin").mode == .Debug) {
        try std.testing.expect(core.stats.precision_insufficient > 0);
    }
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
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.setRetireAfterToken(7);
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "A",
        .color = .white,
    });

    core.setRetireAfterToken(7);
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
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
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = glyph_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    try core.appendRun(&backend, &batch, test_view, .{
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

    try std.testing.expectError(Error.ShapingFailed, core.appendRun(&backend, &batch, test_view, .{
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
