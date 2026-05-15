const std = @import("std");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const glfw = @import("demo_glfw");
const demo_scene = @import("demo_scene");
const demo_vk = @import("host.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();
    if (!glfw.vulkanSupported()) return error.VulkanNotSupported;

    const window = try glfw.createWindow(demo_scene.window_width, demo_scene.window_height, "heavy-slug Vulkan demo");
    defer glfw.destroyWindow(window);
    glfw.setScrollCallback(window);

    var gctx = try demo_vk.GraphicsContext.init(window, allocator);
    defer gctx.deinit();
    try gctx.createSwapchain(window);

    var text_renderer = try heavy_slug_vulkan.Renderer.init(
        gctx.vulkan_ctx,
        gctx.surface_format.format,
        allocator,
        .{},
    );
    defer text_renderer.deinit();

    const font = try text_renderer.loadFont(.{ .path = demo_scene.font_path }, .{ .size_px = demo_scene.font_size_px });

    var scene: demo_scene.Scene = .{};
    var submitted_text_tokens = [_]heavy_slug_vulkan.FrameToken{0} ** demo_vk.GraphicsContext.FRAMES_IN_FLIGHT;
    var last_time = glfw.getTime();

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;

        const now = glfw.getTime();
        const dt: f32 = @floatCast(now - last_time);
        last_time = now;

        const w: f32 = @floatFromInt(gctx.swapchain_extent.width);
        const h: f32 = @floatFromInt(gctx.swapchain_extent.height);
        scene.update(window, dt, now, w, h);
        gctx.clear_color = scene.clearColor();

        const frame = try gctx.beginFrame() orelse {
            try gctx.recreateSwapchain(window);
            continue;
        };
        text_renderer.markFrameComplete(submitted_text_tokens[frame.frame_index]);

        const viewport = [2]f32{ w, h };
        var text_frame = try text_renderer.beginFrame();
        try scene.draw(&text_frame, font);
        submitted_text_tokens[frame.frame_index] = try text_frame.submit(.{
            .command_buffer = frame.cmd,
            .projection = scene.projection(w, h),
            .viewport = viewport,
        });

        if (try gctx.endFrame(frame)) {
            try gctx.recreateSwapchain(window);
        }
    }
    gctx.demo_ddisp.deviceWaitIdle(gctx.device) catch {};
}
