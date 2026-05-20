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
        const dt: f32 = @floatCast(now - last_time);
        last_time = now;

        const size = window.framebufferSize();
        if (size[0] == 0 or size[1] == 0) continue;

        const w: f32 = @floatFromInt(size[0]);
        const h: f32 = @floatFromInt(size[1]);
        scene.update(window.input(), dt, now, w, h);
        window.setColorScheme(if (scene.darkModeEnabled()) .dark else .light);

        var text_frame = try text_renderer.beginFrame(scene.frameView(w, h));
        try scene.draw(&text_frame, font);
        _ = try text_frame.submit(.{
            .clear_color = scene.clearColor(),
        });
        if (heavy_slug_metal.shader_stats_enabled and now - stats_log_time >= 1.0) {
            text_renderer.stats().log();
            stats_log_time = now;
        }
    }
}
