const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const gpu_structs = @import("gpu_structs");
const backend_options = @import("heavy_slug_backend_options");

/// `VK_WHOLE_SIZE` sentinel used when writing null descriptors.
const whole_size: vk.DeviceSize = std.math.maxInt(vk.DeviceSize);

/// Per-glyph draw command uploaded to GPU each frame.
/// Generated from slangc reflection of shaders/core/abi.slang.
pub const GlyphCommand = gpu_structs.GlyphCommand;

/// Per-frame push constants. 80 bytes, within Vulkan's guaranteed
/// 128-byte minimum push constant range.
/// Generated from slangc reflection of shaders/core/abi.slang.
pub const PushConstants = gpu_structs.PushConstants;

test "GlyphCommand is 64 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(GlyphCommand));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(GlyphCommand, "glyph_ref"));
}

test "PushConstants is 80 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(PushConstants));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(PushConstants, "glyph_count"));
}

/// O(1) free-list for descriptor slot indices.
const SlotAllocator = struct {
    /// `stack[0..count]` contains available slots.
    stack: []u32,
    count: u32,
    capacity: u32,

    /// Initialize with every slot available.
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !SlotAllocator {
        const stack = try allocator.alloc(u32, capacity);
        for (stack, 0..) |*slot, i| {
            slot.* = @intCast(i);
        }
        return .{
            .stack = stack,
            .count = capacity,
            .capacity = capacity,
        };
    }

    pub fn deinit(self: *SlotAllocator, allocator: std.mem.Allocator) void {
        allocator.free(self.stack);
        self.* = undefined;
    }

    /// Allocate a free slot index. Returns null if all slots are in use.
    pub fn alloc(self: *SlotAllocator) ?u32 {
        if (self.count == 0) return null;
        self.count -= 1;
        return self.stack[self.count];
    }

    /// Return a slot index to the free list.
    pub fn free(self: *SlotAllocator, slot: u32) void {
        std.debug.assert(slot < self.capacity);
        std.debug.assert(self.count < self.capacity);
        self.stack[self.count] = slot;
        self.count += 1;
    }
};

test "SlotAllocator: allocates unique slots and reuses freed slots" {
    var sa = try SlotAllocator.init(std.testing.allocator, 4);
    defer sa.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), sa.count);
    try std.testing.expectEqual(@as(u32, 4), sa.capacity);

    const a = sa.alloc().?;
    const b = sa.alloc().?;
    const c = sa.alloc().?;
    const d = sa.alloc().?;
    try std.testing.expectEqual(@as(u32, 0), sa.count);

    var seen = [_]bool{false} ** 4;
    for ([_]u32{ a, b, c, d }) |idx| {
        try std.testing.expect(idx < 4);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }

    try std.testing.expectEqual(@as(?u32, null), sa.alloc());

    sa.free(b);
    try std.testing.expectEqual(@as(u32, 1), sa.count);
    const e = sa.alloc().?;
    try std.testing.expectEqual(b, e);
}

const max_glyph_descriptors: u32 = 65_536;
const max_pending_writes: u32 = 256;

pub const DebugStats = if (@import("builtin").mode == .Debug) struct {
    descriptor_writes: u32 = 0,
    descriptor_flush_calls: u32 = 0,

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }
} else struct {
    pub fn reset(_: *@This()) void {}
};

const PendingWrites = struct {
    writes: [max_pending_writes]vk.WriteDescriptorSet = undefined,
    buf_infos: [max_pending_writes]vk.DescriptorBufferInfo = undefined,
    len: u32 = 0,
};

pub const DescriptorTable = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    layout: vk.DescriptorSetLayout,
    pool: vk.DescriptorPool,
    sets: []vk.DescriptorSet,
    slots: SlotAllocator,
    pending: PendingWrites,
    debug_stats: DebugStats,

    pub fn init(
        ctx: gpu_context.VulkanContext,
        allocator: std.mem.Allocator,
        slot_capacity: u32,
        frame_set_count: u32,
    ) !DescriptorTable {
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        std.debug.assert(slot_capacity > 0);
        std.debug.assert(slot_capacity <= max_glyph_descriptors);
        std.debug.assert(frame_set_count > 0);
        try validateDescriptorLimits(ctx.descriptor_indexing_properties, slot_capacity, frame_set_count);
        const binding_count: u32 = if (backend_options.shader_stats) 3 else 2;
        const binding_flags = [3]vk.DescriptorBindingFlags{
            .{
                .partially_bound_bit = true,
                .update_after_bind_bit = true,
                .update_unused_while_pending_bit = true,
            },
            .{},
            .{},
        };
        const bindings = [3]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = slot_capacity,
                .stage_flags = .{ .fragment_bit = true },
                .p_immutable_samplers = null,
            },
            .{
                .binding = 1,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .task_bit_ext = true, .mesh_bit_ext = true },
                .p_immutable_samplers = null,
            },
            .{
                .binding = 2,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .fragment_bit = true },
                .p_immutable_samplers = null,
            },
        };
        const flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .s_type = .descriptor_set_layout_binding_flags_create_info,
            .binding_count = binding_count,
            .p_binding_flags = &binding_flags,
        };
        const layout_ci = vk.DescriptorSetLayoutCreateInfo{
            .s_type = .descriptor_set_layout_create_info,
            .p_next = @ptrCast(&flags_info),
            .flags = .{ .update_after_bind_pool_bit = true },
            .binding_count = binding_count,
            .p_bindings = &bindings,
        };
        const layout = try dispatch.createDescriptorSetLayout(device, &layout_ci, null);
        errdefer dispatch.destroyDescriptorSetLayout(device, layout, null);

        const descriptor_count_per_set = slot_capacity + 1 + @as(u32, if (backend_options.shader_stats) 1 else 0);
        const pool_sizes = [1]vk.DescriptorPoolSize{
            .{
                .type = .storage_buffer,
                .descriptor_count = descriptor_count_per_set * frame_set_count,
            },
        };
        const pool_ci = vk.DescriptorPoolCreateInfo{
            .s_type = .descriptor_pool_create_info,
            .flags = .{ .update_after_bind_bit = true },
            .max_sets = frame_set_count,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        const pool = try dispatch.createDescriptorPool(device, &pool_ci, null);
        errdefer dispatch.destroyDescriptorPool(device, pool, null);

        // Binding 1 is frame-local, so older submissions never observe updates.
        const layouts = try allocator.alloc(vk.DescriptorSetLayout, frame_set_count);
        defer allocator.free(layouts);
        @memset(layouts, layout);

        const sets = try allocator.alloc(vk.DescriptorSet, frame_set_count);
        errdefer allocator.free(sets);
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .s_type = .descriptor_set_allocate_info,
            .descriptor_pool = pool,
            .descriptor_set_count = frame_set_count,
            .p_set_layouts = layouts.ptr,
        };
        try dispatch.allocateDescriptorSets(device, &alloc_info, sets.ptr);
        // Descriptor sets are freed with the pool.

        const slots = try SlotAllocator.init(allocator, slot_capacity);

        return .{
            .device = device,
            .dispatch = dispatch,
            .layout = layout,
            .pool = pool,
            .sets = sets,
            .slots = slots,
            .pending = .{},
            .debug_stats = .{},
        };
    }

    pub fn deinit(self: *DescriptorTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        // Descriptor sets are pool-owned and layout-independent.
        self.dispatch.destroyDescriptorPool(self.device, self.pool, null);
        self.dispatch.destroyDescriptorSetLayout(self.device, self.layout, null);
        allocator.free(self.sets);
        self.* = undefined;
    }

    pub fn setForFrame(self: *const DescriptorTable, frame_index: u32) vk.DescriptorSet {
        std.debug.assert(frame_index < self.sets.len);
        return self.sets[frame_index];
    }

    pub fn resetDebugStats(self: *DescriptorTable) void {
        self.debug_stats.reset();
    }

    pub fn debugStats(self: *const DescriptorTable) DebugStats {
        return self.debug_stats;
    }

    /// Flush all pending descriptor writes in a single Vulkan API call.
    /// Must be called before any GPU work that reads the descriptors.
    pub fn flushWrites(self: *DescriptorTable) void {
        if (self.pending.len == 0) return;
        if (@import("builtin").mode == .Debug) {
            self.debug_stats.descriptor_writes += self.pending.len;
            self.debug_stats.descriptor_flush_calls += 1;
        }
        // `p_buffer_info` pointers must point into the stable inline array.
        for (self.pending.writes[0..self.pending.len], 0..) |*w, i| {
            w.p_buffer_info = @ptrCast(&self.pending.buf_infos[i]);
        }
        self.dispatch.updateDescriptorSets(self.device, self.pending.writes[0..self.pending.len], null);
        self.pending.len = 0;
    }

    /// Append a write to the pending buffer. Auto-flushes if buffer is full.
    fn enqueueWrite(self: *DescriptorTable, buf_info: vk.DescriptorBufferInfo, write: vk.WriteDescriptorSet) void {
        if (self.pending.len == max_pending_writes) {
            self.flushWrites();
        }
        self.pending.buf_infos[self.pending.len] = buf_info;
        self.pending.writes[self.pending.len] = write;
        self.pending.len += 1;
    }

    /// Point glyph descriptor slot `index` at a sub-range of `buffer`.
    pub fn updateSlot(
        self: *DescriptorTable,
        index: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        std.debug.assert(index < self.slots.capacity);
        const buf_info = vk.DescriptorBufferInfo{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };
        for (self.sets) |set| {
            const write = vk.WriteDescriptorSet{
                .s_type = .write_descriptor_set,
                .dst_set = set,
                .dst_binding = 0,
                .dst_array_element = index,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = undefined, // fixed up in flushWrites
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            self.enqueueWrite(buf_info, write);
        }
    }

    /// Update binding 1 to point at the GlyphCommand[] buffer for this frame.
    pub fn updateCommandBuffer(
        self: *DescriptorTable,
        frame_index: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        const set = self.setForFrame(frame_index);
        const buf_info = vk.DescriptorBufferInfo{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };
        const write = vk.WriteDescriptorSet{
            .s_type = .write_descriptor_set,
            .dst_set = set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = undefined, // fixed up in flushWrites
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.enqueueWrite(buf_info, write);
    }

    pub fn updateShaderStatsBuffer(
        self: *DescriptorTable,
        frame_index: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        std.debug.assert(backend_options.shader_stats);
        const set = self.setForFrame(frame_index);
        const buf_info = vk.DescriptorBufferInfo{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };
        const write = vk.WriteDescriptorSet{
            .s_type = .write_descriptor_set,
            .dst_set = set,
            .dst_binding = 2,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = undefined,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.enqueueWrite(buf_info, write);
    }

    /// Allocate a descriptor slot index from the free-list.
    pub fn allocSlot(self: *DescriptorTable) ?u32 {
        return self.slots.alloc();
    }

    /// Return a descriptor slot to the free-list.
    pub fn freeSlot(self: *DescriptorTable, slot: u32) void {
        self.slots.free(slot);
    }

    /// Clear binding 0 at `index` before returning a glyph slot to the free-list.
    pub fn nullSlot(self: *DescriptorTable, index: u32) void {
        std.debug.assert(index < self.slots.capacity);
        const buf_info = vk.DescriptorBufferInfo{
            .buffer = .null_handle,
            .offset = 0,
            .range = whole_size,
        };
        for (self.sets) |set| {
            const write = vk.WriteDescriptorSet{
                .s_type = .write_descriptor_set,
                .dst_set = set,
                .dst_binding = 0,
                .dst_array_element = index,
                .descriptor_count = 1,
                .descriptor_type = .storage_buffer,
                .p_buffer_info = undefined, // fixed up in flushWrites()
                .p_image_info = undefined,
                .p_texel_buffer_view = undefined,
            };
            self.enqueueWrite(buf_info, write);
        }
    }
};

fn validateDescriptorLimits(
    props: vk.PhysicalDeviceDescriptorIndexingProperties,
    slot_capacity: u32,
    frame_set_count: u32,
) !void {
    const update_after_bind_per_set = slot_capacity;
    const extra_frame_bindings: u32 = 1 + @as(u32, if (backend_options.shader_stats) 1 else 0);
    const descriptors_per_set = slot_capacity + extra_frame_bindings;
    const max_descriptors_per_set = max_glyph_descriptors + extra_frame_bindings;
    const update_after_bind_pool_total = update_after_bind_per_set * frame_set_count;

    if (update_after_bind_per_set > props.max_per_stage_descriptor_update_after_bind_storage_buffers or
        update_after_bind_per_set > props.max_descriptor_set_update_after_bind_storage_buffers or
        update_after_bind_per_set > props.max_per_stage_update_after_bind_resources or
        update_after_bind_pool_total > props.max_update_after_bind_descriptors_in_all_pools or
        descriptors_per_set > max_descriptors_per_set)
    {
        return error.DescriptorLimitExceeded;
    }
}

test "DescriptorTable debug stats reset in debug builds" {
    var stats = DebugStats{};
    stats.reset();
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 0), stats.descriptor_writes);
        try std.testing.expectEqual(@as(u32, 0), stats.descriptor_flush_calls);
    }
}

test "DescriptorTable: limit validation accepts typical configured capacity" {
    var props = std.mem.zeroes(vk.PhysicalDeviceDescriptorIndexingProperties);
    props.max_per_stage_descriptor_update_after_bind_storage_buffers = 65_536;
    props.max_per_stage_update_after_bind_resources = 65_536;
    props.max_descriptor_set_update_after_bind_storage_buffers = 65_536;
    props.max_update_after_bind_descriptors_in_all_pools = 65_536 * 3;
    try validateDescriptorLimits(props, 65_536, 3);
}

test "DescriptorTable: limit validation rejects oversized configured capacity" {
    var props = std.mem.zeroes(vk.PhysicalDeviceDescriptorIndexingProperties);
    props.max_per_stage_descriptor_update_after_bind_storage_buffers = 1024;
    props.max_per_stage_update_after_bind_resources = 1024;
    props.max_descriptor_set_update_after_bind_storage_buffers = 1024;
    props.max_update_after_bind_descriptors_in_all_pools = 1024;
    try std.testing.expectError(error.DescriptorLimitExceeded, validateDescriptorLimits(props, 2048, 3));
}

test "DescriptorTable: limit validation rejects insufficient update-after-bind pool total" {
    var props = std.mem.zeroes(vk.PhysicalDeviceDescriptorIndexingProperties);
    props.max_per_stage_descriptor_update_after_bind_storage_buffers = 65_536;
    props.max_per_stage_update_after_bind_resources = 65_536;
    props.max_descriptor_set_update_after_bind_storage_buffers = 65_536;
    props.max_update_after_bind_descriptors_in_all_pools = 65_536 * 2;
    try std.testing.expectError(error.DescriptorLimitExceeded, validateDescriptorLimits(props, 65_536, 3));
}
