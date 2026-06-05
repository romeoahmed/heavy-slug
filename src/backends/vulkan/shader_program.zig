//! Vulkan shader-object program for the mesh/fragment text path.

const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const bindings = @import("bindings.zig");
const spirv = @import("spirv_shaders");

/// Order matches the Vulkan 1.4 `vkCmdBindShadersEXT` graphics-stage list
/// (§10.7 "Shader Objects"): one slot for every graphics stage that can be
/// bound through a shader object, so the harness clears every slot it does
/// not use in one call.
const GraphicsStage = enum {
    vertex,
    tessellation_control,
    tessellation_evaluation,
    geometry,
    task,
    mesh,
    fragment,
};

const graphics_stage_count = @typeInfo(GraphicsStage).@"enum".fields.len;

const graphics_bind_stages: [graphics_stage_count]vk.ShaderStageFlags = blk: {
    var out: [graphics_stage_count]vk.ShaderStageFlags = undefined;
    out[@intFromEnum(GraphicsStage.vertex)] = .{ .vertex_bit = true };
    out[@intFromEnum(GraphicsStage.tessellation_control)] = .{ .tessellation_control_bit = true };
    out[@intFromEnum(GraphicsStage.tessellation_evaluation)] = .{ .tessellation_evaluation_bit = true };
    out[@intFromEnum(GraphicsStage.geometry)] = .{ .geometry_bit = true };
    out[@intFromEnum(GraphicsStage.task)] = .{ .task_bit_ext = true };
    out[@intFromEnum(GraphicsStage.mesh)] = .{ .mesh_bit_ext = true };
    out[@intFromEnum(GraphicsStage.fragment)] = .{ .fragment_bit = true };
    break :blk out;
};

const mesh_bind_index: comptime_int = @intFromEnum(GraphicsStage.mesh);
const fragment_bind_index: comptime_int = @intFromEnum(GraphicsStage.fragment);

/// Shader-object creation order — only mesh and fragment are linked.
const shader_object_stages = [_]vk.ShaderStageFlags{
    .{ .mesh_bit_ext = true },
    .{ .fragment_bit = true },
};

const mesh_shader_index = 0;
const fragment_shader_index = 1;

pub const ShaderProgram = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    pipeline_layout: vk.PipelineLayout,
    shaders: [shader_object_stages.len]vk.ShaderEXT,

    pub fn init(
        ctx: gpu_context.Context,
        frame_set_layout: vk.DescriptorSetLayout,
    ) !ShaderProgram {
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        const push_range = vk.PushConstantRange{
            .stage_flags = .{
                .mesh_bit_ext = true,
                .fragment_bit = true,
            },
            .offset = 0,
            .size = @sizeOf(bindings.FrameParams),
        };
        const layout_ci = vk.PipelineLayoutCreateInfo{
            .s_type = .pipeline_layout_create_info,
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&frame_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_range),
        };
        const pipeline_layout = try dispatch.createPipelineLayout(device, &layout_ci, null);
        errdefer dispatch.destroyPipelineLayout(device, pipeline_layout, null);

        var shaders: [shader_object_stages.len]vk.ShaderEXT = .{.null_handle} ** shader_object_stages.len;
        errdefer destroyShaders(device, dispatch, shaders);

        const set_layouts = [_]vk.DescriptorSetLayout{frame_set_layout};
        const push_ranges = [_]vk.PushConstantRange{push_range};
        const create_infos = shaderCreateInfos(&set_layouts, &push_ranges);
        const result = try dispatch.createShadersEXT(device, &create_infos, null, &shaders);
        if (result != .success) return error.ShaderObjectCreationFailed;

        return .{
            .device = device,
            .dispatch = dispatch,
            .pipeline_layout = pipeline_layout,
            .shaders = shaders,
        };
    }

    /// Bind the mesh + fragment shader objects and clear the unused graphics
    /// pre-raster stages. Cheap; called once per submitted text batch.
    ///
    /// This does NOT set the dozens of dynamic states that are constant for
    /// this renderer (topology, blend equation, write mask, depth/stencil
    /// off, …). Those live in `setFixedRenderState` and should be set once
    /// per command buffer recording by the host.
    pub fn bind(self: ShaderProgram, command_buffer: vk.CommandBuffer) void {
        var bound_shaders = [_]vk.ShaderEXT{.null_handle} ** graphics_bind_stages.len;
        bound_shaders[mesh_bind_index] = self.shaders[mesh_shader_index];
        bound_shaders[fragment_bind_index] = self.shaders[fragment_shader_index];
        self.dispatch.cmdBindShadersEXT(command_buffer, &graphics_bind_stages, &bound_shaders);
    }

    /// Set every shader-object dynamic state the renderer requires but never
    /// varies between frames (topology, blend equation, color write mask,
    /// depth/stencil/multisample disables, …). Hosts that record command
    /// buffers fresh each frame should call this once between
    /// `vkBeginCommandBuffer` and the first `vkCmdDrawMeshTasksEXT`; hosts
    /// that build command buffers ahead of time may call it during recording.
    pub fn setFixedRenderState(self: ShaderProgram, command_buffer: vk.CommandBuffer) void {
        setFixedDynamicState(self.dispatch, command_buffer);
    }

    pub fn deinit(self: *ShaderProgram) void {
        destroyShaders(self.device, self.dispatch, self.shaders);
        self.dispatch.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.* = undefined;
    }
};

fn shaderCreateInfos(
    set_layouts: []const vk.DescriptorSetLayout,
    push_ranges: []const vk.PushConstantRange,
) [shader_object_stages.len]vk.ShaderCreateInfoEXT {
    return .{
        shaderCreateInfo(
            .{ .mesh_bit_ext = true },
            .{ .fragment_bit = true },
            .{ .link_stage_bit_ext = true, .no_task_shader_bit_ext = true },
            spirv.mesh,
            set_layouts,
            push_ranges,
        ),
        shaderCreateInfo(
            .{ .fragment_bit = true },
            .{},
            .{ .link_stage_bit_ext = true },
            spirv.fragment,
            set_layouts,
            push_ranges,
        ),
    };
}

fn shaderCreateInfo(
    stage: vk.ShaderStageFlags,
    next_stage: vk.ShaderStageFlags,
    flags: vk.ShaderCreateFlagsEXT,
    code: []align(4) const u8,
    set_layouts: []const vk.DescriptorSetLayout,
    push_ranges: []const vk.PushConstantRange,
) vk.ShaderCreateInfoEXT {
    return .{
        .flags = flags,
        .stage = stage,
        .next_stage = next_stage,
        .code_type = .spirv_ext,
        .code_size = code.len,
        .p_code = @ptrCast(code.ptr),
        .p_name = "main",
        .set_layout_count = @intCast(set_layouts.len),
        .p_set_layouts = set_layouts.ptr,
        .push_constant_range_count = @intCast(push_ranges.len),
        .p_push_constant_ranges = push_ranges.ptr,
    };
}

fn destroyShaders(
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    shaders: [shader_object_stages.len]vk.ShaderEXT,
) void {
    for (shaders) |shader| {
        if (shader != .null_handle) dispatch.destroyShaderEXT(device, shader, null);
    }
}

fn setFixedDynamicState(dispatch: gpu_context.DeviceDispatch, command_buffer: vk.CommandBuffer) void {
    // Mesh-shading pipelines do not consume vertex input state (Vulkan 1.4
    // §15.2.2 "Mesh Shading"), so we publish an empty vertex input state
    // for validation-layer cleanliness but do not bind any vertex buffers.
    dispatch.cmdSetVertexInputEXT(command_buffer, null, null);
    dispatch.cmdSetPrimitiveTopology(command_buffer, .triangle_list);
    dispatch.cmdSetPrimitiveRestartEnable(command_buffer, .false);

    dispatch.cmdSetRasterizerDiscardEnable(command_buffer, .false);
    dispatch.cmdSetCullMode(command_buffer, .{});
    dispatch.cmdSetFrontFace(command_buffer, .counter_clockwise);
    dispatch.cmdSetPolygonModeEXT(command_buffer, .fill);
    dispatch.cmdSetLineWidth(command_buffer, 1.0);
    dispatch.cmdSetDepthClampEnableEXT(command_buffer, .false);
    dispatch.cmdSetDepthBiasEnable(command_buffer, .false);
    dispatch.cmdSetDepthBias(command_buffer, 0.0, 0.0, 0.0);
    dispatch.cmdSetPatchControlPointsEXT(command_buffer, 1);
    dispatch.cmdSetTessellationDomainOriginEXT(command_buffer, .upper_left);

    dispatch.cmdSetRasterizationSamplesEXT(command_buffer, .{ .@"1_bit" = true });
    var sample_mask = [_]vk.SampleMask{std.math.maxInt(vk.SampleMask)};
    dispatch.cmdSetSampleMaskEXT(command_buffer, .{ .@"1_bit" = true }, &sample_mask);
    dispatch.cmdSetAlphaToCoverageEnableEXT(command_buffer, .false);
    dispatch.cmdSetAlphaToOneEnableEXT(command_buffer, .false);

    dispatch.cmdSetDepthTestEnable(command_buffer, .false);
    dispatch.cmdSetDepthWriteEnable(command_buffer, .false);
    dispatch.cmdSetDepthCompareOp(command_buffer, .always);
    dispatch.cmdSetDepthBoundsTestEnable(command_buffer, .false);
    dispatch.cmdSetDepthBounds(command_buffer, 0.0, 1.0);
    dispatch.cmdSetStencilTestEnable(command_buffer, .false);
    const stencil_faces: vk.StencilFaceFlags = .{ .front_bit = true, .back_bit = true };
    dispatch.cmdSetStencilCompareMask(command_buffer, stencil_faces, 0);
    dispatch.cmdSetStencilWriteMask(command_buffer, stencil_faces, 0);
    dispatch.cmdSetStencilReference(command_buffer, stencil_faces, 0);
    dispatch.cmdSetStencilOp(command_buffer, stencil_faces, .keep, .keep, .keep, .always);

    dispatch.cmdSetLogicOpEnableEXT(command_buffer, .false);
    dispatch.cmdSetLogicOpEXT(command_buffer, .copy);
    const blend_enable = [_]vk.Bool32{.true};
    dispatch.cmdSetColorBlendEnableEXT(command_buffer, 0, &blend_enable);
    const blend_equation = [_]vk.ColorBlendEquationEXT{.{
        .src_color_blend_factor = .one,
        .dst_color_blend_factor = .one_minus_src_alpha,
        .color_blend_op = .add,
        .src_alpha_blend_factor = .one,
        .dst_alpha_blend_factor = .one_minus_src_alpha,
        .alpha_blend_op = .add,
    }};
    dispatch.cmdSetColorBlendEquationEXT(command_buffer, 0, &blend_equation);
    dispatch.cmdSetBlendConstants(command_buffer, &.{ 0.0, 0.0, 0.0, 0.0 });
    const write_mask = [_]vk.ColorComponentFlags{.{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true }};
    dispatch.cmdSetColorWriteMaskEXT(command_buffer, 0, &write_mask);
}

test "push constant range matches FrameParams size" {
    try std.testing.expect(@sizeOf(bindings.FrameParams) <= 128);
}

test "embedded SPIR-V data is non-empty" {
    try std.testing.expect(spirv.mesh.len > 0);
    try std.testing.expect(spirv.fragment.len > 0);
}

test "SPIR-V length is multiple of 4 (u32-aligned words)" {
    try std.testing.expectEqual(@as(usize, 0), spirv.mesh.len % 4);
    try std.testing.expectEqual(@as(usize, 0), spirv.fragment.len % 4);
}

test "shader object creation stages are linked mesh and fragment" {
    try std.testing.expect(shader_object_stages[mesh_shader_index].mesh_bit_ext);
    try std.testing.expect(shader_object_stages[fragment_shader_index].fragment_bit);
}

test "shader object bind stages explicitly clear unused pre-raster stages" {
    try std.testing.expectEqual(@as(usize, 7), graphics_stage_count);
    try std.testing.expect(graphics_bind_stages[@intFromEnum(GraphicsStage.vertex)].vertex_bit);
    try std.testing.expect(graphics_bind_stages[@intFromEnum(GraphicsStage.tessellation_control)].tessellation_control_bit);
    try std.testing.expect(graphics_bind_stages[@intFromEnum(GraphicsStage.tessellation_evaluation)].tessellation_evaluation_bit);
    try std.testing.expect(graphics_bind_stages[@intFromEnum(GraphicsStage.geometry)].geometry_bit);
    try std.testing.expect(graphics_bind_stages[@intFromEnum(GraphicsStage.task)].task_bit_ext);
    try std.testing.expect(graphics_bind_stages[mesh_bind_index].mesh_bit_ext);
    try std.testing.expect(graphics_bind_stages[fragment_bind_index].fragment_bit);
}

test "mesh shader object declares no-task usage" {
    const infos = shaderCreateInfos(&.{}, &.{});
    try std.testing.expect(infos[0].flags.link_stage_bit_ext);
    try std.testing.expect(infos[0].flags.no_task_shader_bit_ext);
    try std.testing.expect(infos[1].flags.link_stage_bit_ext);
    try std.testing.expect(!infos[1].flags.no_task_shader_bit_ext);
}
