const std = @import("std");
const heavy_slug = @import("heavy_slug");
const gpu_structs = @import("gpu_structs");
const msl_shaders = @import("msl_shaders");
const backend_options = @import("heavy_slug_backend_options");
const metal = @import("context.zig");

const pool_mod = heavy_slug.core.cache.byte_pool;
const render = heavy_slug.core.render.renderer_core;
const core_types = heavy_slug.core.types;
const mesh_limits = heavy_slug.gpu.mesh_limits;
const shader_stats_mod = heavy_slug.gpu.shader_stats;

const AbiGlyphInstance = gpu_structs.GlyphInstance;

pub const GlyphInstance = AbiGlyphInstance;
pub const FrameParams = gpu_structs.FrameParams;

const frames_in_flight = 3;

pub const Context = metal.Context;
pub const Host = metal.Host;
pub const Error = metal.Error;

pub const RendererOptions = render.RendererOptions;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const shader_stats_enabled = backend_options.shader_stats;
pub const Stats = if (@import("builtin").mode == .Debug) struct {
    common: render.Stats = .{},
    frame_slot_wait_ns: u64 = 0,
    shader: heavy_slug.ShaderStats = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        if (backend_options.shader_stats) {
            const shader_analysis = self.shader.analysis();
            const mesh_cull = self.shader.meshCullBreakdown();
            std.log.scoped(.renderer).debug(
                "metal stats: wait_ns={d} task_visible={d}/{d} mesh_tiles={d}/{d} tile_culled={d} mesh_cull=empty:{d},invalid:{d},zero_area:{d},clip:{d},nonfinite:{d} fragments={d} frag_per_glyph_milli={d} frag_per_tile_milli={d} fullscan_pm={d} curve_integrations={d}/{d} bbox_reject_pm={d} bbox_empty_pm={d} zero_pm={d}",
                .{
                    self.frame_slot_wait_ns,
                    self.shader.task_glyphs_visible,
                    self.shader.task_glyphs_tested,
                    self.shader.mesh_tiles_emitted,
                    self.shader.mesh_workgroups,
                    self.shader.mesh_tiles_culled,
                    mesh_cull.empty_slices,
                    mesh_cull.invalid_strips,
                    mesh_cull.zero_area,
                    mesh_cull.clip_empty,
                    mesh_cull.non_finite,
                    self.shader.fragment_invocations,
                    shader_analysis.fragments_per_visible_glyph_milli,
                    shader_analysis.fragments_per_mesh_tile_milli,
                    shader_analysis.full_scan_fragment_per_mille,
                    self.shader.totalCurveIntegrations(),
                    self.shader.totalCurveTests(),
                    shader_analysis.bbox_reject_per_mille,
                    shader_analysis.bbox_empty_fragment_per_mille,
                    shader_analysis.coverage_zero_fragment_per_mille,
                },
            );
        } else {
            std.log.scoped(.renderer).debug(
                "metal stats: wait_ns={d}",
                .{self.frame_slot_wait_ns},
            );
        }
        self.common.log(.renderer);
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This()) void {}
};
pub const max_frames_in_flight = frames_in_flight;

pub const Target = struct {
    clear_color: [4]f32,
};

const GlyphBatch = heavy_slug.core.render.GlyphBatch(GlyphInstance);
const ShaderStatsBuffer = if (backend_options.shader_stats) metal.Buffer else void;

fn resetShaderStatsBuffer(buffer: metal.Buffer) void {
    shader_stats_mod.clearBytes(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
}

fn readShaderStatsBuffer(buffer: metal.Buffer) heavy_slug.ShaderStats {
    const bytes: []align(@alignOf(u32)) const u8 = @alignCast(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
    return shader_stats_mod.Snapshot.fromBytes(bytes);
}

fn viewportToU32(view: core_types.FrameView2D) ?[2]u32 {
    if (!view.isFinite()) return null;
    if (view.viewport_width > @as(f64, @floatFromInt(std.math.maxInt(u32))) or
        view.viewport_height > @as(f64, @floatFromInt(std.math.maxInt(u32))))
    {
        return null;
    }
    return .{
        @intFromFloat(@round(view.viewport_width)),
        @intFromFloat(@round(view.viewport_height)),
    };
}

fn monotonicNs() u64 {
    var ts: std.posix.timespec = undefined;
    switch (std.posix.errno(std.posix.system.clock_gettime(std.posix.CLOCK.MONOTONIC, &ts))) {
        .SUCCESS => {
            const sec: u64 = @intCast(ts.sec);
            const nsec: u64 = @intCast(ts.nsec);
            return sec * std.time.ns_per_s + nsec;
        },
        else => return 0,
    }
}

const FrameSlot = struct {
    glyphs: metal.Buffer,
    frame_params: metal.Buffer,
    shader_stats: ShaderStatsBuffer,

    fn deinit(self: FrameSlot) void {
        if (backend_options.shader_stats) self.shader_stats.deinit();
        self.frame_params.deinit();
        self.glyphs.deinit();
    }
};

pub const Frame = struct {
    renderer: *Renderer,
    batch: GlyphBatch,
    view: core_types.FrameView2D,
    submitted: bool = false,

    pub fn drawText(
        self: *Frame,
        run: heavy_slug.TextRun,
    ) !void {
        if (self.submitted) return error.FrameAlreadySubmitted;
        try self.renderer.core.appendRun(self.renderer, &self.batch, self.view, run);
    }

    pub fn submit(self: *Frame, target: Target) !render.FrameToken {
        if (self.submitted) return error.FrameAlreadySubmitted;
        const token = try self.renderer.submitFrame(target, self.view, self.batch.count());
        self.batch.markSubmitted();
        self.submitted = true;
        return token;
    }
};

pub const Renderer = struct {
    pub const GlyphBlobRef = render.GlyphBlobRef;
    pub const FrameToken = render.FrameToken;
    pub const GlyphInstance = AbiGlyphInstance;

    context: Context,
    core: render.RendererCore,
    pool_buffer: metal.Buffer,
    frame_slots: [frames_in_flight]FrameSlot,
    active_frame: u32,
    frame_reserved: bool,
    slot_tokens: [frames_in_flight]render.FrameToken,
    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    stats: Stats,
    shader_stats_snapshot: heavy_slug.ShaderStats,

    pub fn init(
        context: Context,
        allocator: std.mem.Allocator,
        options: RendererOptions,
    ) !Renderer {
        var core = try render.RendererCore.init(allocator, options);
        errdefer core.deinit();

        const pool_buf = try metal.Buffer.init(context, options.pool_buffer_size);
        errdefer pool_buf.deinit();

        const glyph_buffer_size = @as(usize, options.max_glyphs_per_frame) * @sizeOf(AbiGlyphInstance);
        var frame_slots: [frames_in_flight]FrameSlot = undefined;
        var initialized_slots: usize = 0;
        errdefer {
            for (frame_slots[0..initialized_slots]) |slot| slot.deinit();
        }
        for (&frame_slots) |*slot| {
            const glyph_buffer = try metal.Buffer.init(context, glyph_buffer_size);
            errdefer glyph_buffer.deinit();

            const params_buffer = try metal.Buffer.init(context, @sizeOf(FrameParams));
            errdefer params_buffer.deinit();

            var shader_stats: ShaderStatsBuffer = undefined;
            if (backend_options.shader_stats) {
                shader_stats = try metal.Buffer.init(context, @sizeOf(heavy_slug.ShaderStats));
                resetShaderStatsBuffer(shader_stats);
            }

            slot.* = .{
                .glyphs = glyph_buffer,
                .frame_params = params_buffer,
                .shader_stats = shader_stats,
            };
            initialized_slots += 1;
        }

        return .{
            .context = context,
            .core = core,
            .pool_buffer = pool_buf,
            .frame_slots = frame_slots,
            .active_frame = frames_in_flight - 1,
            .frame_reserved = false,
            .slot_tokens = .{0} ** frames_in_flight,
            .last_submitted_frame = 0,
            .completed_frame = 0,
            .stats = .{},
            .shader_stats_snapshot = .{},
        };
    }

    pub fn loadFont(
        self: *Renderer,
        source: core_types.FontSource,
        options: core_types.FontOptions,
    ) !FontHandle {
        return self.core.loadFont(source, options);
    }

    pub fn unloadFont(self: *Renderer, handle: FontHandle) !void {
        self.core.setRetireAfterToken(self.last_submitted_frame);
        try self.core.unloadFont(handle);
    }

    fn reserveFrameSlot(self: *Renderer) Error!void {
        if (self.frame_reserved) {
            metal.releaseFrameSlot(self.context, self.active_frame);
            self.frame_reserved = false;
        }

        self.active_frame = (self.active_frame + 1) % frames_in_flight;
        self.stats.reset();
        var error_buf: [2048]u8 = undefined;
        @memset(&error_buf, 0);
        const wait_start = monotonicNs();
        metal.waitFrameSlot(self.context, self.active_frame, &error_buf) catch {
            std.log.err("Metal frame slot wait failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.MetalDrawFailed;
        };
        if (@import("builtin").mode == .Debug) {
            const wait_end = monotonicNs();
            self.stats.frame_slot_wait_ns = if (wait_end >= wait_start) wait_end - wait_start else 0;
        }
        if (backend_options.shader_stats and self.slot_tokens[self.active_frame] > self.completed_frame) {
            self.shader_stats_snapshot = readShaderStatsBuffer(self.frame_slots[self.active_frame].shader_stats);
        }
        if (self.slot_tokens[self.active_frame] > self.completed_frame) {
            self.completed_frame = self.slot_tokens[self.active_frame];
        }
        if (backend_options.shader_stats) resetShaderStatsBuffer(self.frame_slots[self.active_frame].shader_stats);
        self.frame_reserved = true;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
    }

    pub fn statsSnapshot(self: *const Renderer) Stats {
        if (@import("builtin").mode != .Debug) return .{};
        var out = self.stats;
        out.common = self.core.stats;
        if (backend_options.shader_stats) out.shader = self.shader_stats_snapshot;
        return out;
    }

    pub fn beginFrame(self: *Renderer, view: core_types.FrameView2D) Error!Frame {
        try self.reserveFrameSlot();
        const glyphs: [*]AbiGlyphInstance = @ptrCast(@alignCast(self.frame_slots[self.active_frame].glyphs.mapped));
        const glyph_slice = glyphs[0..self.core.max_glyphs_per_frame];
        return .{
            .renderer = self,
            .batch = GlyphBatch.init(glyph_slice),
            .view = view,
        };
    }

    pub fn uploadBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !GlyphBlobRef {
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..data.len];
        @memcpy(dst, data);
        return GlyphBlobRef.from(pool_alloc.offset);
    }

    pub fn retireBlob(self: *Renderer, _: GlyphBlobRef) void {
        _ = self;
        // Metal stores glyph blob refs as byte offsets into one buffer; RendererCore
        // frees the paired pool allocation only after a completed frame token.
    }

    pub fn completedFrameToken(self: *const Renderer) render.FrameToken {
        return self.completed_frame;
    }

    fn submitFrame(self: *Renderer, target: Target, view: core_types.FrameView2D, glyph_count: u32) Error!render.FrameToken {
        if (glyph_count == 0) {
            if (self.frame_reserved) {
                metal.releaseFrameSlot(self.context, self.active_frame);
                self.frame_reserved = false;
            }
            return self.last_submitted_frame;
        }

        const viewport = viewportToU32(view) orelse return Error.InvalidFrameView;
        const clear_color = target.clear_color;
        const frame_slot = &self.frame_slots[self.active_frame];
        const shader_stats_buffer: ?metal.Buffer = if (backend_options.shader_stats)
            frame_slot.shader_stats
        else
            null;

        const params = FrameParams{
            .viewport_size = .{ @floatFromInt(viewport[0]), @floatFromInt(viewport[1]) },
            .glyph_count = glyph_count,
            .glyph_base = 0,
            .diagnostic_flags = 0,
        };
        const params_bytes = frame_slot.frame_params.mapped[0..@sizeOf(FrameParams)];
        @memcpy(params_bytes, std.mem.asBytes(&params));

        const workgroup_count = mesh_limits.taskWorkgroupCount(glyph_count);
        var error_buf: [2048]u8 = undefined;
        @memset(&error_buf, 0);
        metal.draw(self.context, .{
            .viewport = viewport,
            .clear_color = clear_color,
            .glyphs = frame_slot.glyphs,
            .frame_params = frame_slot.frame_params,
            .glyph_pool = self.pool_buffer,
            .shader_stats = shader_stats_buffer,
            .workgroup_count = workgroup_count,
            .slot_index = self.active_frame,
        }, &error_buf) catch {
            std.log.err("Metal draw failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            metal.releaseFrameSlot(self.context, self.active_frame);
            self.frame_reserved = false;
            return Error.MetalDrawFailed;
        };
        self.frame_reserved = false;

        if (@import("builtin").mode == .Debug) {
            self.core.stats.instances_submitted += glyph_count;
            self.core.stats.pool = self.core.poolSnapshot();
        }
        self.last_submitted_frame +%= 1;
        self.slot_tokens[self.active_frame] = self.last_submitted_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        return self.last_submitted_frame;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.frame_reserved) {
            metal.releaseFrameSlot(self.context, self.active_frame);
            self.frame_reserved = false;
        }
        metal.waitSubmitted(self.context);
        self.completed_frame = std.math.maxInt(render.FrameToken);
        self.core.retireCompleted(self.completed_frame, self);
        for (self.frame_slots) |slot| slot.deinit();
        self.pool_buffer.deinit();
        self.core.deinit();
        self.* = undefined;
    }
};

test "Metal renderer public API compiles" {
    _ = Context;
    _ = Host;
    _ = Renderer;
    try std.testing.expectEqual(@as(usize, 3), max_frames_in_flight);
    try std.testing.expectEqual(backend_options.shader_stats, shader_stats_enabled);
    _ = @TypeOf(Context.init);
    _ = @TypeOf(Renderer.init);
    heavy_slug.core.render.BackendContract(Renderer);
}

test "Metal bridge resource indices match generated Slang MSL" {
    const indices = metal.resourceIndices();
    try std.testing.expectEqual(@as(u32, 0), indices.glyph_pool);
    try std.testing.expectEqual(@as(u32, 1), indices.glyphs);
    const params_index: u32 = if (backend_options.shader_stats) 3 else 2;
    try std.testing.expectEqual(params_index, indices.frame_params);
    try std.testing.expectEqual(@as(u32, 2), indices.shader_stats);

    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.task, "GlyphInstance_0 device* glyphs_1 [[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.task, "[[buffer(0)]]") == null);
    const params_pattern = if (backend_options.shader_stats)
        "constant* pc_1 [[buffer(3)]]"
    else
        "constant* pc_1 [[buffer(2)]]";
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.task, params_pattern) != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "GlyphInstance_0 device* glyphs_1 [[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "uint32_t device* glyphPool_") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[buffer(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, params_pattern) != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "uint32_t device* glyphPool_") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[buffer(0)]]") != null);
    if (backend_options.shader_stats) {
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.task, "shaderStats_") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.task, "[[buffer(2)]]") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "shaderStats_") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[buffer(2)]]") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "shaderStats_") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[buffer(2)]]") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.task, "shaderStats_") == null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "shaderStats_") == null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "shaderStats_") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[user(TEXCOORD_1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[user(TEXCOORD_5)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[user(TEXCOORD_6)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[user(TEXCOORD_1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[user(TEXCOORD_5)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[user(TEXCOORD_6)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "user(TEXCOORD__1)") == null);
}

test "Metal bridge geometry limits match shared mesh ABI" {
    const limits = metal.geometryLimits();
    try std.testing.expectEqual(mesh_limits.task_group_size, limits.task_threadgroup_size);
    try std.testing.expectEqual(mesh_limits.mesh_thread_count, limits.mesh_threadgroup_size);
    try std.testing.expectEqual(mesh_limits.task_max_meshlets, limits.task_max_meshlets);
    try std.testing.expectEqual(mesh_limits.task_payload_bytes, limits.task_payload_bytes);
}
