const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const gpu_context = @import("context.zig");
const bindings = @import("bindings.zig");
const draw_plan = @import("draw_plan.zig");
const memory = @import("memory.zig");
const shader_program_mod = @import("shader_program.zig");
const backend_options = @import("heavy_slug_backend_options");
const render = heavy_slug.core.render.renderer_core;
const core_types = heavy_slug.core.types;
const pool_mod = heavy_slug.core.cache.byte_pool;
const mesh_limits = heavy_slug.gpu.mesh_limits;
const shader_stats_mod = heavy_slug.gpu.shader_stats;

pub const Error = memory.Error || draw_plan.Error || error{
    FrameResourcesInUse,
};

pub const RendererOptions = render.RendererOptions;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const max_frames_in_flight = frames_in_flight;
pub const shader_stats_enabled = backend_options.shader_stats;

const frames_in_flight = 3;

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    core: render.Stats = .{},
    binding_writes: u32 = 0,
    binding_pushes: u32 = 0,
    frame_resources_in_use: u32 = 0,
    shader: heavy_slug.ShaderStats = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        if (backend_options.shader_stats) {
            const shader_ratios = self.shader.ratios();
            const meshlet_cull = self.shader.meshletCull();
            std.log.scoped(.renderer).debug(
                "vulkan stats: binding_writes={d} binding_pushes={d} frame_busy={d} submitted_glyphs={d} submitted_meshlets={d} draw_chunks={d} meshlets={d}/{d} meshlet_culled={d} meshlet_cull=empty:{d},invalid:{d},zero_area:{d},clip:{d},nonfinite:{d} fragments={d} frag_per_glyph_milli={d} frag_per_meshlet_milli={d} meshlets_per_glyph_milli={d} fullscan_pm={d} curve_integrations={d}/{d} bbox_reject_pm={d} bbox_empty_pm={d} zero_pm={d}",
                .{
                    self.binding_writes,
                    self.binding_pushes,
                    self.frame_resources_in_use,
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
                "vulkan stats: binding_writes={d} binding_pushes={d} frame_busy={d}",
                .{
                    self.binding_writes,
                    self.binding_pushes,
                    self.frame_resources_in_use,
                },
            );
        }
        self.core.log(.renderer);
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This()) void {}
};

pub const Target = struct {
    command_buffer: vk.CommandBuffer,
};

const FrameBatch = heavy_slug.core.render.FrameBatch(bindings.GlyphInstance, bindings.GlyphMeshlet);
const ShaderStatsBuffers = if (backend_options.shader_stats) [frames_in_flight]memory.MappedBuffer else void;

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

/// GPU text renderer using the Slug algorithm for exact glyph coverage.
///
/// **Thread safety:** Not thread-safe. `beginFrame`, `Frame.drawText`,
/// `Frame.submit`, `loadFont`, and `unloadFont` must be made from a single
/// thread or externally synchronized. The renderer mutates shared state
/// without synchronization.
pub const Renderer = struct {
    pub const GlyphBlobRef = render.GlyphBlobRef;
    pub const FrameToken = render.FrameToken;
    pub const GlyphInstance = bindings.GlyphInstance;
    pub const GlyphMeshlet = bindings.GlyphMeshlet;

    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    mesh_shader_properties: vk.PhysicalDeviceMeshShaderPropertiesEXT,

    core: render.RendererCore,
    frame_bindings: bindings.FrameBindings,
    shader_program: shader_program_mod.ShaderProgram,

    // Host-visible storage buffers.
    pool_buffer: memory.MappedBuffer,
    glyph_buffers: [frames_in_flight]memory.MappedBuffer,
    meshlet_buffers: [frames_in_flight]memory.MappedBuffer,
    shader_stats_buffers: ShaderStatsBuffers,
    active_frame: u32,

    // Per-frame debug counters, compiled to no-ops outside Debug.
    debug_stats: Stats,

    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    frame_tokens: [frames_in_flight]render.FrameToken,
    last_shader_stats: heavy_slug.ShaderStats,

    pub fn init(
        ctx: gpu_context.Context,
        allocator: std.mem.Allocator,
        options: RendererOptions,
    ) !Renderer {
        try gpu_context.validateDeviceProperties(ctx.api_version, ctx.mesh_shader_properties, ctx.vulkan14_properties);
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        var frame_bindings = try bindings.FrameBindings.init(ctx);
        errdefer frame_bindings.deinit();

        var shader_program = try shader_program_mod.ShaderProgram.init(
            ctx,
            frame_bindings.layout,
        );
        errdefer shader_program.deinit();

        var core = try render.RendererCore.init(allocator, options);
        errdefer core.deinit();

        // Glyph blob storage, read by the fragment shader.
        const pool_buf = try memory.createMapped(
            ctx,
            options.pool_buffer_size,
            .{ .storage_buffer_bit = true },
        );
        errdefer memory.destroy(pool_buf, device, dispatch);

        // One glyph instance buffer per frame slot.
        const glyph_buffer_size = @as(vk.DeviceSize, options.max_glyphs_per_frame) *
            @sizeOf(bindings.GlyphInstance);
        var glyph_buffers: [frames_in_flight]memory.MappedBuffer = undefined;
        var initialized_glyph_buffers: usize = 0;
        errdefer {
            for (glyph_buffers[0..initialized_glyph_buffers]) |glyph_buffer| {
                memory.destroy(glyph_buffer, device, dispatch);
            }
        }
        for (&glyph_buffers) |*glyph_buffer| {
            glyph_buffer.* = try memory.createMapped(
                ctx,
                glyph_buffer_size,
                .{ .storage_buffer_bit = true },
            );
            initialized_glyph_buffers += 1;
        }

        const meshlet_buffer_size = @as(vk.DeviceSize, mesh_limits.maxMeshletsForGlyphCapacity(options.max_glyphs_per_frame)) *
            @sizeOf(bindings.GlyphMeshlet);
        var meshlet_buffers: [frames_in_flight]memory.MappedBuffer = undefined;
        var initialized_meshlet_buffers: usize = 0;
        errdefer {
            for (meshlet_buffers[0..initialized_meshlet_buffers]) |meshlet_buffer| {
                memory.destroy(meshlet_buffer, device, dispatch);
            }
        }
        for (&meshlet_buffers) |*meshlet_buffer| {
            meshlet_buffer.* = try memory.createMapped(
                ctx,
                meshlet_buffer_size,
                .{ .storage_buffer_bit = true },
            );
            initialized_meshlet_buffers += 1;
        }

        var shader_stats_buffers: ShaderStatsBuffers = undefined;
        if (backend_options.shader_stats) {
            var initialized_shader_stats: usize = 0;
            errdefer {
                for (shader_stats_buffers[0..initialized_shader_stats]) |stats_buf| {
                    memory.destroy(stats_buf, device, dispatch);
                }
            }
            for (&shader_stats_buffers) |*stats_buf| {
                stats_buf.* = try memory.createMapped(
                    ctx,
                    @sizeOf(heavy_slug.ShaderStats),
                    .{ .storage_buffer_bit = true },
                );
                resetShaderStatsBuffer(stats_buf.*);
                initialized_shader_stats += 1;
            }
        }

        return .{
            .device = device,
            .dispatch = dispatch,
            .mesh_shader_properties = ctx.mesh_shader_properties,
            .core = core,
            .frame_bindings = frame_bindings,
            .shader_program = shader_program,
            .pool_buffer = pool_buf,
            .glyph_buffers = glyph_buffers,
            .meshlet_buffers = meshlet_buffers,
            .shader_stats_buffers = shader_stats_buffers,
            .active_frame = frames_in_flight - 1,
            .debug_stats = .{},
            .last_submitted_frame = 0,
            .completed_frame = 0,
            .frame_tokens = .{0} ** frames_in_flight,
            .last_shader_stats = .{},
        };
    }

    /// Load a font and return the handle used by draw calls.
    pub fn loadFont(
        self: *Renderer,
        source: core_types.FontSource,
        options: core_types.FontOptions,
    ) !FontHandle {
        return self.core.loadFont(source, options);
    }

    /// Unload a font and defer retirement of its cached glyph resources.
    pub fn unloadFont(self: *Renderer, handle: FontHandle) !void {
        self.core.setRetireAfterToken(self.last_submitted_frame);
        try self.core.unloadFont(handle);
    }

    fn reserveFrameSlot(self: *Renderer) Error!void {
        const next_frame = (self.active_frame + 1) % frames_in_flight;
        if (self.frame_tokens[next_frame] > self.completed_frame) {
            if (@import("builtin").mode == .Debug) self.debug_stats.frame_resources_in_use += 1;
            return Error.FrameResourcesInUse;
        }
        self.active_frame = next_frame;
        self.debug_stats.reset();
        if (backend_options.shader_stats) resetShaderStatsBuffer(self.shader_stats_buffers[self.active_frame]);
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
    }

    pub fn beginFrame(self: *Renderer, view: core_types.View) Error!Frame {
        try self.reserveFrameSlot();
        const glyphs: [*]bindings.GlyphInstance = @ptrCast(@alignCast(self.glyph_buffers[self.active_frame].mapped));
        const glyph_slice = glyphs[0..self.core.max_glyphs_per_frame];
        const meshlets: [*]bindings.GlyphMeshlet = @ptrCast(@alignCast(self.meshlet_buffers[self.active_frame].mapped));
        const meshlet_slice = meshlets[0..mesh_limits.maxMeshletsForGlyphCapacity(self.core.max_glyphs_per_frame)];
        return .{
            .renderer = self,
            .batch = FrameBatch.init(glyph_slice, meshlet_slice),
            .view = view,
        };
    }

    pub fn markFrameComplete(self: *Renderer, token: render.FrameToken) void {
        if (token > self.completed_frame) {
            self.captureCompletedShaderStats(token);
            self.completed_frame = token;
            self.core.retireCompleted(self.completed_frame, self);
        }
    }

    pub fn stats(self: *const Renderer) Stats {
        if (@import("builtin").mode != .Debug) return .{};
        var out = self.debug_stats;
        out.core = self.core.stats;
        if (backend_options.shader_stats) out.shader = self.last_shader_stats;
        return out;
    }

    pub fn completedFrameToken(self: *const Renderer) render.FrameToken {
        return self.completed_frame;
    }

    fn captureCompletedShaderStats(self: *Renderer, completed_token: render.FrameToken) void {
        if (!backend_options.shader_stats) return;
        var best_slot: ?usize = null;
        var best_token: render.FrameToken = 0;
        for (self.frame_tokens, 0..) |slot_token, slot_i| {
            if (slot_token == 0 or slot_token > completed_token or slot_token <= self.completed_frame) continue;
            if (best_slot == null or slot_token >= best_token) {
                best_slot = slot_i;
                best_token = slot_token;
            }
        }
        if (best_slot) |slot_i| {
            self.last_shader_stats = readShaderStatsBuffer(self.shader_stats_buffers[slot_i]);
        }
    }

    pub fn uploadBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !GlyphBlobRef {
        self.pool_buffer.copyFrom(pool_alloc.offset, data);
        return GlyphBlobRef.from(pool_alloc.offset);
    }

    pub fn retireBlob(self: *Renderer, _: GlyphBlobRef) void {
        _ = self;
    }

    /// Record GPU commands into the caller's command buffer.
    /// The command buffer must be in a recording state inside a dynamic
    /// rendering pass. The caller is responsible for starting/ending the
    /// render pass and submitting the command buffer.
    ///
    fn submitFrame(self: *Renderer, target: Target, view: core_types.View, glyph_count: u32, meshlet_count: u32) Error!render.FrameToken {
        if (glyph_count == 0 or meshlet_count == 0) return self.last_submitted_frame;
        const vk_cmd = target.command_buffer;
        const geometry = try draw_plan.frameGeometry(view);

        self.dispatch.cmdSetViewportWithCount(vk_cmd, &.{geometry.viewport});
        self.dispatch.cmdSetScissorWithCount(vk_cmd, &.{geometry.scissor});

        self.shader_program.bind(vk_cmd);

        const glyph_buffer = self.glyph_buffers[self.active_frame];
        const meshlet_buffer = self.meshlet_buffers[self.active_frame];
        const max_workgroups_per_draw = draw_plan.maxMeshWorkgroupsPerDraw(self.mesh_shader_properties);
        const draw_chunks = draw_plan.chunkCount(meshlet_count, max_workgroups_per_draw);
        if (backend_options.shader_stats) {
            seedShaderStatsBuffer(
                self.shader_stats_buffers[self.active_frame],
                glyph_count,
                meshlet_count,
                draw_chunks,
            );
        }
        const shader_stats_binding: ?bindings.BufferView = if (backend_options.shader_stats) blk: {
            const stats_buffer = self.shader_stats_buffers[self.active_frame];
            break :blk stats_buffer.view();
        } else null;
        const push_stats = self.frame_bindings.pushFrameBuffers(
            vk_cmd,
            self.shader_program.pipeline_layout,
            self.pool_buffer.view(),
            glyph_buffer.view(),
            meshlet_buffer.view(),
            shader_stats_binding,
        );
        if (@import("builtin").mode == .Debug) {
            self.debug_stats.binding_writes += push_stats.binding_writes;
            self.debug_stats.binding_pushes += push_stats.push_calls;
        }

        var chunks = draw_plan.ChunkIterator.init(meshlet_count, max_workgroups_per_draw);
        while (chunks.next()) |chunk| {
            try draw_plan.validateDrawChunk(self.mesh_shader_properties, chunk.workgroup_count);

            const params = draw_plan.frameParams(geometry, chunk);
            self.dispatch.cmdPushConstants(
                vk_cmd,
                self.shader_program.pipeline_layout,
                .{ .mesh_bit_ext = true, .fragment_bit = true },
                0,
                @sizeOf(bindings.FrameParams),
                @ptrCast(&params),
            );

            self.dispatch.cmdDrawMeshTasksEXT(vk_cmd, chunk.workgroup_count, 1, 1);
        }
        if (@import("builtin").mode == .Debug) {
            self.core.stats.submitted_glyphs += glyph_count;
            self.core.stats.submitted_meshlets += meshlet_count;
            self.core.stats.pool = self.core.poolSnapshot();
        }

        self.last_submitted_frame +%= 1;
        self.frame_tokens[self.active_frame] = self.last_submitted_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        return self.last_submitted_frame;
    }

    pub fn deinit(self: *Renderer) void {
        self.markFrameComplete(std.math.maxInt(render.FrameToken));
        for (self.glyph_buffers) |glyph_buffer| {
            memory.destroy(glyph_buffer, self.device, self.dispatch);
        }
        for (self.meshlet_buffers) |meshlet_buffer| {
            memory.destroy(meshlet_buffer, self.device, self.dispatch);
        }
        if (backend_options.shader_stats) {
            for (self.shader_stats_buffers) |stats_buf| {
                memory.destroy(stats_buf, self.device, self.dispatch);
            }
        }
        memory.destroy(self.pool_buffer, self.device, self.dispatch);

        self.core.deinit();
        self.shader_program.deinit();
        self.frame_bindings.deinit();

        self.* = undefined;
    }
};

fn resetShaderStatsBuffer(buffer: memory.MappedBuffer) void {
    shader_stats_mod.clearBytes(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
}

fn seedShaderStatsBuffer(buffer: memory.MappedBuffer, glyph_count: u32, meshlet_count: u32, draw_chunks: u32) void {
    const bytes: []align(@alignOf(u32)) u8 = @alignCast(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
    shader_stats_mod.seedFrameSubmission(bytes, glyph_count, meshlet_count, draw_chunks);
}

fn readShaderStatsBuffer(buffer: memory.MappedBuffer) heavy_slug.ShaderStats {
    const bytes: []align(@alignOf(u32)) const u8 = @alignCast(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
    return shader_stats_mod.Stats.fromBytes(bytes);
}

test "RendererOptions has correct defaults" {
    const opts = RendererOptions{};
    try std.testing.expectEqual(@as(u32, 16_384), opts.max_glyphs_per_frame);
    try std.testing.expectEqual(@as(u32, 4_096), opts.hot_slab_count);
    try std.testing.expectEqual(@as(u32, 8_192), opts.cold_lru_count);
    try std.testing.expectEqual(@as(u8, 3), opts.promote_frames);
    try std.testing.expectEqual(@as(u32, 32 * 1024 * 1024), opts.pool_buffer_size);
    try std.testing.expectEqual(@as(u32, 256), opts.min_storage_alignment);
}

test "Renderer satisfies core backend contract" {
    heavy_slug.core.render.checkBackend(Renderer);
    try std.testing.expect(true);
}

test "Stats type compiles and has expected API" {
    var stats = Stats{};
    stats.reset();
    stats.log();
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 0), stats.binding_writes);
        try std.testing.expectEqual(@as(u32, 0), stats.binding_pushes);
    }
}

test "shader stats option is exposed" {
    try std.testing.expectEqual(backend_options.shader_stats, shader_stats_enabled);
}
