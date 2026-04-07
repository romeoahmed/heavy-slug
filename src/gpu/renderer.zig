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

    const mem_req = dispatch.getBufferMemoryRequirements(device, buffer);

    const mem_type_index = findMemoryType(
        memory_properties,
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

pub const FontHandle = struct {
    id: u32,
    entry: *FontEntry,
};

const FontEntry = struct {
    id: u32,
    ctx: glyph_mod.FontContext,
};

pub const TextRenderer = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,

    // Subsystems
    descriptor_table: descriptors.DescriptorTable,
    pip: pipeline_mod.Pipeline,
    glyph_cache: cache_mod.GlyphCache,
    pool_alloc: pool_mod.PoolAllocator,

    // Vulkan buffers
    pool_buffer: MappedBuffer,
    command_buffer: MappedBuffer,

    // Font management
    ft_library: ft.Library,
    fonts: std.AutoHashMap(u32, *FontEntry),
    next_font_id: u32,

    // Per-frame state
    glyph_count: u32,
    max_glyphs_per_frame: u32,

    // Reusable HarfBuzz buffer (zero-alloc render loop)
    shape_buffer: hb.Buffer,

    // Stored for future buffer creation
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,

    pub fn init(
        device: vk.Device,
        dispatch: gpu_context.DeviceDispatch,
        color_format: vk.Format,
        memory_properties: vk.PhysicalDeviceMemoryProperties,
        allocator: std.mem.Allocator,
        options: InitOptions,
    ) !TextRenderer {
        // 1. Descriptor table
        var desc_table = try descriptors.DescriptorTable.init(
            device, dispatch, allocator, options.max_glyph_descriptors,
        );
        errdefer desc_table.deinit(allocator);

        // 2. Pipeline
        var pip = try pipeline_mod.Pipeline.init(
            device, dispatch, desc_table.layout, color_format,
        );
        errdefer pip.deinit();

        // 3. Glyph cache (pre-allocate HashMap to avoid render-loop allocations)
        var glyph_cache = cache_mod.GlyphCache.init(
            allocator, options.hot_slab_count, options.cold_lru_count, options.promote_frames,
        );
        errdefer glyph_cache.deinit();
        const total_cache_capacity = options.hot_slab_count + options.cold_lru_count;
        try glyph_cache.map.ensureTotalCapacity(total_cache_capacity);

        // 4. Pool allocator (pre-allocate free list to avoid render-loop allocations)
        var pool_alloc = pool_mod.PoolAllocator.init(
            allocator, options.pool_buffer_size, options.min_storage_alignment,
        );
        errdefer pool_alloc.deinit();
        try pool_alloc.free_blocks.ensureTotalCapacity(allocator, total_cache_capacity);

        // 5. Pool buffer (glyph blob storage, GPU reads as storage buffer)
        var pool_buf = try createMappedBuffer(
            device, dispatch, options.pool_buffer_size,
            .{ .storage_buffer_bit = true }, memory_properties,
        );
        errdefer destroyMappedBuffer(pool_buf, device, dispatch);

        // 6. Command buffer (GlyphCommand[] per frame, GPU reads as storage buffer)
        const cmd_buf_size = @as(vk.DeviceSize, options.max_glyphs_per_frame) *
            @sizeOf(descriptors.GlyphCommand);
        var cmd_buf = try createMappedBuffer(
            device, dispatch, cmd_buf_size,
            .{ .storage_buffer_bit = true }, memory_properties,
        );
        errdefer destroyMappedBuffer(cmd_buf, device, dispatch);

        // 7. FreeType library
        const ft_library = try ft.Library.init();
        errdefer ft_library.deinit();

        // 8. Reusable shaping buffer
        const shape_buffer = try hb.Buffer.create();
        errdefer shape_buffer.destroy();

        return .{
            .device = device,
            .dispatch = dispatch,
            .descriptor_table = desc_table,
            .pip = pip,
            .glyph_cache = glyph_cache,
            .pool_alloc = pool_alloc,
            .pool_buffer = pool_buf,
            .command_buffer = cmd_buf,
            .ft_library = ft_library,
            .fonts = std.AutoHashMap(u32, *FontEntry).init(allocator),
            .next_font_id = 0,
            .glyph_count = 0,
            .max_glyphs_per_frame = options.max_glyphs_per_frame,
            .shape_buffer = shape_buffer,
            .memory_properties = memory_properties,
            .allocator = allocator,
        };
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

test "TextRenderer type compiles with expected fields" {
    _ = TextRenderer;
    try std.testing.expect(@hasField(TextRenderer, "device"));
    try std.testing.expect(@hasField(TextRenderer, "dispatch"));
    try std.testing.expect(@hasField(TextRenderer, "descriptor_table"));
    try std.testing.expect(@hasField(TextRenderer, "pip"));
    try std.testing.expect(@hasField(TextRenderer, "glyph_cache"));
    try std.testing.expect(@hasField(TextRenderer, "pool_alloc"));
    try std.testing.expect(@hasField(TextRenderer, "pool_buffer"));
    try std.testing.expect(@hasField(TextRenderer, "command_buffer"));
    try std.testing.expect(@hasField(TextRenderer, "ft_library"));
    try std.testing.expect(@hasField(TextRenderer, "fonts"));
    try std.testing.expect(@hasField(TextRenderer, "glyph_count"));
    try std.testing.expect(@hasField(TextRenderer, "shape_buffer"));
}
