//! Vulkan WSI policy for the native demo host.

const std = @import("std");
const vk = @import("vulkan");
const dispatch = @import("dispatch.zig");

pub const QueueFamilies = struct {
    graphics: u32,
    present: u32,

    pub fn isUnified(self: QueueFamilies) bool {
        return self.graphics == self.present;
    }
};

pub const SurfaceConfig = struct {
    caps: vk.SurfaceCapabilitiesKHR,
    format: vk.SurfaceFormatKHR,
    present_mode: vk.PresentModeKHR,
};

pub const SwapchainRenderPath = enum {
    direct_wsi,
};

pub const SwapchainPlan = struct {
    render_path: SwapchainRenderPath = .direct_wsi,
    extent: vk.Extent2D,
    image_count: u32 = 0,
    image_usage: vk.ImageUsageFlags = .{},
    sharing_mode: vk.SharingMode = .exclusive,
    queue_family_indices: [2]u32 = .{ 0, 0 },
    queue_family_index_count: u32 = 0,
    composite_alpha: vk.CompositeAlphaFlagsKHR = .{},

    pub fn isDrawable(self: SwapchainPlan) bool {
        return self.extent.width > 0 and self.extent.height > 0;
    }

    pub fn isDirectZeroCopy(self: SwapchainPlan) bool {
        return self.render_path == .direct_wsi and
            self.image_usage.color_attachment_bit and
            !self.image_usage.transfer_src_bit and
            !self.image_usage.transfer_dst_bit and
            !self.image_usage.storage_bit;
    }

    pub fn queueFamilyIndexPtr(self: *const SwapchainPlan) ?[*]const u32 {
        if (self.queue_family_index_count == 0) return null;
        return self.queue_family_indices[0..self.queue_family_index_count].ptr;
    }
};

pub fn querySurfaceConfig(
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    idisp: dispatch.InstanceDispatch,
    allocator: std.mem.Allocator,
) !SurfaceConfig {
    const surface_info = vk.PhysicalDeviceSurfaceInfo2KHR{ .surface = surface };
    var caps2 = vk.SurfaceCapabilities2KHR{
        .surface_capabilities = std.mem.zeroes(vk.SurfaceCapabilitiesKHR),
    };
    try idisp.getPhysicalDeviceSurfaceCapabilities2KHR(pdev, &surface_info, &caps2);

    const formats = try querySurfaceFormats2(pdev, &surface_info, idisp, allocator);
    defer allocator.free(formats);

    var present_mode_count: u32 = 0;
    _ = try idisp.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);
    if (present_mode_count == 0) return error.SurfacePresentModeUnavailable;
    const present_modes = try allocator.alloc(vk.PresentModeKHR, present_mode_count);
    defer allocator.free(present_modes);
    _ = try idisp.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, present_modes.ptr);

    return .{
        .caps = caps2.surface_capabilities,
        .format = chooseSurfaceFormat(formats) orelse return error.SurfaceFormatUnavailable,
        .present_mode = choosePresentMode(present_modes) orelse return error.SurfaceFifoPresentModeMissing,
    };
}

fn querySurfaceFormats2(
    pdev: vk.PhysicalDevice,
    surface_info: *const vk.PhysicalDeviceSurfaceInfo2KHR,
    idisp: dispatch.InstanceDispatch,
    allocator: std.mem.Allocator,
) ![]vk.SurfaceFormat2KHR {
    var formats: []vk.SurfaceFormat2KHR = &.{};
    errdefer allocator.free(formats);

    while (true) {
        var format_count: u32 = 0;
        _ = try idisp.getPhysicalDeviceSurfaceFormats2KHR(pdev, surface_info, &format_count, null);
        if (format_count == 0) return error.SurfaceFormatUnavailable;

        formats = try allocator.realloc(formats, format_count);
        initSurfaceFormat2Slots(formats);

        var written_count = format_count;
        const result = try idisp.getPhysicalDeviceSurfaceFormats2KHR(
            pdev,
            surface_info,
            &written_count,
            formats.ptr,
        );
        if (result == .incomplete) continue;
        return if (written_count == formats.len) formats else allocator.realloc(formats, written_count);
    }
}

fn initSurfaceFormat2Slots(formats: []vk.SurfaceFormat2KHR) void {
    for (formats) |*format| {
        format.* = .{
            .surface_format = std.mem.zeroes(vk.SurfaceFormatKHR),
        };
    }
}

pub fn chooseDirectSwapchainPlan(
    surface_config: SurfaceConfig,
    framebuffer_size: [2]u32,
    queues: QueueFamilies,
) !SwapchainPlan {
    var plan = SwapchainPlan{
        .extent = chooseSwapchainExtent(surface_config.caps, framebuffer_size),
        .composite_alpha = chooseCompositeAlpha(surface_config.caps.supported_composite_alpha),
    };
    if (!plan.isDrawable()) return plan;

    if (!surface_config.caps.supported_usage_flags.color_attachment_bit) {
        return error.SurfaceColorAttachmentUnsupported;
    }
    if (surface_config.caps.max_image_array_layers < 1) {
        return error.SurfaceImageArrayUnsupported;
    }

    plan.image_count = chooseSwapchainImageCount(surface_config.caps);
    plan.image_usage = directSwapchainImageUsage(surface_config.caps);
    if (queues.isUnified()) {
        plan.sharing_mode = .exclusive;
        plan.queue_family_index_count = 0;
    } else {
        plan.sharing_mode = .concurrent;
        plan.queue_family_indices = .{ queues.graphics, queues.present };
        plan.queue_family_index_count = 2;
    }
    return plan;
}

pub fn colorSubresourceRange() vk.ImageSubresourceRange {
    return .{
        .aspect_mask = .{ .color_bit = true },
        .base_mip_level = 0,
        .level_count = 1,
        .base_array_layer = 0,
        .layer_count = 1,
    };
}

pub fn discardSwapchainAcquireBarrier(image: vk.Image) vk.ImageMemoryBarrier2 {
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

pub fn presentReleaseBarrier(image: vk.Image) vk.ImageMemoryBarrier2 {
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

fn directSwapchainImageUsage(caps: vk.SurfaceCapabilitiesKHR) vk.ImageUsageFlags {
    std.debug.assert(caps.supported_usage_flags.color_attachment_bit);
    return .{ .color_attachment_bit = true };
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

fn chooseSurfaceFormat(formats: []const vk.SurfaceFormat2KHR) ?vk.SurfaceFormatKHR {
    if (formats.len == 0) return null;

    const preferred_color_space = vk.ColorSpaceKHR.srgb_nonlinear_khr;
    const preferred_formats = [_]vk.Format{
        .b8g8r8a8_srgb,
        .r8g8b8a8_srgb,
    };
    if (formats.len == 1 and formats[0].surface_format.format == .undefined) {
        return .{
            .format = preferred_formats[0],
            .color_space = preferred_color_space,
        };
    }

    for (preferred_formats) |preferred_format| {
        for (formats) |format| {
            const surface_format = format.surface_format;
            if (surface_format.format == preferred_format and surface_format.color_space == preferred_color_space) {
                return surface_format;
            }
        }
    }
    return formats[0].surface_format;
}

fn choosePresentMode(modes: []const vk.PresentModeKHR) ?vk.PresentModeKHR {
    for (modes) |mode| {
        if (mode == .fifo_khr) return .fifo_khr;
    }
    return null;
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

fn testSurfaceFormat2(format: vk.Format, color_space: vk.ColorSpaceKHR) vk.SurfaceFormat2KHR {
    return .{
        .surface_format = .{
            .format = format,
            .color_space = color_space,
        },
    };
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

test "Vulkan demo swapchain plan keeps the main pass zero-copy" {
    const config = SurfaceConfig{
        .caps = testSurfaceCapabilities(),
        .format = .{
            .format = .b8g8r8a8_srgb,
            .color_space = .srgb_nonlinear_khr,
        },
        .present_mode = .fifo_khr,
    };
    const plan = try chooseDirectSwapchainPlan(config, .{ 1280, 720 }, .{ .graphics = 2, .present = 2 });

    try std.testing.expect(plan.isDrawable());
    try std.testing.expect(plan.isDirectZeroCopy());
    try std.testing.expectEqual(SwapchainRenderPath.direct_wsi, plan.render_path);
    try std.testing.expectEqual(vk.SharingMode.exclusive, plan.sharing_mode);
    try std.testing.expectEqual(@as(u32, 0), plan.queue_family_index_count);
    try std.testing.expect(plan.queueFamilyIndexPtr() == null);
    try std.testing.expectEqual(@as(u32, 3), plan.image_count);
    try std.testing.expect(plan.image_usage.color_attachment_bit);
}

test "Vulkan demo swapchain plan uses concurrent sharing only for split queues" {
    const config = SurfaceConfig{
        .caps = testSurfaceCapabilities(),
        .format = .{
            .format = .b8g8r8a8_srgb,
            .color_space = .srgb_nonlinear_khr,
        },
        .present_mode = .fifo_khr,
    };
    const plan = try chooseDirectSwapchainPlan(config, .{ 800, 600 }, .{ .graphics = 1, .present = 3 });
    const indices = plan.queueFamilyIndexPtr().?;

    try std.testing.expect(plan.isDirectZeroCopy());
    try std.testing.expectEqual(vk.SharingMode.concurrent, plan.sharing_mode);
    try std.testing.expectEqual(@as(u32, 2), plan.queue_family_index_count);
    try std.testing.expectEqual(@as(u32, 1), indices[0]);
    try std.testing.expectEqual(@as(u32, 3), indices[1]);
}

test "Vulkan demo swapchain plan rejects non-renderable WSI images" {
    var config = SurfaceConfig{
        .caps = testSurfaceCapabilities(),
        .format = .{
            .format = .b8g8r8a8_srgb,
            .color_space = .srgb_nonlinear_khr,
        },
        .present_mode = .fifo_khr,
    };
    config.caps.supported_usage_flags = .{ .transfer_dst_bit = true };
    try std.testing.expectError(
        error.SurfaceColorAttachmentUnsupported,
        chooseDirectSwapchainPlan(config, .{ 800, 600 }, .{ .graphics = 0, .present = 0 }),
    );
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

test "Vulkan demo surface-format-2 slots keep valid output structure headers" {
    var formats: [2]vk.SurfaceFormat2KHR = undefined;
    initSurfaceFormat2Slots(&formats);

    for (formats) |format| {
        try std.testing.expectEqual(vk.StructureType.surface_format_2_khr, format.s_type);
        try std.testing.expect(format.p_next == null);
    }
}

test "Vulkan demo surface format prefers sRGB B8G8R8A8 then R8G8B8A8" {
    const preferred = testSurfaceFormat2(.b8g8r8a8_srgb, .srgb_nonlinear_khr);
    const second = testSurfaceFormat2(.r8g8b8a8_srgb, .srgb_nonlinear_khr);
    const alternate = testSurfaceFormat2(.a8b8g8r8_srgb_pack32, .srgb_nonlinear_khr);

    try std.testing.expectEqual(preferred.surface_format, chooseSurfaceFormat(&.{ alternate, second, preferred }).?);
    try std.testing.expectEqual(second.surface_format, chooseSurfaceFormat(&.{ alternate, second }).?);
    try std.testing.expectEqual(alternate.surface_format, chooseSurfaceFormat(&.{alternate}).?);
    try std.testing.expectEqual(preferred.surface_format, chooseSurfaceFormat(&.{
        testSurfaceFormat2(.undefined, .srgb_nonlinear_khr),
    }).?);
    try std.testing.expect(chooseSurfaceFormat(&.{}) == null);
}

test "Vulkan demo present mode uses required FIFO mode" {
    try std.testing.expectEqual(vk.PresentModeKHR.fifo_khr, choosePresentMode(&.{ .immediate_khr, .fifo_khr }).?);
    try std.testing.expectEqual(vk.PresentModeKHR.fifo_khr, choosePresentMode(&.{.fifo_khr}).?);
    try std.testing.expect(choosePresentMode(&.{.immediate_khr}) == null);
}

test "Vulkan demo swapchain barriers synchronize acquire and present layouts explicitly" {
    const acquire = discardSwapchainAcquireBarrier(.null_handle);
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
