const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");

/// Per-glyph draw command uploaded to GPU each frame (spec §10.1).
/// 64 bytes, tightly packed for storage buffer access.
pub const GlyphCommand = extern struct {
    motor: [4]f32,           // offset  0: PGA Motor [s, e12, e01, e02]
    color: [4]f32,           // offset 16: RGBA
    em_x_min: f32,           // offset 32
    em_y_min: f32,           // offset 36
    em_x_max: f32,           // offset 40
    em_y_max: f32,           // offset 44
    descriptor_index: u32,   // offset 48: index into glyph_blobs[] descriptor array
    flags: u32,              // offset 52: bit 0 = even-odd fill (0 = nonzero winding)
    _pad: [2]u32 = .{ 0, 0 }, // offset 56: align to 64 bytes
};

test "GlyphCommand is 64 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(GlyphCommand));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(GlyphCommand, "descriptor_index"));
}

/// Per-frame push constants (spec §6.3). 80 bytes, within Vulkan's
/// guaranteed 128-byte minimum push constant range.
pub const PushConstants = extern struct {
    proj: [4][4]f32,        // offset  0: column-major projection matrix
    viewport_dim: [2]f32,   // offset 64: viewport width, height in pixels
    glyph_count: u32,       // offset 72: number of glyphs this frame
    _pad: u32 = 0,          // offset 76: align to 80 bytes
};

test "PushConstants is 80 bytes with correct field offsets" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(PushConstants));
    try std.testing.expectEqual(@as(usize, 72), @offsetOf(PushConstants, "glyph_count"));
}

/// Stack-based free-list for descriptor slot indices.
/// Manages indices 0..capacity-1. O(1) alloc/free.
pub const SlotAllocator = struct {
    /// Stack of free slot indices. stack[0..count] are available.
    stack: []u32,
    count: u32,
    capacity: u32,

    /// Initialize with all slots free (indices 0..capacity-1 on the stack).
    pub fn init(allocator: std.mem.Allocator, capacity: u32) !SlotAllocator {
        const stack = try allocator.alloc(u32, capacity);
        // Fill stack with indices 0..capacity-1 (index capacity-1 at top; allocated first)
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

test "SlotAllocator: init populates all slots" {
    var sa = try SlotAllocator.init(std.testing.allocator, 4);
    defer sa.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u32, 4), sa.count);
    try std.testing.expectEqual(@as(u32, 4), sa.capacity);
}

test "SlotAllocator: alloc returns indices, free returns them" {
    var sa = try SlotAllocator.init(std.testing.allocator, 4);
    defer sa.deinit(std.testing.allocator);

    // Allocate all 4 slots
    const a = sa.alloc().?;
    const b = sa.alloc().?;
    const c = sa.alloc().?;
    const d = sa.alloc().?;
    try std.testing.expectEqual(@as(u32, 0), sa.count);

    // All indices should be distinct and < capacity
    var seen = [_]bool{false} ** 4;
    for ([_]u32{ a, b, c, d }) |idx| {
        try std.testing.expect(idx < 4);
        try std.testing.expect(!seen[idx]);
        seen[idx] = true;
    }

    // Alloc when empty returns null
    try std.testing.expectEqual(@as(?u32, null), sa.alloc());

    // Free one, re-alloc succeeds
    sa.free(b);
    try std.testing.expectEqual(@as(u32, 1), sa.count);
    const e = sa.alloc().?;
    try std.testing.expectEqual(b, e);
}

test "SlotAllocator: free and re-alloc cycle" {
    var sa = try SlotAllocator.init(std.testing.allocator, 2);
    defer sa.deinit(std.testing.allocator);

    const x = sa.alloc().?;
    sa.free(x);
    const y = sa.alloc().?;
    try std.testing.expectEqual(x, y);
}

pub const max_glyph_descriptors: u32 = 65_536;

pub const DescriptorTable = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    layout: vk.DescriptorSetLayout,
    pool: vk.DescriptorPool,
    set: vk.DescriptorSet,
    slots: SlotAllocator,

    pub fn init(
        device: vk.Device,
        dispatch: gpu_context.DeviceDispatch,
        allocator: std.mem.Allocator,
        slot_capacity: u32,
    ) !DescriptorTable {
        std.debug.assert(slot_capacity > 0);
        std.debug.assert(slot_capacity <= max_glyph_descriptors);
        // -- Create descriptor set layout --
        const binding_flags = [2]vk.DescriptorBindingFlags{
            .{ .partially_bound_bit = true, .update_after_bind_bit = true },
            .{},
        };
        const bindings = [2]vk.DescriptorSetLayoutBinding{
            .{
                .binding = 0,
                .descriptor_type = .storage_buffer,
                .descriptor_count = max_glyph_descriptors,
                .stage_flags = .{ .mesh_shader_bit_ext = true, .fragment_bit = true },
                .p_immutable_samplers = null,
            },
            .{
                .binding = 1,
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .task_shader_bit_ext = true, .mesh_shader_bit_ext = true },
                .p_immutable_samplers = null,
            },
        };
        const flags_info = vk.DescriptorSetLayoutBindingFlagsCreateInfo{
            .s_type = .descriptor_set_layout_binding_flags_create_info,
            .binding_count = 2,
            .p_binding_flags = &binding_flags,
        };
        const layout_ci = vk.DescriptorSetLayoutCreateInfo{
            .s_type = .descriptor_set_layout_create_info,
            .p_next = @ptrCast(&flags_info),
            .flags = .{ .update_after_bind_pool_bit = true },
            .binding_count = 2,
            .p_bindings = &bindings,
        };
        const layout = try dispatch.createDescriptorSetLayout(device, &layout_ci, null);
        errdefer dispatch.destroyDescriptorSetLayout(device, layout, null);

        // -- Create descriptor pool --
        const pool_sizes = [2]vk.DescriptorPoolSize{
            .{ .type = .storage_buffer, .descriptor_count = max_glyph_descriptors },
            .{ .type = .storage_buffer, .descriptor_count = 1 },
        };
        const pool_ci = vk.DescriptorPoolCreateInfo{
            .s_type = .descriptor_pool_create_info,
            .flags = .{ .update_after_bind_bit = true },
            .max_sets = 1,
            .pool_size_count = 2,
            .p_pool_sizes = &pool_sizes,
        };
        const pool = try dispatch.createDescriptorPool(device, &pool_ci, null);
        errdefer dispatch.destroyDescriptorPool(device, pool, null);

        // -- Allocate descriptor set --
        var set: vk.DescriptorSet = undefined;
        const alloc_info = vk.DescriptorSetAllocateInfo{
            .s_type = .descriptor_set_allocate_info,
            .descriptor_pool = pool,
            .descriptor_set_count = 1,
            .p_set_layouts = @ptrCast(&layout),
        };
        try dispatch.allocateDescriptorSets(device, &alloc_info, @ptrCast(&set));
        // No errdefer needed for `set`: descriptor sets allocated from a pool without
        // FREE_DESCRIPTOR_SET_BIT are freed implicitly when the pool is destroyed.

        // -- Slot allocator --
        const slots = try SlotAllocator.init(allocator, slot_capacity);

        return .{
            .device = device,
            .dispatch = dispatch,
            .layout = layout,
            .pool = pool,
            .set = set,
            .slots = slots,
        };
    }

    pub fn deinit(self: *DescriptorTable, allocator: std.mem.Allocator) void {
        self.slots.deinit(allocator);
        // Pool is destroyed before layout: the set was allocated without FREE_DESCRIPTOR_SET_BIT
        // so destroying the pool implicitly frees it. Layout has no dependency on the pool.
        self.dispatch.destroyDescriptorPool(self.device, self.pool, null);
        self.dispatch.destroyDescriptorSetLayout(self.device, self.layout, null);
        self.* = undefined;
    }

    /// Point descriptor slot `index` at a sub-range of `buffer`.
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
        const write = vk.WriteDescriptorSet{
            .s_type = .write_descriptor_set,
            .dst_set = self.set,
            .dst_binding = 0,
            .dst_array_element = index,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = @ptrCast(&buf_info),
            .p_image_info = null,
            .p_texel_buffer_view = null,
        };
        self.dispatch.updateDescriptorSets(self.device, 1, @ptrCast(&write), 0, null);
    }

    /// Update binding 1 to point at the GlyphCommand[] buffer for this frame.
    pub fn updateCommandBuffer(
        self: *DescriptorTable,
        buffer: vk.Buffer,
        offset: vk.DeviceSize,
        range: vk.DeviceSize,
    ) void {
        const buf_info = vk.DescriptorBufferInfo{
            .buffer = buffer,
            .offset = offset,
            .range = range,
        };
        const write = vk.WriteDescriptorSet{
            .s_type = .write_descriptor_set,
            .dst_set = self.set,
            .dst_binding = 1,
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = @ptrCast(&buf_info),
            .p_image_info = null,
            .p_texel_buffer_view = null,
        };
        self.dispatch.updateDescriptorSets(self.device, 1, @ptrCast(&write), 0, null);
    }

    /// Allocate a descriptor slot index from the free-list.
    pub fn allocSlot(self: *DescriptorTable) ?u32 {
        return self.slots.alloc();
    }

    /// Return a descriptor slot to the free-list.
    pub fn freeSlot(self: *DescriptorTable, slot: u32) void {
        self.slots.free(slot);
    }

    /// Write a null descriptor to binding 0 at `index`, making the slot safe
    /// to leave unbound. Call before freeSlot() on glyph cache eviction.
    /// Requires nullDescriptor feature from VK_EXT_robustness2.
    pub fn nullSlot(self: *DescriptorTable, index: u32) void {
        std.debug.assert(index < self.slots.capacity);
        const buf_info = vk.DescriptorBufferInfo{
            .buffer = .null_handle,
            .offset = 0,
            .range = std.math.maxInt(vk.DeviceSize), // VK_WHOLE_SIZE
        };
        const write = vk.WriteDescriptorSet{
            .s_type = .write_descriptor_set,
            .dst_set = self.set,
            .dst_binding = 0,
            .dst_array_element = index,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = @ptrCast(&buf_info),
            .p_image_info = null,
            .p_texel_buffer_view = null,
        };
        self.dispatch.updateDescriptorSets(self.device, 1, @ptrCast(&write), 0, null);
    }
};

test "DescriptorTable type and field layout compiles" {
    _ = DescriptorTable;
    // Verify the struct has expected fields
    try std.testing.expect(@hasField(DescriptorTable, "device"));
    try std.testing.expect(@hasField(DescriptorTable, "dispatch"));
    try std.testing.expect(@hasField(DescriptorTable, "layout"));
    try std.testing.expect(@hasField(DescriptorTable, "pool"));
    try std.testing.expect(@hasField(DescriptorTable, "set"));
    try std.testing.expect(@hasField(DescriptorTable, "slots"));
}
