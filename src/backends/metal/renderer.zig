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
const AbiGlyphMeshlet = gpu_structs.GlyphMeshlet;

pub const GlyphInstance = AbiGlyphInstance;
pub const GlyphMeshlet = AbiGlyphMeshlet;
pub const FrameParams = gpu_structs.FrameParams;

const frames_in_flight = metal.frame_slot_count;

pub const Context = metal.Context;
pub const Host = metal.Host;
pub const Error = metal.Error || error{
    InvalidView,
};

pub const RendererOptions = render.RendererOptions;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const shader_stats_enabled = backend_options.shader_stats;
pub const Stats = if (@import("builtin").mode == .Debug) struct {
    core: render.Stats = .{},
    slot_wait_ns: u64 = 0,
    shader: heavy_slug.ShaderStats = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        if (backend_options.shader_stats) {
            const shader_ratios = self.shader.ratios();
            const meshlet_cull = self.shader.meshletCull();
            std.log.scoped(.renderer).debug(
                "metal stats: wait_ns={d} submitted_glyphs={d} submitted_meshlets={d} draw_chunks={d} meshlets={d}/{d} meshlet_culled={d} meshlet_cull=empty:{d},invalid:{d},zero_area:{d},clip:{d},nonfinite:{d} fragments={d} frag_per_glyph_milli={d} frag_per_meshlet_milli={d} meshlets_per_glyph_milli={d} fullscan_pm={d} curve_integrations={d}/{d} bbox_reject_pm={d} bbox_empty_pm={d} zero_pm={d}",
                .{
                    self.slot_wait_ns,
                    self.shader.submitted_glyphs,
                    self.shader.submitted_meshlets,
                    self.shader.draw_chunks,
                    self.shader.meshlets_emitted,
                    self.shader.mesh_workgroups,
                    self.shader.meshlets_culled,
                    meshlet_cull.empty_slices,
                    meshlet_cull.invalid_strips,
                    meshlet_cull.zero_area,
                    meshlet_cull.clip_empty,
                    meshlet_cull.non_finite,
                    self.shader.fragment_invocations,
                    shader_ratios.fragments_per_glyph_milli,
                    shader_ratios.fragments_per_meshlet_milli,
                    shader_ratios.meshlets_per_glyph_milli,
                    shader_ratios.full_scan_fragment_per_mille,
                    self.shader.totalCurveIntegrations(),
                    self.shader.totalCurveTests(),
                    shader_ratios.bbox_reject_per_mille,
                    shader_ratios.bbox_empty_fragment_per_mille,
                    shader_ratios.coverage_zero_fragment_per_mille,
                },
            );
        } else {
            std.log.scoped(.renderer).debug(
                "metal stats: wait_ns={d}",
                .{self.slot_wait_ns},
            );
        }
        self.core.log(.renderer);
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This()) void {}
};
pub const max_frames_in_flight = frames_in_flight;

pub const Target = struct {
    clear_color: [4]f32,
};

const FrameBatch = heavy_slug.core.render.FrameBatch(GlyphInstance, GlyphMeshlet);
const ShaderStatsBuffer = if (backend_options.shader_stats) metal.Buffer else void;

fn drawChunkCount(meshlet_count: u32) u32 {
    return (meshlet_count / metal.max_mesh_threadgroups_per_draw) +
        @intFromBool(meshlet_count % metal.max_mesh_threadgroups_per_draw != 0);
}

fn frameParamChunkCount(max_glyphs_per_frame: u32) u32 {
    return drawChunkCount(mesh_limits.maxMeshletsForGlyphCapacity(max_glyphs_per_frame));
}

fn byteSizeFor(comptime Element: type, count: usize) Error!usize {
    return std.math.mul(usize, count, @sizeOf(Element)) catch Error.BufferCreateFailed;
}

fn resetShaderStatsBuffer(buffer: metal.Buffer) void {
    shader_stats_mod.clearBytes(buffer.bytes()[0..@sizeOf(heavy_slug.ShaderStats)]);
}

fn seedShaderStatsBuffer(buffer: metal.Buffer, glyph_count: u32, meshlet_count: u32, draw_chunks: u32) void {
    const bytes: []align(@alignOf(u32)) u8 = @alignCast(buffer.bytes()[0..@sizeOf(heavy_slug.ShaderStats)]);
    shader_stats_mod.seedFrameSubmission(bytes, glyph_count, meshlet_count, draw_chunks);
}

fn readShaderStatsBuffer(buffer: metal.Buffer) heavy_slug.ShaderStats {
    const bytes: []align(@alignOf(u32)) const u8 = @alignCast(buffer.constBytes()[0..@sizeOf(heavy_slug.ShaderStats)]);
    return shader_stats_mod.Stats.fromBytes(bytes);
}

fn viewSizeU32(view: core_types.View) ?[2]u32 {
    if (!view.isFinite()) return null;
    if (view.width > @as(f64, @floatFromInt(std.math.maxInt(u32))) or
        view.height > @as(f64, @floatFromInt(std.math.maxInt(u32))))
    {
        return null;
    }
    const width: u32 = @intFromFloat(@round(view.width));
    const height: u32 = @intFromFloat(@round(view.height));
    if (width == 0 or height == 0) return null;
    return .{ width, height };
}

fn writeFrameParams(buffer: metal.Buffer, view_size: [2]u32, meshlet_count: u32) Error!void {
    var meshlet_base: u32 = 0;
    var chunk_index: usize = 0;
    while (meshlet_base < meshlet_count) : (chunk_index += 1) {
        const chunk_count = @min(meshlet_count - meshlet_base, metal.max_mesh_threadgroups_per_draw);
        const params = FrameParams{
            .viewport_size = .{ @floatFromInt(view_size[0]), @floatFromInt(view_size[1]) },
            .screen_from_framebuffer_2x2 = .{ 1, 0, 0, -1 },
            .screen_from_framebuffer_offset = .{ 0, @floatFromInt(view_size[1]) },
            .meshlet_count = chunk_count,
            .meshlet_base = meshlet_base,
        };
        const offset = chunk_index * @sizeOf(FrameParams);
        if (offset > buffer.size or @sizeOf(FrameParams) > buffer.size - offset) {
            return Error.DrawFailed;
        }
        @memcpy(buffer.bytes()[offset..][0..@sizeOf(FrameParams)], std.mem.asBytes(&params));
        meshlet_base += chunk_count;
    }
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
    meshlets: metal.Buffer,
    frame_params: metal.Buffer,
    shader_stats: ShaderStatsBuffer,

    fn deinit(self: FrameSlot) void {
        if (backend_options.shader_stats) self.shader_stats.deinit();
        self.frame_params.deinit();
        self.meshlets.deinit();
        self.glyphs.deinit();
    }
};

pub const Frame = struct {
    renderer: *Renderer,
    batch: FrameBatch,
    view: core_types.View,
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
        const token = try self.renderer.submitFrame(target, self.view, self.batch.glyphCount(), self.batch.meshletCount());
        self.batch.markSubmitted();
        self.submitted = true;
        return token;
    }
};

pub const Renderer = struct {
    pub const GlyphBlobRef = render.GlyphBlobRef;
    pub const FrameToken = render.FrameToken;
    pub const GlyphInstance = AbiGlyphInstance;
    pub const GlyphMeshlet = AbiGlyphMeshlet;

    context: Context,
    core: render.RendererCore,
    pool_buffer: metal.Buffer,
    frame_slots: [frames_in_flight]FrameSlot,
    active_frame: usize,
    frame_reserved: bool,
    slot_tokens: [frames_in_flight]render.FrameToken,
    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    debug_stats: Stats,
    last_shader_stats: heavy_slug.ShaderStats,

    pub fn init(
        context: Context,
        allocator: std.mem.Allocator,
        options: RendererOptions,
    ) !Renderer {
        var core = try render.RendererCore.init(allocator, options);
        errdefer core.deinit();

        const pool_buf = try metal.Buffer.init(context, options.pool_buffer_size);
        errdefer pool_buf.deinit();

        const glyph_buffer_size = try byteSizeFor(AbiGlyphInstance, @intCast(options.max_glyphs_per_frame));
        const meshlet_buffer_size = try byteSizeFor(AbiGlyphMeshlet, @intCast(mesh_limits.maxMeshletsForGlyphCapacity(options.max_glyphs_per_frame)));
        const frame_params_size = try byteSizeFor(FrameParams, @intCast(frameParamChunkCount(options.max_glyphs_per_frame)));
        var frame_slots: [frames_in_flight]FrameSlot = undefined;
        var initialized_slots: usize = 0;
        errdefer {
            for (frame_slots[0..initialized_slots]) |slot| slot.deinit();
        }
        for (&frame_slots) |*slot| {
            const glyph_buffer = try metal.Buffer.init(context, glyph_buffer_size);
            errdefer glyph_buffer.deinit();

            const meshlet_buffer = try metal.Buffer.init(context, meshlet_buffer_size);
            errdefer meshlet_buffer.deinit();

            const params_buffer = try metal.Buffer.init(context, frame_params_size);
            errdefer params_buffer.deinit();

            var shader_stats: ShaderStatsBuffer = undefined;
            if (backend_options.shader_stats) {
                shader_stats = try metal.Buffer.init(context, @sizeOf(heavy_slug.ShaderStats));
                resetShaderStatsBuffer(shader_stats);
            }

            slot.* = .{
                .glyphs = glyph_buffer,
                .meshlets = meshlet_buffer,
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
            .debug_stats = .{},
            .last_shader_stats = .{},
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
            metal.releaseFrameSlot(self.context, @intCast(self.active_frame));
            self.frame_reserved = false;
        }

        self.active_frame = (self.active_frame + 1) % frames_in_flight;
        self.debug_stats.reset();
        var error_buf: [metal.diagnostic_capacity]u8 = undefined;
        @memset(&error_buf, 0);
        const wait_start = monotonicNs();
        metal.waitFrameSlot(self.context, @intCast(self.active_frame), &error_buf) catch {
            std.log.err("Metal frame slot wait failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.DrawFailed;
        };
        if (@import("builtin").mode == .Debug) {
            const wait_end = monotonicNs();
            self.debug_stats.slot_wait_ns = if (wait_end >= wait_start) wait_end - wait_start else 0;
        }
        if (backend_options.shader_stats and self.slot_tokens[self.active_frame] > self.completed_frame) {
            self.last_shader_stats = readShaderStatsBuffer(self.frame_slots[self.active_frame].shader_stats);
        }
        if (self.slot_tokens[self.active_frame] > self.completed_frame) {
            self.completed_frame = self.slot_tokens[self.active_frame];
        }
        if (backend_options.shader_stats) resetShaderStatsBuffer(self.frame_slots[self.active_frame].shader_stats);
        self.frame_reserved = true;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
    }

    pub fn stats(self: *const Renderer) Stats {
        if (@import("builtin").mode != .Debug) return .{};
        var out = self.debug_stats;
        out.core = self.core.stats;
        if (backend_options.shader_stats) out.shader = self.last_shader_stats;
        return out;
    }

    pub fn beginFrame(self: *Renderer, view: core_types.View) Error!Frame {
        try self.reserveFrameSlot();
        const glyphs: [*]AbiGlyphInstance = @ptrCast(@alignCast(self.frame_slots[self.active_frame].glyphs.mapped));
        const glyph_slice = glyphs[0..self.core.max_glyphs_per_frame];
        const meshlets: [*]AbiGlyphMeshlet = @ptrCast(@alignCast(self.frame_slots[self.active_frame].meshlets.mapped));
        const meshlet_slice = meshlets[0..mesh_limits.maxMeshletsForGlyphCapacity(self.core.max_glyphs_per_frame)];
        return .{
            .renderer = self,
            .batch = FrameBatch.init(glyph_slice, meshlet_slice),
            .view = view,
        };
    }

    pub fn uploadBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !GlyphBlobRef {
        if (pool_alloc.offset > self.pool_buffer.size or data.len > self.pool_buffer.size - pool_alloc.offset) {
            return Error.DrawFailed;
        }
        const dst = self.pool_buffer.bytes()[pool_alloc.offset..][0..data.len];
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

    fn submitFrame(self: *Renderer, target: Target, view: core_types.View, glyph_count: u32, meshlet_count: u32) Error!render.FrameToken {
        if (glyph_count == 0 or meshlet_count == 0) {
            if (self.frame_reserved) {
                metal.releaseFrameSlot(self.context, @intCast(self.active_frame));
                self.frame_reserved = false;
            }
            return self.last_submitted_frame;
        }

        const view_size = viewSizeU32(view) orelse return Error.InvalidView;
        const clear_color = target.clear_color;
        const frame_slot = &self.frame_slots[self.active_frame];
        const draw_chunks = drawChunkCount(meshlet_count);
        if (backend_options.shader_stats) {
            seedShaderStatsBuffer(frame_slot.shader_stats, glyph_count, meshlet_count, draw_chunks);
        }
        const shader_stats_buffer: ?metal.Buffer = if (backend_options.shader_stats)
            frame_slot.shader_stats
        else
            null;

        try writeFrameParams(frame_slot.frame_params, view_size, meshlet_count);

        const workgroup_count = meshlet_count;
        var error_buf: [metal.diagnostic_capacity]u8 = undefined;
        @memset(&error_buf, 0);
        metal.draw(self.context, .{
            .viewport = view_size,
            .clear_color = clear_color,
            .glyphs = frame_slot.glyphs,
            .meshlets = frame_slot.meshlets,
            .frame_params = frame_slot.frame_params,
            .frame_params_stride = @sizeOf(FrameParams),
            .glyph_pool = self.pool_buffer,
            .shader_stats = shader_stats_buffer,
            .workgroup_count = workgroup_count,
            .slot_index = @intCast(self.active_frame),
        }, &error_buf) catch {
            std.log.err("Metal draw failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            metal.releaseFrameSlot(self.context, @intCast(self.active_frame));
            self.frame_reserved = false;
            return Error.DrawFailed;
        };
        self.frame_reserved = false;

        if (@import("builtin").mode == .Debug) {
            self.core.stats.submitted_glyphs += glyph_count;
            self.core.stats.submitted_meshlets += meshlet_count;
            self.core.stats.pool = self.core.poolSnapshot();
        }
        self.last_submitted_frame +%= 1;
        self.slot_tokens[self.active_frame] = self.last_submitted_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        return self.last_submitted_frame;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.frame_reserved) {
            metal.releaseFrameSlot(self.context, @intCast(self.active_frame));
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
    heavy_slug.core.render.checkBackend(Renderer);
}

test "Metal frame params are chunked by mesh threadgroup draw limit" {
    try std.testing.expectEqual(@as(u32, 0), drawChunkCount(0));
    try std.testing.expectEqual(@as(u32, 1), drawChunkCount(1));
    try std.testing.expectEqual(@as(u32, 2), drawChunkCount(metal.max_mesh_threadgroups_per_draw + 1));
    try std.testing.expectEqual(@as(u32, 0), frameParamChunkCount(0));
    try std.testing.expectEqual(@as(u32, 1), frameParamChunkCount(1));
    try std.testing.expectEqual(@as(u32, 2), frameParamChunkCount((metal.max_mesh_threadgroups_per_draw / mesh_limits.max_subdivisions_per_glyph) + 1));
}

test "Metal view size conversion rejects zero rounded extents" {
    try std.testing.expect(viewSizeU32(core_types.View.identity(1, 1)) != null);
    try std.testing.expect(viewSizeU32(core_types.View.identity(0.25, 1)) == null);
    try std.testing.expect(viewSizeU32(core_types.View.identity(1, 0.25)) == null);
}

test "Metal bridge resource indices match generated Slang MSL" {
    const indices = metal.resourceIndices();
    try std.testing.expectEqual(@as(u32, 0), indices.glyph_pool);
    try std.testing.expectEqual(@as(u32, 1), indices.glyphs);
    try std.testing.expectEqual(@as(u32, 2), indices.meshlets);
    const params_index: u32 = if (backend_options.shader_stats) 4 else 3;
    try std.testing.expectEqual(params_index, indices.frame_params);
    try std.testing.expectEqual(@as(u32, 3), indices.shader_stats);

    const params_pattern = if (backend_options.shader_stats)
        "constant* pc_1 [[buffer(4)]]"
    else
        "constant* pc_1 [[buffer(3)]]";
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "GlyphInstance_0 device* glyphs_1 [[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "GlyphMeshlet_0 device* meshlets_1 [[buffer(2)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "glyphPool_") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[buffer(0)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, params_pattern) != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "uint32_t device* glyphPool_") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "GlyphInstance_0 device* glyphs_1 [[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "GlyphMeshlet_0 device* meshlets_1 [[buffer(2)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[buffer(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, params_pattern) != null);
    if (backend_options.shader_stats) {
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "shaderStats_") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[buffer(3)]]") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "shaderStats_") != null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[buffer(3)]]") != null);
    } else {
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "shaderStats_") == null);
        try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "shaderStats_") == null);
    }
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[user(TEXCOORD_1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[user(TEXCOORD_2)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.mesh, "[[user(TEXCOORD_6)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[user(TEXCOORD_1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[user(TEXCOORD_2)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "[[user(TEXCOORD_6)]]") == null);
    try std.testing.expect(std.mem.indexOf(u8, msl_shaders.fragment, "user(TEXCOORD__1)") == null);
}

test "Metal bridge geometry limits match shared mesh ABI" {
    const limits = metal.geometryLimits();
    try std.testing.expectEqual(@as(u32, 0), limits.object_threadgroup_size);
    try std.testing.expectEqual(mesh_limits.mesh_thread_count, limits.mesh_threadgroup_size);
    try std.testing.expectEqual(metal.max_mesh_threadgroups_per_draw, limits.max_mesh_threadgroups_per_draw);
}
