const std = @import("std");
const heavy_slug = @import("heavy_slug");
const glfw = @import("demo/glfw.zig");
const demo_vk = @import("demo/vulkan.zig");
const pga = heavy_slug.pga;
const renderer_mod = heavy_slug.renderer;

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

    try gctx.createSwapchain(window);

    var text_renderer = try renderer_mod.TextRenderer.initFromContext(
        gctx.vulkan_ctx,
        gctx.surface_format.format,
        allocator,
        .{},
    );
    defer text_renderer.deinit();

    const font_large = try text_renderer.loadFont("assets/Inter-Regular.otf", 48);
    const font_medium = try text_renderer.loadFont("assets/Inter-Regular.otf", 28);
    const font_small = try text_renderer.loadFont("assets/Inter-Regular.otf", 18);

    var last_time = glfw.getTime();
    var frame_count: u32 = 0;
    var fps_timer: f64 = 0;
    var fps_text: [32]u8 = undefined;
    var fps_len: usize = 3;
    @memcpy(fps_text[0..3], "FPS");

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;

        const now = glfw.getTime();
        const dt: f32 = @floatCast(now - last_time);
        last_time = now;

        frame_count += 1;
        fps_timer += dt;
        if (fps_timer >= 1.0) {
            if (std.fmt.bufPrint(&fps_text, "{d:.0} FPS", .{@as(f64, @floatFromInt(frame_count)) / fps_timer})) |s| {
                fps_len = s.len;
            } else |_| {
                fps_len = 5;
                @memcpy(fps_text[0..5], "? FPS");
            }
            frame_count = 0;
            fps_timer = 0;
        }

        const frame = try gctx.beginFrame() orelse {
            try gctx.recreateSwapchain(window);
            continue;
        };

        const w: f32 = @floatFromInt(gctx.swapchain_extent.width);
        const h: f32 = @floatFromInt(gctx.swapchain_extent.height);
        const proj = orthoProjection(w, h);
        const viewport = [2]f32{ w, h };
        const t: f32 = @floatCast(now);

        text_renderer.begin();

        // === Static header ===
        try text_renderer.drawText(font_large, "heavy-slug", pga.Motor.fromTranslation(w * 0.5 - 140, h - 60), .{ 1.0, 1.0, 1.0, 1.0 });
        try text_renderer.drawText(font_medium, "GPU Text Rendering", pga.Motor.fromTranslation(w * 0.5 - 160, h - 110), .{ 0.6, 0.7, 0.9, 1.0 });

        // === Animated rotating text ===
        const rot_motor = pga.Motor.compose(
            pga.Motor.fromTranslation(w * 0.5, h * 0.45),
            pga.Motor.fromRotation(t * 0.5),
        );
        try text_renderer.drawText(font_medium, "Spinning!", rot_motor, .{ 1.0, 0.8, 0.2, 1.0 });

        // === Orbiting text ===
        const orbit_r: f32 = 120;
        const orbit_x = w * 0.5 + orbit_r * @cos(t * 1.2);
        const orbit_y = h * 0.35 + orbit_r * @sin(t * 1.2);
        try text_renderer.drawText(font_small, "orbiting", pga.Motor.fromTranslation(orbit_x, orbit_y), .{ 0.4, 1.0, 0.6, 1.0 });

        // === Bouncing text ===
        const bounce_y = h * 0.2 + 30.0 * @abs(@sin(t * 3.0));
        try text_renderer.drawText(font_medium, "Bounce!", pga.Motor.fromTranslation(60, bounce_y), .{ 1.0, 0.4, 0.5, 1.0 });

        // === Color cycling text ===
        const r = 0.5 + 0.5 * @sin(t);
        const g = 0.5 + 0.5 * @sin(t + 2.094);
        const b = 0.5 + 0.5 * @sin(t + 4.189);
        try text_renderer.drawText(font_small, "Slug algorithm: exact quadratic Bezier coverage", pga.Motor.fromTranslation(40, 80), .{ r, g, b, 1.0 });

        // === FPS counter (top-right area) ===
        try text_renderer.drawText(font_small, fps_text[0..fps_len], pga.Motor.fromTranslation(w - 100, h - 30), .{ 0.5, 1.0, 0.5, 1.0 });

        text_renderer.flush(frame.cmd, proj, viewport);
        try gctx.endFrame(frame);
    }
    gctx.demo_ddisp.deviceWaitIdle(gctx.device) catch {};
}

/// Orthographic projection: maps (0,0)..(w,h) to Vulkan clip space.
/// Origin at bottom-left, y increases upward.
/// Use motor y = h - offset_from_top for positions near the top.
fn orthoProjection(w: f32, h: f32) [4][4]f32 {
    return .{
        .{ 2.0 / w, 0, 0, 0 },
        .{ 0, -2.0 / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1, 1, 0, 1 },
    };
}
