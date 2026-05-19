//! Demo-only Vulkan bootstrap: instance, device, swapchain, and frame management.

const std = @import("std");
const vk = @import("vulkan");
const demo_platform = @import("demo_platform");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const gpu_context = heavy_slug_vulkan.context;
const vk_chains = heavy_slug_vulkan.chains;

const device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
} ++ gpu_context.Context.required_device_extensions;

fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    return demo_platform.getRequiredInstanceExtensions();
}

fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    return demo_platform.getInstanceProcAddress(instance, name);
}

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
    vkCreateWaylandSurfaceKHR: ?vk.PfnCreateWaylandSurfaceKHR = null,
    vkCreateWin32SurfaceKHR: ?vk.PfnCreateWin32SurfaceKHR = null,
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

/// Owns demo-only Vulkan state: instance, device, swapchain, sync, and frames.
pub const Host = struct {
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
    renderer_context: gpu_context.Context,
    surface_format: vk.SurfaceFormatKHR,

    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_images: []vk.Image = &.{},
    swapchain_views: []vk.ImageView = &.{},
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    command_pool: vk.CommandPool = .null_handle,
    command_buffers: [frames_in_flight]vk.CommandBuffer = .{.null_handle} ** frames_in_flight,
    image_available: [frames_in_flight]vk.Semaphore = .{.null_handle} ** frames_in_flight,
    submit_finished: []vk.Semaphore = &.{},
    in_flight_fences: [frames_in_flight]vk.Fence = .{.null_handle} ** frames_in_flight,
    frame_index: u32 = 0,
    /// Linear RGBA clear color. Vulkan converts to sRGB on write for sRGB swapchain formats.
    clear_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },

    allocator: std.mem.Allocator,

    pub const frames_in_flight = 2;

    pub fn init(window: *demo_platform.Window, allocator: std.mem.Allocator) !Host {
        const base = BaseDispatch.load(getInstanceProcAddress);
        const platform_exts = getRequiredInstanceExtensions();
        const app_info = vk.ApplicationInfo{
            .p_application_name = "heavy-slug demo",
            .application_version = 0,
            .p_engine_name = "heavy-slug",
            .engine_version = 0,
            .api_version = @bitCast(vk.API_VERSION_1_4),
        };
        const instance = try base.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(platform_exts.len),
            .pp_enabled_extension_names = @ptrCast(platform_exts.ptr),
        }, null);

        const demo_idisp = DemoInstanceDispatch.load(instance, getInstanceProcAddress);
        const lib_idisp = gpu_context.InstanceDispatch.load(instance, getInstanceProcAddress);

        const surface = try window.createSurface(instance, demo_idisp);

        var dev_count: u32 = 0;
        _ = try demo_idisp.enumeratePhysicalDevices(instance, &dev_count, null);
        const devices = try allocator.alloc(vk.PhysicalDevice, dev_count);
        defer allocator.free(devices);
        _ = try demo_idisp.enumeratePhysicalDevices(instance, &dev_count, devices.ptr);

        var chosen_pdev: ?vk.PhysicalDevice = null;
        var chosen_gfx: u32 = undefined;
        var chosen_present: u32 = undefined;
        for (devices[0..dev_count]) |pdev| {
            if (!try supportsDeviceExtensions(pdev, lib_idisp, allocator, &device_extensions)) continue;
            gpu_context.Context.checkDeviceSupport(pdev, lib_idisp, allocator) catch continue;
            if (!supportsRequiredDemoFeatures(pdev, lib_idisp)) continue;

            const families = findQueueFamilies(pdev, surface, demo_idisp, allocator) catch continue;
            chosen_gfx = families[0];
            chosen_present = families[1];
            chosen_pdev = pdev;
            break;
        }
        const physical_device = chosen_pdev orelse return error.NoSuitableDevice;

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

        var enabled_features = vk_chains.FeatureChain.init();
        enabled_features.enableRendererFeatures();
        enabled_features.enableSynchronization2();

        // pp_enabled_layer_names is *const *const u8 (non-optional in this vk.zig version).
        // We pass 0 layers; the pointer is never dereferenced by the driver when count=0.
        const empty_layers = [0][*:0]const u8{};
        const device = try demo_idisp.createDevice(physical_device, &.{
            .p_next = @ptrCast(enabled_features.rootInfo()),
            .queue_create_info_count = @intCast(unique_families.len),
            .p_queue_create_infos = &queue_cis,
            .enabled_layer_count = 0,
            .pp_enabled_layer_names = @ptrCast(&empty_layers),
            .enabled_extension_count = device_extensions.len,
            .pp_enabled_extension_names = &device_extensions,
            .p_enabled_features = null,
        }, null);

        const get_device_proc_addr: vk.PfnGetDeviceProcAddr = @ptrCast(
            demo_idisp.dispatch.vkGetDeviceProcAddr orelse return error.MissingFunction,
        );
        const demo_ddisp = DemoDeviceDispatch.load(device, get_device_proc_addr);
        const renderer_context = gpu_context.Context.init(
            physical_device,
            device,
            lib_idisp,
            get_device_proc_addr,
        );
        const gfx_queue = demo_ddisp.getDeviceQueue(device, chosen_gfx, 0);
        const present_queue = demo_ddisp.getDeviceQueue(device, chosen_present, 0);

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

        var host = Host{
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
            .renderer_context = renderer_context,
            .surface_format = surface_format,
            .allocator = allocator,
        };

        errdefer host.deinit();
        try host.createSyncObjects();

        return host;
    }

    fn createSyncObjects(self: *Host) !void {
        self.command_pool = try self.demo_ddisp.createCommandPool(self.device, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_family,
        }, null);

        try self.demo_ddisp.allocateCommandBuffers(self.device, &.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = frames_in_flight,
        }, &self.command_buffers);

        for (0..frames_in_flight) |i| {
            self.image_available[i] = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
            self.in_flight_fences[i] = try self.demo_ddisp.createFence(self.device, &.{
                .flags = .{ .signaled_bit = true },
            }, null);
        }
    }

    pub const SwapchainFrame = struct {
        cmd: vk.CommandBuffer,
        image_view: vk.ImageView,
        image: vk.Image,
        image_index: u32,
        frame_index: u32,
        submit_finished: vk.Semaphore,
        suboptimal: bool,
    };

    pub fn createSwapchain(self: *Host, window: *const demo_platform.Window) !void {
        const caps = try self.demo_idisp.getPhysicalDeviceSurfaceCapabilitiesKHR(
            self.physical_device,
            self.surface,
        );

        const extent = chooseSwapchainExtent(caps, window.framebufferSize());
        if (extent.width == 0 or extent.height == 0) {
            self.destroySwapchain();
            self.swapchain_extent = extent;
            return;
        }
        if (!caps.supported_usage_flags.color_attachment_bit) return error.SurfaceColorAttachmentUnsupported;

        const image_count = chooseSwapchainImageCount(caps);

        const same_family = self.graphics_family == self.present_family;
        const families = [_]u32{ self.graphics_family, self.present_family };

        const old_swapchain = self.swapchain;
        const new_swapchain = try self.demo_ddisp.createSwapchainKHR(self.device, &.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = self.surface_format.format,
            .image_color_space = self.surface_format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = if (same_family) .exclusive else .concurrent,
            .queue_family_index_count = if (same_family) 0 else 2,
            .p_queue_family_indices = if (same_family) null else &families,
            .pre_transform = caps.current_transform,
            .composite_alpha = chooseCompositeAlpha(caps.supported_composite_alpha),
            .present_mode = .fifo_khr,
            .clipped = .true,
            .old_swapchain = old_swapchain,
        }, null);
        errdefer self.demo_ddisp.destroySwapchainKHR(self.device, new_swapchain, null);

        var img_count: u32 = 0;
        _ = try self.demo_ddisp.getSwapchainImagesKHR(self.device, new_swapchain, &img_count, null);
        const images = try self.allocator.alloc(vk.Image, img_count);
        errdefer {
            self.allocator.free(images);
        }
        _ = try self.demo_ddisp.getSwapchainImagesKHR(self.device, new_swapchain, &img_count, images.ptr);

        const views = try self.allocator.alloc(vk.ImageView, img_count);
        var views_created: usize = 0;
        errdefer {
            for (views[0..views_created]) |view| {
                self.demo_ddisp.destroyImageView(self.device, view, null);
            }
            self.allocator.free(views);
        }
        for (images, 0..) |img, i| {
            views[i] = try self.demo_ddisp.createImageView(self.device, &.{
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

        const submit_finished = try self.allocator.alloc(vk.Semaphore, img_count);
        var semaphores_created: usize = 0;
        errdefer {
            for (submit_finished[0..semaphores_created]) |semaphore| {
                self.demo_ddisp.destroySemaphore(self.device, semaphore, null);
            }
            self.allocator.free(submit_finished);
        }
        for (submit_finished) |*semaphore| {
            semaphore.* = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
            semaphores_created += 1;
        }

        self.destroySwapchainResources();
        if (old_swapchain != .null_handle) {
            self.demo_ddisp.destroySwapchainKHR(self.device, old_swapchain, null);
        }

        self.swapchain = new_swapchain;
        self.swapchain_images = images;
        self.swapchain_views = views;
        self.submit_finished = submit_finished;
        self.swapchain_extent = extent;
    }

    fn destroySwapchainResources(self: *Host) void {
        for (self.swapchain_views) |view| {
            self.demo_ddisp.destroyImageView(self.device, view, null);
        }
        for (self.submit_finished) |semaphore| {
            self.demo_ddisp.destroySemaphore(self.device, semaphore, null);
        }
        if (self.swapchain_views.len > 0) self.allocator.free(self.swapchain_views);
        if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
        if (self.submit_finished.len > 0) self.allocator.free(self.submit_finished);
        self.swapchain_views = &.{};
        self.swapchain_images = &.{};
        self.submit_finished = &.{};
    }

    fn destroySwapchain(self: *Host) void {
        self.destroySwapchainResources();
        if (self.swapchain != .null_handle) {
            self.demo_ddisp.destroySwapchainKHR(self.device, self.swapchain, null);
            self.swapchain = .null_handle;
        }
        self.swapchain_extent = .{ .width = 0, .height = 0 };
    }

    pub fn beginFrame(self: *Host) !?SwapchainFrame {
        // Window minimization can leave swapchain creation deferred.
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
        image_index = acquire_result.image_index;

        try self.demo_ddisp.resetFences(self.device, self.in_flight_fences[fi .. fi + 1]);

        const cmd = self.command_buffers[fi];
        try self.demo_ddisp.resetCommandBuffer(cmd, .{});
        try self.demo_ddisp.beginCommandBuffer(cmd, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        self.transitionImage(cmd, self.swapchain_images[image_index], .undefined, .color_attachment_optimal);

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
            .frame_index = fi,
            .submit_finished = self.submit_finished[image_index],
            .suboptimal = acquire_result.result == .suboptimal_khr,
        };
    }

    /// Returns true if the swapchain needs recreation (out-of-date).
    pub fn endFrame(self: *Host, frame: SwapchainFrame) !bool {
        const fi = self.frame_index;
        const cmd = frame.cmd;

        self.demo_ddisp.cmdEndRendering(cmd);

        self.transitionImage(cmd, frame.image, .color_attachment_optimal, .present_src_khr);

        try self.demo_ddisp.endCommandBuffer(cmd);

        const wait_info = vk.SemaphoreSubmitInfo{
            .semaphore = self.image_available[fi],
            .stage_mask = .{ .color_attachment_output_bit = true },
            .value = 0,
            .device_index = 0,
        };
        const signal_info = vk.SemaphoreSubmitInfo{
            .semaphore = frame.submit_finished,
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

        var needs_recreate = frame.suboptimal;
        const present_result = self.demo_ddisp.queuePresentKHR(self.present_queue, &vk.PresentInfoKHR{
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&frame.submit_finished),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&frame.image_index),
        }) catch |err| switch (err) {
            error.OutOfDateKHR => blk: {
                needs_recreate = true;
                break :blk .success;
            },
            else => return err,
        };
        if (present_result == .suboptimal_khr) {
            needs_recreate = true;
        }

        self.frame_index = (fi + 1) % frames_in_flight;
        return needs_recreate;
    }

    fn transitionImage(
        self: *Host,
        cmd: vk.CommandBuffer,
        image: vk.Image,
        old_layout: vk.ImageLayout,
        new_layout: vk.ImageLayout,
    ) void {
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

    pub fn recreateSwapchain(self: *Host, window: *const demo_platform.Window) !void {
        try self.demo_ddisp.deviceWaitIdle(self.device);
        try self.createSwapchain(window);
    }

    pub fn deinit(self: *Host) void {
        self.demo_ddisp.deviceWaitIdle(self.device) catch {};

        for (0..frames_in_flight) |i| {
            if (self.image_available[i] != .null_handle)
                self.demo_ddisp.destroySemaphore(self.device, self.image_available[i], null);
            if (self.in_flight_fences[i] != .null_handle)
                self.demo_ddisp.destroyFence(self.device, self.in_flight_fences[i], null);
        }
        if (self.command_pool != .null_handle)
            self.demo_ddisp.destroyCommandPool(self.device, self.command_pool, null);

        self.destroySwapchain();

        self.demo_ddisp.destroyDevice(self.device, null);

        self.demo_idisp.destroySurfaceKHR(self.instance, self.surface, null);
        self.demo_idisp.destroyInstance(self.instance, null);
    }
};

fn chooseSwapchainExtent(caps: vk.SurfaceCapabilitiesKHR, framebuffer_size: [2]u32) vk.Extent2D {
    if (caps.current_extent.width != std.math.maxInt(u32)) return caps.current_extent;
    if (framebuffer_size[0] == 0 or framebuffer_size[1] == 0) {
        return .{ .width = 0, .height = 0 };
    }
    return .{
        .width = std.math.clamp(
            framebuffer_size[0],
            caps.min_image_extent.width,
            caps.max_image_extent.width,
        ),
        .height = std.math.clamp(
            framebuffer_size[1],
            caps.min_image_extent.height,
            caps.max_image_extent.height,
        ),
    };
}

fn chooseSwapchainImageCount(caps: vk.SurfaceCapabilitiesKHR) u32 {
    const preferred = caps.min_image_count + 1;
    if (caps.max_image_count == 0) return preferred;
    return @min(preferred, caps.max_image_count);
}

fn chooseCompositeAlpha(supported: vk.CompositeAlphaFlagsKHR) vk.CompositeAlphaFlagsKHR {
    if (supported.opaque_bit_khr) return .{ .opaque_bit_khr = true };
    if (supported.pre_multiplied_bit_khr) return .{ .pre_multiplied_bit_khr = true };
    if (supported.post_multiplied_bit_khr) return .{ .post_multiplied_bit_khr = true };
    return .{ .inherit_bit_khr = true };
}

fn supportsDeviceExtensions(
    pdev: vk.PhysicalDevice,
    idisp: gpu_context.InstanceDispatch,
    allocator: std.mem.Allocator,
    required_extensions: []const [*:0]const u8,
) error{OutOfMemory}!bool {
    const available = idisp.enumerateDeviceExtensionPropertiesAlloc(
        pdev,
        null,
        allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return false,
    };
    defer allocator.free(available);

    for (required_extensions) |required| {
        const req_name = std.mem.span(required);
        var found = false;
        for (available) |ext| {
            const ext_name = std.mem.sliceTo(&ext.extension_name, 0);
            if (std.mem.eql(u8, ext_name, req_name)) {
                found = true;
                break;
            }
        }
        if (!found) return false;
    }
    return true;
}

fn supportsRequiredDemoFeatures(
    pdev: vk.PhysicalDevice,
    idisp: gpu_context.InstanceDispatch,
) bool {
    var features = vk_chains.FeatureChain.init();
    idisp.getPhysicalDeviceFeatures2(pdev, features.rootInfo());

    return features.hasRendererFeatures() and features.hasSynchronization2();
}

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

fn testSurfaceCapabilities() vk.SurfaceCapabilitiesKHR {
    var caps = std.mem.zeroes(vk.SurfaceCapabilitiesKHR);
    caps.current_extent = .{
        .width = std.math.maxInt(u32),
        .height = std.math.maxInt(u32),
    };
    caps.min_image_extent = .{ .width = 64, .height = 32 };
    caps.max_image_extent = .{ .width = 4096, .height = 2160 };
    caps.min_image_count = 2;
    caps.max_image_count = 3;
    caps.supported_composite_alpha = .{ .opaque_bit_khr = true };
    caps.supported_usage_flags = .{ .color_attachment_bit = true };
    return caps;
}

test "Vulkan demo swapchain extent follows fixed surface extent" {
    var caps = testSurfaceCapabilities();
    caps.current_extent = .{ .width = 1280, .height = 720 };

    try std.testing.expectEqual(
        vk.Extent2D{ .width = 1280, .height = 720 },
        chooseSwapchainExtent(caps, .{ 640, 480 }),
    );
}

test "Vulkan demo swapchain extent clamps framebuffer size and preserves minimization" {
    const caps = testSurfaceCapabilities();

    try std.testing.expectEqual(
        vk.Extent2D{ .width = 64, .height = 32 },
        chooseSwapchainExtent(caps, .{ 1, 1 }),
    );
    try std.testing.expectEqual(
        vk.Extent2D{ .width = 4096, .height = 2160 },
        chooseSwapchainExtent(caps, .{ 8192, 4096 }),
    );
    try std.testing.expectEqual(
        vk.Extent2D{ .width = 0, .height = 0 },
        chooseSwapchainExtent(caps, .{ 0, 720 }),
    );
}

test "Vulkan demo swapchain image count respects bounded and unbounded caps" {
    var caps = testSurfaceCapabilities();
    try std.testing.expectEqual(@as(u32, 3), chooseSwapchainImageCount(caps));

    caps.max_image_count = 0;
    try std.testing.expectEqual(@as(u32, 3), chooseSwapchainImageCount(caps));

    caps.min_image_count = 3;
    caps.max_image_count = 3;
    try std.testing.expectEqual(@as(u32, 3), chooseSwapchainImageCount(caps));
}

test "Vulkan demo composite alpha prefers opaque and falls back deterministically" {
    try std.testing.expectEqual(
        vk.CompositeAlphaFlagsKHR{ .opaque_bit_khr = true },
        chooseCompositeAlpha(.{ .opaque_bit_khr = true, .inherit_bit_khr = true }),
    );
    try std.testing.expectEqual(
        vk.CompositeAlphaFlagsKHR{ .pre_multiplied_bit_khr = true },
        chooseCompositeAlpha(.{ .pre_multiplied_bit_khr = true }),
    );
    try std.testing.expectEqual(
        vk.CompositeAlphaFlagsKHR{ .inherit_bit_khr = true },
        chooseCompositeAlpha(.{ .inherit_bit_khr = true }),
    );
}
