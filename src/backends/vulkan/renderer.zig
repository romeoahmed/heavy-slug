const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const gpu_context = @import("context.zig");
const descriptors = @import("descriptors.zig");
const pipeline_mod = @import("pipeline.zig");
const backend_options = @import("heavy_slug_backend_options");
const render = heavy_slug.core.render.renderer_core;
const core_types = heavy_slug.core.types;
const pool_mod = heavy_slug.core.cache.byte_pool;

pub const Error = error{
    NoSuitableMemoryType,
    FrameResourcesInUse,
};

pub const RendererOptions = render.RendererOptions;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const max_frames_in_flight = frames_in_flight;
pub const shader_stats_enabled = backend_options.shader_stats;

const frames_in_flight = 3;

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    common: render.Stats = .{},
    descriptor_writes: u32 = 0,
    descriptor_flush_calls: u32 = 0,
    frame_resources_in_use: u32 = 0,
    shader: heavy_slug.ShaderStats = .{},

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        if (backend_options.shader_stats) {
            const shader_analysis = self.shader.analysis();
            std.log.scoped(.renderer).debug(
                "vulkan stats: desc_writes={d} desc_flushes={d} frame_busy={d} task_visible={d}/{d} mesh_tiles={d}/{d} tile_culled={d} fragments={d} frag_per_glyph_milli={d} frag_per_tile_milli={d} fullscan_pm={d} curve_integrations={d}/{d} bbox_reject_pm={d} bbox_empty_pm={d} zero_pm={d}",
                .{
                    self.descriptor_writes,
                    self.descriptor_flush_calls,
                    self.frame_resources_in_use,
                    self.shader.task_glyphs_visible,
                    self.shader.task_glyphs_tested,
                    self.shader.mesh_tiles_emitted,
                    self.shader.mesh_workgroups,
                    self.shader.mesh_tiles_culled,
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
                "vulkan stats: desc_writes={d} desc_flushes={d} frame_busy={d}",
                .{
                    self.descriptor_writes,
                    self.descriptor_flush_calls,
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
    projection: [4][4]f32,
    viewport: [2]f32,
};

const CommandBatch = heavy_slug.core.render.TextBatch(descriptors.GlyphCommand);
const ShaderStatsBuffers = if (backend_options.shader_stats) [frames_in_flight]MappedBuffer else void;

pub const Frame = struct {
    renderer: *Renderer,
    batch: CommandBatch,
    submitted: bool = false,

    pub fn drawText(
        self: *Frame,
        run: heavy_slug.TextRun,
    ) !void {
        if (self.submitted) return error.FrameAlreadySubmitted;
        try self.renderer.core.appendRun(self.renderer, &self.batch, run);
    }

    pub fn submit(self: *Frame, target: Target) !render.FrameToken {
        if (self.submitted) return error.FrameAlreadySubmitted;
        const token = self.renderer.submitFrame(target, self.batch.count());
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
    ctx: gpu_context.VulkanContext,
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

/// GPU text renderer using the Slug algorithm for exact glyph coverage.
///
/// **Thread safety:** Not thread-safe. `beginFrame`, `Frame.drawText`,
/// `Frame.submit`, `loadFont`, and `unloadFont` must be made from a single
/// thread or externally synchronized. The renderer mutates shared state
/// without synchronization.
pub const Renderer = struct {
    pub const GlyphRef = render.GlyphRef;
    pub const FrameToken = render.FrameToken;
    pub const Command = descriptors.GlyphCommand;

    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,

    core: render.RendererCore,
    descriptor_table: descriptors.DescriptorTable,
    pip: pipeline_mod.Pipeline,

    // Host-visible storage buffers.
    pool_buffer: MappedBuffer,
    command_buffers: [frames_in_flight]MappedBuffer,
    shader_stats_buffers: ShaderStatsBuffers,
    active_frame: u32,

    // Per-frame debug counters, compiled to no-ops outside Debug.
    stats: Stats,

    memory_properties: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,
    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    frame_tokens: [frames_in_flight]render.FrameToken,
    shader_stats_snapshot: heavy_slug.ShaderStats,

    pub fn init(
        ctx: gpu_context.VulkanContext,
        color_format: vk.Format,
        allocator: std.mem.Allocator,
        options: RendererOptions,
    ) !Renderer {
        try gpu_context.validateDeviceProperties(ctx.api_version, ctx.mesh_shader_properties);

        const device = ctx.device;
        const dispatch = ctx.dispatch;
        var desc_table = try descriptors.DescriptorTable.init(
            ctx,
            allocator,
            frames_in_flight,
        );
        errdefer desc_table.deinit(allocator);

        var pip = try pipeline_mod.Pipeline.init(
            ctx,
            desc_table.layout,
            color_format,
        );
        errdefer pip.deinit();

        var core = try render.RendererCore.init(allocator, options);
        errdefer core.deinit();

        // Glyph blob storage, read by the fragment shader.
        const pool_buf = try createMappedBuffer(
            ctx,
            options.pool_buffer_size,
            .{ .storage_buffer_bit = true },
        );
        errdefer destroyMappedBuffer(pool_buf, device, dispatch);

        // One command buffer per frame slot.
        const cmd_buf_size = @as(vk.DeviceSize, options.max_glyphs_per_frame) *
            @sizeOf(descriptors.GlyphCommand);
        var command_buffers: [frames_in_flight]MappedBuffer = undefined;
        var initialized_command_buffers: usize = 0;
        errdefer {
            for (command_buffers[0..initialized_command_buffers]) |cmd_buf| {
                destroyMappedBuffer(cmd_buf, device, dispatch);
            }
        }
        for (&command_buffers) |*cmd_buf| {
            cmd_buf.* = try createMappedBuffer(
                ctx,
                cmd_buf_size,
                .{ .storage_buffer_bit = true },
            );
            initialized_command_buffers += 1;
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
            .core = core,
            .descriptor_table = desc_table,
            .pip = pip,
            .pool_buffer = pool_buf,
            .command_buffers = command_buffers,
            .shader_stats_buffers = shader_stats_buffers,
            .active_frame = frames_in_flight - 1,
            .stats = .{},
            .memory_properties = ctx.memory_properties,
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
        self.descriptor_table.resetDebugStats();
        if (backend_options.shader_stats) resetShaderStatsBuffer(self.shader_stats_buffers[self.active_frame]);
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
    }

    pub fn beginFrame(self: *Renderer) Error!Frame {
        try self.reserveFrameSlot();
        const commands: [*]descriptors.GlyphCommand = @ptrCast(@alignCast(self.command_buffers[self.active_frame].mapped));
        const command_slice = commands[0..self.core.max_glyphs_per_frame];
        return .{
            .renderer = self,
            .batch = CommandBatch.init(command_slice),
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
        const desc_stats = self.descriptor_table.debugStats();
        out.common = self.core.stats;
        out.descriptor_writes = desc_stats.descriptor_writes;
        out.descriptor_flush_calls = desc_stats.descriptor_flush_calls;
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

    pub fn uploadBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !GlyphRef {
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..data.len];
        @memcpy(dst, data);
        return GlyphRef.from(pool_alloc.offset);
    }

    pub fn retireBlob(self: *Renderer, _: GlyphRef) void {
        _ = self;
    }

    /// Record GPU commands into the caller's command buffer.
    /// The command buffer must be in a recording state inside a dynamic
    /// rendering pass. The caller is responsible for starting/ending the
    /// render pass and submitting the command buffer.
    ///
    /// `proj`: column-major 4×4 projection matrix (e.g. orthographic).
    /// `viewport`: viewport dimensions in pixels [width, height].
    fn submitFrame(self: *Renderer, target: Target, glyph_count: u32) render.FrameToken {
        if (glyph_count == 0) return self.last_submitted_frame;
        const cmd_buf = target.command_buffer;
        const proj = target.projection;
        const viewport = target.viewport;

        const vk_viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = viewport[0],
            .height = viewport[1],
            .min_depth = 0,
            .max_depth = 1,
        };
        self.dispatch.cmdSetViewport(cmd_buf, 0, &.{vk_viewport});

        const vk_scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intFromFloat(viewport[0]),
                .height = @intFromFloat(viewport[1]),
            },
        };
        self.dispatch.cmdSetScissor(cmd_buf, 0, &.{vk_scissor});

        self.dispatch.cmdBindPipeline(cmd_buf, .graphics, self.pip.pipeline);

        const command_buffer = self.command_buffers[self.active_frame];
        self.descriptor_table.updateGlyphPool(self.active_frame, self.pool_buffer.buffer, 0, self.pool_buffer.size);
        self.descriptor_table.updateCommandBuffer(self.active_frame, command_buffer.buffer, 0, command_buffer.size);
        if (backend_options.shader_stats) {
            const stats_buffer = self.shader_stats_buffers[self.active_frame];
            self.descriptor_table.updateShaderStatsBuffer(
                self.active_frame,
                stats_buffer.buffer,
                0,
                @sizeOf(heavy_slug.ShaderStats),
            );
        }
        // Commit all descriptor writes before binding the frame-local set.
        self.descriptor_table.flushWrites();

        self.dispatch.cmdBindDescriptorSets(
            cmd_buf,
            .graphics,
            self.pip.pipeline_layout,
            0,
            &.{self.descriptor_table.setForFrame(self.active_frame)},
            null,
        );

        // Scale projection from pixel-space to 26.6 em-space.
        // Motor translations and em-box extents are in 26.6 units (64x pixels).
        // Dividing columns 0 and 1 by 64 maps 26.6 world coords to clip space.
        const proj_em = render.projectionToEm(proj);

        const push = descriptors.PushConstants{
            .proj = proj_em,
            .viewport_dim = viewport,
            .glyph_count = glyph_count,
            .glyph_base = 0,
        };
        self.dispatch.cmdPushConstants(
            cmd_buf,
            self.pip.pipeline_layout,
            .{ .task_bit_ext = true, .mesh_bit_ext = true, .fragment_bit = true },
            0,
            @sizeOf(descriptors.PushConstants),
            @ptrCast(&push),
        );

        // The task shader handles 32 glyphs per workgroup.
        const workgroup_count = (glyph_count + 31) / 32;
        self.dispatch.cmdDrawMeshTasksEXT(cmd_buf, workgroup_count, 1, 1);
        if (@import("builtin").mode == .Debug) {
            self.core.stats.glyphs_submitted += glyph_count;
            self.core.stats.pool = self.core.poolSnapshot();
        }

        self.last_submitted_frame +%= 1;
        self.frame_tokens[self.active_frame] = self.last_submitted_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        return self.last_submitted_frame;
    }

    pub fn deinit(self: *Renderer) void {
        self.markFrameComplete(std.math.maxInt(render.FrameToken));
        for (self.command_buffers) |cmd_buf| {
            destroyMappedBuffer(cmd_buf, self.device, self.dispatch);
        }
        if (backend_options.shader_stats) {
            for (self.shader_stats_buffers) |stats_buf| {
                destroyMappedBuffer(stats_buf, self.device, self.dispatch);
            }
        }
        destroyMappedBuffer(self.pool_buffer, self.device, self.dispatch);

        self.core.deinit();
        self.pip.deinit();
        self.descriptor_table.deinit(self.allocator);

        self.* = undefined;
    }
};

fn resetShaderStatsBuffer(buffer: MappedBuffer) void {
    @memset(buffer.mapped[0..@sizeOf(heavy_slug.ShaderStats)], 0);
}

fn readShaderStatsBuffer(buffer: MappedBuffer) heavy_slug.ShaderStats {
    const counters: *const [heavy_slug.gpu.shader_stats.counter_count]u32 = @ptrCast(@alignCast(buffer.mapped));
    return heavy_slug.gpu.shader_stats.Snapshot.fromCounters(counters);
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

test "Renderer satisfies core backend contract" {
    heavy_slug.core.render.BackendContract(Renderer);
    try std.testing.expect(true);
}

test "Stats type compiles and has expected API" {
    var stats = Stats{};
    stats.reset();
    stats.log();
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 0), stats.descriptor_writes);
        try std.testing.expectEqual(@as(u32, 0), stats.descriptor_flush_calls);
    }
}

test "shader stats option is exposed" {
    try std.testing.expectEqual(backend_options.shader_stats, shader_stats_enabled);
}
