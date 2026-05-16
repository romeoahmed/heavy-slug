const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const gpu_structs = @import("gpu_structs");
const backend_options = @import("heavy_slug_backend_options");

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

const max_pending_writes: u32 = 8;

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

fn frameBindingCount() u32 {
    return if (backend_options.shader_stats) 3 else 2;
}

pub const DescriptorTable = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    layout: vk.DescriptorSetLayout,
    pool: vk.DescriptorPool,
    sets: []vk.DescriptorSet,
    pending: PendingWrites,
    debug_stats: DebugStats,

    pub fn init(
        ctx: gpu_context.VulkanContext,
        allocator: std.mem.Allocator,
        frame_set_count: u32,
    ) !DescriptorTable {
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        std.debug.assert(frame_set_count > 0);

        const binding_count = frameBindingCount();
        const bindings = [3]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .mesh_bit_ext = true, .fragment_bit = true },
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
                .stage_flags = .{ .task_bit_ext = true, .mesh_bit_ext = true, .fragment_bit = true },
                .p_immutable_samplers = null,
            },
        };
        const layout_ci = vk.DescriptorSetLayoutCreateInfo{
            .s_type = .descriptor_set_layout_create_info,
            .flags = .{},
            .binding_count = binding_count,
            .p_bindings = &bindings,
        };
        const layout = try dispatch.createDescriptorSetLayout(device, &layout_ci, null);
        errdefer dispatch.destroyDescriptorSetLayout(device, layout, null);

        const pool_sizes = [1]vk.DescriptorPoolSize{
            .{
                .type = .storage_buffer,
                .descriptor_count = binding_count * frame_set_count,
            },
        };
        const pool_ci = vk.DescriptorPoolCreateInfo{
            .s_type = .descriptor_pool_create_info,
            .flags = .{},
            .max_sets = frame_set_count,
            .pool_size_count = pool_sizes.len,
            .p_pool_sizes = &pool_sizes,
        };
        const pool = try dispatch.createDescriptorPool(device, &pool_ci, null);
        errdefer dispatch.destroyDescriptorPool(device, pool, null);

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

        return .{
            .device = device,
            .dispatch = dispatch,
            .layout = layout,
            .pool = pool,
            .sets = sets,
            .pending = .{},
            .debug_stats = .{},
        };
    }

    pub fn deinit(self: *DescriptorTable, allocator: std.mem.Allocator) void {
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

    pub fn flushWrites(self: *DescriptorTable) void {
        if (self.pending.len == 0) return;
        if (@import("builtin").mode == .Debug) {
            self.debug_stats.descriptor_writes += self.pending.len;
            self.debug_stats.descriptor_flush_calls += 1;
        }
        for (self.pending.writes[0..self.pending.len], 0..) |*w, i| {
            w.p_buffer_info = @ptrCast(&self.pending.buf_infos[i]);
        }
        self.dispatch.updateDescriptorSets(self.device, self.pending.writes[0..self.pending.len], null);
        self.pending.len = 0;
    }

    fn enqueueStorageBuffer(
        self: *DescriptorTable,
        frame_index: u32,
        binding: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        if (self.pending.len == max_pending_writes) {
            self.flushWrites();
        }
        const set = self.setForFrame(frame_index);
        self.pending.buf_infos[self.pending.len] = .{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };
        self.pending.writes[self.pending.len] = .{
            .s_type = .write_descriptor_set,
            .dst_set = set,
            .dst_binding = binding,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = undefined,
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        self.pending.len += 1;
    }

    pub fn updateGlyphPool(
        self: *DescriptorTable,
        frame_index: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        self.enqueueStorageBuffer(frame_index, 0, buffer, offset, range);
    }

    pub fn updateCommandBuffer(
        self: *DescriptorTable,
        frame_index: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        self.enqueueStorageBuffer(frame_index, 1, buffer, offset, range);
    }

    pub fn updateShaderStatsBuffer(
        self: *DescriptorTable,
        frame_index: u32,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        std.debug.assert(backend_options.shader_stats);
        self.enqueueStorageBuffer(frame_index, 2, buffer, offset, range);
    }
};

test "DescriptorTable debug stats reset in debug builds" {
    var stats = DebugStats{};
    stats.reset();
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 0), stats.descriptor_writes);
        try std.testing.expectEqual(@as(u32, 0), stats.descriptor_flush_calls);
    }
}

test "DescriptorTable: frame binding count follows shader stats option" {
    const expected: u32 = if (backend_options.shader_stats) 3 else 2;
    try std.testing.expectEqual(expected, frameBindingCount());
}
