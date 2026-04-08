const std = @import("std");
const heavy_slug = @import("heavy_slug");
const glfw = @import("demo/glfw.zig");

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) return error.VulkanNotSupported;

    const window = try glfw.createWindow(1024, 768, "heavy-slug demo");
    defer glfw.destroyWindow(window);

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
    }
}
