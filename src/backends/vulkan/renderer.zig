const std = @import("std");
const vk = @import("vulkan");
const heavy_slug = @import("heavy_slug");
const gpu_context = @import("context.zig");
const descriptors = @import("descriptors.zig");
const pipeline_mod = @import("pipeline.zig");
const render = heavy_slug.core.render.renderer_core;
const core_types = heavy_slug.core.types;
const pool_mod = heavy_slug.core.cache.byte_pool;

pub const Error = error{
    NoSuitableMemoryType,
    DescriptorSlotExhausted,
    FrameResourcesInUse,
};

pub const Options = render.Options;
pub const InitOptions = Options;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const max_frames_in_flight = frames_in_flight;

const frames_in_flight = 3;

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    common: render.Stats = .{},
    descriptors_flushed: u32 = 0,

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        std.log.scoped(.renderer).debug(
            "frame stats: desc_flushes={d}",
            .{self.descriptors_flushed},
        );
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

pub const Frame = struct {
    renderer: *Renderer,
    submitted: bool = false,

    pub fn drawText(
        self: *Frame,
        run: heavy_slug.TextRun,
    ) !void {
        if (self.submitted) return error.FrameAlreadySubmitted;
        try self.renderer.appendRun(run);
    }

    pub fn submit(self: *Frame, target: Target) !render.FrameToken {
        if (self.submitted) return error.FrameAlreadySubmitted;
        const token = self.renderer.submitFrame(target);
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
    pub const GlyphRef = u32;
    pub const FrameToken = render.FrameToken;
    pub const Command = descriptors.GlyphCommand;

    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,

    core: render.RendererCore,
    descriptor_table: descriptors.DescriptorTable,
    pip: pipeline_mod.Pipeline,

    // Vulkan buffers
    pool_buffer: MappedBuffer,
    command_buffers: [frames_in_flight]MappedBuffer,
    active_frame: u32,

    // Per-frame debug counters (zero-cost in release)
    stats: Stats,

    // Stored for future buffer creation
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,
    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    frame_tokens: [frames_in_flight]render.FrameToken,

    pub fn init(
        ctx: gpu_context.VulkanContext,
        color_format: vk.Format,
        allocator: std.mem.Allocator,
        options: InitOptions,
    ) !Renderer {
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        // 1. Descriptor table
        var desc_table = try descriptors.DescriptorTable.init(
            ctx,
            allocator,
            options.max_glyph_descriptors,
        );
        errdefer desc_table.deinit(allocator);

        // 2. Pipeline
        var pip = try pipeline_mod.Pipeline.init(
            ctx,
            desc_table.layout,
            color_format,
        );
        errdefer pip.deinit();

        var core = try render.RendererCore.init(allocator, options);
        errdefer core.deinit();

        // 3. Pool buffer (glyph blob storage, GPU reads as storage buffer)
        const pool_buf = try createMappedBuffer(
            ctx,
            options.pool_buffer_size,
            .{ .storage_buffer_bit = true },
        );
        errdefer destroyMappedBuffer(pool_buf, device, dispatch);

        // 4. Command buffers (GlyphCommand[] per frame, GPU reads as storage buffer)
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

        return .{
            .device = device,
            .dispatch = dispatch,
            .core = core,
            .descriptor_table = desc_table,
            .pip = pip,
            .pool_buffer = pool_buf,
            .command_buffers = command_buffers,
            .active_frame = frames_in_flight - 1,
            .stats = .{},
            .memory_properties = ctx.memory_properties,
            .allocator = allocator,
            .last_submitted_frame = 0,
            .completed_frame = 0,
            .frame_tokens = .{0} ** frames_in_flight,
        };
    }

    /// Load a font from a file path at the given pixel size.
    /// Returns a FontHandle used in drawText calls.
    pub fn loadFont(
        self: *Renderer,
        source: core_types.FontSource,
        options: core_types.FontOptions,
    ) !FontHandle {
        return self.core.loadFont(source, options);
    }

    /// Unload a font and evict all its cached glyphs.
    /// Caller must ensure the GPU has finished consuming any commands that
    /// reference this font's glyphs before calling this function.
    pub fn unloadFont(self: *Renderer, handle: FontHandle) !void {
        self.core.setRetireAfterToken(self.last_submitted_frame);
        try self.core.unloadFont(handle);
    }

    fn reserveFrameSlot(self: *Renderer) Error!void {
        const next_frame = (self.active_frame + 1) % frames_in_flight;
        if (self.frame_tokens[next_frame] > self.completed_frame) return Error.FrameResourcesInUse;
        self.active_frame = next_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
        self.stats.reset();
    }

    pub fn beginFrame(self: *Renderer) Error!Frame {
        try self.reserveFrameSlot();
        return .{ .renderer = self };
    }

    pub fn markFrameComplete(self: *Renderer, token: render.FrameToken) void {
        if (token > self.completed_frame) {
            self.completed_frame = token;
            self.core.retireCompleted(self.completed_frame, self);
        }
    }

    pub fn completedFrameToken(self: *const Renderer) render.FrameToken {
        return self.completed_frame;
    }

    fn appendRun(self: *Renderer, run: heavy_slug.TextRun) !void {
        const commands: [*]descriptors.GlyphCommand = @ptrCast(@alignCast(self.command_buffers[self.active_frame].mapped));
        try self.core.appendRun(self, descriptors.GlyphCommand, commands, run);
    }

    pub fn uploadGlyphBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !u32 {
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..data.len];
        @memcpy(dst, data);
        const slot = self.descriptor_table.allocSlot() orelse
            return Error.DescriptorSlotExhausted;
        self.descriptor_table.updateSlot(
            slot,
            self.pool_buffer.buffer,
            @as(vk.DeviceSize, pool_alloc.offset),
            @as(vk.DeviceSize, data.len),
        );
        return slot;
    }

    pub fn releaseGlyphRef(self: *Renderer, slot: u32) void {
        self.descriptor_table.nullSlot(slot);
        self.descriptor_table.freeSlot(slot);
    }

    /// Record GPU commands into the caller's command buffer.
    /// The command buffer must be in a recording state inside a dynamic
    /// rendering pass. The caller is responsible for starting/ending the
    /// render pass and submitting the command buffer.
    ///
    /// `proj`: column-major 4×4 projection matrix (e.g. orthographic).
    /// `viewport`: viewport dimensions in pixels [width, height].
    fn submitFrame(self: *Renderer, target: Target) render.FrameToken {
        const glyph_count = self.core.commandCount();
        if (glyph_count == 0) return self.last_submitted_frame;
        const cmd_buf = target.command_buffer;
        const proj = target.projection;
        const viewport = target.viewport;

        // Set dynamic viewport state
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

        // Bind pipeline
        self.dispatch.cmdBindPipeline(cmd_buf, .graphics, self.pip.pipeline);

        // Bind descriptor set
        const command_buffer = self.command_buffers[self.active_frame];
        self.descriptor_table.updateCommandBuffer(command_buffer.buffer, 0, command_buffer.size);
        self.dispatch.cmdBindDescriptorSets(
            cmd_buf,
            .graphics,
            self.pip.pipeline_layout,
            0,
            &.{self.descriptor_table.set},
            null,
        );

        // Scale projection from pixel-space to 26.6 em-space.
        // Motor translations and em-box extents are in 26.6 units (64x pixels).
        // Dividing columns 0 and 1 by 64 maps 26.6 world coords to clip space.
        const proj_em = render.projectionToEm(proj);

        // Push constants
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

        // Dispatch mesh shader workgroups (32 threads per workgroup in task shader)
        const workgroup_count = (glyph_count + 31) / 32;
        // Commit all pending descriptor updates before GPU dispatch
        if (@import("builtin").mode == .Debug) self.stats.descriptors_flushed += self.descriptor_table.pending.len;
        self.descriptor_table.flushWrites();
        self.dispatch.cmdDrawMeshTasksEXT(cmd_buf, workgroup_count, 1, 1);
        if (@import("builtin").mode == .Debug) {
            self.core.stats.glyphs_submitted += glyph_count;
            self.core.stats.pool_free_blocks = self.core.poolFreeBlockCount();
        }

        self.last_submitted_frame +%= 1;
        self.frame_tokens[self.active_frame] = self.last_submitted_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        return self.last_submitted_frame;
    }

    pub fn deinit(self: *Renderer) void {
        self.markFrameComplete(std.math.maxInt(render.FrameToken));
        // Destroy Vulkan buffers (unmap + destroy buffer + free memory)
        for (self.command_buffers) |cmd_buf| {
            destroyMappedBuffer(cmd_buf, self.device, self.dispatch);
        }
        destroyMappedBuffer(self.pool_buffer, self.device, self.dispatch);

        // Destroy subsystems (reverse init order)
        self.core.deinit();
        self.pip.deinit();
        self.descriptor_table.deinit(self.allocator);

        self.* = undefined;
    }
};

test "InitOptions has correct defaults" {
    const opts = InitOptions{};
    try std.testing.expectEqual(@as(u32, 65_536), opts.max_glyph_descriptors);
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
    // Type 0: device-local only
    props.memory_types[0].property_flags = .{ .device_local_bit = true };
    // Type 1: host-visible only
    props.memory_types[1].property_flags = .{ .host_visible_bit = true };
    // Type 2: host-visible + host-coherent
    props.memory_types[2].property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true };

    const filter: u32 = 0b111;

    // Require host-visible + host-coherent → type 2
    const result = findMemoryType(props, filter, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try std.testing.expectEqual(@as(?u32, 2), result);

    // Require device-local → type 0
    const dl = findMemoryType(props, filter, .{ .device_local_bit = true });
    try std.testing.expectEqual(@as(?u32, 0), dl);

    // Require something unavailable → null
    const none = findMemoryType(props, filter, .{ .protected_bit = true });
    try std.testing.expectEqual(@as(?u32, null), none);

    // Type filter excludes type 2 → null for host-visible + host-coherent
    const filtered = findMemoryType(props, 0b011, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try std.testing.expectEqual(@as(?u32, null), filtered);
}

test "Renderer type compiles with expected fields" {
    _ = Renderer;
    try std.testing.expect(@hasField(Renderer, "device"));
    try std.testing.expect(@hasField(Renderer, "dispatch"));
    try std.testing.expect(@hasField(Renderer, "core"));
    try std.testing.expect(@hasField(Renderer, "descriptor_table"));
    try std.testing.expect(@hasField(Renderer, "pip"));
    try std.testing.expect(@hasField(Renderer, "pool_buffer"));
    try std.testing.expect(@hasField(Renderer, "command_buffers"));
    try std.testing.expect(@hasField(Renderer, "stats"));
}

test "Renderer satisfies core backend contract" {
    heavy_slug.core.render.BackendContract(Renderer);
    try std.testing.expect(true);
}

test "Renderer.init compiles" {
    // Type-check only — cannot call without a live Vulkan device
    _ = @TypeOf(Renderer.init);
}

test "Stats type compiles and has expected API" {
    var stats = Stats{};
    stats.reset();
    stats.log();
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 0), stats.descriptors_flushed);
    }
}
