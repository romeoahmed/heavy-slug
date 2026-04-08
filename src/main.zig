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
    var fps_buf: [32]u8 = undefined;
    var fps_len: usize = 0;

    while (!glfw.shouldClose(window)) {
        glfw.pollEvents();
        if (glfw.getKey(window, glfw.KEY_ESCAPE)) break;

        const now = glfw.getTime();
        const dt: f32 = @floatCast(now - last_time);
        last_time = now;

        frame_count += 1;
        fps_timer += dt;
        if (fps_timer >= 1.0) {
            const fps = @as(f64, @floatFromInt(frame_count)) / fps_timer;
            if (std.fmt.bufPrint(&fps_buf, "{d:.0} FPS", .{fps})) |s| {
                fps_len = s.len;
            } else |_| {
                fps_len = 0;
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

        // --- Title block (top) ---
        try text_renderer.drawText(font_large, "heavy-slug", pga.Motor.fromTranslation(40, h - 50), .{ 1.0, 1.0, 1.0, 1.0 });
        try text_renderer.drawText(font_small, "GPU text rendering via Vulkan mesh shaders", pga.Motor.fromTranslation(40, h - 90), .{ 0.6, 0.7, 0.9, 1.0 });

        // --- Feature list (left column, static) ---
        try text_renderer.drawText(font_small, "Slug algorithm: exact quadratic Bezier coverage", pga.Motor.fromTranslation(40, h - 160), .{ 0.8, 0.8, 0.8, 1.0 });
        try text_renderer.drawText(font_small, "HarfBuzz shaping + FreeType outlines", pga.Motor.fromTranslation(40, h - 190), .{ 0.8, 0.8, 0.8, 1.0 });
        try text_renderer.drawText(font_small, "Zero-alloc render loop", pga.Motor.fromTranslation(40, h - 220), .{ 0.8, 0.8, 0.8, 1.0 });

        // --- Animated section (center, below features) ---
        // Color cycling label
        const r = 0.5 + 0.5 * @sin(t);
        const g = 0.5 + 0.5 * @sin(t + 2.094);
        const b = 0.5 + 0.5 * @sin(t + 4.189);
        try text_renderer.drawText(font_medium, "Color cycling", pga.Motor.fromTranslation(40, h - 300), .{ r, g, b, 1.0 });

        // Bouncing text
        const bounce_y = h - 370 + 20.0 * @abs(@sin(t * 2.0));
        try text_renderer.drawText(font_medium, "Bounce!", pga.Motor.fromTranslation(40, bounce_y), .{ 1.0, 0.4, 0.5, 1.0 });

        // Rotating text (right side, well separated)
        const rot_motor = pga.Motor.compose(
            pga.Motor.fromTranslation(w * 0.7, h * 0.4),
            pga.Motor.fromRotation(t * 0.5),
        );
        try text_renderer.drawText(font_medium, "Spinning!", rot_motor, .{ 1.0, 0.8, 0.2, 1.0 });

        // --- FPS counter (top-right) ---
        if (fps_len > 0) {
            try text_renderer.drawText(font_medium, fps_buf[0..fps_len], pga.Motor.fromTranslation(w - 160, h - 50), .{ 0.3, 1.0, 0.3, 1.0 });
        }

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
