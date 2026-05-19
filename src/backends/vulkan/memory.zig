//! Vulkan buffer allocation helpers used by the backend-owned storage streams.

const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");

pub const Error = error{
    NoSuitableMemoryType,
};

pub const MappedBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
    size: vk.DeviceSize,

    pub fn view(self: MappedBuffer) BufferView {
        return .{
            .buffer = self.buffer,
            .offset = 0,
            .range = self.size,
        };
    }

    pub fn bytes(self: MappedBuffer) []u8 {
        return self.mapped[0..@intCast(self.size)];
    }

    pub fn copyFrom(self: MappedBuffer, offset: usize, data: []const u8) void {
        const len: usize = @intCast(self.size);
        std.debug.assert(offset <= len);
        std.debug.assert(data.len <= len - offset);
        @memcpy(self.bytes()[offset..][0..data.len], data);
    }
};

pub const BufferView = struct {
    buffer: vk.Buffer,
    offset: vk.DeviceSize,
    range: vk.DeviceSize,
};

const mapped_properties: vk.MemoryPropertyFlags = .{
    .host_visible_bit = true,
    .host_coherent_bit = true,
};

pub fn findMemoryType(
    properties: vk.PhysicalDeviceMemoryProperties,
    type_filter: u32,
    required: vk.MemoryPropertyFlags,
) ?u32 {
    const required_bits: u32 = @bitCast(required);
    for (0..properties.memory_type_count) |i| {
        const mask = @as(u32, 1) << @as(u5, @intCast(i));
        if (type_filter & mask == 0) continue;

        const flags_bits: u32 = @bitCast(properties.memory_types[i].property_flags);
        if (flags_bits & required_bits == required_bits) {
            return @intCast(i);
        }
    }
    return null;
}

pub fn createMapped(
    ctx: gpu_context.Context,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
) !MappedBuffer {
    std.debug.assert(size > 0);

    const device = ctx.device;
    const dispatch = ctx.dispatch;
    const buffer = try dispatch.createBuffer(device, &.{
        .flags = .{},
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
    }, null);
    errdefer dispatch.destroyBuffer(device, buffer, null);

    const mem_req = dispatch.getBufferMemoryRequirements(device, buffer);
    const mem_type_index = findMemoryType(
        ctx.memory_properties,
        mem_req.memory_type_bits,
        mapped_properties,
    ) orelse return Error.NoSuitableMemoryType;

    const memory = try dispatch.allocateMemory(device, &.{
        .allocation_size = mem_req.size,
        .memory_type_index = mem_type_index,
    }, null);
    errdefer dispatch.freeMemory(device, memory, null);

    try dispatch.bindBufferMemory(device, buffer, memory, 0);

    const mapped = try dispatch.mapMemory(device, memory, 0, size, .{});
    errdefer dispatch.unmapMemory(device, memory);

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = @ptrCast(mapped.?),
        .size = size,
    };
}

pub fn destroy(self: MappedBuffer, device: vk.Device, dispatch: gpu_context.DeviceDispatch) void {
    dispatch.unmapMemory(device, self.memory);
    dispatch.destroyBuffer(device, self.buffer, null);
    dispatch.freeMemory(device, self.memory, null);
}

test "findMemoryType selects the first type matching filter and properties" {
    var props = std.mem.zeroes(vk.PhysicalDeviceMemoryProperties);
    props.memory_type_count = 3;
    props.memory_types[0].property_flags = .{ .device_local_bit = true };
    props.memory_types[1].property_flags = .{ .host_visible_bit = true };
    props.memory_types[2].property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true };

    const filter: u32 = 0b111;

    try std.testing.expectEqual(
        @as(?u32, 2),
        findMemoryType(props, filter, mapped_properties),
    );
    try std.testing.expectEqual(
        @as(?u32, 0),
        findMemoryType(props, filter, .{ .device_local_bit = true }),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        findMemoryType(props, filter, .{ .protected_bit = true }),
    );
    try std.testing.expectEqual(
        @as(?u32, null),
        findMemoryType(props, 0b011, mapped_properties),
    );
}
