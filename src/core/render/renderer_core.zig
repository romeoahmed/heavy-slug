//! Core text rendering orchestration shared by all GPU backends.

const std = @import("std");
const cache_mod = @import("../cache/glyph_cache.zig");
const pool_mod = @import("../cache/byte_pool.zig");
const blob_format = @import("../blob/format.zig");
const blob_decode = @import("../blob/decode.zig");
const font_mod = @import("../font/root.zig");
const glyph_store_mod = @import("glyph_store.zig");
const backend_contract = @import("backend_contract.zig");
const frame_batch_mod = @import("frame_batch.zig");
const mesh_plan = @import("mesh_plan.zig");
const options_mod = @import("options.zig");
const core_types = @import("../types.zig");
const units = @import("../units.zig");
const mesh_limits = @import("../../gpu/mesh_limits.zig");
const hb = font_mod.hb;

pub const GlyphBlobRef = cache_mod.GlyphBlobRef;
pub const RendererOptions = options_mod.RendererOptions;

pub const Error = error{
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
    InvalidView,
    InvalidPrecisionPolicy,
    TextPositionOverflow,
    MeshletCapacityExceeded,
};

pub const TextRun = struct {
    font: core_types.FontHandle,
    text: []const u8,
    transform: core_types.Transform = .identity,
    color: core_types.Color = .black,
    fill_rule: core_types.FillRule = .non_zero,
};

pub const ScreenTextRun = struct {
    font: core_types.FontHandle,
    text: []const u8,
    screen_from_text: core_types.Transform = .identity,
    color: core_types.Color = .black,
    fill_rule: core_types.FillRule = .non_zero,
};

pub const RunRejectReason = enum(u8) {
    invalid_world_transform,
};

pub const GlyphRejectReason = enum(u8) {
    invalid_transform,
    precision_unsupported,
    cache_encode_unsupported,
    nonfinite_bounds,
    host_culled,
    f32_chart_overflow,
    meshlet_empty,
    empty_glyph,
};

pub const FrameBlockingReason = union(enum) {
    run: RunRejectReason,
    glyph: GlyphRejectReason,
};

pub const FrameWarning = enum(u8) {
    invalid_world_transform,
    invalid_transform,
    precision_unsupported,
    cache_encode_unsupported,
    nonfinite_bounds,
    f32_chart_overflow,
    meshlet_empty,
    empty_after_blocking_rejects,
};

pub const max_frame_warnings = @typeInfo(FrameWarning).@"enum".fields.len;

pub const FrameWarnings = struct {
    items: [max_frame_warnings]FrameWarning = undefined,
    len: u8 = 0,

    pub fn slice(self: *const FrameWarnings) []const FrameWarning {
        return self.items[0..self.len];
    }

    fn appendUnique(self: *FrameWarnings, warning: FrameWarning) void {
        for (self.slice()) |existing| {
            if (existing == warning) return;
        }
        if (self.len >= self.items.len) return;
        self.items[self.len] = warning;
        self.len += 1;
    }
};

pub const RunRejectCounters = struct {
    invalid_world_transform: u32 = 0,

    pub fn total(self: RunRejectCounters) u32 {
        return self.invalid_world_transform;
    }

    pub fn hasBlocking(self: RunRejectCounters) bool {
        return self.total() != 0;
    }
};

pub const RejectCounters = struct {
    invalid_transform: u32 = 0,
    precision_unsupported: u32 = 0,
    cache_encode_unsupported: u32 = 0,
    nonfinite_bounds: u32 = 0,
    host_culled: u32 = 0,
    f32_chart_overflow: u32 = 0,
    meshlet_empty: u32 = 0,
    empty_glyph: u32 = 0,

    pub fn total(self: RejectCounters) u32 {
        var sum: u32 = 0;
        sum = saturatingAdd(sum, self.invalid_transform);
        sum = saturatingAdd(sum, self.precision_unsupported);
        sum = saturatingAdd(sum, self.cache_encode_unsupported);
        sum = saturatingAdd(sum, self.nonfinite_bounds);
        sum = saturatingAdd(sum, self.host_culled);
        sum = saturatingAdd(sum, self.f32_chart_overflow);
        sum = saturatingAdd(sum, self.meshlet_empty);
        sum = saturatingAdd(sum, self.empty_glyph);
        return sum;
    }

    pub fn totalBlocking(self: RejectCounters) u32 {
        var sum: u32 = 0;
        sum = saturatingAdd(sum, self.invalid_transform);
        sum = saturatingAdd(sum, self.precision_unsupported);
        sum = saturatingAdd(sum, self.cache_encode_unsupported);
        sum = saturatingAdd(sum, self.nonfinite_bounds);
        sum = saturatingAdd(sum, self.f32_chart_overflow);
        sum = saturatingAdd(sum, self.meshlet_empty);
        return sum;
    }

    pub fn totalNonBlocking(self: RejectCounters) u32 {
        var sum: u32 = 0;
        sum = saturatingAdd(sum, self.host_culled);
        sum = saturatingAdd(sum, self.empty_glyph);
        return sum;
    }

    pub fn hasBlocking(self: RejectCounters) bool {
        return self.totalBlocking() != 0;
    }
};

pub const DrawTextResult = struct {
    shaped_glyphs: u32 = 0,
    emitted_glyphs: u32 = 0,
    emitted_meshlets: u32 = 0,
    run_rejects: RunRejectCounters = .{},
    glyph_rejects: RejectCounters = .{},

    pub fn emitted(self: DrawTextResult) bool {
        return self.emitted_glyphs != 0 and self.emitted_meshlets != 0;
    }

    pub fn degraded(self: DrawTextResult) bool {
        return self.run_rejects.hasBlocking() or self.glyph_rejects.total() != 0;
    }
};

pub const FrameDiagnostics = struct {
    runs: u32 = 0,
    shaped_glyphs: u32 = 0,
    emitted_glyphs: u32 = 0,
    emitted_meshlets: u32 = 0,
    run_rejects: RunRejectCounters = .{},
    glyph_rejects: RejectCounters = .{},
    max_sigma: f64 = 0,
    max_required_fraction_bits: u16 = 0,
    first_blocking_reason: ?FrameBlockingReason = null,

    pub fn hasPrecisionUnsupported(self: FrameDiagnostics) bool {
        return self.glyph_rejects.precision_unsupported != 0;
    }

    pub fn hasVisiblePayload(self: FrameDiagnostics) bool {
        return self.emitted_glyphs != 0 and self.emitted_meshlets != 0;
    }

    pub fn hasBlockingRejects(self: FrameDiagnostics) bool {
        return self.run_rejects.hasBlocking() or self.glyph_rejects.hasBlocking();
    }

    pub fn warnings(self: FrameDiagnostics) FrameWarnings {
        var out: FrameWarnings = .{};
        if (self.run_rejects.invalid_world_transform != 0) out.appendUnique(.invalid_world_transform);
        if (self.glyph_rejects.invalid_transform != 0) out.appendUnique(.invalid_transform);
        if (self.glyph_rejects.precision_unsupported != 0) out.appendUnique(.precision_unsupported);
        if (self.glyph_rejects.cache_encode_unsupported != 0) out.appendUnique(.cache_encode_unsupported);
        if (self.glyph_rejects.nonfinite_bounds != 0) out.appendUnique(.nonfinite_bounds);
        if (self.glyph_rejects.f32_chart_overflow != 0) out.appendUnique(.f32_chart_overflow);
        if (self.glyph_rejects.meshlet_empty != 0) out.appendUnique(.meshlet_empty);
        if (!self.hasVisiblePayload() and self.hasBlockingRejects()) out.appendUnique(.empty_after_blocking_rejects);
        return out;
    }

    fn reset(self: *FrameDiagnostics) void {
        self.* = .{};
    }
};

pub const EmptyFrame = struct {
    previous_token: FrameToken,
    diagnostics: FrameDiagnostics,
};

pub const SubmitResult = union(enum) {
    submitted_text: FrameToken,
    submitted_clear_only: FrameToken,
    empty_noop: EmptyFrame,
};

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    runs_shaped: u32 = 0,
    glyphs_shaped: u32 = 0,
    glyphs_written: u32 = 0,
    meshlets_written: u32 = 0,
    empty_glyphs_skipped: u32 = 0,
    host_culled: u32 = 0,
    invalid_transform: u32 = 0,
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
    pool_exhausted: u32 = 0,
    submitted_glyphs: u32 = 0,
    submitted_meshlets: u32 = 0,
    pool: pool_mod.Snapshot = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This(), comptime scope: anytype) void {
        std.log.scoped(scope).debug(
            "core stats: runs={d} shaped={d} glyphs={d} meshlets={d} empty={d} host_culled={d} invalid_transform={d} precision_insufficient={d} tier_promotions={d} hits={d} misses={d} encoded={d} spans={d} upload_bytes={d} evictions={d} retire_q={d} retire_done={d} pool_exhausted={d} pool_used={d} pool_free={d} largest_free={d} free_blocks={d}",
            .{
                self.runs_shaped,
                self.glyphs_shaped,
                self.glyphs_written,
                self.meshlets_written,
                self.empty_glyphs_skipped,
                self.host_culled,
                self.invalid_transform,
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
                self.pool_exhausted,
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
    bounds_q: cache_mod.FixedBounds,
    precision_bits: u8,
    mesh_metadata: cache_mod.MeshMetadata,
};

const TextSpace = enum {
    world,
    screen,
};

const InternalTextRun = struct {
    font: core_types.FontHandle,
    text: []const u8,
    transform: core_types.Transform,
    color: core_types.Color,
    fill_rule: core_types.FillRule,
    space: TextSpace,
};

fn saturatingAdd(a: u32, b: u32) u32 {
    return if (std.math.maxInt(u32) - a < b) std.math.maxInt(u32) else a + b;
}

fn saturatingIncrement(value: *u32) void {
    if (value.* != std.math.maxInt(u32)) value.* += 1;
}

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

pub fn emBoxFromBlobBounds(blob: blob_format.CoverageBlob) blob_decode.Error!cache_mod.EmBox {
    return emBoxFromBlobView(try blob_decode.BlobView.initCoverageBlob(blob));
}

fn emBoxFromBlobView(view: blob_decode.BlobView) cache_mod.EmBox {
    const header = view.header;
    const fraction_bits: u8 = @intCast(header.fraction_bits);
    return .{
        .x_min = @floatCast(blob_format.dequantize(header.bounds_min_x_q, fraction_bits)),
        .y_min = @floatCast(blob_format.dequantize(header.bounds_min_y_q, fraction_bits)),
        .x_max = @floatCast(blob_format.dequantize(header.bounds_max_x_q, fraction_bits)),
        .y_max = @floatCast(blob_format.dequantize(header.bounds_max_y_q, fraction_bits)),
    };
}

pub fn fixedBoundsFromBlob(blob: blob_format.CoverageBlob) blob_decode.Error!cache_mod.FixedBounds {
    return fixedBoundsFromBlobView(try blob_decode.BlobView.initCoverageBlob(blob));
}

fn fixedBoundsFromBlobView(view: blob_decode.BlobView) cache_mod.FixedBounds {
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
    fonts: std.AutoHashMapUnmanaged(u32, *FontEntry) = .empty,
    next_font_id: u32,
    max_glyphs_per_frame: u32,
    precision_policy: core_types.PrecisionPolicy,
    shape_plan: font_mod.ShapePlan,
    frame_diagnostics: FrameDiagnostics,
    stats: Stats,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, options: RendererOptions) !RendererCore {
        try options.validate();

        var store = try glyph_store_mod.GlyphStore.init(allocator, options);
        errdefer store.deinit();

        var font_system = try font_mod.FontSystem.init(allocator);
        errdefer font_system.deinit();

        var shape_plan = try font_mod.ShapePlan.init();
        errdefer shape_plan.deinit();

        return .{
            .store = store,
            .font_system = font_system,
            .next_font_id = 0,
            .max_glyphs_per_frame = options.max_glyphs_per_frame,
            .precision_policy = options.precision_policy,
            .shape_plan = shape_plan,
            .frame_diagnostics = .{},
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
        self.fonts.deinit(self.allocator);
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
        try self.fonts.putNoClobber(self.allocator, id, entry);
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
        comptime backend_contract.checkBackend(@TypeOf(backend));
        self.frame_diagnostics.reset();
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
        comptime backend_contract.checkBackend(@TypeOf(backend));
        const retired = self.store.retireCompleted(completed_token, backend);
        if (@import("builtin").mode == .Debug) {
            self.stats.retirements_completed += retired;
            self.stats.pool = self.store.poolSnapshot();
        }
    }

    pub fn poolSnapshot(self: *const RendererCore) pool_mod.Snapshot {
        return self.store.poolSnapshot();
    }

    pub fn frameDiagnostics(self: *const RendererCore) FrameDiagnostics {
        return self.frame_diagnostics;
    }

    pub fn appendRun(
        self: *RendererCore,
        backend: anytype,
        batch: anytype,
        view: core_types.View,
        run: TextRun,
    ) !DrawTextResult {
        return self.appendTextRun(backend, batch, view, .{
            .font = run.font,
            .text = run.text,
            .transform = run.transform,
            .color = run.color,
            .fill_rule = run.fill_rule,
            .space = .world,
        });
    }

    pub fn appendScreenRun(
        self: *RendererCore,
        backend: anytype,
        batch: anytype,
        view: core_types.View,
        run: ScreenTextRun,
    ) !DrawTextResult {
        return self.appendTextRun(backend, batch, view, .{
            .font = run.font,
            .text = run.text,
            .transform = run.screen_from_text,
            .color = run.color,
            .fill_rule = run.fill_rule,
            .space = .screen,
        });
    }

    fn appendTextRun(
        self: *RendererCore,
        backend: anytype,
        batch: anytype,
        view: core_types.View,
        run: InternalTextRun,
    ) !DrawTextResult {
        comptime backend_contract.checkBackend(@TypeOf(backend));
        comptime {
            const ExpectedBatch = *frame_batch_mod.FrameBatch(
                backend_contract.glyphInstanceType(@TypeOf(backend)),
                backend_contract.glyphMeshletType(@TypeOf(backend)),
            );
            if (@TypeOf(batch) != ExpectedBatch) {
                @compileError("RendererCore.appendRun requires *FrameBatch(backend GlyphInstance, backend GlyphMeshlet)");
            }
        }
        if (!view.hasFiniteViewport()) return Error.InvalidView;
        var result: DrawTextResult = .{};
        if (run.space == .world and !view.hasFiniteWorldTransform()) {
            self.recordRunReject(&result, .invalid_world_transform);
            return result;
        }
        const font = run.font;
        const font_entry = self.fonts.get(font.id) orelse return Error.ShapingFailed;

        const shaped = font_entry.loaded.shape(&self.shape_plan, run.text, .{}) catch return Error.ShapingFailed;
        const infos = shaped.infos;
        const positions = shaped.positions;
        self.recordShapedRun(&result, @intCast(infos.len));
        if (@import("builtin").mode == .Debug) {
            self.stats.runs_shaped += 1;
            self.stats.glyphs_shaped += @intCast(infos.len);
        }
        const run_screen_from_text = switch (run.space) {
            .world => core_types.Transform.compose(view.screen_from_world, run.transform),
            .screen => run.transform,
        };
        const color = run.color.rgba;
        const flags = run.fill_rule.shaderFlags();
        const start_glyph_count = batch.glyph_count;
        const start_meshlet_count = batch.meshlet_count;
        errdefer {
            batch.rollback(start_glyph_count, start_meshlet_count);
        }

        var pen_x: i64 = 0;
        var pen_y: i64 = 0;

        if (!run_screen_from_text.isFinite()) {
            for (infos) |_| self.recordGlyphReject(&result, .invalid_transform);
            return result;
        }

        for (infos, positions) |info, pos| {
            const glyph_x_hb = std.math.add(i64, pen_x, pos.x_offset) catch return Error.TextPositionOverflow;
            const glyph_y_hb = std.math.add(i64, pen_y, pos.y_offset) catch return Error.TextPositionOverflow;
            const glyph_x = units.hb26p6ToPixelsI64(glyph_x_hb);
            const glyph_y = units.hb26p6ToPixelsI64(glyph_y_hb);
            const screen_from_glyph_pixels = run_screen_from_text.translate(glyph_x, glyph_y);
            const screen_from_local = screen_from_glyph_pixels.scaleLinear(1.0 / units.hb_subpixels_per_pixel_f64);
            const local_from_screen = screen_from_local.inverse() orelse {
                self.recordGlyphReject(&result, .invalid_transform);
                try advancePen(&pen_x, &pen_y, pos);
                continue;
            };
            const precision_bits = switch (self.precision_policy.selectFractionBits(screen_from_local) catch |err| switch (err) {
                error.InvalidTransform => {
                    self.recordGlyphReject(&result, .invalid_transform);
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                },
                error.InvalidPrecisionPolicy => return Error.InvalidPrecisionPolicy,
            }) {
                .supported => |supported| blk: {
                    self.recordPrecisionSelection(supported.sigma, supported.required_bits);
                    break :blk supported.fraction_bits;
                },
                .unsupported => |unsupported| {
                    self.recordPrecisionSelection(unsupported.sigma, unsupported.required_bits);
                    self.recordGlyphReject(&result, .precision_unsupported);
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
                    .bounds_q = entry.bounds_q,
                    .precision_bits = entry.precision_bits,
                    .mesh_metadata = entry.mesh_metadata,
                };
            } else blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_misses += 1;
                break :blk self.ensureGlyphCached(backend, font_entry, cache_key, precision_bits) catch |err| switch (err) {
                    error.CacheEncodeUnsupported => {
                        self.recordGlyphReject(&result, .cache_encode_unsupported);
                        try advancePen(&pen_x, &pen_y, pos);
                        continue;
                    },
                    else => return err,
                };
            };

            if (!cached_glyph.blob_ref.isEmpty()) {
                const local_bounds = mesh_plan.localRectFromFixed(cached_glyph.bounds_q, cached_glyph.precision_bits);
                const screen_bounds = screen_from_local.applyRect(local_bounds);
                if (!screen_bounds.isFinite() or screen_bounds.isEmpty()) {
                    self.recordGlyphReject(&result, .nonfinite_bounds);
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                }
                if (!screen_bounds.intersects(mesh_plan.inflatedViewportRect(view, 1.0))) {
                    self.recordGlyphReject(&result, .host_culled);
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                }

                const glyph_anchor_q = mesh_plan.chooseGlyphAnchorQ(
                    cached_glyph.bounds_q,
                    cached_glyph.precision_bits,
                    local_from_screen,
                    .{
                        view.width * 0.5,
                        view.height * 0.5,
                    },
                );
                const anchor_local = mesh_plan.localPointFromFixed(glyph_anchor_q, cached_glyph.precision_bits);
                const screen_anchor = screen_from_local.apply(anchor_local);
                const screen_anchor_px = mesh_plan.castPoint2F32(screen_anchor) orelse {
                    self.recordGlyphReject(&result, .f32_chart_overflow);
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                };
                const screen_from_local_2x2 = mesh_plan.castAffineLinear2x2F32(screen_from_local) orelse {
                    self.recordGlyphReject(&result, .f32_chart_overflow);
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                };
                const local_from_screen_2x2 = mesh_plan.castAffineLinear2x2F32(local_from_screen) orelse {
                    self.recordGlyphReject(&result, .f32_chart_overflow);
                    try advancePen(&pen_x, &pen_y, pos);
                    continue;
                };

                const GlyphInstance = backend_contract.glyphInstanceType(@TypeOf(backend));
                const glyph_payload: GlyphInstance = .{
                    .color = color,
                    .blob_ref = cached_glyph.blob_ref.value,
                    .flags = flags,
                    .precision_bits = cached_glyph.precision_bits,
                    .glyph_anchor_q = glyph_anchor_q,
                    .screen_anchor_px = screen_anchor_px,
                    .screen_from_local_2x2 = screen_from_local_2x2,
                    .local_from_screen_2x2 = local_from_screen_2x2,
                };

                const glyph_mark = batch.glyph_count;
                const meshlet_mark = batch.meshlet_count;
                const glyph_index = try batch.appendGlyph(glyph_payload);
                try mesh_plan.appendGlyphMeshlets(
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
                if (batch.meshlet_count == meshlet_mark) {
                    batch.rollback(glyph_mark, meshlet_mark);
                    self.recordGlyphReject(&result, .meshlet_empty);
                } else {
                    self.recordEmitted(&result, 1, batch.meshlet_count - meshlet_mark);
                }
            } else {
                self.recordGlyphReject(&result, .empty_glyph);
            }

            try advancePen(&pen_x, &pen_y, pos);
        }

        return result;
    }

    fn recordShapedRun(self: *RendererCore, result: *DrawTextResult, glyphs: u32) void {
        saturatingIncrement(&self.frame_diagnostics.runs);
        self.frame_diagnostics.shaped_glyphs = saturatingAdd(self.frame_diagnostics.shaped_glyphs, glyphs);
        result.shaped_glyphs = saturatingAdd(result.shaped_glyphs, glyphs);
    }

    fn recordEmitted(self: *RendererCore, result: *DrawTextResult, glyphs: u32, meshlets: u32) void {
        self.frame_diagnostics.emitted_glyphs = saturatingAdd(self.frame_diagnostics.emitted_glyphs, glyphs);
        self.frame_diagnostics.emitted_meshlets = saturatingAdd(self.frame_diagnostics.emitted_meshlets, meshlets);
        result.emitted_glyphs = saturatingAdd(result.emitted_glyphs, glyphs);
        result.emitted_meshlets = saturatingAdd(result.emitted_meshlets, meshlets);
        if (@import("builtin").mode == .Debug) {
            self.stats.glyphs_written = saturatingAdd(self.stats.glyphs_written, glyphs);
            self.stats.meshlets_written = saturatingAdd(self.stats.meshlets_written, meshlets);
        }
    }

    fn recordPrecisionSelection(self: *RendererCore, sigma: f64, required_bits: u16) void {
        if (std.math.isFinite(sigma) and sigma > self.frame_diagnostics.max_sigma) {
            self.frame_diagnostics.max_sigma = sigma;
        }
        if (required_bits > self.frame_diagnostics.max_required_fraction_bits) {
            self.frame_diagnostics.max_required_fraction_bits = required_bits;
        }
    }

    fn recordRunReject(self: *RendererCore, result: *DrawTextResult, reason: RunRejectReason) void {
        incrementRunReject(&self.frame_diagnostics.run_rejects, reason);
        incrementRunReject(&result.run_rejects, reason);
        if (self.frame_diagnostics.first_blocking_reason == null) {
            self.frame_diagnostics.first_blocking_reason = .{ .run = reason };
        }
    }

    fn recordGlyphReject(self: *RendererCore, result: *DrawTextResult, reason: GlyphRejectReason) void {
        incrementGlyphReject(&self.frame_diagnostics.glyph_rejects, reason);
        incrementGlyphReject(&result.glyph_rejects, reason);
        if (isBlockingGlyphReject(reason) and self.frame_diagnostics.first_blocking_reason == null) {
            self.frame_diagnostics.first_blocking_reason = .{ .glyph = reason };
        }
        if (@import("builtin").mode == .Debug) {
            switch (reason) {
                .invalid_transform, .nonfinite_bounds, .f32_chart_overflow => self.stats.invalid_transform += 1,
                .precision_unsupported => self.stats.precision_insufficient += 1,
                .host_culled, .meshlet_empty => self.stats.host_culled += 1,
                .empty_glyph => self.stats.empty_glyphs_skipped += 1,
                .cache_encode_unsupported => {},
            }
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
            error.PrecisionUnsupported, error.GlyphTooLarge, error.GlyphOffsetOverflow => return error.CacheEncodeUnsupported,
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
            try self.store.glyph_cache.insert(.cold, cache_key, .{
                .blob_ref = GlyphBlobRef.empty,
                .pool_alloc = .{ .offset = 0, .size = 0 },
                .em_box = extent_box,
                .bounds_q = empty_bounds,
            });
            return .{
                .blob_ref = GlyphBlobRef.empty,
                .bounds_q = empty_bounds,
                .precision_bits = precision_bits,
                .mesh_metadata = .empty(),
            };
        }

        const blob_view = blob_decode.BlobView.initCoverageBlob(encoded.blob) catch return Error.ShapingFailed;
        const em_box = emBoxFromBlobView(blob_view);
        const bounds_q = fixedBoundsFromBlobView(blob_view);
        var mesh_metadata = try mesh_plan.metadataFromBlobView(self.allocator, blob_view);
        var owns_mesh_metadata = true;
        errdefer if (owns_mesh_metadata) mesh_metadata.deinit(self.allocator);
        const pool_alloc = self.store.pool_alloc.alloc(@intCast(encoded.data.len)) orelse {
            if (@import("builtin").mode == .Debug) self.stats.pool_exhausted += 1;
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
        try self.store.glyph_cache.insert(.cold, cache_key, .{
            .blob_ref = blob_ref,
            .pool_alloc = pool_alloc,
            .em_box = em_box,
            .bounds_q = bounds_q,
            .mesh_metadata = mesh_metadata,
        });
        return .{
            .blob_ref = blob_ref,
            .bounds_q = bounds_q,
            .precision_bits = precision_bits,
            .mesh_metadata = mesh_metadata,
        };
    }
};

fn incrementRunReject(counters: *RunRejectCounters, reason: RunRejectReason) void {
    switch (reason) {
        .invalid_world_transform => saturatingIncrement(&counters.invalid_world_transform),
    }
}

fn incrementGlyphReject(counters: *RejectCounters, reason: GlyphRejectReason) void {
    switch (reason) {
        .invalid_transform => saturatingIncrement(&counters.invalid_transform),
        .precision_unsupported => saturatingIncrement(&counters.precision_unsupported),
        .cache_encode_unsupported => saturatingIncrement(&counters.cache_encode_unsupported),
        .nonfinite_bounds => saturatingIncrement(&counters.nonfinite_bounds),
        .host_culled => saturatingIncrement(&counters.host_culled),
        .f32_chart_overflow => saturatingIncrement(&counters.f32_chart_overflow),
        .meshlet_empty => saturatingIncrement(&counters.meshlet_empty),
        .empty_glyph => saturatingIncrement(&counters.empty_glyph),
    }
}

fn isBlockingGlyphReject(reason: GlyphRejectReason) bool {
    return switch (reason) {
        .invalid_transform,
        .precision_unsupported,
        .cache_encode_unsupported,
        .nonfinite_bounds,
        .f32_chart_overflow,
        .meshlet_empty,
        => true,
        .host_culled,
        .empty_glyph,
        => false,
    };
}

fn advancePen(pen_x: *i64, pen_y: *i64, pos: anytype) Error!void {
    pen_x.* = std.math.add(i64, pen_x.*, pos.x_advance) catch return Error.TextPositionOverflow;
    pen_y.* = std.math.add(i64, pen_y.*, pos.y_advance) catch return Error.TextPositionOverflow;
}

const TestGlyphInstance = extern struct {
    color: [4]f32,
    blob_ref: u32,
    flags: u32,
    precision_bits: u32,
    glyph_anchor_q: [2]i32,
    screen_anchor_px: [2]f32,
    screen_from_local_2x2: [4]f32,
    local_from_screen_2x2: [4]f32,
};

const TestGlyphMeshlet = extern struct {
    glyph_index: u32,
    _pad0: u32 = 0,
    rect_min_q: [2]i32,
    rect_max_q: [2]i32,
    mesh_anchor_q: [2]i32,
    screen_anchor_px: [2]f32,
};

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

const test_font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";
const test_view = core_types.View.identity(1280, 720);

test "render: FakeBackend satisfies backend contract" {
    backend_contract.checkBackend(FakeBackend);
    backend_contract.checkBackend(*FakeBackend);
    try std.testing.expect(true);
}

test "RendererOptions mirrors current default capacities" {
    const opts = RendererOptions{};
    try std.testing.expectEqual(@as(u32, 16_384), opts.max_glyphs_per_frame);
}

test "render: RendererCore rejects invalid options before resource allocation" {
    try std.testing.expectError(
        error.InvalidRendererOptions,
        RendererCore.init(std.testing.allocator, .{ .min_storage_alignment = 0 }),
    );
}

test "render: emBoxFromBlobBounds uses encoded curve bounds" {
    const blob_encode = @import("../blob/encode.zig");
    const regularize = @import("../outline/regularize.zig");
    var blob = try blob_encode.curves(std.testing.allocator, &.{
        regularize.lineAsCubic(.{ .x = -1.0, .y = -0.5 }, .{ .x = 3.0, .y = 4.5 }),
    }, blob_format.default_fraction_bits);
    defer blob.deinit();

    const em_box = try emBoxFromBlobBounds(blob);
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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, test_view, .{
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
    try std.testing.expect(std.math.isFinite(glyphs[0].screen_anchor_px[0]));
    try std.testing.expect(meshlets[0].glyph_index < batch.glyphCount());
    try std.testing.expect(meshlets[0].rect_max_q[0] > meshlets[0].rect_min_q[0]);
    try std.testing.expect(meshlets[0].rect_max_q[1] > meshlets[0].rect_min_q[1]);
    try std.testing.expect(std.math.isFinite(meshlets[0].screen_anchor_px[0]));
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 1), core.stats.runs_shaped);
        try std.testing.expect(core.stats.glyphs_shaped >= batch.glyphCount());
        try std.testing.expectEqual(batch.glyphCount(), core.stats.glyphs_written);
        try std.testing.expectEqual(batch.meshletCount(), core.stats.meshlets_written);
        try std.testing.expect(core.stats.cache_misses > 0);
        try std.testing.expect(core.stats.glyphs_encoded > 0);
        try std.testing.expect(core.stats.outline_segments > 0);
        try std.testing.expect(core.stats.regularized_spans > 0);
        try std.testing.expect(core.stats.blob_bytes_uploaded > 0);
        try std.testing.expect(core.stats.pool.used_bytes > 0);
    }

    const refs_after_first = backend.next_ref;
    _ = try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "Hi",
        .transform = core_types.Transform.translation(10, 20),
        .color = .white,
    });
    try std.testing.expectEqual(refs_after_first, backend.next_ref);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expect(core.stats.cache_hits > 0);
        try std.testing.expectEqual(batch.glyphCount(), core.stats.glyphs_written);
    }
}

test "render: RendererCore skips empty glyph instances while preserving cache entry" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, test_view, .{
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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, test_view, .{
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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    const world = core_types.Transform.translation(-1.0e12, -1.0e12);
    const run_transform = core_types.Transform.translation(1.0e12 + 32.0, 1.0e12 + 48.0);
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, core_types.View.init(1280, 720, world), .{
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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    const result = try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "A",
        .transform = core_types.Transform.scale(1.0e12, 1.0e12),
        .color = .white,
    });

    try std.testing.expectEqual(@as(u32, 0), batch.glyphCount());
    try std.testing.expectEqual(@as(u32, 0), batch.meshletCount());
    try std.testing.expect(result.shaped_glyphs > 0);
    try std.testing.expectEqual(result.shaped_glyphs, result.glyph_rejects.total());
    try std.testing.expectEqual(@as(u32, 0), result.emitted_glyphs);
    try std.testing.expectEqual(result.shaped_glyphs, core.frameDiagnostics().glyph_rejects.total());
    try std.testing.expect(core.frameDiagnostics().hasPrecisionUnsupported());
    const warnings = core.frameDiagnostics().warnings();
    try std.testing.expect(warnings.slice().len >= 2);
    if (@import("builtin").mode == .Debug) {
        try std.testing.expect(core.stats.precision_insufficient > 0);
    }

    core.beginFrame(0, &backend);
    try std.testing.expect(!core.frameDiagnostics().hasPrecisionUnsupported());
}

test "render: screen-space runs only require a finite viewport" {
    var core = try RendererCore.init(std.testing.allocator, .{ .max_glyphs_per_frame = 4 });
    defer core.deinit();

    var pool: [16 * 1024]u8 = undefined;
    var backend = FakeBackend{ .pool = &pool };
    var glyphs: [4]TestGlyphInstance = undefined;
    var meshlets: [4 * mesh_limits.max_subdivisions_per_glyph]TestGlyphMeshlet = undefined;
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    const invalid_world = core_types.Transform.init(std.math.nan(f64), 0, 0, 1, 0, 0);
    const view = core_types.View.init(1280, 720, invalid_world);
    core.beginFrame(0, &backend);

    const world_result = try core.appendRun(&backend, &batch, view, .{
        .font = font,
        .text = "A",
        .color = .white,
    });
    try std.testing.expectEqual(@as(u32, 0), world_result.shaped_glyphs);
    try std.testing.expectEqual(@as(u32, 1), world_result.run_rejects.invalid_world_transform);

    const screen_result = try core.appendScreenRun(&backend, &batch, view, .{
        .font = font,
        .text = "A",
        .screen_from_text = core_types.Transform.translation(32, 48),
        .color = .white,
    });
    try std.testing.expect(screen_result.emitted());
    try std.testing.expect(batch.glyphCount() > 0);
    try std.testing.expectEqual(@as(u32, 1), core.frameDiagnostics().run_rejects.invalid_world_transform);
    try std.testing.expect(core.frameDiagnostics().hasVisiblePayload());
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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.setRetireAfterToken(7);
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, test_view, .{
        .font = font,
        .text = "A",
        .color = .white,
    });

    core.setRetireAfterToken(7);
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, test_view, .{
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
    var batch = frame_batch_mod.FrameBatch(TestGlyphInstance, TestGlyphMeshlet).init(&glyphs, &meshlets);

    const font = try core.loadFont(.{ .path = test_font_path }, .{ .size_px = 24 });
    core.beginFrame(0, &backend);
    _ = try core.appendRun(&backend, &batch, test_view, .{
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
