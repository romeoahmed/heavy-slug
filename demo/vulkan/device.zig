//! Physical-device selection and logical-device creation for the Vulkan demo.

const std = @import("std");
const vk = @import("vulkan");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const dispatch = @import("dispatch.zig");
const wsi = @import("wsi.zig");

const gpu_context = heavy_slug_vulkan.context;
const vk_chains = heavy_slug_vulkan.chains;

const swapchain_extension: [*:0]const u8 = "VK_KHR_swapchain";
const swapchain_maintenance_khr: [*:0]const u8 = "VK_KHR_swapchain_maintenance1";
const max_device_extensions = 2 + gpu_context.Context.required_device_extensions.len;

pub const QueueFamilies = wsi.QueueFamilies;

pub const DeviceExtensionSet = struct {
    names: [max_device_extensions][*:0]const u8 = undefined,
    len: usize = 0,

    pub fn init() DeviceExtensionSet {
        var set = DeviceExtensionSet{};
        set.push(swapchain_extension);
        for (gpu_context.Context.required_device_extensions) |extension| {
            set.push(extension);
        }
        set.push(swapchain_maintenance_khr);
        return set;
    }

    pub fn slice(self: *const DeviceExtensionSet) []const [*:0]const u8 {
        return self.names[0..self.len];
    }

    fn push(self: *DeviceExtensionSet, extension: [*:0]const u8) void {
        std.debug.assert(self.len < self.names.len);
        self.names[self.len] = extension;
        self.len += 1;
    }
};

pub const DeviceSelection = struct {
    physical_device: vk.PhysicalDevice,
    queues: QueueFamilies,
    surface_format: vk.SurfaceFormatKHR,
};

pub const LogicalDevice = struct {
    device: vk.Device,
    dispatch: dispatch.DeviceDispatch,
    get_device_proc_addr: vk.PfnGetDeviceProcAddr,
};

const QueueFamilySupport = struct {
    graphics: bool,
    present: bool,
};

const DeviceCandidate = struct {
    selection: DeviceSelection,
    score: u64,
};

const DemoFeatureChain = struct {
    renderer: vk_chains.FeatureChain,
    swapchain_maintenance: vk.PhysicalDeviceSwapchainMaintenance1FeaturesKHR,

    fn init() DemoFeatureChain {
        return .{
            .renderer = gpu_context.Context.requiredFeatureChain(),
            .swapchain_maintenance = .{},
        };
    }

    fn rootInfo(self: *DemoFeatureChain) *vk.PhysicalDeviceFeatures2 {
        const root = self.renderer.rootInfo();
        self.swapchain_maintenance.p_next = root.p_next;
        root.p_next = @ptrCast(&self.swapchain_maintenance);
        return root;
    }

    fn enableRequired(self: *DemoFeatureChain) void {
        self.renderer.enableSynchronization2();
        self.swapchain_maintenance.swapchain_maintenance_1 = .true;
    }

    fn supportsRequired(self: DemoFeatureChain) bool {
        return self.renderer.hasRendererFeatures() and
            self.renderer.hasSynchronization2() and
            self.swapchain_maintenance.swapchain_maintenance_1 == .true;
    }
};

pub fn validateInstanceExtensions(
    base: dispatch.BaseDispatch,
    allocator: std.mem.Allocator,
    required_extensions: []const [*:0]const u8,
) !void {
    const available = try base.enumerateInstanceExtensionPropertiesAlloc(null, allocator);
    defer allocator.free(available);

    for (required_extensions) |required| {
        if (!hasExtension(available, required)) return error.InstanceExtensionUnavailable;
    }
}

pub fn choosePhysicalDevice(
    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    idisp: dispatch.InstanceDispatch,
    lib_idisp: gpu_context.InstanceDispatch,
    allocator: std.mem.Allocator,
) !DeviceSelection {
    var device_count: u32 = 0;
    _ = try idisp.enumeratePhysicalDevices(instance, &device_count, null);
    if (device_count == 0) return error.NoPhysicalDevices;

    const devices = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(devices);
    _ = try idisp.enumeratePhysicalDevices(instance, &device_count, devices.ptr);

    var best: ?DeviceCandidate = null;
    for (devices[0..device_count]) |pdev| {
        const candidate = try inspectPhysicalDevice(pdev, surface, idisp, lib_idisp, allocator) orelse continue;
        if (best == null or candidate.score > best.?.score) {
            best = candidate;
        }
    }
    return if (best) |candidate| candidate.selection else error.NoSuitableDevice;
}

pub fn createLogicalDevice(
    selection: DeviceSelection,
    idisp: dispatch.InstanceDispatch,
) !LogicalDevice {
    const queue_family_indices: [2]u32 = .{ selection.queues.graphics, selection.queues.present };
    const queue_family_count: usize = if (selection.queues.isUnified()) 1 else 2;
    const priority = [_]f32{1.0};
    var queue_cis: [2]vk.DeviceQueueCreateInfo = undefined;
    for (queue_family_indices[0..queue_family_count], 0..) |family, i| {
        queue_cis[i] = .{
            .queue_family_index = family,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        };
    }

    var enabled_features = DemoFeatureChain.init();
    enabled_features.enableRequired();
    const feature_root = enabled_features.rootInfo();

    const enabled_extensions = DeviceExtensionSet.init();
    const device = try idisp.createDevice(selection.physical_device, &.{
        .p_next = @ptrCast(feature_root),
        .queue_create_info_count = @intCast(queue_family_count),
        .p_queue_create_infos = &queue_cis,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = null,
        .enabled_extension_count = @intCast(enabled_extensions.slice().len),
        .pp_enabled_extension_names = enabled_extensions.slice().ptr,
        .p_enabled_features = null,
    }, null);

    const get_device_proc_addr: vk.PfnGetDeviceProcAddr = @ptrCast(
        idisp.dispatch.vkGetDeviceProcAddr orelse return error.MissingFunction,
    );
    const ddisp = dispatch.DeviceDispatch.load(device, get_device_proc_addr);
    try dispatch.validateDeviceDispatch(ddisp);
    return .{
        .device = device,
        .dispatch = ddisp,
        .get_device_proc_addr = get_device_proc_addr,
    };
}

fn inspectPhysicalDevice(
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    idisp: dispatch.InstanceDispatch,
    lib_idisp: gpu_context.InstanceDispatch,
    allocator: std.mem.Allocator,
) error{OutOfMemory}!?DeviceCandidate {
    const available_extensions = lib_idisp.enumerateDeviceExtensionPropertiesAlloc(
        pdev,
        null,
        allocator,
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    defer allocator.free(available_extensions);

    if (!hasRequiredBaseExtensions(available_extensions)) return null;
    gpu_context.Context.checkDeviceSupport(pdev, lib_idisp, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    if (!supportsRequiredDemoFeatures(pdev, lib_idisp)) return null;

    const queues = findQueueFamilies(pdev, surface, idisp, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const surface_config = wsi.querySurfaceConfig(pdev, surface, idisp, allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
    const properties = idisp.getPhysicalDeviceProperties(pdev);
    const selection = DeviceSelection{
        .physical_device = pdev,
        .queues = queues,
        .surface_format = surface_config.format,
    };

    return .{
        .selection = selection,
        .score = scoreDevice(properties, queues),
    };
}

fn hasRequiredBaseExtensions(available: []const vk.ExtensionProperties) bool {
    const required_extensions = DeviceExtensionSet.init();
    for (required_extensions.slice()) |extension| {
        if (!hasExtension(available, extension)) return false;
    }
    return true;
}

fn hasExtension(available: []const vk.ExtensionProperties, required: [*:0]const u8) bool {
    const required_name = std.mem.span(required);
    for (available) |extension| {
        const available_name = std.mem.sliceTo(&extension.extension_name, 0);
        if (std.mem.eql(u8, available_name, required_name)) return true;
    }
    return false;
}

fn supportsRequiredDemoFeatures(
    pdev: vk.PhysicalDevice,
    idisp: gpu_context.InstanceDispatch,
) bool {
    var features = DemoFeatureChain.init();
    idisp.getPhysicalDeviceFeatures2(pdev, features.rootInfo());
    return features.supportsRequired();
}

fn findQueueFamilies(
    pdev: vk.PhysicalDevice,
    surface: vk.SurfaceKHR,
    idisp: dispatch.InstanceDispatch,
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

fn scoreDevice(
    properties: vk.PhysicalDeviceProperties,
    queues: QueueFamilies,
) u64 {
    var score: u64 = switch (properties.device_type) {
        .discrete_gpu => 10_000,
        .integrated_gpu => 8_000,
        .virtual_gpu => 4_000,
        .other => 2_000,
        .cpu => 1_000,
        else => 0,
    };
    if (queues.isUnified()) score += 1_000;
    score += @min(@as(u64, properties.limits.max_image_dimension_2d), 8192);
    return score;
}

fn extensionName(comptime name: []const u8) [vk.MAX_EXTENSION_NAME_SIZE]u8 {
    comptime {
        if (name.len >= vk.MAX_EXTENSION_NAME_SIZE) @compileError("extension name too long");
    }
    var out = [_]u8{0} ** vk.MAX_EXTENSION_NAME_SIZE;
    @memcpy(out[0..name.len], name);
    return out;
}

fn testProperties(device_type: vk.PhysicalDeviceType) vk.PhysicalDeviceProperties {
    var properties = std.mem.zeroes(vk.PhysicalDeviceProperties);
    properties.device_type = device_type;
    properties.limits.max_image_dimension_2d = 4096;
    return properties;
}

test "Vulkan demo device extension set requires the KHR present fence path" {
    const extensions = DeviceExtensionSet.init();
    try std.testing.expectEqual(@as(usize, 2 + gpu_context.Context.required_device_extensions.len), extensions.slice().len);
    try std.testing.expect(std.mem.eql(u8, std.mem.span(extensions.slice()[0]), "VK_KHR_swapchain"));
    try std.testing.expect(std.mem.eql(
        u8,
        std.mem.span(extensions.slice()[extensions.slice().len - 1]),
        "VK_KHR_swapchain_maintenance1",
    ));
}

test "Vulkan demo device extension lookup treats extension names as NUL-terminated data" {
    const available = [_]vk.ExtensionProperties{
        .{ .extension_name = extensionName("VK_KHR_swapchain"), .spec_version = 1 },
        .{ .extension_name = extensionName("VK_EXT_mesh_shader"), .spec_version = 1 },
    };

    try std.testing.expect(hasExtension(&available, "VK_KHR_swapchain"));
    try std.testing.expect(!hasExtension(&available, "VK_EXT_shader_object"));
}

test "Vulkan demo device support requires swapchain maintenance KHR" {
    const available = [_]vk.ExtensionProperties{
        .{ .extension_name = extensionName("VK_KHR_swapchain"), .spec_version = 1 },
        .{ .extension_name = extensionName("VK_EXT_mesh_shader"), .spec_version = 1 },
        .{ .extension_name = extensionName("VK_EXT_shader_object"), .spec_version = 1 },
        .{ .extension_name = extensionName("VK_KHR_swapchain_maintenance1"), .spec_version = 1 },
    };

    try std.testing.expect(hasRequiredBaseExtensions(&available));
    try std.testing.expect(!hasRequiredBaseExtensions(available[0..3]));
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

test "Vulkan demo feature chain enables synchronization2 and swapchain maintenance" {
    var features = DemoFeatureChain.init();
    try std.testing.expect(!features.supportsRequired());

    _ = features.rootInfo();
    features.enableRequired();
    try std.testing.expect(features.supportsRequired());
}

test "Vulkan demo physical device scoring prefers GPU class, then unified present" {
    const split = QueueFamilies{ .graphics = 0, .present = 1 };
    const unified = QueueFamilies{ .graphics = 0, .present = 0 };

    try std.testing.expect(scoreDevice(testProperties(.discrete_gpu), split) >
        scoreDevice(testProperties(.integrated_gpu), unified));
    try std.testing.expect(scoreDevice(testProperties(.integrated_gpu), unified) >
        scoreDevice(testProperties(.integrated_gpu), split));
}
