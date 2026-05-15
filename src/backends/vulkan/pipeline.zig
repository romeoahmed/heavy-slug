const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const descriptors = @import("descriptors.zig");
const spv = @import("shader_spv");

pub const Pipeline = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    pipeline_layout: vk.PipelineLayout,
    pipeline: vk.Pipeline,

    pub fn init(
        ctx: gpu_context.VulkanContext,
        descriptor_set_layout: vk.DescriptorSetLayout,
        color_format: vk.Format,
    ) !Pipeline {
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        // --- Pipeline layout ---
        const push_range = vk.PushConstantRange{
            .stage_flags = .{
                .task_bit_ext = true,
                .mesh_bit_ext = true,
                .fragment_bit = true,
            },
            .offset = 0,
            .size = @sizeOf(descriptors.PushConstants),
        };
        const layout_ci = vk.PipelineLayoutCreateInfo{
            .s_type = .pipeline_layout_create_info,
            .flags = .{},
            .set_layout_count = 1,
            .p_set_layouts = @ptrCast(&descriptor_set_layout),
            .push_constant_range_count = 1,
            .p_push_constant_ranges = @ptrCast(&push_range),
        };
        const pipeline_layout = try dispatch.createPipelineLayout(device, &layout_ci, null);
        errdefer dispatch.destroyPipelineLayout(device, pipeline_layout, null);

        // --- Shader modules (transient — destroyed after pipeline creation) ---
        const task_module = try createShaderModule(device, dispatch, spv.task);
        defer dispatch.destroyShaderModule(device, task_module, null);

        const mesh_module = try createShaderModule(device, dispatch, spv.mesh);
        defer dispatch.destroyShaderModule(device, mesh_module, null);

        const frag_module = try createShaderModule(device, dispatch, spv.fragment);
        defer dispatch.destroyShaderModule(device, frag_module, null);

        // --- Shader stages ---
        const stages = [3]vk.PipelineShaderStageCreateInfo{
            .{
                .s_type = .pipeline_shader_stage_create_info,
                .flags = .{},
                .stage = .{ .task_bit_ext = true },
                .module = task_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .s_type = .pipeline_shader_stage_create_info,
                .flags = .{},
                .stage = .{ .mesh_bit_ext = true },
                .module = mesh_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
            .{
                .s_type = .pipeline_shader_stage_create_info,
                .flags = .{},
                .stage = .{ .fragment_bit = true },
                .module = frag_module,
                .p_name = "main",
                .p_specialization_info = null,
            },
        };

        // --- Dynamic rendering (no VkRenderPass) ---
        const rendering_info = vk.PipelineRenderingCreateInfo{
            .s_type = .pipeline_rendering_create_info,
            .p_next = null,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachment_formats = @ptrCast(&color_format),
            .depth_attachment_format = .undefined,
            .stencil_attachment_format = .undefined,
        };

        // --- Viewport (dynamic state) ---
        const viewport_state = vk.PipelineViewportStateCreateInfo{
            .s_type = .pipeline_viewport_state_create_info,
            .flags = .{},
            .viewport_count = 1,
            .p_viewports = null,
            .scissor_count = 1,
            .p_scissors = null,
        };

        // --- Rasterization ---
        const raster_state = vk.PipelineRasterizationStateCreateInfo{
            .s_type = .pipeline_rasterization_state_create_info,
            .flags = .{},
            .depth_clamp_enable = .false,
            .rasterizer_discard_enable = .false,
            .polygon_mode = .fill,
            .cull_mode = .{}, // no culling — quads may flip depending on motor
            .front_face = .counter_clockwise,
            .depth_bias_enable = .false,
            .depth_bias_constant_factor = 0.0,
            .depth_bias_clamp = 0.0,
            .depth_bias_slope_factor = 0.0,
            .line_width = 1.0,
        };

        // --- Multisample ---
        const multisample_state = vk.PipelineMultisampleStateCreateInfo{
            .s_type = .pipeline_multisample_state_create_info,
            .flags = .{},
            .rasterization_samples = .{ .@"1_bit" = true },
            .sample_shading_enable = .false,
            .min_sample_shading = 0.0,
            .p_sample_mask = null,
            .alpha_to_coverage_enable = .false,
            .alpha_to_one_enable = .false,
        };

        // --- Color blend: premultiplied alpha ---
        const blend_attachment = vk.PipelineColorBlendAttachmentState{
            .blend_enable = .true,
            .src_color_blend_factor = .one,
            .dst_color_blend_factor = .one_minus_src_alpha,
            .color_blend_op = .add,
            .src_alpha_blend_factor = .one,
            .dst_alpha_blend_factor = .one_minus_src_alpha,
            .alpha_blend_op = .add,
            .color_write_mask = .{ .r_bit = true, .g_bit = true, .b_bit = true, .a_bit = true },
        };
        const blend_state = vk.PipelineColorBlendStateCreateInfo{
            .s_type = .pipeline_color_blend_state_create_info,
            .flags = .{},
            .logic_op_enable = .false,
            .logic_op = .copy,
            .attachment_count = 1,
            .p_attachments = @ptrCast(&blend_attachment),
            .blend_constants = .{ 0.0, 0.0, 0.0, 0.0 },
        };

        // --- Dynamic state ---
        const dynamic_states = [_]vk.DynamicState{ .viewport, .scissor };
        const dynamic_state = vk.PipelineDynamicStateCreateInfo{
            .s_type = .pipeline_dynamic_state_create_info,
            .flags = .{},
            .dynamic_state_count = dynamic_states.len,
            .p_dynamic_states = &dynamic_states,
        };

        // --- Graphics pipeline ---
        const pipeline_ci = vk.GraphicsPipelineCreateInfo{
            .s_type = .graphics_pipeline_create_info,
            .p_next = @ptrCast(&rendering_info),
            .flags = .{},
            .stage_count = stages.len,
            .p_stages = &stages,
            .p_vertex_input_state = null, // mesh shader — no vertex input
            .p_input_assembly_state = null, // mesh shader — no input assembly
            .p_tessellation_state = null,
            .p_viewport_state = &viewport_state,
            .p_rasterization_state = &raster_state,
            .p_multisample_state = &multisample_state,
            .p_depth_stencil_state = null,
            .p_color_blend_state = &blend_state,
            .p_dynamic_state = &dynamic_state,
            .layout = pipeline_layout,
            .render_pass = .null_handle,
            .subpass = 0,
            .base_pipeline_handle = .null_handle,
            .base_pipeline_index = -1,
        };
        var pipeline_handle: vk.Pipeline = undefined;
        _ = try dispatch.createGraphicsPipelines(
            device,
            .null_handle, // no pipeline cache
            @as([]const vk.GraphicsPipelineCreateInfo, &.{pipeline_ci}),
            null,
            @as([]vk.Pipeline, (&pipeline_handle)[0..1]),
        );

        return .{
            .device = device,
            .dispatch = dispatch,
            .pipeline_layout = pipeline_layout,
            .pipeline = pipeline_handle,
        };
    }

    pub fn deinit(self: *Pipeline) void {
        self.dispatch.destroyPipeline(self.device, self.pipeline, null);
        self.dispatch.destroyPipelineLayout(self.device, self.pipeline_layout, null);
        self.* = undefined;
    }
};

/// Create a VkShaderModule from embedded SPIR-V bytes.
/// SPIR-V data must be a multiple of 4 bytes (u32-aligned words).
fn createShaderModule(
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,
    bytecode: []align(4) const u8,
) !vk.ShaderModule {
    const ci = vk.ShaderModuleCreateInfo{
        .s_type = .shader_module_create_info,
        .flags = .{},
        .code_size = bytecode.len,
        .p_code = @ptrCast(bytecode.ptr),
    };
    return dispatch.createShaderModule(device, &ci, null);
}

test "Pipeline type compiles with expected fields" {
    _ = Pipeline;
    try std.testing.expect(@hasField(Pipeline, "device"));
    try std.testing.expect(@hasField(Pipeline, "dispatch"));
    try std.testing.expect(@hasField(Pipeline, "pipeline_layout"));
    try std.testing.expect(@hasField(Pipeline, "pipeline"));
}

test "push constant range matches PushConstants size" {
    try std.testing.expectEqual(@as(usize, 80), @sizeOf(descriptors.PushConstants));
}

test "embedded SPIR-V data is non-empty" {
    try std.testing.expect(spv.task.len > 0);
    try std.testing.expect(spv.mesh.len > 0);
    try std.testing.expect(spv.fragment.len > 0);
}

test "SPIR-V length is multiple of 4 (u32-aligned words)" {
    try std.testing.expectEqual(@as(usize, 0), spv.task.len % 4);
    try std.testing.expectEqual(@as(usize, 0), spv.mesh.len % 4);
    try std.testing.expectEqual(@as(usize, 0), spv.fragment.len % 4);
}
