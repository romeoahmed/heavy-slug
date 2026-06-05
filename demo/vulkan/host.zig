//! Demo-only Vulkan host: instance, device, swapchain, synchronization, and frame pacing.

const std = @import("std");
const vk = @import("vulkan");
const demo_platform = @import("demo_platform");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const dispatch = @import("dispatch.zig");
const device_mod = @import("device.zig");
const wsi = @import("wsi.zig");

const gpu_context = heavy_slug_vulkan.context;
const log = std.log.scoped(.demo_vulkan);

pub const DemoDeviceDispatch = dispatch.DeviceDispatch;

const demo_instance_extensions = [_][*:0]const u8{
    "VK_KHR_get_surface_capabilities2",
    "VK_KHR_surface_maintenance1",
};

fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    return demo_platform.getRequiredInstanceExtensions();
}

fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    return demo_platform.getInstanceProcAddress(instance, name);
}

fn buildRequiredInstanceExtensions(
    allocator: std.mem.Allocator,
    platform_extensions: []const [*:0]const u8,
) ![]const [*:0]const u8 {
    const extensions = try allocator.alloc([*:0]const u8, platform_extensions.len + demo_instance_extensions.len);
    errdefer allocator.free(extensions);

    var extension_count: usize = 0;
    for (platform_extensions) |extension| {
        appendUniqueExtension(extensions, &extension_count, extension);
    }
    for (demo_instance_extensions) |extension| {
        appendUniqueExtension(extensions, &extension_count, extension);
    }
    return allocator.realloc(extensions, extension_count);
}

fn appendUniqueExtension(
    extensions: [][*:0]const u8,
    extension_count: *usize,
    extension: [*:0]const u8,
) void {
    for (extensions[0..extension_count.*]) |existing| {
        if (std.mem.eql(u8, std.mem.span(existing), std.mem.span(extension))) return;
    }
    extensions[extension_count.*] = extension;
    extension_count.* += 1;
}

const FrameSlot = struct {
    command_buffer: vk.CommandBuffer = .null_handle,
    image_available: vk.Semaphore = .null_handle,
    in_flight: vk.Fence = .null_handle,
};

const SwapchainImageState = struct {
    image: vk.Image = .null_handle,
    view: vk.ImageView = .null_handle,
    render_complete: vk.Semaphore = .null_handle,
    present_complete: vk.Fence = .null_handle,
    present_pending: bool = false,
};

const AcquiredImage = struct {
    result: vk.Result,
    image_index: u32,
};

/// Owns demo-only Vulkan state. The library backend still owns only renderer
/// GPU resources; surfaces, swapchains, queues, and command buffers stay here.
pub const Host = struct {
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    physical_device: vk.PhysicalDevice,
    device: vk.Device,
    graphics_queue: vk.Queue,
    present_queue: vk.Queue,
    graphics_family: u32,
    present_family: u32,
    demo_idisp: dispatch.InstanceDispatch,
    demo_ddisp: dispatch.DeviceDispatch,
    lib_idisp: gpu_context.InstanceDispatch,
    renderer_context: gpu_context.Context,
    surface_format: vk.SurfaceFormatKHR,

    swapchain: vk.SwapchainKHR = .null_handle,
    swapchain_images: []SwapchainImageState = &.{},
    swapchain_extent: vk.Extent2D = .{ .width = 0, .height = 0 },

    command_pool: vk.CommandPool = .null_handle,
    frames: [frames_in_flight]FrameSlot = .{FrameSlot{}} ** frames_in_flight,
    frame_index: usize = 0,
    /// Linear RGBA clear color. Vulkan converts to sRGB on write for sRGB swapchain formats.
    clear_color: [4]f32 = .{ 1.0, 1.0, 1.0, 1.0 },

    allocator: std.mem.Allocator,

    pub const frames_in_flight = heavy_slug_vulkan.renderer.max_frames_in_flight;

    pub fn init(window: *demo_platform.Window, allocator: std.mem.Allocator) !Host {
        const platform_surface = window.surfaceCapabilities();
        if (!platform_surface.supportsDirectSwapchain()) {
            return error.PlatformDirectSwapchainUnsupported;
        }

        const base = dispatch.BaseDispatch.load(getInstanceProcAddress);
        const platform_exts = getRequiredInstanceExtensions();
        const instance_exts = try buildRequiredInstanceExtensions(allocator, platform_exts);
        defer allocator.free(instance_exts);
        try device_mod.validateInstanceExtensions(base, allocator, instance_exts);

        const app_info = vk.ApplicationInfo{
            .p_application_name = "heavy-slug demo",
            .application_version = 0,
            .p_engine_name = "heavy-slug",
            .engine_version = 0,
            .api_version = @bitCast(vk.API_VERSION_1_4),
        };
        const instance = try base.createInstance(&.{
            .p_application_info = &app_info,
            .enabled_extension_count = @intCast(instance_exts.len),
            .pp_enabled_extension_names = instance_exts.ptr,
        }, null);

        const demo_idisp = dispatch.InstanceDispatch.load(instance, getInstanceProcAddress);
        try dispatch.validateInstanceDispatch(demo_idisp);
        var instance_alive = true;
        errdefer if (instance_alive) demo_idisp.destroyInstance(instance, null);

        const lib_idisp = gpu_context.InstanceDispatch.load(instance, getInstanceProcAddress);
        const surface = try window.createSurface(instance, demo_idisp);
        var surface_alive = true;
        errdefer if (surface_alive) demo_idisp.destroySurfaceKHR(instance, surface, null);

        const selection = try device_mod.choosePhysicalDevice(instance, surface, demo_idisp, lib_idisp, allocator);
        const logical_device = try device_mod.createLogicalDevice(selection, demo_idisp);
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
            .graphics_queue = getDeviceQueue(demo_ddisp, device, selection.queues.graphics),
            .present_queue = getDeviceQueue(demo_ddisp, device, selection.queues.present),
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
        image_index: u32,
        frame_index: usize,
        suboptimal: bool,
    };

    pub fn createSwapchain(self: *Host, window: *const demo_platform.Window) !void {
        if (self.swapchain != .null_handle) {
            try self.drainSubmittedWork();
        }

        const surface_config = try wsi.querySurfaceConfig(
            self.physical_device,
            self.surface,
            self.demo_idisp,
            self.allocator,
        );
        const plan = try wsi.chooseDirectSwapchainPlan(
            surface_config,
            window.framebufferSize(),
            .{ .graphics = self.graphics_family, .present = self.present_family },
        );
        if (!plan.isDrawable()) {
            self.destroySwapchain();
            self.surface_format = surface_config.format;
            self.swapchain_extent = plan.extent;
            return;
        }
        std.debug.assert(plan.isDirectZeroCopy());

        const queue_family_indices = plan.queueFamilyIndexPtr();
        const new_swapchain = try self.demo_ddisp.createSwapchainKHR(self.device, &.{
            .surface = self.surface,
            .min_image_count = plan.image_count,
            .image_format = surface_config.format.format,
            .image_color_space = surface_config.format.color_space,
            .image_extent = plan.extent,
            .image_array_layers = 1,
            .image_usage = plan.image_usage,
            .image_sharing_mode = plan.sharing_mode,
            .queue_family_index_count = plan.queue_family_index_count,
            .p_queue_family_indices = queue_family_indices,
            .pre_transform = surface_config.caps.current_transform,
            .composite_alpha = plan.composite_alpha,
            .present_mode = surface_config.present_mode,
            .clipped = .true,
            .old_swapchain = self.swapchain,
        }, null);
        errdefer self.demo_ddisp.destroySwapchainKHR(self.device, new_swapchain, null);

        const new_images = try self.createSwapchainImages(new_swapchain, surface_config.format.format);
        errdefer self.destroySwapchainImages(new_images);

        const old_swapchain = self.swapchain;
        const old_images = self.swapchain_images;

        self.swapchain = new_swapchain;
        self.swapchain_images = new_images;
        self.swapchain_extent = plan.extent;
        self.surface_format = surface_config.format;

        self.destroySwapchainImages(old_images);
        if (old_swapchain != .null_handle) {
            self.demo_ddisp.destroySwapchainKHR(self.device, old_swapchain, null);
        }
    }

    fn createSwapchainImages(
        self: *Host,
        swapchain: vk.SwapchainKHR,
        format: vk.Format,
    ) ![]SwapchainImageState {
        const images = try self.getSwapchainImages(swapchain);
        defer self.allocator.free(images);

        const states = try self.allocator.alloc(SwapchainImageState, images.len);
        @memset(states, .{});
        errdefer self.destroySwapchainImages(states);

        for (images, 0..) |image, i| {
            states[i].image = image;
            states[i].view = try self.demo_ddisp.createImageView(self.device, &.{
                .image = image,
                .view_type = .@"2d",
                .format = format,
                .components = .{ .r = .identity, .g = .identity, .b = .identity, .a = .identity },
                .subresource_range = wsi.colorSubresourceRange(),
            }, null);
            states[i].render_complete = try self.demo_ddisp.createSemaphore(self.device, &.{}, null);
            states[i].present_complete = try self.demo_ddisp.createFence(self.device, &.{}, null);
        }
        return states;
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

    fn destroySwapchainImages(self: *Host, images: []SwapchainImageState) void {
        if (images.len == 0) return;

        self.waitPresentCompletionFor(images) catch |err| {
            log.debug("present-fence drain during swapchain teardown failed: {}", .{err});
        };
        for (images) |image| {
            if (image.view != .null_handle) {
                self.demo_ddisp.destroyImageView(self.device, image.view, null);
            }
            if (image.render_complete != .null_handle) {
                self.demo_ddisp.destroySemaphore(self.device, image.render_complete, null);
            }
            if (image.present_complete != .null_handle) {
                self.demo_ddisp.destroyFence(self.device, image.present_complete, null);
            }
        }
        self.allocator.free(images);
    }

    fn destroySwapchain(self: *Host) void {
        const images = self.swapchain_images;
        const swapchain = self.swapchain;

        self.swapchain_images = &.{};
        self.swapchain = .null_handle;
        self.swapchain_extent = .{ .width = 0, .height = 0 };

        self.destroySwapchainImages(images);
        if (swapchain != .null_handle) {
            self.demo_ddisp.destroySwapchainKHR(self.device, swapchain, null);
        }
    }

    pub fn hasDrawableSwapchain(self: *const Host) bool {
        return self.swapchain != .null_handle and
            self.swapchain_images.len > 0 and
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
        _ = try self.demo_ddisp.waitForFences(self.device, fenceSlice(&slot.in_flight), .true, std.math.maxInt(u64));

        const acquire_result = self.acquireNextImage(slot.image_available) catch |err| switch (err) {
            error.OutOfDateKHR => return null,
            else => return err,
        };
        // VK_TIMEOUT / VK_NOT_READY are success codes that mean the next
        // drawable isn't available within the bounded wait; just skip this
        // frame and let the host try again next iteration.
        switch (acquire_result.result) {
            .success, .suboptimal_khr => {},
            .timeout, .not_ready => return null,
            else => return error.SwapchainImageIndexInvalid,
        }
        const image_index_usize: usize = @intCast(acquire_result.image_index);
        if (image_index_usize >= self.swapchain_images.len) return error.SwapchainImageIndexInvalid;
        const image_state = &self.swapchain_images[image_index_usize];
        try self.waitAndResetPresentFence(image_state);

        const cmd = slot.command_buffer;
        try self.demo_ddisp.resetCommandBuffer(cmd, .{});
        try self.demo_ddisp.beginCommandBuffer(cmd, &.{
            .flags = .{ .one_time_submit_bit = true },
        });

        self.transitionImage(cmd, wsi.discardSwapchainAcquireBarrier(image_state.image));

        const clear_value = vk.ClearValue{ .color = .{ .float_32 = self.clear_color } };
        const color_attachment = vk.RenderingAttachmentInfo{
            .image_view = image_state.view,
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
            .image_index = acquire_result.image_index,
            .frame_index = slot_index,
            .suboptimal = acquire_result.result == .suboptimal_khr,
        };
    }

    /// Returns true when the swapchain should be recreated before the next frame.
    pub fn endFrame(self: *Host, frame: SwapchainFrame) !bool {
        const image_index_usize: usize = @intCast(frame.image_index);
        if (image_index_usize >= self.swapchain_images.len) return error.SwapchainImageIndexInvalid;

        const slot = &self.frames[frame.frame_index];
        const image_state = &self.swapchain_images[image_index_usize];
        const cmd = frame.cmd;

        self.demo_ddisp.cmdEndRendering(cmd);
        self.transitionImage(cmd, wsi.presentReleaseBarrier(image_state.image));
        try self.demo_ddisp.endCommandBuffer(cmd);

        try self.demo_ddisp.resetFences(self.device, fenceSlice(&slot.in_flight));

        const wait_info = vk.SemaphoreSubmitInfo{
            .semaphore = slot.image_available,
            .stage_mask = .{ .color_attachment_output_bit = true },
            .value = 0,
            .device_index = 0,
        };
        // The command buffer's final GPU writes are color attachment stores;
        // the present queue only needs to wait on COLOR_ATTACHMENT_OUTPUT
        // rather than ALL_COMMANDS, allowing the driver to overlap any
        // subsequent presentation setup with later-stage work.
        // (Vulkan 1.4 §6.4.4 "Semaphore Signaling and Waiting".)
        const signal_info = vk.SemaphoreSubmitInfo{
            .semaphore = image_state.render_complete,
            .stage_mask = .{ .color_attachment_output_bit = true },
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

        var needs_recreate = frame.suboptimal;
        var present_accepted = true;
        var present_fence_info = vk.SwapchainPresentFenceInfoKHR{
            .swapchain_count = 1,
            .p_fences = @ptrCast(&image_state.present_complete),
        };
        const present_info = vk.PresentInfoKHR{
            .p_next = @ptrCast(&present_fence_info),
            .wait_semaphore_count = 1,
            .p_wait_semaphores = @ptrCast(&image_state.render_complete),
            .swapchain_count = 1,
            .p_swapchains = @ptrCast(&self.swapchain),
            .p_image_indices = @ptrCast(&frame.image_index),
        };
        const present_result = self.demo_ddisp.queuePresentKHR(self.present_queue, &present_info) catch |err| switch (err) {
            error.OutOfDateKHR => blk: {
                needs_recreate = true;
                present_accepted = false;
                break :blk .success;
            },
            else => return err,
        };
        if (present_result == .suboptimal_khr) needs_recreate = true;
        if (present_accepted) image_state.present_pending = true;

        self.advanceFrame();
        return needs_recreate;
    }

    pub fn abortFrame(self: *Host, frame: SwapchainFrame) !void {
        _ = try self.endFrame(frame);
    }

    /// Block at most one second for the next swapchain image. A wedged
    /// compositor or a stalled GPU should not freeze the demo's main loop
    /// indefinitely; on VK_TIMEOUT we report it the same way as
    /// VK_NOT_READY and let the caller skip this frame. Per the Vulkan 1.4
    /// `vkAcquireNextImage2KHR` Return Codes list, both are non-error
    /// success codes that the wrapper exposes in `.result`.
    const acquire_timeout_ns: u64 = std.time.ns_per_s;

    fn acquireNextImage(self: *Host, semaphore: vk.Semaphore) !AcquiredImage {
        const acquire_info = vk.AcquireNextImageInfoKHR{
            .swapchain = self.swapchain,
            .timeout = acquire_timeout_ns,
            .semaphore = semaphore,
            .fence = .null_handle,
            .device_mask = 1,
        };
        const acquired = try self.demo_ddisp.acquireNextImage2KHR(self.device, &acquire_info);
        return .{ .result = acquired.result, .image_index = acquired.image_index };
    }

    fn transitionImage(self: *Host, cmd: vk.CommandBuffer, barrier: vk.ImageMemoryBarrier2) void {
        self.demo_ddisp.cmdPipelineBarrier2(cmd, &.{
            .image_memory_barrier_count = 1,
            .p_image_memory_barriers = @ptrCast(&barrier),
        });
    }

    pub fn recreateSwapchain(self: *Host, window: *const demo_platform.Window) !void {
        try self.createSwapchain(window);
    }

    fn drainSubmittedWork(self: *Host) !void {
        try self.waitForFrameSlots();
        try self.waitPresentCompletion();
    }

    fn waitForFrameSlots(self: *Host) !void {
        var fences: [frames_in_flight]vk.Fence = undefined;
        for (self.frames, 0..) |slot, i| {
            fences[i] = slot.in_flight;
        }
        _ = try self.demo_ddisp.waitForFences(self.device, &fences, .true, std.math.maxInt(u64));
    }

    fn waitPresentCompletion(self: *Host) !void {
        try self.waitPresentCompletionFor(self.swapchain_images);
    }

    fn waitPresentCompletionFor(self: *Host, images: []SwapchainImageState) !void {
        for (images) |*image| {
            try self.waitAndResetPresentFence(image);
        }
    }

    fn waitAndResetPresentFence(self: *Host, image: *SwapchainImageState) !void {
        if (!image.present_pending) return;
        _ = try self.demo_ddisp.waitForFences(self.device, fenceSlice(&image.present_complete), .true, std.math.maxInt(u64));
        try self.demo_ddisp.resetFences(self.device, fenceSlice(&image.present_complete));
        image.present_pending = false;
    }

    fn advanceFrame(self: *Host) void {
        self.frame_index = (self.frame_index + 1) % frames_in_flight;
    }

    pub fn waitIdle(self: *Host) void {
        self.drainSubmittedWork() catch |err| {
            log.debug("Vulkan demo frame/present drain during shutdown failed: {}", .{err});
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

fn fenceSlice(fence: *const vk.Fence) []const vk.Fence {
    return @as(*const [1]vk.Fence, @ptrCast(fence))[0..1];
}

fn getDeviceQueue(ddisp: dispatch.DeviceDispatch, device: vk.Device, family: u32) vk.Queue {
    return ddisp.getDeviceQueue2(device, &.{
        .queue_family_index = family,
        .queue_index = 0,
    });
}

test "Vulkan demo frames align with renderer frame resources" {
    try std.testing.expectEqual(@as(usize, heavy_slug_vulkan.renderer.max_frames_in_flight), Host.frames_in_flight);
}

test "Vulkan demo instance extensions append modern WSI requirements once" {
    const platform_extensions = [_][*:0]const u8{
        "VK_KHR_surface",
        "VK_KHR_win32_surface",
        "VK_KHR_get_surface_capabilities2",
    };
    const extensions = try buildRequiredInstanceExtensions(std.testing.allocator, &platform_extensions);
    defer std.testing.allocator.free(extensions);

    try std.testing.expectEqual(@as(usize, 4), extensions.len);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(extensions[0]), "VK_KHR_surface"));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(extensions[1]), "VK_KHR_win32_surface"));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(extensions[2]), "VK_KHR_get_surface_capabilities2"));
    try std.testing.expect(std.mem.eql(u8, std.mem.span(extensions[3]), "VK_KHR_surface_maintenance1"));
}

test {
    _ = dispatch;
    _ = device_mod;
    _ = wsi;
}
