const std = @import("std");
const heavy_slug = @import("heavy_slug");
const glfw = @import("demo/glfw.zig");
const demo_vk = @import("demo/vulkan.zig");
const pga = heavy_slug.pga;
const renderer_mod = heavy_slug.renderer;

const lorem_lines = [_][]const u8{
    "Lorem ipsum dolor sit amet, consectetur adipiscing elit. Nullam tincidunt nibh",
    "quis semper malesuada. Mauris sit amet metus sed tellus gravida maximus sit",
    "amet a enim. Morbi et lorem congue, aliquam lorem vitae, condimentum erat.",
    "Mauris aliquet, sapien consequat blandit mattis, velit ante molestie mi, ac",
    "condimentum justo leo sed odio. Curabitur at suscipit quam.",
    "",
    "Ut ac convallis ante, at sollicitudin sapien. Nulla pellentesque felis id mi",
    "blandit dictum. Phasellus ultrices, odio non volutpat tincidunt, neque quam",
    "tristique lacus, nec gravida nulla ante id risus. Nulla sit amet bibendum",
    "lectus, sed bibendum lectus. Vivamus ultrices metus sit amet sapien posuere",
    "volutpat. Suspendisse luctus non mauris nec iaculis.",
    "",
    "Duis mattis enim libero, ac malesuada tortor gravida tempor. Cras sagittis",
    "felis at sollicitudin fermentum. Duis et ipsum bibendum, viverra felis quis,",
    "consectetur lacus. Donec vulputate risus imperdiet, tincidunt purus nec,",
    "vestibulum lorem. Morbi iaculis tincidunt rutrum.",
    "",
    "Duis sit amet nulla ut lectus efficitur suscipit. Curabitur urna turpis,",
    "congue lacinia varius vitae, interdum vel dolor. Vestibulum sit amet suscipit",
    "arcu, sit amet tincidunt ipsum. Maecenas feugiat ante vel fermentum viverra.",
    "Sed aliquam sem ac quam bibendum, sit amet fringilla augue pharetra.",
    "",
    "Morbi scelerisque tempus purus, interdum tempor est pulvinar bibendum. Duis",
    "tincidunt dictum ante vel sodales. Fusce quis cursus metus. Pellentesque mi",
    "mauris, tincidunt ut orci ut, interdum dapibus dolor. Aliquam blandit, nisl",
    "et rhoncus laoreet, tellus nulla blandit tellus, sit amet cursus magna enim",
    "nec ante. Integer venenatis a est sed hendrerit.",
    "",
    "Proin id porttitor turpis, aliquam tempus ex. Morbi tristique, felis ut",
    "aliquet luctus, orci tortor sodales sem, vel imperdiet justo tortor sit amet",
    "arcu. Quisque ipsum sem, lacinia in fermentum eu, maximus in lectus.",
};

const line_height: f32 = 32;
const margin: f32 = 40;
const content_width: f32 = 1100;
const content_height: f32 = @as(f32, @floatFromInt(lorem_lines.len)) * line_height + 2 * margin;

/// Compute scale + pan that centers the text block at 90% of viewport.
fn contentFit(vw: f32, vh: f32) struct { scale: f32, pan_x: f32, pan_y: f32 } {
    const s = 0.9 * @min(vw / content_width, vh / content_height);
    return .{
        .scale = s,
        .pan_x = vw / (2 * s) - content_width / 2,
        .pan_y = content_height / 2 - vh / (2 * s),
    };
}

pub fn main() !void {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    try glfw.init();
    defer glfw.terminate();
    if (!glfw.vulkanSupported()) return error.VulkanNotSupported;

    const window = try glfw.createWindow(1280, 720, "heavy-slug demo");
    defer glfw.destroyWindow(window);
    glfw.setScrollCallback(window);

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

    const font = try text_renderer.loadFont("assets/Inter-Regular.otf", 24);
    const font_ui = try text_renderer.loadFont("assets/Inter-Regular.otf", 16);

    // View state — content-fit applied on first frame once viewport size is known.
    var scale: f32 = 1.0;
    var pan_x: f32 = 0;
    var pan_y: f32 = 0;
    var view_initialized = false;
    var dark_mode = false;
    var b_was_pressed = false;
    var r_was_pressed = false;

    // Mouse drag state
    var dragging = false;
    var last_cursor: [2]f64 = .{ 0, 0 };

    // FPS counter state
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

        // FPS — update display every second.
        frame_count += 1;
        fps_timer += dt;
        if (fps_timer >= 1.0) {
            const fps = @as(f64, @floatFromInt(frame_count)) / fps_timer;
            if (std.fmt.bufPrint(&fps_buf, "{d:.0} fps", .{fps})) |s| {
                fps_len = s.len;
            } else |_| {
                fps_len = 0;
            }
            frame_count = 0;
            fps_timer = 0;
        }

        const w: f32 = @floatFromInt(gctx.swapchain_extent.width);
        const h: f32 = @floatFromInt(gctx.swapchain_extent.height);

        // Apply content-fit on the first frame once viewport size is known.
        if (!view_initialized) {
            const fit = contentFit(w, h);
            scale = fit.scale;
            pan_x = fit.pan_x;
            pan_y = fit.pan_y;
            view_initialized = true;
        }

        // Dark mode toggle (b key, edge-triggered).
        const b_pressed = glfw.getKey(window, glfw.KEY_B);
        if (b_pressed and !b_was_pressed) {
            dark_mode = !dark_mode;
            gctx.clear_color = if (dark_mode) .{ 0, 0, 0, 1 } else .{ 1, 1, 1, 1 };
        }
        b_was_pressed = b_pressed;

        // View reset (r key, edge-triggered).
        const r_pressed = glfw.getKey(window, glfw.KEY_R);
        if (r_pressed and !r_was_pressed) {
            const fit = contentFit(w, h);
            scale = fit.scale;
            pan_x = fit.pan_x;
            pan_y = fit.pan_y;
        }
        r_was_pressed = r_pressed;

        // Arrow key pan.
        const pan_speed: f32 = 400 / scale;
        if (glfw.getKey(window, glfw.KEY_UP)) pan_y += pan_speed * dt;
        if (glfw.getKey(window, glfw.KEY_DOWN)) pan_y -= pan_speed * dt;
        if (glfw.getKey(window, glfw.KEY_LEFT)) pan_x += pan_speed * dt;
        if (glfw.getKey(window, glfw.KEY_RIGHT)) pan_x -= pan_speed * dt;

        // +/- keyboard zoom.
        if (glfw.getKey(window, glfw.KEY_EQUAL)) scale *= 1.0 + 2.0 * dt;
        if (glfw.getKey(window, glfw.KEY_MINUS)) scale *= 1.0 - 2.0 * dt;
        scale = std.math.clamp(scale, 0.1, 20.0);

        // Scroll zoom — around cursor position.
        const scroll = glfw.consumeScrollDelta();
        if (scroll != 0) {
            const cursor = glfw.getCursorPos(window);
            const sx: f32 = @floatCast(cursor[0]);
            const sy: f32 = @floatCast(cursor[1]);
            const old_scale = scale;
            const factor: f32 = @floatCast(std.math.pow(f64, 1.1, scroll));
            scale = std.math.clamp(scale * factor, 0.1, 20.0);
            // Adjust pan so the world point under the cursor stays fixed.
            const inv_new = 1.0 / scale;
            const inv_old = 1.0 / old_scale;
            pan_x += sx * (inv_new - inv_old);
            pan_y += (h - sy) * (inv_old - inv_new);
        }

        // Mouse drag pan.
        {
            const cursor = glfw.getCursorPos(window);
            if (glfw.getMouseButton(window, glfw.MOUSE_BUTTON_LEFT)) {
                if (dragging) {
                    pan_x += @as(f32, @floatCast(cursor[0] - last_cursor[0])) / scale;
                    pan_y -= @as(f32, @floatCast(cursor[1] - last_cursor[1])) / scale;
                }
                dragging = true;
            } else {
                dragging = false;
            }
            last_cursor = cursor;
        }

        const frame = try gctx.beginFrame() orelse {
            try gctx.recreateSwapchain(window);
            continue;
        };

        const viewport = [2]f32{ w, h };
        const fg: [4]f32 = if (dark_mode) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 1 };

        // Pass 1: Lorem ipsum in fixed world space with view transform (pan/zoom).
        text_renderer.begin();
        for (lorem_lines, 0..) |line, i| {
            if (line.len == 0) continue;
            const y = content_height - margin - @as(f32, @floatFromInt(i)) * line_height;
            try text_renderer.drawText(font, line, pga.Motor.fromTranslation(margin, y), fg);
        }
        text_renderer.flush(frame.cmd, viewProjection(w, h, scale, pan_x, pan_y), viewport);

        // Pass 2: FPS overlay — fixed screen position, no pan/zoom.
        if (fps_len > 0) {
            text_renderer.begin();
            const fps_fg: [4]f32 = .{ 0.5, 0.5, 0.5, 1.0 };
            try text_renderer.drawText(font_ui, fps_buf[0..fps_len], pga.Motor.fromTranslation(w - 90, h - 20), fps_fg);
            text_renderer.flush(frame.cmd, orthoProjection(w, h), viewport);
        }

        try gctx.endFrame(frame);
    }
    gctx.demo_ddisp.deviceWaitIdle(gctx.device) catch {};
}

/// Orthographic projection with pan and zoom baked in.
/// Text in world space is scaled and translated to fill the viewport.
fn viewProjection(w: f32, h: f32, scale: f32, pan_x: f32, pan_y: f32) [4][4]f32 {
    return .{
        .{ 2.0 * scale / w, 0, 0, 0 },
        .{ 0, -2.0 * scale / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1.0 + 2.0 * scale * pan_x / w, 1.0 + 2.0 * scale * pan_y / h, 0, 1 },
    };
}

/// Plain orthographic projection: maps (0,0)..(w,h) to Vulkan clip space.
/// Used for fixed-screen overlays (FPS counter) that must not pan or zoom.
fn orthoProjection(w: f32, h: f32) [4][4]f32 {
    return .{
        .{ 2.0 / w, 0, 0, 0 },
        .{ 0, -2.0 / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1, 1, 0, 1 },
    };
}
