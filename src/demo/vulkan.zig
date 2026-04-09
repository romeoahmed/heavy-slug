//! Demo Vulkan bootstrap: instance, device, swapchain, and frame management.
//! This is demo infrastructure — the heavy-slug library itself only needs
//! a VkDevice and dispatch table (provided via VulkanContext).

const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw.zig");
const gpu_context = @import("heavy_slug").gpu_context;

// ============================================================
// Dispatch types
// ============================================================

/// Pre-instance Vulkan functions (loaded with null instance).
const BaseDispatchTable = struct {
    vkCreateInstance: ?vk.PfnCreateInstance = null,
    vkEnumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
};
const BaseDispatch = vk.BaseWrapperWithCustomDispatch(BaseDispatchTable);

/// Instance-level functions for the demo (surface queries, device creation).
const DemoInstanceTable = struct {
    vkDestroyInstance: ?vk.PfnDestroyInstance = null,
    vkEnumeratePhysicalDevices: ?vk.PfnEnumeratePhysicalDevices = null,
    vkGetPhysicalDeviceProperties: ?vk.PfnGetPhysicalDeviceProperties = null,
    vkGetPhysicalDeviceQueueFamilyProperties: ?vk.PfnGetPhysicalDeviceQueueFamilyProperties = null,
    vkCreateDevice: ?vk.PfnCreateDevice = null,
    vkGetDeviceProcAddr: ?vk.PfnGetDeviceProcAddr = null,
    vkDestroySurfaceKHR: ?vk.PfnDestroySurfaceKHR = null,
    vkGetPhysicalDeviceSurfaceSupportKHR: ?vk.PfnGetPhysicalDeviceSurfaceSupportKHR = null,
    vkGetPhysicalDeviceSurfaceCapabilitiesKHR: ?vk.PfnGetPhysicalDeviceSurfaceCapabilitiesKHR = null,
    vkGetPhysicalDeviceSurfaceFormatsKHR: ?vk.PfnGetPhysicalDeviceSurfaceFormatsKHR = null,
    vkGetPhysicalDeviceSurfacePresentModesKHR: ?vk.PfnGetPhysicalDeviceSurfacePresentModesKHR = null,
};
const DemoInstanceDispatch = vk.InstanceWrapperWithCustomDispatch(DemoInstanceTable);

/// Device-level functions for the demo (swapchain, command buffers, sync, rendering).
const DemoDeviceTable = struct {
    vkDestroyDevice: ?vk.PfnDestroyDevice = null,
    vkDeviceWaitIdle: ?vk.PfnDeviceWaitIdle = null,
    // Swapchain
    vkCreateSwapchainKHR: ?vk.PfnCreateSwapchainKHR = null,
    vkDestroySwapchainKHR: ?vk.PfnDestroySwapchainKHR = null,
    vkGetSwapchainImagesKHR: ?vk.PfnGetSwapchainImagesKHR = null,
    vkAcquireNextImageKHR: ?vk.PfnAcquireNextImageKHR = null,
    // Image views
    vkCreateImageView: ?vk.PfnCreateImageView = null,
    vkDestroyImageView: ?vk.PfnDestroyImageView = null,
    // Command buffers
    vkCreateCommandPool: ?vk.PfnCreateCommandPool = null,
    vkDestroyCommandPool: ?vk.PfnDestroyCommandPool = null,
    vkAllocateCommandBuffers: ?vk.PfnAllocateCommandBuffers = null,
    vkResetCommandBuffer: ?vk.PfnResetCommandBuffer = null,
    vkBeginCommandBuffer: ?vk.PfnBeginCommandBuffer = null,
    vkEndCommandBuffer: ?vk.PfnEndCommandBuffer = null,
    // Sync
    vkCreateFence: ?vk.PfnCreateFence = null,
    vkDestroyFence: ?vk.PfnDestroyFence = null,
    vkWaitForFences: ?vk.PfnWaitForFences = null,
    vkResetFences: ?vk.PfnResetFences = null,
    vkCreateSemaphore: ?vk.PfnCreateSemaphore = null,
    vkDestroySemaphore: ?vk.PfnDestroySemaphore = null,
    // Queue
    vkGetDeviceQueue: ?vk.PfnGetDeviceQueue = null,
    vkQueueSubmit2: ?vk.PfnQueueSubmit2 = null,
    vkQueuePresentKHR: ?vk.PfnQueuePresentKHR = null,
    // Dynamic rendering
    vkCmdBeginRendering: ?vk.PfnCmdBeginRendering = null,
    vkCmdEndRendering: ?vk.PfnCmdEndRendering = null,
    // Barriers
    vkCmdPipelineBarrier2: ?vk.PfnCmdPipelineBarrier2 = null,
};
pub const DemoDeviceDispatch = vk.DeviceWrapperWithCustomDispatch(DemoDeviceTable);

// ============================================================
// Graphics context — owns all demo Vulkan state
// ============================================================

pub const GraphicsContext = struct {
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    graphics_family: u32,
    present_family: u32,
    demo_idisp: DemoInstanceDispatch,
    demo_ddisp: DemoDeviceDispatch,
    lib_idisp: gpu_context.InstanceDispatch,
    vulkan_ctx: gpu_context.VulkanContext,
    surface_format: vk.SurfaceFormatKHR,

    // Swapchain (filled in Task 4)
    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_images: []vk.Image = &.{},
    swapchain_views: []vk.ImageView = &.{},
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    // Per-frame sync (filled in Task 4)
    command_pool: vk.CommandPool = .null_handle,
    command_buffers: [FRAMES_IN_FLIGHT]vk.CommandBuffer = .{.null_handle} ** FRAMES_IN_FLIGHT,
    image_available: [FRAMES_IN_FLIGHT]vk.Semaphore = .{.null_handle} ** FRAMES_IN_FLIGHT,
    render_finished: [FRAMES_IN_FLIGHT]vk.Semaphore = .{.null_handle} ** FRAMES_IN_FLIGHT,
    in_flight_fences: [FRAMES_IN_FLIGHT]vk.Fence = .{.null_handle} ** FRAMES_IN_FLIGHT,
    frame_index: u32 = 0,
    /// Linear RGBA clear color. Vulkan converts to sRGB on write for sRGB swapchain formats.
    clear_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },

    allocator: std.mem.Allocator,

    pub const FRAMES_IN_FLIGHT = 2;

    pub fn init(window: glfw.Window, allocator: std.mem.Allocator) !GraphicsContext {
        // 1. Load base dispatch and create instance
        const base = BaseDispatch.load(glfw.getInstanceProcAddress);
        const glfw_exts = glfw.getRequiredInstanceExtensions();
        const app_info = vk.ApplicationInfo{
            .p_application_name = "heavy-slug demo",
            .application_version = 0,
            .p_engine_name = "heavy-slug",
            .engine_version = 0,
            .api_version = @bitCast(vk.API_VERSION_1_4),
        };
        const instance = try base.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(glfw_exts.len),
            .pp_enabled_extension_names = @ptrCast(glfw_exts.ptr),
        }, null);

        // 2. Load dispatch tables
        const demo_idisp = DemoInstanceDispatch.load(instance, glfw.getInstanceProcAddress);
        const lib_idisp = gpu_context.InstanceDispatch.load(instance, glfw.getInstanceProcAddress);

        // 3. Create surface
        const surface = try glfw.createSurface(instance, window);

        // 4. Pick physical device
        var dev_count: u32 = 0;
        _ = try demo_idisp.enumeratePhysicalDevices(instance, &dev_count, null);
        const devices = try allocator.alloc(vk.PhysicalDevice, dev_count);
        defer allocator.free(devices);
        _ = try demo_idisp.enumeratePhysicalDevices(instance, &dev_count, devices.ptr);

        var chosen_pdev: ?vk.PhysicalDevice = null;
        var chosen_gfx: u32 = undefined;
        var chosen_present: u32 = undefined;
        for (devices[0..dev_count]) |pdev| {
            // Check heavy-slug requirements (mesh shader, robustness2)
            gpu_context.VulkanContext.checkDeviceSupport(pdev, lib_idisp, allocator) catch continue;

            // Find graphics + present queue families
            const families = findQueueFamilies(pdev, surface, demo_idisp, allocator) catch continue;
            chosen_gfx = families[0];
            chosen_present = families[1];
            chosen_pdev = pdev;
            break;
        }
        const physical_device = chosen_pdev orelse return error.NoSuitableDevice;

        // 5. Create logical device
        const unique_families = if (chosen_gfx == chosen_present)
            &[_]u32{chosen_gfx}
        else
            &[_]u32{ chosen_gfx, chosen_present };

        var queue_cis: [2]vk.DeviceQueueCreateInfo = undefined;
        const priority = [_]f32{1.0};
        for (unique_families, 0..) |fam, i| {
            queue_cis[i] = .{
                .queue_family_index = fam,
                .queue_count = 1,
                .p_queue_priorities = &priority,
            };
        }

        // Feature chain (pNext traversal order): features2 → vk12 → vk13 → mesh_shader → robustness2
        // Bool32 enum fields use .true/.false (not vk.TRUE/vk.FALSE)
        var robustness2 = vk.PhysicalDeviceRobustness2FeaturesEXT{
            .null_descriptor = .true,
        };
        var mesh_shader = vk.PhysicalDeviceMeshShaderFeaturesEXT{
            .p_next = @ptrCast(&robustness2),
            .task_shader = .true,
            .mesh_shader = .true,
        };
        var vk13_features = vk.PhysicalDeviceVulkan13Features{
            .p_next = @ptrCast(&mesh_shader),
            .dynamic_rendering = .true,
            .synchronization_2 = .true,
            .maintenance_4 = .true,
        };
        var vk12_features = vk.PhysicalDeviceVulkan12Features{
            .p_next = @ptrCast(&vk13_features),
            .descriptor_indexing = .true,
            .descriptor_binding_partially_bound = .true,
            .descriptor_binding_storage_buffer_update_after_bind = .true,
            .runtime_descriptor_array = .true,
            .shader_storage_buffer_array_non_uniform_indexing = .true,
            .buffer_device_address = .true,
        };
        var features2 = vk.PhysicalDeviceFeatures2{
            .p_next = @ptrCast(&vk12_features),
            .features = .{},
        };

        const all_device_exts = [_][*:0]const u8{
            "VK_KHR_swapchain",
            "VK_EXT_mesh_shader",
            "VK_EXT_robustness2",
        };

        // pp_enabled_layer_names is *const *const u8 (non-optional in this vk.zig version).
        // We pass 0 layers; the pointer is never dereferenced by the driver when count=0.
        const empty_layers = [0][*:0]const u8{};
        const device = try demo_idisp.createDevice(physical_device, &.{
            .p_next = @ptrCast(&features2),
            .queue_create_info_count = @intCast(unique_families.len),
            .p_queue_create_infos = &queue_cis,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = @ptrCast(&empty_layers),
            .enabled_extension_count = all_device_exts.len,
            .pp_enabled_extension_names = &all_device_exts,
            .p_enabled_features = null,
        }, null);

        // 6. Load device dispatch + get queues
        const get_device_proc_addr: vk.PfnGetDeviceProcAddr = @ptrCast(
            demo_idisp.dispatch.vkGetDeviceProcAddr orelse return error.MissingFunction,
        );
        const demo_ddisp = DemoDeviceDispatch.load(device, get_device_proc_addr);
        const vulkan_ctx = gpu_context.VulkanContext.init(
            physical_device,
            device,
            lib_idisp,
            get_device_proc_addr,
        );
        const gfx_queue = demo_ddisp.getDeviceQueue(device, chosen_gfx, 0);
        const present_queue = demo_ddisp.getDeviceQueue(device, chosen_present, 0);

        // 7. Choose surface format (prefer B8G8R8A8_SRGB + sRGB nonlinear)
        var fmt_count: u32 = 0;
        _ = try demo_idisp.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &fmt_count, null);
        const formats = try allocator.alloc(vk.SurfaceFormatKHR, fmt_count);
        defer allocator.free(formats);
        _ = try demo_idisp.getPhysicalDeviceSurfaceFormatsKHR(physical_device, surface, &fmt_count, formats.ptr);

        var surface_format = formats[0];
        for (formats[0..fmt_count]) |fmt| {
            if (fmt.format == .b8g8r8a8_srgb and fmt.color_space == .srgb_nonlinear_khr) {
                surface_format = fmt;
                break;
            }
        }

        var ctx = GraphicsContext{
            .instance = instance,
            .surface = surface,
            .physical_device = physical_device,
            .device = device,
            .graphics_queue = gfx_queue,
            .present_queue = present_queue,
            .graphics_family = chosen_gfx,
            .present_family = chosen_present,
            .demo_idisp = demo_idisp,
            .demo_ddisp = demo_ddisp,
            .lib_idisp = lib_idisp,
            .vulkan_ctx = vulkan_ctx,
            .surface_format = surface_format,
            .allocator = allocator,
        };

        // 8. Create sync + command objects
        errdefer ctx.deinit();
        try ctx.createSyncObjects();

        return ctx;
    }

    fn createSyncObjects(self: *GraphicsContext) !void {
        self.command_pool = try self.demo_ddisp.createCommandPool(self.device, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_family,
        }, null);

        try self.demo_ddisp.allocateCommandBuffers(self.device, &.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = FRAMES_IN_FLIGHT,
        }, &self.command_buffers);

        for (0..FRAMES_IN_FLIGHT) |i| {
            self.image_available[i] = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
            self.render_finished[i] = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
            self.in_flight_fences[i] = try self.demo_ddisp.createFence(self.device, &.{
                .flags = .{ .signaled_bit = true },
            }, null);
        }
    }

    pub const FrameInfo = struct {
        cmd: vk.CommandBuffer,
        image_view: vk.ImageView,
        image: vk.Image,
        image_index: u32,
    };

    pub fn createSwapchain(self: *GraphicsContext, window: glfw.Window) !void {
        const caps = try self.demo_idisp.getPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physical_device,
            self.surface,
        );

        const fb_size = glfw.getFramebufferSize(window);
        self.swapchain_extent = .{
            .width = std.math.clamp(fb_size[0], caps.min_image_extent.width, caps.max_image_extent.width),
            .height = std.math.clamp(fb_size[1], caps.min_image_extent.height, caps.max_image_extent.height),
        };

        if (self.swapchain_extent.width == 0 or self.swapchain_extent.height == 0) return;

        var image_count = caps.min_image_count + 1;
        if (caps.max_image_count > 0) image_count = @min(image_count, caps.max_image_count);

        const same_family = self.graphics_family == self.present_family;
        const families = [_]u32{ self.graphics_family, self.present_family };

        const old_swapchain = self.swapchain;
        self.swapchain = try self.demo_ddisp.createSwapchainKHR(self.device, &.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = self.surface_format.format,
            .image_color_space = self.surface_format.color_space,
            .image_extent = self.swapchain_extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = if (same_family) .exclusive else .concurrent,
            .queue_family_index_count = if (same_family) 0 else 2,
            .p_queue_family_indices = if (same_family) null else &families,
            .pre_transform = caps.current_transform,
            .composite_alpha = .{ .opaque_bit_khr = true },
            .present_mode = .fifo_khr,
            .clipped = .true,
            .old_swapchain = old_swapchain,
        }, null);

        if (old_swapchain != .null_handle) {
            self.destroySwapchainResources();
            self.demo_ddisp.destroySwapchainKHR(self.device, old_swapchain, null);
        }

        // Get images
        var img_count: u32 = 0;
        _ = try self.demo_ddisp.getSwapchainImagesKHR(self.device, self.swapchain, &img_count, null);
        self.swapchain_images = try self.allocator.alloc(vk.Image, img_count);
        errdefer {
            self.allocator.free(self.swapchain_images);
            self.swapchain_images = &.{};
        }
        _ = try self.demo_ddisp.getSwapchainImagesKHR(self.device, self.swapchain, &img_count, self.swapchain_images.ptr);

        // Create image views
        self.swapchain_views = try self.allocator.alloc(vk.ImageView, img_count);
        var views_created: usize = 0;
        errdefer {
            for (self.swapchain_views[0..views_created]) |view| {
                self.demo_ddisp.destroyImageView(self.device, view, null);
            }
            self.allocator.free(self.swapchain_views);
            self.swapchain_views = &.{};
        }
        for (self.swapchain_images, 0..) |img, i| {
            self.swapchain_views[i] = try self.demo_ddisp.createImageView(self.device, &.{
                .image = img,
                .view_type = .@"2d",
                .format = self.surface_format.format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = .{
                    .aspect_mask = .{ .color_bit = true },
                    .base_mip_level = 0,
                    .level_count = 1,
                    .base_array_layer = 0,
                    .layer_count = 1,
                },
            }, null);
            views_created += 1;
        }
    }

    fn destroySwapchainResources(self: *GraphicsContext) void {
        for (self.swapchain_views) |view| {
            self.demo_ddisp.destroyImageView(self.device, view, null);
        }
        if (self.swapchain_views.len > 0) self.allocator.free(self.swapchain_views);
        if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
        self.swapchain_views = &.{};
        self.swapchain_images = &.{};
    }

    pub fn beginFrame(self: *GraphicsContext) !?FrameInfo {
        // Guard: swapchain is not yet created (e.g. window minimized during recreation)
        if (self.swapchain == .null_handle) return null;

        const fi = self.frame_index;

        _ = try self.demo_ddisp.waitForFences(self.device, self.in_flight_fences[fi .. fi + 1], .true, std.math.maxInt(u64));

        var image_index: u32 = undefined;
        const acquire_result = self.demo_ddisp.acquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            self.image_available[fi],
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => return null,
            else => return err,
        };
        if (acquire_result.result == .suboptimal_khr) return null;
        image_index = acquire_result.image_index;

        try self.demo_ddisp.resetFences(self.device, self.in_flight_fences[fi .. fi + 1]);

        const cmd = self.command_buffers[fi];
        try self.demo_ddisp.resetCommandBuffer(cmd, .{});
        try self.demo_ddisp.beginCommandBuffer(cmd, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        // Transition image: undefined → color attachment
        self.transitionImage(cmd, self.swapchain_images[image_index], .undefined, .color_attachment_optimal);

        // Begin dynamic rendering
        const clear_value = vk.ClearValue{ .color = .{ .float_32 = self.clear_color } };
        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = self.swapchain_views[image_index],
            .image_layout = .color_attachment_optimal,
            .resolve_mode = .{},
            .resolve_image_layout = .undefined,
            .load_op = .clear,
            .store_op = .store,
            .clear_value = clear_value,
        };
        self.demo_ddisp.cmdBeginRendering(cmd, &vk.RenderingInfo{
            .render_area = .{
                .offset = .{ .x = 0, .y = 0 },
                .extent = self.swapchain_extent,
            },
            .layer_count = 1,
            .view_mask = 0,
            .color_attachment_count = 1,
            .p_color_attachments = @ptrCast(&color_attachment),
        });

        return .{
            .cmd = cmd,
            .image_view = self.swapchain_views[image_index],
            .image = self.swapchain_images[image_index],
            .image_index = image_index,
        };
    }

    /// Returns true if the swapchain needs recreation (out-of-date).
    pub fn endFrame(self: *GraphicsContext, frame: FrameInfo) !bool {
        const fi = self.frame_index;
        const cmd = frame.cmd;

        self.demo_ddisp.cmdEndRendering(cmd);

        // Transition: color attachment → present
        self.transitionImage(cmd, frame.image, .color_attachment_optimal, .present_src_khr);

        try self.demo_ddisp.endCommandBuffer(cmd);

        // Submit with synchronization2
        const wait_info = vk.SemaphoreSubmitInfo{
            .semaphore = self.image_available[fi],
            .stage_mask = .{ .color_attachment_output_bit = true },
            .value = 0,
            .device_index = 0,
        };
        const signal_info = vk.SemaphoreSubmitInfo{
            .semaphore = self.render_finished[fi],
            .stage_mask = .{ .all_commands_bit = true },
            .value = 0,
            .device_index = 0,
        };
        const cmd_info = vk.CommandBufferSubmitInfo{
            .command_buffer = cmd,
            .device_mask = 0,
        };
        const submit_info = vk.SubmitInfo2{
            .wait_semaphore_info_count = 1,
            .p_wait_semaphore_infos = @ptrCast(&wait_info),
            .command_buffer_info_count = 1,
            .p_command_buffer_infos = @ptrCast(&cmd_info),
            .signal_semaphore_info_count = 1,
            .p_signal_semaphore_infos = @ptrCast(&signal_info),
        };
        try self.demo_ddisp.queueSubmit2(self.graphics_queue, &[_]vk.SubmitInfo2{submit_info}, self.in_flight_fences[fi]);

        var needs_recreate = false;
        _ = self.demo_ddisp.queuePresentKHR(self.present_queue, &vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&self.render_finished[fi]),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&frame.image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => {
                needs_recreate = true;
            },
            else => return err,
        };

        self.frame_index = (fi + 1) % FRAMES_IN_FLIGHT;
        return needs_recreate;
    }

    fn transitionImage(
        self: *GraphicsContext,
        cmd: vk.CommandBuffer,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
    ) void {
        // Choose stage/access masks based on the specific transition.
        const src_stage: vk.PipelineStageFlags2 = if (old_layout == .undefined)
            .{ .top_of_pipe_bit = true }
        else
            .{ .color_attachment_output_bit = true };
        const src_access: vk.AccessFlags2 = if (old_layout == .undefined)
            .{}
        else
            .{ .color_attachment_write_bit = true };
        const dst_stage: vk.PipelineStageFlags2 = if (new_layout == .color_attachment_optimal)
            .{ .color_attachment_output_bit = true }
        else
            .{ .bottom_of_pipe_bit = true };
        const dst_access: vk.AccessFlags2 = if (new_layout == .color_attachment_optimal)
            .{ .color_attachment_write_bit = true }
        else
            .{};

        const barrier = vk.ImageMemoryBarrier2{
            .src_stage_mask = src_stage,
            .src_access_mask = src_access,
            .dst_stage_mask = dst_stage,
            .dst_access_mask = dst_access,
            .old_layout = old_layout,
            .new_layout = new_layout,
            .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
            .image = image,
            .subresource_range = .{
                .aspect_mask = .{ .color_bit = true },
                .base_mip_level = 0,
                .level_count = 1,
                .base_array_layer = 0,
                .layer_count = 1,
            },
        };
        self.demo_ddisp.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    pub fn recreateSwapchain(self: *GraphicsContext, window: glfw.Window) !void {
        try self.demo_ddisp.deviceWaitIdle(self.device);
        try self.createSwapchain(window);
    }

    pub fn deinit(self: *GraphicsContext) void {
        self.demo_ddisp.deviceWaitIdle(self.device) catch {};

        for (0..FRAMES_IN_FLIGHT) |i| {
            if (self.image_available[i] != .null_handle)
                self.demo_ddisp.destroySemaphore(self.device, self.image_available[i], null);
            if (self.render_finished[i] != .null_handle)
                self.demo_ddisp.destroySemaphore(self.device, self.render_finished[i], null);
            if (self.in_flight_fences[i] != .null_handle)
                self.demo_ddisp.destroyFence(self.device, self.in_flight_fences[i], null);
        }
        if (self.command_pool != .null_handle)
            self.demo_ddisp.destroyCommandPool(self.device, self.command_pool, null);

        self.destroySwapchainResources();
        if (self.swapchain != .null_handle) {
            self.demo_ddisp.destroySwapchainKHR(self.device, self.swapchain, null);
        }

        self.demo_ddisp.destroyDevice(self.device, null);

        self.demo_idisp.destroySurfaceKHR(self.instance, self.surface, null);
        self.demo_idisp.destroyInstance(self.instance, null);
    }
};

// ============================================================
// Internal helpers
// ============================================================

fn findQueueFamilies(
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    idisp: DemoInstanceDispatch,
    allocator: std.mem.Allocator,
) !struct { u32, u32 } {
    var family_count: u32 = 0;
    idisp.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);
    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    idisp.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var gfx: ?u32 = null;
    var present: ?u32 = null;
    for (families[0..family_count], 0..) |fam, i| {
        const idx: u32 = @intCast(i);
        if (fam.queue_flags.graphics_bit) gfx = gfx orelse idx;
        const present_support = try idisp.getPhysicalDeviceSurfaceSupportKHR(pdev, idx, surface);
        if (present_support == .true) present = present orelse idx;
        if (gfx != null and present != null) break;
    }
    return .{ gfx orelse return error.NoGraphicsQueue, present orelse return error.NoPresentQueue };
}
