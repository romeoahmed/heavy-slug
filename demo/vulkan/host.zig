//! Demo-only Vulkan bootstrap: instance, device, swapchain, and frame pacing.

const std = @import("std");
const vk = @import("vulkan");
const demo_platform = @import("demo_platform");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const gpu_context = heavy_slug_vulkan.context;
const vk_chains = heavy_slug_vulkan.chains;

const log = std.log.scoped(.demo_vulkan);

const device_extensions = [_][*:0]const u8{
    "VK_KHR_swapchain",
} ++ gpu_context.Context.required_device_extensions;

fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    return demo_platform.getRequiredInstanceExtensions();
}

fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    return demo_platform.getInstanceProcAddress(instance, name);
}

/// Pre-instance Vulkan functions loaded through the platform Vulkan loader.
const BaseDispatchTable = struct {
    vkCreateInstance: ?vk.PfnCreateInstance = null,
    vkEnumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
};
const BaseDispatch = vk.BaseWrapperWithCustomDispatch(BaseDispatchTable);

/// Instance-level commands owned by the demo host.
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

/// Device-level commands owned by the demo host.
const DemoDeviceTable = struct {
    vkDestroyDevice: ?vk.PfnDestroyDevice = null,
    vkDeviceWaitIdle: ?vk.PfnDeviceWaitIdle = null,
    vkCreateSwapchainKHR: ?vk.PfnCreateSwapchainKHR = null,
    vkDestroySwapchainKHR: ?vk.PfnDestroySwapchainKHR = null,
    vkGetSwapchainImagesKHR: ?vk.PfnGetSwapchainImagesKHR = null,
    vkAcquireNextImageKHR: ?vk.PfnAcquireNextImageKHR = null,
    vkCreateImageView: ?vk.PfnCreateImageView = null,
    vkDestroyImageView: ?vk.PfnDestroyImageView = null,
    vkCreateCommandPool: ?vk.PfnCreateCommandPool = null,
    vkDestroyCommandPool: ?vk.PfnDestroyCommandPool = null,
    vkAllocateCommandBuffers: ?vk.PfnAllocateCommandBuffers = null,
    vkResetCommandBuffer: ?vk.PfnResetCommandBuffer = null,
    vkBeginCommandBuffer: ?vk.PfnBeginCommandBuffer = null,
    vkEndCommandBuffer: ?vk.PfnEndCommandBuffer = null,
    vkCreateFence: ?vk.PfnCreateFence = null,
    vkDestroyFence: ?vk.PfnDestroyFence = null,
    vkWaitForFences: ?vk.PfnWaitForFences = null,
    vkResetFences: ?vk.PfnResetFences = null,
    vkCreateSemaphore: ?vk.PfnCreateSemaphore = null,
    vkDestroySemaphore: ?vk.PfnDestroySemaphore = null,
    vkGetDeviceQueue: ?vk.PfnGetDeviceQueue = null,
    vkQueueSubmit2: ?vk.PfnQueueSubmit2 = null,
    vkQueuePresentKHR: ?vk.PfnQueuePresentKHR = null,
    vkCmdBeginRendering: ?vk.PfnCmdBeginRendering = null,
    vkCmdEndRendering: ?vk.PfnCmdEndRendering = null,
    vkCmdPipelineBarrier2: ?vk.PfnCmdPipelineBarrier2 = null,
};
pub const DemoDeviceDispatch = vk.DeviceWrapperWithCustomDispatch(DemoDeviceTable);

const QueueFamilies = struct {
    graphics: u32,
    present: u32,

    fn isUnified(self: QueueFamilies) bool {
        return self.graphics == self.present;
    }
};

const QueueFamilySupport = struct {
    graphics: bool,
    present: bool,
};

const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    queues: QueueFamilies,
    surface_format: vk.SurfaceFormatKHR,
};

const SurfaceConfig = struct {
    caps: vk.SurfaceCapabilitiesKHR,
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
};

const FrameSlot = struct {
    command_buffer: vk.CommandBuffer = .null_handle,
    image_available: vk.Semaphore = .null_handle,
    in_flight: vk.Fence = .null_handle,
};

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
    frames: [frames_in_flight]FrameSlot = .{FrameSlot{}} ** frames_in_flight,
    submit_finished: []vk.Semaphore = &.{},
    frame_index: usize = 0,
    /// Linear RGBA clear color. Vulkan converts to sRGB on write for sRGB swapchain formats.
    clear_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },

    allocator: std.mem.Allocator,

    pub const frames_in_flight = heavy_slug_vulkan.renderer.max_frames_in_flight;

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
        var instance_alive = true;
        errdefer if (instance_alive) demo_idisp.destroyInstance(instance, null);

        const lib_idisp = gpu_context.InstanceDispatch.load(instance, getInstanceProcAddress);
        const surface = try window.createSurface(instance, demo_idisp);
        var surface_alive = true;
        errdefer if (surface_alive) demo_idisp.destroySurfaceKHR(instance, surface, null);

        const selection = try choosePhysicalDevice(instance, surface, demo_idisp, lib_idisp, allocator);
        const logical_device = try createLogicalDevice(selection.physical_device, selection.queues, demo_idisp);
        const device = logical_device.device;
        const demo_ddisp = logical_device.dispatch;
        var device_alive = true;
        errdefer if (device_alive) demo_ddisp.destroyDevice(device, null);

        const renderer_context = try gpu_context.Context.init(
            selection.physical_device,
            device,
            lib_idisp,
            logical_device.get_device_proc_addr,
        );

        var host = Host{
            .instance = instance,
            .surface = surface,
            .physical_device = selection.physical_device,
            .device = device,
            .graphics_queue = demo_ddisp.getDeviceQueue(device, selection.queues.graphics, 0),
            .present_queue = demo_ddisp.getDeviceQueue(device, selection.queues.present, 0),
            .graphics_family = selection.queues.graphics,
            .present_family = selection.queues.present,
            .demo_idisp = demo_idisp,
            .demo_ddisp = demo_ddisp,
            .lib_idisp = lib_idisp,
            .renderer_context = renderer_context,
            .surface_format = selection.surface_format,
            .allocator = allocator,
        };

        instance_alive = false;
        surface_alive = false;
        device_alive = false;
        errdefer host.deinit();

        try host.createFrameResources();
        return host;
    }

    fn createFrameResources(self: *Host) !void {
        self.command_pool = try self.demo_ddisp.createCommandPool(self.device, &.{
            .flags = .{ .reset_command_buffer_bit = true },
            .queue_family_index = self.graphics_family,
        }, null);
        errdefer self.destroyFrameResources();

        var command_buffers: [frames_in_flight]vk.CommandBuffer = undefined;
        try self.demo_ddisp.allocateCommandBuffers(self.device, &.{
            .command_pool = self.command_pool,
            .level = .primary,
            .command_buffer_count = @intCast(frames_in_flight),
        }, &command_buffers);
        for (&self.frames, command_buffers) |*slot, command_buffer| {
            slot.command_buffer = command_buffer;
        }

        for (&self.frames) |*slot| {
            slot.image_available = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
            slot.in_flight = try self.demo_ddisp.createFence(self.device, &.{
                .flags = .{ .signaled_bit = true },
            }, null);
        }
    }

    fn destroyFrameResources(self: *Host) void {
        for (&self.frames) |*slot| {
            if (slot.image_available != .null_handle) {
                self.demo_ddisp.destroySemaphore(self.device, slot.image_available, null);
            }
            if (slot.in_flight != .null_handle) {
                self.demo_ddisp.destroyFence(self.device, slot.in_flight, null);
            }
            slot.image_available = .null_handle;
            slot.in_flight = .null_handle;
            slot.command_buffer = .null_handle;
        }
        if (self.command_pool != .null_handle) {
            self.demo_ddisp.destroyCommandPool(self.device, self.command_pool, null);
            self.command_pool = .null_handle;
        }
    }

    pub const SwapchainFrame = struct {
        cmd: vk.CommandBuffer,
        image: vk.Image,
        image_index: u32,
        frame_index: usize,
        submit_finished: vk.Semaphore,
        suboptimal: bool,
    };

    pub fn createSwapchain(self: *Host, window: *const demo_platform.Window) !void {
        const surface_config = try querySurfaceConfig(
            self.physical_device,
            self.surface,
            self.demo_idisp,
            self.allocator,
        );
        const extent = chooseSwapchainExtent(surface_config.caps, window.framebufferSize());
        if (extent.width == 0 or extent.height == 0) {
            self.destroySwapchain();
            self.surface_format = surface_config.format;
            self.swapchain_extent = extent;
            return;
        }
        if (!surface_config.caps.supported_usage_flags.color_attachment_bit) {
            return error.SurfaceColorAttachmentUnsupported;
        }
        if (surface_config.caps.max_image_array_layers < 1) {
            return error.SurfaceImageArrayUnsupported;
        }

        const image_count = chooseSwapchainImageCount(surface_config.caps);
        const queue_families = [_]u32{ self.graphics_family, self.present_family };
        const same_family = self.graphics_family == self.present_family;
        const old_swapchain = self.swapchain;

        const new_swapchain = self.demo_ddisp.createSwapchainKHR(self.device, &.{
            .surface = self.surface,
            .min_image_count = image_count,
            .image_format = surface_config.format.format,
            .image_color_space = surface_config.format.color_space,
            .image_extent = extent,
            .image_array_layers = 1,
            .image_usage = .{ .color_attachment_bit = true },
            .image_sharing_mode = if (same_family) .exclusive else .concurrent,
            .queue_family_index_count = if (same_family) 0 else queue_families.len,
            .p_queue_family_indices = if (same_family) null else &queue_families,
            .pre_transform = surface_config.caps.current_transform,
            .composite_alpha = chooseCompositeAlpha(surface_config.caps.supported_composite_alpha),
            .present_mode = surface_config.present_mode,
            .clipped = .true,
            .old_swapchain = old_swapchain,
        }, null) catch |err| {
            if (old_swapchain != .null_handle) self.destroySwapchain();
            return err;
        };
        errdefer {
            self.demo_ddisp.destroySwapchainKHR(self.device, new_swapchain, null);
            if (old_swapchain != .null_handle) self.destroySwapchain();
        }

        const images = try getSwapchainImages(self, new_swapchain);
        errdefer self.allocator.free(images);

        const views = try createSwapchainViews(self, images, surface_config.format.format);
        errdefer destroyImageViews(self.demo_ddisp, self.device, views, self.allocator);

        const present_semaphores = try createPresentSemaphores(self, images.len);
        errdefer destroySemaphores(self.demo_ddisp, self.device, present_semaphores, self.allocator);

        self.destroySwapchainResources();
        if (old_swapchain != .null_handle) {
            self.demo_ddisp.destroySwapchainKHR(self.device, old_swapchain, null);
        }

        self.swapchain = new_swapchain;
        self.swapchain_images = images;
        self.swapchain_views = views;
        self.submit_finished = present_semaphores;
        self.swapchain_extent = extent;
        self.surface_format = surface_config.format;
    }

    fn getSwapchainImages(self: *Host, swapchain: vk.SwapchainKHR) ![]vk.Image {
        var image_count: u32 = 0;
        _ = try self.demo_ddisp.getSwapchainImagesKHR(self.device, swapchain, &image_count, null);
        if (image_count == 0) return error.SwapchainImageUnavailable;

        const images = try self.allocator.alloc(vk.Image, image_count);
        errdefer self.allocator.free(images);
        _ = try self.demo_ddisp.getSwapchainImagesKHR(self.device, swapchain, &image_count, images.ptr);
        return images;
    }

    fn destroySwapchainResources(self: *Host) void {
        destroyImageViews(self.demo_ddisp, self.device, self.swapchain_views, self.allocator);
        destroySemaphores(self.demo_ddisp, self.device, self.submit_finished, self.allocator);
        if (self.swapchain_images.len > 0) self.allocator.free(self.swapchain_images);
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

    pub fn hasDrawableSwapchain(self: *const Host) bool {
        return self.swapchain != .null_handle and
            self.swapchain_extent.width > 0 and
            self.swapchain_extent.height > 0;
    }

    pub fn needsResize(self: *const Host, framebuffer_size: [2]u32) bool {
        if (framebuffer_size[0] == 0 or framebuffer_size[1] == 0) return self.swapchain != .null_handle;
        return !self.hasDrawableSwapchain() or
            framebuffer_size[0] != self.swapchain_extent.width or
            framebuffer_size[1] != self.swapchain_extent.height;
    }

    pub fn beginFrame(self: *Host) !?SwapchainFrame {
        if (!self.hasDrawableSwapchain()) return null;

        const slot_index = self.frame_index;
        const slot = &self.frames[slot_index];
        _ = try self.demo_ddisp.waitForFences(self.device, self.fenceSlice(slot), .true, std.math.maxInt(u64));

        const acquire_result = self.demo_ddisp.acquireNextImageKHR(
            self.device,
            self.swapchain,
            std.math.maxInt(u64),
            slot.image_available,
            .null_handle,
        ) catch |err| switch (err) {
            error.OutOfDateKHR => return null,
            else => return err,
        };

        const image_index = acquire_result.image_index;
        const cmd = slot.command_buffer;
        try self.demo_ddisp.resetCommandBuffer(cmd, .{});
        try self.demo_ddisp.beginCommandBuffer(cmd, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        self.transitionImage(cmd, colorAttachmentAcquireBarrier(self.swapchain_images[image_index]));

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
            .image = self.swapchain_images[image_index],
            .image_index = image_index,
            .frame_index = slot_index,
            .submit_finished = self.submit_finished[image_index],
            .suboptimal = acquire_result.result == .suboptimal_khr,
        };
    }

    /// Returns true when the swapchain should be recreated before the next frame.
    pub fn endFrame(self: *Host, frame: SwapchainFrame) !bool {
        const slot = &self.frames[frame.frame_index];
        const cmd = frame.cmd;

        self.demo_ddisp.cmdEndRendering(cmd);
        self.transitionImage(cmd, presentReleaseBarrier(frame.image));
        try self.demo_ddisp.endCommandBuffer(cmd);

        try self.demo_ddisp.resetFences(self.device, self.fenceSlice(slot));

        const wait_info = vk.SemaphoreSubmitInfo{
            .semaphore = slot.image_available,
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
        try self.demo_ddisp.queueSubmit2(self.graphics_queue, &[_]vk.SubmitInfo2{submit_info}, slot.in_flight);
        errdefer self.advanceFrame();

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
        if (present_result == .suboptimal_khr) needs_recreate = true;

        self.advanceFrame();
        return needs_recreate;
    }

    fn advanceFrame(self: *Host) void {
        self.frame_index = (self.frame_index + 1) % frames_in_flight;
    }

    fn fenceSlice(_: *Host, slot: *FrameSlot) []const vk.Fence {
        return @as(*const [1]vk.Fence, @ptrCast(&slot.in_flight))[0..1];
    }

    fn transitionImage(self: *Host, cmd: vk.CommandBuffer, barrier: vk.ImageMemoryBarrier2) void {
        self.demo_ddisp.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    pub fn recreateSwapchain(self: *Host, window: *const demo_platform.Window) !void {
        try self.demo_ddisp.deviceWaitIdle(self.device);
        try self.createSwapchain(window);
    }

    pub fn waitIdle(self: *Host) void {
        self.demo_ddisp.deviceWaitIdle(self.device) catch |err| {
            log.debug("vkDeviceWaitIdle during shutdown failed: {}", .{err});
        };
    }

    pub fn deinit(self: *Host) void {
        self.waitIdle();
        self.destroySwapchain();
        self.destroyFrameResources();
        self.demo_ddisp.destroyDevice(self.device, null);
        self.demo_idisp.destroySurfaceKHR(self.instance, self.surface, null);
        self.demo_idisp.destroyInstance(self.instance, null);
    }
};

const LogicalDevice = struct {
    device: vk.Device,
    dispatch: DemoDeviceDispatch,
    get_device_proc_addr: vk.PfnGetDeviceProcAddr,
};

fn createLogicalDevice(
    physical_device: vk.PhysicalDevice,
    queues: QueueFamilies,
    idisp: DemoInstanceDispatch,
) !LogicalDevice {
    var queue_family_indices: [2]u32 = .{ queues.graphics, queues.present };
    const queue_family_count: usize = if (queues.isUnified()) 1 else 2;
    const priority = [_]f32{1.0};
    var queue_cis: [2]vk.DeviceQueueCreateInfo = undefined;
    for (queue_family_indices[0..queue_family_count], 0..) |family, i| {
        queue_cis[i] = .{
            .queue_family_index = family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        };
    }

    var enabled_features = gpu_context.Context.requiredFeatureChain();
    enabled_features.enableSynchronization2();

    // pp_enabled_layer_names is *const *const u8 in this vk.zig version. With
    // count=0 the Vulkan implementation must not dereference the pointer.
    const empty_layers = [0][*:0]const u8{};
    const device = try idisp.createDevice(physical_device, &.{
        .p_next = @ptrCast(enabled_features.rootInfo()),
        .queue_create_info_count = @intCast(queue_family_count),
        .p_queue_create_infos = &queue_cis,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = @ptrCast(&empty_layers),
        .enabled_extension_count = @intCast(device_extensions.len),
        .pp_enabled_extension_names = &device_extensions,
        .p_enabled_features = null,
    }, null);

    const get_device_proc_addr: vk.PfnGetDeviceProcAddr = @ptrCast(
        idisp.dispatch.vkGetDeviceProcAddr orelse return error.MissingFunction,
    );
    return .{
        .device = device,
        .dispatch = DemoDeviceDispatch.load(device, get_device_proc_addr),
        .get_device_proc_addr = get_device_proc_addr,
    };
}

fn choosePhysicalDevice(
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    idisp: DemoInstanceDispatch,
    lib_idisp: gpu_context.InstanceDispatch,
    allocator: std.mem.Allocator,
) !DeviceSelection {
    var device_count: u32 = 0;
    _ = try idisp.enumeratePhysicalDevices(instance, &device_count, null);
    if (device_count == 0) return error.NoPhysicalDevices;

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);
    _ = try idisp.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    for (devices[0..device_count]) |pdev| {
        if (!try supportsDeviceExtensions(pdev, lib_idisp, allocator, &device_extensions)) continue;
        gpu_context.Context.checkDeviceSupport(pdev, lib_idisp, allocator) catch continue;
        if (!supportsRequiredDemoFeatures(pdev, lib_idisp)) continue;

        const queues = findQueueFamilies(pdev, surface, idisp, allocator) catch continue;
        const surface_config = querySurfaceConfig(pdev, surface, idisp, allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };

        return .{
            .physical_device = pdev,
            .queues = queues,
            .surface_format = surface_config.format,
        };
    }
    return error.NoSuitableDevice;
}

fn querySurfaceConfig(
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    idisp: DemoInstanceDispatch,
    allocator: std.mem.Allocator,
) !SurfaceConfig {
    const caps = try idisp.getPhysicalDeviceSurfaceCapabilitiesKHR(pdev, surface);

    var format_count: u32 = 0;
    _ = try idisp.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);
    if (format_count == 0) return error.SurfaceFormatUnavailable;
    const formats = try allocator.alloc(vk.SurfaceFormatKHR, format_count);
    defer allocator.free(formats);
    _ = try idisp.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, formats.ptr);

    var present_mode_count: u32 = 0;
    _ = try idisp.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);
    if (present_mode_count == 0) return error.SurfacePresentModeUnavailable;
    const present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    defer allocator.free(present_modes);
    _ = try idisp.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, present_modes.ptr);

    return .{
        .caps = caps,
        .format = chooseSurfaceFormat(formats) orelse return error.SurfaceFormatUnavailable,
        .present_mode = choosePresentMode(present_modes) orelse return error.SurfaceFifoPresentModeMissing,
    };
}

fn createSwapchainViews(
    self: *Host,
    images: []const vk.Image,
    format: vk.Format,
) ![]vk.ImageView {
    const views = try self.allocator.alloc(vk.ImageView, images.len);
    errdefer self.allocator.free(views);

    var created: usize = 0;
    errdefer {
        for (views[0..created]) |view| {
            self.demo_ddisp.destroyImageView(self.device, view, null);
        }
    }
    for (images, 0..) |image, i| {
        views[i] = try self.demo_ddisp.createImageView(self.device, &.{
            .image = image,
            .view_type = .@"2d",
            .format = format,
            .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
            .subresource_range = colorSubresourceRange(),
        }, null);
        created += 1;
    }
    return views;
}

fn createPresentSemaphores(self: *Host, count: usize) ![]vk.Semaphore {
    const semaphores = try self.allocator.alloc(vk.Semaphore, count);
    errdefer self.allocator.free(semaphores);

    var created: usize = 0;
    errdefer {
        for (semaphores[0..created]) |semaphore| {
            self.demo_ddisp.destroySemaphore(self.device, semaphore, null);
        }
    }
    for (semaphores) |*semaphore| {
        semaphore.* = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
        created += 1;
    }
    return semaphores;
}

fn destroyImageViews(
    ddisp: DemoDeviceDispatch,
    device: vk.Device,
    views: []vk.ImageView,
    allocator: std.mem.Allocator,
) void {
    for (views) |view| {
        ddisp.destroyImageView(device, view, null);
    }
    if (views.len > 0) allocator.free(views);
}

fn destroySemaphores(
    ddisp: DemoDeviceDispatch,
    device: vk.Device,
    semaphores: []vk.Semaphore,
    allocator: std.mem.Allocator,
) void {
    for (semaphores) |semaphore| {
        ddisp.destroySemaphore(device, semaphore, null);
    }
    if (semaphores.len > 0) allocator.free(semaphores);
}

fn chooseSwapchainExtent(caps: vk.SurfaceCapabilitiesKHR, framebuffer_size: [2]u32) vk.Extent2D {
    const variable_extent = caps.current_extent.width == std.math.maxInt(u32) and
        caps.current_extent.height == std.math.maxInt(u32);
    if (!variable_extent) return caps.current_extent;
    if (framebuffer_size[0] == 0 or framebuffer_size[1] == 0) {
        return .{ .width = 0, .height = 0 };
    }
    if (caps.max_image_extent.width == 0 or caps.max_image_extent.height == 0) {
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

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormatKHR) ?vk.SurfaceFormatKHR {
    if (formats.len == 0) return null;

    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };
    if (formats.len == 1 and formats[0].format == .undefined) return preferred;

    for (formats) |format| {
        if (format.format == preferred.format and format.color_space == preferred.color_space) {
            return format;
        }
    }
    return formats[0];
}

fn choosePresentMode(modes: []const vk.PresentModeKHR) ?vk.PresentModeKHR {
    for (modes) |mode| {
        if (mode == .fifo_khr) return .fifo_khr;
    }
    return null;
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
        const required_name = std.mem.span(required);
        var found = false;
        for (available) |extension| {
            const available_name = std.mem.sliceTo(&extension.extension_name, 0);
            if (std.mem.eql(u8, available_name, required_name)) {
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
) !QueueFamilies {
    var family_count: u32 = 0;
    idisp.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);
    if (family_count == 0) return error.NoQueueFamilies;

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    idisp.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    const support = try allocator.alloc(QueueFamilySupport, family_count);
    defer allocator.free(support);

    for (families[0..family_count], 0..) |family, i| {
        const index: u32 = @intCast(i);
        support[i] = .{
            .graphics = family.queue_flags.graphics_bit,
            .present = try idisp.getPhysicalDeviceSurfaceSupportKHR(pdev, index, surface) == .true,
        };
    }
    return chooseQueueFamilies(support) orelse error.NoSuitableQueueFamilies;
}

fn chooseQueueFamilies(support: []const QueueFamilySupport) ?QueueFamilies {
    for (support, 0..) |family, i| {
        if (family.graphics and family.present) {
            const index: u32 = @intCast(i);
            return .{ .graphics = index, .present = index };
        }
    }

    var graphics: ?u32 = null;
    var present: ?u32 = null;
    for (support, 0..) |family, i| {
        const index: u32 = @intCast(i);
        if (family.graphics) graphics = graphics orelse index;
        if (family.present) present = present orelse index;
    }
    return .{
        .graphics = graphics orelse return null,
        .present = present orelse return null,
    };
}

fn colorAttachmentAcquireBarrier(image: vk.Image) vk.ImageMemoryBarrier2 {
    return imageBarrier(
        image,
        .undefined,
        .color_attachment_optimal,
        .{ .color_attachment_output_bit = true },
        .{},
        .{ .color_attachment_output_bit = true },
        .{ .color_attachment_write_bit = true },
    );
}

fn presentReleaseBarrier(image: vk.Image) vk.ImageMemoryBarrier2 {
    return imageBarrier(
        image,
        .color_attachment_optimal,
        .present_src_khr,
        .{ .color_attachment_output_bit = true },
        .{ .color_attachment_write_bit = true },
        .{},
        .{},
    );
}

fn imageBarrier(
    image: vk.Image,
    old_layout: vk.ImageLayout,
    new_layout: vk.ImageLayout,
    src_stage: vk.PipelineStageFlags2,
    src_access: vk.AccessFlags2,
    dst_stage: vk.PipelineStageFlags2,
    dst_access: vk.AccessFlags2,
) vk.ImageMemoryBarrier2 {
    return .{
        .src_stage_mask = src_stage,
        .src_access_mask = src_access,
        .dst_stage_mask = dst_stage,
        .dst_access_mask = dst_access,
        .old_layout = old_layout,
        .new_layout = new_layout,
        .src_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .dst_queue_family_index = vk.QUEUE_FAMILY_IGNORED,
        .image = image,
        .subresource_range = colorSubresourceRange(),
    };
}

fn colorSubresourceRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
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
    caps.max_image_array_layers = 1;
    caps.supported_composite_alpha = .{ .opaque_bit_khr = true };
    caps.supported_usage_flags = .{ .color_attachment_bit = true };
    return caps;
}

test "Vulkan demo frames align with renderer frame resources" {
    try std.testing.expectEqual(@as(usize, heavy_slug_vulkan.renderer.max_frames_in_flight), Host.frames_in_flight);
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
    var caps = testSurfaceCapabilities();

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

    caps.max_image_extent = .{ .width = 0, .height = 0 };
    try std.testing.expectEqual(
        vk.Extent2D{ .width = 0, .height = 0 },
        chooseSwapchainExtent(caps, .{ 1280, 720 }),
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

test "Vulkan demo surface format prefers sRGB B8G8R8A8 and handles unrestricted surfaces" {
    const preferred = vk.SurfaceFormatKHR{
        .format = .b8g8r8a8_srgb,
        .color_space = .srgb_nonlinear_khr,
    };
    const fallback = vk.SurfaceFormatKHR{
        .format = .a8b8g8r8_srgb_pack32,
        .color_space = .srgb_nonlinear_khr,
    };

    try std.testing.expectEqual(preferred, chooseSurfaceFormat(&.{ fallback, preferred }).?);
    try std.testing.expectEqual(fallback, chooseSurfaceFormat(&.{fallback}).?);
    try std.testing.expectEqual(preferred, chooseSurfaceFormat(&.{.{
        .format = .undefined,
        .color_space = .srgb_nonlinear_khr,
    }}).?);
    try std.testing.expect(chooseSurfaceFormat(&.{}) == null);
}

test "Vulkan demo present mode uses required FIFO mode" {
    try std.testing.expectEqual(vk.PresentModeKHR.fifo_khr, choosePresentMode(&.{ .immediate_khr, .fifo_khr }).?);
    try std.testing.expectEqual(vk.PresentModeKHR.fifo_khr, choosePresentMode(&.{.fifo_khr}).?);
    try std.testing.expect(choosePresentMode(&.{.immediate_khr}) == null);
}

test "Vulkan demo queue selection prefers a unified graphics-present family" {
    const unified = chooseQueueFamilies(&.{
        .{ .graphics = true, .present = false },
        .{ .graphics = true, .present = true },
        .{ .graphics = false, .present = true },
    }).?;
    try std.testing.expectEqual(@as(u32, 1), unified.graphics);
    try std.testing.expectEqual(@as(u32, 1), unified.present);

    const split = chooseQueueFamilies(&.{
        .{ .graphics = true, .present = false },
        .{ .graphics = false, .present = true },
    }).?;
    try std.testing.expectEqual(@as(u32, 0), split.graphics);
    try std.testing.expectEqual(@as(u32, 1), split.present);

    try std.testing.expect(chooseQueueFamilies(&.{.{ .graphics = true, .present = false }}) == null);
}

test "Vulkan demo swapchain barriers synchronize acquire and present layouts explicitly" {
    const acquire = colorAttachmentAcquireBarrier(.null_handle);
    try std.testing.expect(acquire.src_stage_mask.color_attachment_output_bit);
    try std.testing.expect(acquire.dst_stage_mask.color_attachment_output_bit);
    try std.testing.expect(!acquire.src_access_mask.color_attachment_write_bit);
    try std.testing.expect(acquire.dst_access_mask.color_attachment_write_bit);
    try std.testing.expectEqual(vk.ImageLayout.undefined, acquire.old_layout);
    try std.testing.expectEqual(vk.ImageLayout.color_attachment_optimal, acquire.new_layout);

    const release = presentReleaseBarrier(.null_handle);
    try std.testing.expect(release.src_stage_mask.color_attachment_output_bit);
    try std.testing.expect(release.src_access_mask.color_attachment_write_bit);
    try std.testing.expectEqual(@as(vk.PipelineStageFlags2, .{}), release.dst_stage_mask);
    try std.testing.expectEqual(@as(vk.AccessFlags2, .{}), release.dst_access_mask);
    try std.testing.expectEqual(vk.ImageLayout.color_attachment_optimal, release.old_layout);
    try std.testing.expectEqual(vk.ImageLayout.present_src_khr, release.new_layout);
}
