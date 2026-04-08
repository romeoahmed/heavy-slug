const std = @import("std");
const heavy_slug = @import("heavy_slug");
const glfw = @import("demo/glfw.zig");
const demo_vk = @import("demo/vulkan.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();

    if (!glfw.vulkanSupported()) return error.VulkanNotSupported;

    const window = try glfw.createWindow(1280, 720, "heavy-slug demo");
    defer glfw.destroyWindow(window);

    var gctx = try demo_vk.GraphicsContext.init(window, allocator);
    defer gctx.deinit();

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;
    }
}
