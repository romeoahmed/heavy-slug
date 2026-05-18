const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const gpu_context = @import("context.zig");
const bindings = @import("bindings.zig");
const shader_program_mod = @import("shader_program.zig");
const backend_options = @import("heavy_slug_backend_options");
const render = heavy_slug.core.render.renderer_core;
const core_types = heavy_slug.core.types;
const pool_mod = heavy_slug.core.cache.byte_pool;
const mesh_limits = heavy_slug.gpu.mesh_limits;
const shader_stats_mod = heavy_slug.gpu.shader_stats;

pub const Error = error{
    NoSuitableMemoryType,
    FrameResourcesInUse,
    InvalidFrameView,
    MeshWorkgroupLimitExceeded,
};

pub const RendererOptions = render.RendererOptions;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const max_frames_in_flight = frames_in_flight;
pub const shader_stats_enabled = backend_options.shader_stats;

const frames_in_flight = 3;

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    common: render.Stats = .{},
    binding_writes: u32 = 0,
    binding_pushes: u32 = 0,
    frame_resources_in_use: u32 = 0,
    shader: heavy_slug.ShaderStats = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        if (backend_options.shader_stats) {
            const shader_analysis = self.shader.analysis();
            const mesh_cull = self.shader.meshCullBreakdown();
            std.log.scoped(.renderer).debug(
                "vulkan stats: binding_writes={d} binding_pushes={d} frame_busy={d} cpu_glyphs={d} cpu_meshlets={d} draw_chunks={d} mesh_tiles={d}/{d} tile_culled={d} mesh_cull=empty:{d},invalid:{d},zero_area:{d},clip:{d},nonfinite:{d} fragments={d} frag_per_glyph_milli={d} frag_per_tile_milli={d} meshlets_per_glyph_milli={d} fullscan_pm={d} curve_integrations={d}/{d} bbox_reject_pm={d} bbox_empty_pm={d} zero_pm={d}",
                .{
                    self.binding_writes,
                    self.binding_pushes,
                    self.frame_resources_in_use,
                    self.shader.cpu_glyphs_submitted,
                    self.shader.cpu_meshlets_submitted,
                    self.shader.draw_chunks,
                    self.shader.mesh_tiles_emitted,
                    self.shader.mesh_workgroups,
                    self.shader.mesh_tiles_culled,
                    mesh_cull.empty_slices,
                    mesh_cull.invalid_strips,
                    mesh_cull.zero_area,
                    mesh_cull.clip_empty,
                    mesh_cull.non_finite,
                    self.shader.fragment_invocations,
                    shader_analysis.fragments_per_submitted_glyph_milli,
                    shader_analysis.fragments_per_mesh_tile_milli,
                    shader_analysis.meshlets_per_glyph_milli,
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
                "vulkan stats: binding_writes={d} binding_pushes={d} frame_busy={d}",
                .{
                    self.binding_writes,
                    self.binding_pushes,
                    self.frame_resources_in_use,
                },
            );
        }
        self.common.log(.renderer);
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This()) void {}
};

pub const Target = struct {
    command_buffer: vk.CommandBuffer,
};

const FrameBatch = heavy_slug.core.render.FrameBatch(bindings.GlyphInstance, bindings.GlyphMeshlet);
const ShaderStatsBuffers = if (backend_options.shader_stats) [frames_in_flight]MappedBuffer else void;

pub const Frame = struct {
    renderer: *Renderer,
    batch: FrameBatch,
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
        const token = try self.renderer.submitFrame(target, self.view, self.batch.glyphCount(), self.batch.meshletCount());
        self.batch.markSubmitted();
        self.submitted = true;
        return token;
    }
};

/// A host-visible, host-coherent VkBuffer with persistently mapped memory.
const MappedBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
    size: vk.DeviceSize,
};

/// Find a memory type index that satisfies both the type filter (from
/// VkMemoryRequirements.memoryTypeBits) and the required property flags.
fn findMemoryType(
    properties: vk.PhysicalDeviceMemoryProperties,
    type_filter: u32,
    required: vk.MemoryPropertyFlags,
) ?u32 {
    const required_bits: u32 = @bitCast(required);
    for (0..properties.memory_type_count) |i| {
        if (type_filter & (@as(u32, 1) << @as(u5, @intCast(i))) != 0) {
            const flags_bits: u32 = @bitCast(properties.memory_types[i].property_flags);
            if (flags_bits & required_bits == required_bits) {
                return @intCast(i);
            }
        }
    }
    return null;
}

fn createMappedBuffer(
    ctx: gpu_context.Context,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
) !MappedBuffer {
    const device = ctx.device;
    const dispatch = ctx.dispatch;
    const buffer_ci = vk.BufferCreateInfo{
        .s_type = .buffer_create_info,
        .flags = .{},
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
    };
    const buffer = try dispatch.createBuffer(device, &buffer_ci, null);

    const mem_req = dispatch.getBufferMemoryRequirements(device, buffer);

    const mem_type_index = findMemoryType(
        ctx.memory_properties,
        mem_req.memory_type_bits,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    ) orelse {
        dispatch.destroyBuffer(device, buffer, null);
        return Error.NoSuitableMemoryType;
    };

    const alloc_info = vk.MemoryAllocateInfo{
        .s_type = .memory_allocate_info,
        .allocation_size = mem_req.size,
        .memory_type_index = mem_type_index,
    };
    const memory = dispatch.allocateMemory(device, &alloc_info, null) catch |err| {
        dispatch.destroyBuffer(device, buffer, null);
        return err;
    };
    // Buffer and memory both exist; errdefer must destroy buffer before freeing memory.
    errdefer {
        dispatch.destroyBuffer(device, buffer, null);
        dispatch.freeMemory(device, memory, null);
    }

    try dispatch.bindBufferMemory(device, buffer, memory, 0);

    const mapped_ptr = try dispatch.mapMemory(device, memory, 0, size, .{});

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = @ptrCast(mapped_ptr.?),
        .size = size,
    };
}

fn destroyMappedBuffer(self: MappedBuffer, device: vk.Device, dispatch: gpu_context.DeviceDispatch) void {
    dispatch.unmapMemory(device, self.memory);
    dispatch.destroyBuffer(device, self.buffer, null);
    dispatch.freeMemory(device, self.memory, null);
}

fn validateMeshDrawWorkgroups(
    props: vk.PhysicalDeviceMeshShaderPropertiesEXT,
    workgroup_count: u32,
) Error!void {
    if (workgroup_count == 0) return;
    if (workgroup_count > props.max_mesh_work_group_count[0] or
        workgroup_count > props.max_mesh_work_group_total_count)
    {
        return Error.MeshWorkgroupLimitExceeded;
    }
}

fn maxMeshWorkgroupsPerDraw(props: vk.PhysicalDeviceMeshShaderPropertiesEXT) u32 {
    return @min(props.max_mesh_work_group_count[0], props.max_mesh_work_group_total_count);
}

fn drawChunkCount(workgroup_count: u32, max_workgroups_per_draw: u32) u32 {
    if (workgroup_count == 0) return 0;
    std.debug.assert(max_workgroups_per_draw > 0);
    return (workgroup_count / max_workgroups_per_draw) +
        @intFromBool(workgroup_count % max_workgroups_per_draw != 0);
}

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
    pool_buffer: MappedBuffer,
    glyph_buffers: [frames_in_flight]MappedBuffer,
    meshlet_buffers: [frames_in_flight]MappedBuffer,
    shader_stats_buffers: ShaderStatsBuffers,
    active_frame: u32,

    // Per-frame debug counters, compiled to no-ops outside Debug.
    stats: Stats,

    allocator: std.mem.Allocator,
    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    frame_tokens: [frames_in_flight]render.FrameToken,
    shader_stats_snapshot: heavy_slug.ShaderStats,

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
        const pool_buf = try createMappedBuffer(
            ctx,
            options.pool_buffer_size,
            .{ .storage_buffer_bit = true },
        );
        errdefer destroyMappedBuffer(pool_buf, device, dispatch);

        // One glyph instance buffer per frame slot.
        const glyph_buffer_size = @as(vk.DeviceSize, options.max_glyphs_per_frame) *
            @sizeOf(bindings.GlyphInstance);
        var glyph_buffers: [frames_in_flight]MappedBuffer = undefined;
        var initialized_glyph_buffers: usize = 0;
        errdefer {
            for (glyph_buffers[0..initialized_glyph_buffers]) |glyph_buffer| {
                destroyMappedBuffer(glyph_buffer, device, dispatch);
            }
        }
        for (&glyph_buffers) |*glyph_buffer| {
            glyph_buffer.* = try createMappedBuffer(
                ctx,
                glyph_buffer_size,
                .{ .storage_buffer_bit = true },
            );
            initialized_glyph_buffers += 1;
        }

        const meshlet_buffer_size = @as(vk.DeviceSize, mesh_limits.maxMeshletsForGlyphCapacity(options.max_glyphs_per_frame)) *
            @sizeOf(bindings.GlyphMeshlet);
        var meshlet_buffers: [frames_in_flight]MappedBuffer = undefined;
        var initialized_meshlet_buffers: usize = 0;
        errdefer {
            for (meshlet_buffers[0..initialized_meshlet_buffers]) |meshlet_buffer| {
                destroyMappedBuffer(meshlet_buffer, device, dispatch);
            }
        }
        for (&meshlet_buffers) |*meshlet_buffer| {
            meshlet_buffer.* = try createMappedBuffer(
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
                    destroyMappedBuffer(stats_buf, device, dispatch);
                }
            }
            for (&shader_stats_buffers) |*stats_buf| {
                stats_buf.* = try createMappedBuffer(
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
            .stats = .{},
            .allocator = allocator,
            .last_submitted_frame = 0,
            .completed_frame = 0,
            .frame_tokens = .{0} ** frames_in_flight,
            .shader_stats_snapshot = .{},
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
            if (@import("builtin").mode == .Debug) self.stats.frame_resources_in_use += 1;
            return Error.FrameResourcesInUse;
        }
        self.active_frame = next_frame;
        self.stats.reset();
        if (backend_options.shader_stats) resetShaderStatsBuffer(self.shader_stats_buffers[self.active_frame]);
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
    }

    pub fn beginFrame(self: *Renderer, view: core_types.FrameView2D) Error!Frame {
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

    pub fn statsSnapshot(self: *const Renderer) Stats {
        if (@import("builtin").mode != .Debug) return .{};
        var out = self.stats;
        out.common = self.core.stats;
        if (backend_options.shader_stats) out.shader = self.shader_stats_snapshot;
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
            self.shader_stats_snapshot = readShaderStatsBuffer(self.shader_stats_buffers[slot_i]);
        }
    }

    pub fn uploadBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !GlyphBlobRef {
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..data.len];
        @memcpy(dst, data);
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
    fn submitFrame(self: *Renderer, target: Target, view: core_types.FrameView2D, glyph_count: u32, meshlet_count: u32) Error!render.FrameToken {
        if (glyph_count == 0 or meshlet_count == 0) return self.last_submitted_frame;
        const vk_cmd = target.command_buffer;
        const viewport = viewportToF32(view) orelse return Error.InvalidFrameView;

        const vk_viewport = yUpViewport(viewport);
        self.dispatch.cmdSetViewportWithCount(vk_cmd, &.{vk_viewport});

        const vk_scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intFromFloat(@round(viewport[0])),
                .height = @intFromFloat(@round(viewport[1])),
            },
        };
        self.dispatch.cmdSetScissorWithCount(vk_cmd, &.{vk_scissor});

        self.shader_program.bind(vk_cmd);

        const glyph_buffer = self.glyph_buffers[self.active_frame];
        const meshlet_buffer = self.meshlet_buffers[self.active_frame];
        const max_workgroups_per_draw = maxMeshWorkgroupsPerDraw(self.mesh_shader_properties);
        const draw_chunks = drawChunkCount(meshlet_count, max_workgroups_per_draw);
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
            break :blk .{
                .buffer = stats_buffer.buffer,
                .offset = 0,
                .range = @sizeOf(heavy_slug.ShaderStats),
            };
        } else null;
        const push_stats = self.frame_bindings.pushFrameBuffers(
            vk_cmd,
            self.shader_program.pipeline_layout,
            .{
                .buffer = self.pool_buffer.buffer,
                .offset = 0,
                .range = self.pool_buffer.size,
            },
            .{
                .buffer = glyph_buffer.buffer,
                .offset = 0,
                .range = glyph_buffer.size,
            },
            .{
                .buffer = meshlet_buffer.buffer,
                .offset = 0,
                .range = meshlet_buffer.size,
            },
            shader_stats_binding,
        );
        if (@import("builtin").mode == .Debug) {
            self.stats.binding_writes += push_stats.binding_writes;
            self.stats.binding_pushes += push_stats.push_calls;
        }

        var meshlet_base: u32 = 0;
        while (meshlet_base < meshlet_count) {
            const workgroup_count = @min(meshlet_count - meshlet_base, max_workgroups_per_draw);
            try validateMeshDrawWorkgroups(self.mesh_shader_properties, workgroup_count);

            const params = bindings.FrameParams{
                .viewport_size = viewport,
                .screen_from_framebuffer_2x2 = .{ 1, 0, 0, -1 },
                .screen_from_framebuffer_offset = .{ 0, viewport[1] },
                .meshlet_count = workgroup_count,
                .meshlet_base = meshlet_base,
            };
            self.dispatch.cmdPushConstants(
                vk_cmd,
                self.shader_program.pipeline_layout,
                .{ .mesh_bit_ext = true, .fragment_bit = true },
                0,
                @sizeOf(bindings.FrameParams),
                @ptrCast(&params),
            );

            self.dispatch.cmdDrawMeshTasksEXT(vk_cmd, workgroup_count, 1, 1);
            meshlet_base += workgroup_count;
        }
        if (@import("builtin").mode == .Debug) {
            self.core.stats.instances_submitted += glyph_count;
            self.core.stats.meshlets_submitted += meshlet_count;
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
            destroyMappedBuffer(glyph_buffer, self.device, self.dispatch);
        }
        for (self.meshlet_buffers) |meshlet_buffer| {
            destroyMappedBuffer(meshlet_buffer, self.device, self.dispatch);
        }
        if (backend_options.shader_stats) {
            for (self.shader_stats_buffers) |stats_buf| {
                destroyMappedBuffer(stats_buf, self.device, self.dispatch);
            }
        }
        destroyMappedBuffer(self.pool_buffer, self.device, self.dispatch);

        self.core.deinit();
        self.shader_program.deinit();
        self.frame_bindings.deinit();

        self.* = undefined;
    }
};

fn resetShaderStatsBuffer(buffer: MappedBuffer) void {
    shader_stats_mod.clearBytes(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
}

fn seedShaderStatsBuffer(buffer: MappedBuffer, glyph_count: u32, meshlet_count: u32, draw_chunks: u32) void {
    const bytes: []align(@alignOf(u32)) u8 = @alignCast(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
    shader_stats_mod.seedFrameSubmission(bytes, glyph_count, meshlet_count, draw_chunks);
}

fn readShaderStatsBuffer(buffer: MappedBuffer) heavy_slug.ShaderStats {
    const bytes: []align(@alignOf(u32)) const u8 = @alignCast(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)]);
    return shader_stats_mod.Snapshot.fromBytes(bytes);
}

fn viewportToF32(view: core_types.FrameView2D) ?[2]f32 {
    if (!view.isFinite()) return null;
    if (view.viewport_width > @as(f64, @floatFromInt(std.math.maxInt(u32))) or
        view.viewport_height > @as(f64, @floatFromInt(std.math.maxInt(u32))))
    {
        return null;
    }
    return .{
        @floatCast(view.viewport_width),
        @floatCast(view.viewport_height),
    };
}

// Match the Metal demo's y-up clip-space convention without changing shared scene input math.
fn yUpViewport(viewport: [2]f32) vk.Viewport {
    return .{
        .x = 0,
        .y = viewport[1],
        .width = viewport[0],
        .height = -viewport[1],
        .min_depth = 0,
        .max_depth = 1,
    };
}

fn viewportFramebufferY(viewport: vk.Viewport, ndc_y: f32) f32 {
    return viewport.y + (ndc_y + 1.0) * viewport.height * 0.5;
}

fn framebufferToScreenYUpForCurrentBackends(framebuffer: [2]f32, viewport: [2]f32) [2]f32 {
    return .{ framebuffer[0], viewport[1] - framebuffer[1] };
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

test "findMemoryType selects correct memory type" {
    var props = std.mem.zeroes(vk.PhysicalDeviceMemoryProperties);
    props.memory_type_count = 3;
    props.memory_types[0].property_flags = .{ .device_local_bit = true };
    props.memory_types[1].property_flags = .{ .host_visible_bit = true };
    props.memory_types[2].property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true };

    const filter: u32 = 0b111;

    const result = findMemoryType(props, filter, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try std.testing.expectEqual(@as(?u32, 2), result);

    const dl = findMemoryType(props, filter, .{ .device_local_bit = true });
    try std.testing.expectEqual(@as(?u32, 0), dl);

    const none = findMemoryType(props, filter, .{ .protected_bit = true });
    try std.testing.expectEqual(@as(?u32, null), none);

    const filtered = findMemoryType(props, 0b011, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try std.testing.expectEqual(@as(?u32, null), filtered);
}

test "mesh workgroup validation follows Vulkan mesh shader draw limits" {
    var props = std.mem.zeroes(vk.PhysicalDeviceMeshShaderPropertiesEXT);
    props.max_mesh_work_group_total_count = 4;
    props.max_mesh_work_group_count = .{ 4, 1, 1 };

    try validateMeshDrawWorkgroups(props, 4);
    try std.testing.expectError(Error.MeshWorkgroupLimitExceeded, validateMeshDrawWorkgroups(props, 5));

    props.max_mesh_work_group_total_count = 3;
    try std.testing.expectError(Error.MeshWorkgroupLimitExceeded, validateMeshDrawWorkgroups(props, 4));
    try std.testing.expectEqual(@as(u32, 3), maxMeshWorkgroupsPerDraw(props));
    try std.testing.expectEqual(@as(u32, 0), drawChunkCount(0, 3));
    try std.testing.expectEqual(@as(u32, 1), drawChunkCount(3, 3));
    try std.testing.expectEqual(@as(u32, 2), drawChunkCount(4, 3));
}

test "yUpViewport matches the Metal demo clip-space convention" {
    const viewport = yUpViewport(.{ 1280, 720 });

    try std.testing.expectEqual(@as(f32, 0), viewport.x);
    try std.testing.expectEqual(@as(f32, 720), viewport.y);
    try std.testing.expectEqual(@as(f32, 1280), viewport.width);
    try std.testing.expectEqual(@as(f32, -720), viewport.height);
    try std.testing.expectEqual(@as(f32, 0), viewportFramebufferY(viewport, 1));
    try std.testing.expectEqual(@as(f32, 720), viewportFramebufferY(viewport, -1));
}

test "fragment framebuffer conversion restores y-up screen coordinates" {
    const viewport = [2]f32{ 1280, 720 };
    const samples = [_][2]f32{
        .{ 0, 720 },
        .{ 10, 640 },
        .{ 640, 360 },
        .{ 1279.5, 0.5 },
    };
    const expected = [_][2]f32{
        .{ 0, 0 },
        .{ 10, 80 },
        .{ 640, 360 },
        .{ 1279.5, 719.5 },
    };

    for (samples, expected) |framebuffer, screen| {
        const converted = framebufferToScreenYUpForCurrentBackends(framebuffer, viewport);
        try std.testing.expectEqual(screen[0], converted[0]);
        try std.testing.expectEqual(screen[1], converted[1]);
    }
}

test "Renderer satisfies core backend contract" {
    heavy_slug.core.render.BackendContract(Renderer);
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
