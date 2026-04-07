const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const descriptors = @import("descriptors.zig");
const pipeline_mod = @import("pipeline.zig");
const pool_mod = @import("pool.zig");
const cache_mod = @import("cache.zig");
const ft = @import("../font/ft.zig");
const hb = @import("../font/hb.zig");
const glyph_mod = @import("../font/glyph.zig");
const pga = @import("../math/pga.zig");

pub const Error = error{
    NoSuitableMemoryType,
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
    DescriptorSlotExhausted,
};

pub const InitOptions = struct {
    max_glyph_descriptors: u32 = 65_536,
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024, // 32 MB
    /// Must match device's minStorageBufferOffsetAlignment. 256 is
    /// conservatively correct for all conformant Vulkan implementations.
    min_storage_alignment: u32 = 256,
};

/// A host-visible, host-coherent VkBuffer with persistently mapped memory.
pub const MappedBuffer = struct {
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
        if (type_filter & (@as(u32, 1) << @intCast(i)) != 0) {
            const flags_bits: u32 = @bitCast(properties.memory_types[i].property_flags);
            if (flags_bits & required_bits == required_bits) {
                return @intCast(i);
            }
        }
    }
    return null;
}

fn createMappedBuffer(
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
    memory_properties: vk.PhysicalDeviceMemoryProperties,
) !MappedBuffer {
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
    errdefer dispatch.destroyBuffer(device, buffer, null);

    const mem_req = dispatch.getBufferMemoryRequirements(device, buffer);

    const mem_type_index = findMemoryType(
        memory_properties,
        mem_req.memory_type_bits,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    ) orelse return Error.NoSuitableMemoryType;

    const alloc_info = vk.MemoryAllocateInfo{
        .s_type = .memory_allocate_info,
        .allocation_size = mem_req.size,
        .memory_type_index = mem_type_index,
    };
    const memory = try dispatch.allocateMemory(device, &alloc_info, null);
    errdefer dispatch.freeMemory(device, memory, null);

    try dispatch.bindBufferMemory(device, buffer, memory, 0);

    const mapped_ptr = try dispatch.mapMemory(device, memory, 0, size, .{});

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = @ptrCast(mapped_ptr),
        .size = size,
    };
}

fn destroyMappedBuffer(self: MappedBuffer, device: vk.Device, dispatch: gpu_context.DeviceDispatch) void {
    dispatch.unmapMemory(device, self.memory);
    dispatch.destroyBuffer(device, self.buffer, null);
    dispatch.freeMemory(device, self.memory, null);
}

pub const FontHandle = struct {
    id: u32,
    entry: *FontEntry,
};

const FontEntry = struct {
    id: u32,
    ctx: glyph_mod.FontContext,
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
