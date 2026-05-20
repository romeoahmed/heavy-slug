//! Demo-owned Vulkan dispatch tables.

const std = @import("std");
const vk = @import("vulkan");

/// Pre-instance Vulkan functions loaded through the platform Vulkan loader.
const BaseDispatchTable = struct {
    vkCreateInstance: ?vk.PfnCreateInstance = null,
    vkEnumerateInstanceExtensionProperties: ?vk.PfnEnumerateInstanceExtensionProperties = null,
};

/// Instance-level commands owned by the demo host.
const InstanceTable = struct {
    vkDestroyInstance: ?vk.PfnDestroyInstance = null,
    vkEnumeratePhysicalDevices: ?vk.PfnEnumeratePhysicalDevices = null,
    vkGetPhysicalDeviceProperties: ?vk.PfnGetPhysicalDeviceProperties = null,
    vkGetPhysicalDeviceQueueFamilyProperties: ?vk.PfnGetPhysicalDeviceQueueFamilyProperties = null,
    vkCreateDevice: ?vk.PfnCreateDevice = null,
    vkGetDeviceProcAddr: ?vk.PfnGetDeviceProcAddr = null,
    vkDestroySurfaceKHR: ?vk.PfnDestroySurfaceKHR = null,
    vkGetPhysicalDeviceSurfaceSupportKHR: ?vk.PfnGetPhysicalDeviceSurfaceSupportKHR = null,
    vkGetPhysicalDeviceSurfaceCapabilities2KHR: ?vk.PfnGetPhysicalDeviceSurfaceCapabilities2KHR = null,
    vkGetPhysicalDeviceSurfaceFormats2KHR: ?vk.PfnGetPhysicalDeviceSurfaceFormats2KHR = null,
    vkGetPhysicalDeviceSurfacePresentModesKHR: ?vk.PfnGetPhysicalDeviceSurfacePresentModesKHR = null,
    vkCreateWaylandSurfaceKHR: ?vk.PfnCreateWaylandSurfaceKHR = null,
    vkCreateWin32SurfaceKHR: ?vk.PfnCreateWin32SurfaceKHR = null,
};

/// Device-level commands owned by the demo host.
const DeviceTable = struct {
    vkDestroyDevice: ?vk.PfnDestroyDevice = null,
    vkCreateSwapchainKHR: ?vk.PfnCreateSwapchainKHR = null,
    vkDestroySwapchainKHR: ?vk.PfnDestroySwapchainKHR = null,
    vkGetSwapchainImagesKHR: ?vk.PfnGetSwapchainImagesKHR = null,
    vkAcquireNextImage2KHR: ?vk.PfnAcquireNextImage2KHR = null,
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
    vkGetDeviceQueue2: ?vk.PfnGetDeviceQueue2 = null,
    vkQueueSubmit2: ?vk.PfnQueueSubmit2 = null,
    vkQueuePresentKHR: ?vk.PfnQueuePresentKHR = null,
    vkCmdBeginRendering: ?vk.PfnCmdBeginRendering = null,
    vkCmdEndRendering: ?vk.PfnCmdEndRendering = null,
    vkCmdPipelineBarrier2: ?vk.PfnCmdPipelineBarrier2 = null,
};

pub const BaseDispatch = vk.BaseWrapperWithCustomDispatch(BaseDispatchTable);
pub const InstanceDispatch = vk.InstanceWrapperWithCustomDispatch(InstanceTable);
pub const DeviceDispatch = vk.DeviceWrapperWithCustomDispatch(DeviceTable);

pub fn validateInstanceDispatch(idisp: InstanceDispatch) !void {
    if (idisp.dispatch.vkDestroyInstance == null or
        idisp.dispatch.vkEnumeratePhysicalDevices == null or
        idisp.dispatch.vkGetPhysicalDeviceProperties == null or
        idisp.dispatch.vkGetPhysicalDeviceQueueFamilyProperties == null or
        idisp.dispatch.vkCreateDevice == null or
        idisp.dispatch.vkGetDeviceProcAddr == null or
        idisp.dispatch.vkDestroySurfaceKHR == null or
        idisp.dispatch.vkGetPhysicalDeviceSurfaceSupportKHR == null or
        idisp.dispatch.vkGetPhysicalDeviceSurfaceCapabilities2KHR == null or
        idisp.dispatch.vkGetPhysicalDeviceSurfaceFormats2KHR == null or
        idisp.dispatch.vkGetPhysicalDeviceSurfacePresentModesKHR == null)
    {
        return error.MissingModernWsiCommand;
    }
}

pub fn validateDeviceDispatch(ddisp: DeviceDispatch) !void {
    if (ddisp.dispatch.vkDestroyDevice == null or
        ddisp.dispatch.vkCreateSwapchainKHR == null or
        ddisp.dispatch.vkDestroySwapchainKHR == null or
        ddisp.dispatch.vkGetSwapchainImagesKHR == null or
        ddisp.dispatch.vkAcquireNextImage2KHR == null or
        ddisp.dispatch.vkCreateImageView == null or
        ddisp.dispatch.vkDestroyImageView == null or
        ddisp.dispatch.vkCreateCommandPool == null or
        ddisp.dispatch.vkDestroyCommandPool == null or
        ddisp.dispatch.vkAllocateCommandBuffers == null or
        ddisp.dispatch.vkResetCommandBuffer == null or
        ddisp.dispatch.vkBeginCommandBuffer == null or
        ddisp.dispatch.vkEndCommandBuffer == null or
        ddisp.dispatch.vkCreateFence == null or
        ddisp.dispatch.vkDestroyFence == null or
        ddisp.dispatch.vkWaitForFences == null or
        ddisp.dispatch.vkResetFences == null or
        ddisp.dispatch.vkCreateSemaphore == null or
        ddisp.dispatch.vkDestroySemaphore == null or
        ddisp.dispatch.vkGetDeviceQueue2 == null or
        ddisp.dispatch.vkQueueSubmit2 == null or
        ddisp.dispatch.vkQueuePresentKHR == null or
        ddisp.dispatch.vkCmdPipelineBarrier2 == null or
        ddisp.dispatch.vkCmdBeginRendering == null or
        ddisp.dispatch.vkCmdEndRendering == null)
    {
        return error.MissingModernDeviceCommand;
    }
}

test "Vulkan demo dispatch tables expose modern WSI, synchronization2, and dynamic rendering" {
    comptime {
        std.debug.assert(@hasField(BaseDispatchTable, "vkEnumerateInstanceExtensionProperties"));
        std.debug.assert(@hasField(InstanceTable, "vkGetPhysicalDeviceSurfaceCapabilities2KHR"));
        std.debug.assert(@hasField(InstanceTable, "vkGetPhysicalDeviceSurfaceFormats2KHR"));
        std.debug.assert(@hasField(DeviceTable, "vkAcquireNextImage2KHR"));
        std.debug.assert(@hasField(DeviceTable, "vkGetDeviceQueue2"));
        std.debug.assert(@hasField(DeviceTable, "vkQueueSubmit2"));
        std.debug.assert(@hasField(DeviceTable, "vkCmdBeginRendering"));
    }
}
