//! Vulkan demo entry point.

const std = @import("std");
const heavy_slug_vulkan = @import("heavy_slug_vulkan");
const demo_platform = @import("demo_platform");
const demo_scene = @import("demo_scene");
const demo_vk = @import("host.zig");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window: demo_platform.Window = .{};
    try window.init(allocator, demo_scene.window_width, demo_scene.window_height, "heavy-slug Vulkan demo");
    defer window.deinit();

    var host = try demo_vk.Host.init(&window, allocator);
    defer host.deinit();
    try host.createSwapchain(&window);

    var text_renderer = try heavy_slug_vulkan.Renderer.init(
        host.renderer_context,
        host.surface_format.format,
        allocator,
        .{},
    );
    defer text_renderer.deinit();

    const font = try text_renderer.loadFont(.{ .path = demo_scene.font_path }, .{ .size_px = demo_scene.font_size_px });

    var scene: demo_scene.Scene = .{};
    var submitted_text_tokens = [_]heavy_slug_vulkan.FrameToken{0} ** demo_vk.Host.frames_in_flight;
    var last_time = window.time();
    var stats_log_time = last_time;

    while (!window.should_close) {
        window.pollEvents();
        if (window.should_close or window.input().getKey(.escape)) break;

        const fb_size = window.framebufferSize();
        if (fb_size[0] != host.swapchain_extent.width or fb_size[1] != host.swapchain_extent.height) {
            try host.recreateSwapchain(&window);
        }

        const now = window.time();
        const dt: f32 = @floatCast(now - last_time);
        last_time = now;

        const w: f32 = @floatFromInt(host.swapchain_extent.width);
        const h: f32 = @floatFromInt(host.swapchain_extent.height);
        scene.update(window.input(), dt, now, w, h);
        window.setDarkMode(scene.dark_mode);
        host.clear_color = scene.clearColor();

        const frame = try host.beginFrame() orelse {
            try host.recreateSwapchain(&window);
            continue;
        };
        text_renderer.markFrameComplete(submitted_text_tokens[frame.frame_index]);
        if (heavy_slug_vulkan.shader_stats_enabled and now - stats_log_time >= 1.0) {
            text_renderer.statsSnapshot().log();
            stats_log_time = now;
        }

        var text_frame = try text_renderer.beginFrame(scene.frameView(w, h));
        try scene.draw(&text_frame, font);
        submitted_text_tokens[frame.frame_index] = try text_frame.submit(.{
            .command_buffer = frame.cmd,
        });

        if (try host.endFrame(frame)) {
            try host.recreateSwapchain(&window);
        }
    }
    host.demo_ddisp.deviceWaitIdle(host.device) catch {};
}
