//! Thin GLFW wrapper for the demo executable.
//! Vulkan-related GLFW functions are declared as manual externs to avoid
//! including vulkan.h (which would conflict with vulkan-zig types).

const vk = @import("vulkan");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "");
    @cInclude("GLFW/glfw3.h");
});

// --- Manual Vulkan externs (avoids vulkan.h type conflicts) ---

extern fn glfwGetInstanceProcAddress(instance: vk.Instance, procname: [*:0]const u8) ?vk.PfnVoidFunction;
extern fn glfwCreateWindowSurface(instance: vk.Instance, window: *c.GLFWwindow, allocator: ?*const anyopaque, surface: *vk.SurfaceKHR) vk.Result;

// --- Public API ---

pub const Window = *c.GLFWwindow;

pub const Error = error{
    GlfwInitFailed,
    WindowCreationFailed,
    SurfaceCreationFailed,
    VulkanNotSupported,
};

pub fn init() Error!void {
    if (c.glfwInit() != c.GLFW_TRUE) return error.GlfwInitFailed;
}

pub fn terminate() void {
    c.glfwTerminate();
}

pub fn vulkanSupported() bool {
    return c.glfwVulkanSupported() == c.GLFW_TRUE;
}

pub fn createWindow(width: c_int, height: c_int, title: [*:0]const u8) Error!Window {
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    c.glfwWindowHint(c.GLFW_RESIZABLE, c.GLFW_TRUE);
    return c.glfwCreateWindow(width, height, title, null, null) orelse
        return error.WindowCreationFailed;
}

pub fn destroyWindow(window: Window) void {
    c.glfwDestroyWindow(window);
}

pub fn shouldClose(window: Window) bool {
    return c.glfwWindowShouldClose(window) == c.GLFW_TRUE;
}

pub fn pollEvents() void {
    c.glfwPollEvents();
}

pub fn getFramebufferSize(window: Window) [2]u32 {
    var w: c_int = 0;
    var h: c_int = 0;
    c.glfwGetFramebufferSize(window, &w, &h);
    return .{ @intCast(w), @intCast(h) };
}

/// Returns the Vulkan instance extensions required by GLFW.
/// The returned slice points to GLFW-managed static memory — valid until
/// `terminate()` is called. Do not free the slice or the string pointers.
pub fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    var count: u32 = 0;
    const exts = c.glfwGetRequiredInstanceExtensions(&count) orelse return &.{};
    // GLFW guarantees all returned extension names are null-terminated C strings.
    return @ptrCast(exts[0..count]);
}

/// Loader function compatible with vulkan-zig's dispatch .load() methods.
pub fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) ?vk.PfnVoidFunction {
    return glfwGetInstanceProcAddress(instance, name);
}

pub fn createSurface(instance: vk.Instance, window: Window) Error!vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    const result = glfwCreateWindowSurface(instance, window, null, &surface);
    if (result != .success) return error.SurfaceCreationFailed;
    return surface;
}

pub fn getTime() f64 {
    return c.glfwGetTime();
}

pub fn getKey(window: Window, key: c_int) bool {
    return c.glfwGetKey(window, key) == c.GLFW_PRESS;
}

pub const KEY_ESCAPE = c.GLFW_KEY_ESCAPE;
pub const KEY_SPACE = c.GLFW_KEY_SPACE;
