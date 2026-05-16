//! Metal demo entry point.

const std = @import("std");
const heavy_slug_metal = @import("heavy_slug_metal");
const glfw = @import("demo_glfw");
const demo_scene = @import("demo_scene");

const MetalHostHandle = opaque {};

extern fn hs_demo_metal_host_create(
    window: glfw.Window,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) ?*MetalHostHandle;
extern fn hs_demo_metal_host_destroy(host: *MetalHostHandle) void;
extern fn hs_demo_metal_host_device(host: *MetalHostHandle) *anyopaque;
extern fn hs_demo_metal_host_command_queue(host: *MetalHostHandle) *anyopaque;
extern fn hs_demo_metal_host_layer(host: *MetalHostHandle) *anyopaque;

pub fn main() !void {
    try glfw.init();
    defer glfw.terminate();

    const window = try glfw.createWindow(demo_scene.window_width, demo_scene.window_height, "heavy-slug Metal 4 demo");
    defer glfw.destroyWindow(window);
    glfw.setScrollCallback(window);

    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var error_buf: [2048]u8 = undefined;
    const host = hs_demo_metal_host_create(window, &error_buf, error_buf.len) orelse {
        std.log.err("Metal host init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
        return error.MetalHostInitFailed;
    };
    defer hs_demo_metal_host_destroy(host);

    var ctx = try heavy_slug_metal.Context.init(.{
        .device = hs_demo_metal_host_device(host),
        .command_queue = hs_demo_metal_host_command_queue(host),
        .layer = hs_demo_metal_host_layer(host),
    });
    defer ctx.deinit();

    var text_renderer = try heavy_slug_metal.Renderer.init(ctx, allocator, .{});
    defer text_renderer.deinit();

    const font = try text_renderer.loadFont(.{ .path = demo_scene.font_path }, .{ .size_px = demo_scene.font_size_px });

    var scene: demo_scene.Scene = .{};
    var last_time = glfw.getTime();
    var stats_log_time = last_time;

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;

        const now = glfw.getTime();
        const dt: f32 = @floatCast(now - last_time);
        last_time = now;

        const size = glfw.getFramebufferSize(window);
        if (size[0] == 0 or size[1] == 0) continue;

        const w: f32 = @floatFromInt(size[0]);
        const h: f32 = @floatFromInt(size[1]);
        scene.update(window, dt, now, w, h);

        var text_frame = try text_renderer.beginFrame();
        try scene.draw(&text_frame, font);
        _ = try text_frame.submit(.{
            .viewport = .{ size[0], size[1] },
            .projection = scene.projection(w, h),
            .clear_color = scene.clearColor(),
        });
        if (now - stats_log_time >= 1.0) {
            text_renderer.statsSnapshot().log();
            stats_log_time = now;
        }
    }
}
