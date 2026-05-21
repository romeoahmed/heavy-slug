//! Metal demo entry point.

const std = @import("std");
const heavy_slug_metal = @import("heavy_slug_metal");
const demo_platform = @import("demo_platform");
const demo_scene = @import("demo_scene");

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var window: demo_platform.Window = .{};
    try window.init(.{
        .width = demo_scene.window_width,
        .height = demo_scene.window_height,
        .title = "heavy-slug Metal 4 demo",
        .initial_color_scheme = .light,
    });
    defer window.deinit();

    const host = try window.metalHost();
    var ctx = try heavy_slug_metal.Context.init(.{
        .device = host.device,
        .command_queue = host.command_queue,
        .layer = host.layer,
    });
    defer ctx.deinit();

    var text_renderer = try heavy_slug_metal.Renderer.init(ctx, allocator, .{});
    defer text_renderer.deinit();

    const font = try text_renderer.loadFont(.{ .path = demo_scene.font_path }, .{ .size_px = demo_scene.font_size_px });

    var scene: demo_scene.Scene = .{};
    var last_time = window.time();
    var stats_log_time = last_time;

    while (!window.should_close) {
        try window.pollEvents();
        if (window.should_close or window.input().getKey(.escape)) break;

        const now = window.time();
        const dt = now - last_time;
        last_time = now;

        const size = window.framebufferSize();
        if (size[0] == 0 or size[1] == 0) continue;

        const frame_metrics = demo_scene.FrameMetrics.init(size[0], size[1], window.displayScale()) orelse continue;
        scene.update(window.input(), dt, now, frame_metrics);
        window.setColorScheme(if (scene.darkModeEnabled()) .dark else .light);

        const view = scene.frameView(frame_metrics);
        var text_frame = try text_renderer.beginFrame(view);
        var text_frame_open = true;
        errdefer if (text_frame_open) text_frame.discard();
        try scene.draw(&text_frame, font, view, frame_metrics);
        _ = try text_frame.submit(.{
            .clear_color = scene.clearColor(),
        });
        text_frame_open = false;
        if (heavy_slug_metal.shader_stats_enabled and now - stats_log_time >= 1.0) {
            text_renderer.stats().log();
            stats_log_time = now;
        }
    }
}
