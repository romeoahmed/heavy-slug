const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const gpu_structs = @import("gpu_structs");
const backend_options = @import("heavy_slug_backend_options");
const heavy_slug = @import("heavy_slug");
const memory = @import("memory.zig");

const resource_model = heavy_slug.gpu.resource_model;

/// Per-glyph draw instance uploaded to GPU each frame.
/// Generated from slangc reflection of shaders/core/abi.slang.
pub const GlyphInstance = gpu_structs.GlyphInstance;

/// Per-meshlet draw record uploaded to GPU each frame.
/// Generated from slangc reflection of shaders/core/abi.slang.
pub const GlyphMeshlet = gpu_structs.GlyphMeshlet;

/// Per-frame shader parameters. Kept within Vulkan's guaranteed
/// 128-byte minimum push constant range when sent through push constants.
/// Generated from slangc reflection of shaders/core/abi.slang.
pub const FrameParams = gpu_structs.FrameParams;

test "GlyphInstance has compact chart fields with stable leading offsets" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(GlyphInstance, "color"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(GlyphInstance, "blob_ref"));
    try std.testing.expect(@offsetOf(GlyphInstance, "glyph_anchor_q") > @offsetOf(GlyphInstance, "precision_bits"));
    try std.testing.expect(@sizeOf(GlyphInstance) <= 96);
}

test "GlyphMeshlet carries CPU-authored strip bounds" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(GlyphMeshlet, "glyph_index"));
    try std.testing.expect(@offsetOf(GlyphMeshlet, "rect_min_q") > @offsetOf(GlyphMeshlet, "glyph_index"));
    try std.testing.expect(@sizeOf(GlyphMeshlet) <= 64);
}

test "FrameParams carries mesh draw parameters and framebuffer conversion" {
    try std.testing.expect(@sizeOf(FrameParams) <= 128);
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(FrameParams, "viewport_size"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(FrameParams, "screen_from_framebuffer_2x2"));
    try std.testing.expect(@offsetOf(FrameParams, "meshlet_base") > @offsetOf(FrameParams, "meshlet_count"));
}

pub const PushStats = if (@import("builtin").mode == .Debug) struct {
    binding_writes: u32 = 0,
    push_calls: u32 = 0,
} else struct {};

pub fn frameBufferCount() u32 {
    return resource_model.descriptorBindingCount(backend_options.shader_stats);
}

pub const BufferView = memory.BufferView;

pub const FrameBindings = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    layout: vk.DescriptorSetLayout,

    pub fn init(
        ctx: gpu_context.Context,
    ) !FrameBindings {
        const device = ctx.device;
        const dispatch = ctx.dispatch;

        const binding_count = frameBufferCount();
        const bindings = [4]vk.DescriptorSetLayoutBinding{
            .{
                .binding = @intFromEnum(resource_model.BufferBinding.glyph_pool),
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .mesh_bit_ext = true, .fragment_bit = true },
                .p_immutable_samplers = null,
            },
            .{
                .binding = @intFromEnum(resource_model.BufferBinding.glyphs),
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .mesh_bit_ext = true, .fragment_bit = true },
                .p_immutable_samplers = null,
            },
            .{
                .binding = @intFromEnum(resource_model.BufferBinding.meshlets),
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .mesh_bit_ext = true, .fragment_bit = true },
                .p_immutable_samplers = null,
            },
            .{
                .binding = @intFromEnum(resource_model.BufferBinding.shader_stats),
                .descriptor_type = .storage_buffer,
                .descriptor_count = 1,
                .stage_flags = .{ .mesh_bit_ext = true, .fragment_bit = true },
                .p_immutable_samplers = null,
            },
        };
        const layout_ci = vk.DescriptorSetLayoutCreateInfo{
            .s_type = .descriptor_set_layout_create_info,
            .flags = .{ .push_descriptor_bit = true },
            .binding_count = binding_count,
            .p_bindings = &bindings,
        };
        const layout = try dispatch.createDescriptorSetLayout(device, &layout_ci, null);

        return .{
            .device = device,
            .dispatch = dispatch,
            .layout = layout,
        };
    }

    pub fn deinit(self: *FrameBindings) void {
        self.dispatch.destroyDescriptorSetLayout(self.device, self.layout, null);
        self.* = undefined;
    }

    pub fn pushFrameBuffers(
        self: FrameBindings,
        command_buffer: vk.CommandBuffer,
        pipeline_layout: vk.PipelineLayout,
        glyph_pool: BufferView,
        glyph_instances: BufferView,
        glyph_meshlets: BufferView,
        shader_stats: ?BufferView,
    ) PushStats {
        var buffer_infos: [4]vk.DescriptorBufferInfo = undefined;
        var writes: [4]vk.WriteDescriptorSet = undefined;
        var write_count: u32 = 0;

        appendBufferWrite(&buffer_infos, &writes, &write_count, .glyph_pool, glyph_pool);
        appendBufferWrite(&buffer_infos, &writes, &write_count, .glyphs, glyph_instances);
        appendBufferWrite(&buffer_infos, &writes, &write_count, .meshlets, glyph_meshlets);
        if (shader_stats) |stats| {
            std.debug.assert(backend_options.shader_stats);
            appendBufferWrite(&buffer_infos, &writes, &write_count, .shader_stats, stats);
        }

        self.dispatch.cmdPushDescriptorSet(
            command_buffer,
            .graphics,
            pipeline_layout,
            0,
            writes[0..write_count],
        );

        if (@import("builtin").mode == .Debug) return .{
            .binding_writes = write_count,
            .push_calls = 1,
        };
        return .{};
    }

    fn appendBufferWrite(
        buffer_infos: *[4]vk.DescriptorBufferInfo,
        writes: *[4]vk.WriteDescriptorSet,
        write_count: *u32,
        binding: resource_model.BufferBinding,
        buffer_binding: BufferView,
    ) void {
        const index = write_count.*;
        std.debug.assert(index < frameBufferCount());
        buffer_infos[index] = .{
            .buffer = buffer_binding.buffer,
            .offset = buffer_binding.offset,
            .range = buffer_binding.range,
        };
        writes[index] = .{
            .s_type = .write_descriptor_set,
            .dst_set = .null_handle,
            .dst_binding = @intFromEnum(binding),
            .dst_array_element = 0,
            .descriptor_count = 1,
            .descriptor_type = .storage_buffer,
            .p_buffer_info = @ptrCast(&buffer_infos[index]),
            .p_image_info = undefined,
            .p_texel_buffer_view = undefined,
        };
        write_count.* += 1;
    }
};

test "FrameBindings debug stats compile in debug builds" {
    const stats = PushStats{};
    if (@import("builtin").mode == .Debug) {
        try std.testing.expectEqual(@as(u32, 0), stats.binding_writes);
        try std.testing.expectEqual(@as(u32, 0), stats.push_calls);
    }
}

test "FrameBindings: frame buffer count follows shader stats option" {
    const expected: u32 = if (backend_options.shader_stats) 4 else 3;
    try std.testing.expectEqual(expected, frameBufferCount());
}
