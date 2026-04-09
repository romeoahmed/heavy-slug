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
const content_cx: f32 = margin + content_width / 2;
const content_cy: f32 = content_height / 2;

/// Compute scale + pan that centers the text block at 90% of viewport.
fn contentFit(vw: f32, vh: f32) struct { scale: f32, pan_x: f32, pan_y: f32 } {
    const s = 0.9 * @min(vw / content_width, vh / content_height);
    return .{
        .scale = s,
        .pan_x = vw / (2 * s) - content_width / 2,
        .pan_y = content_height / 2 - vh / (2 * s),
    };
}

/// Orthographic projection with pan and zoom baked in.
fn viewProjection(w: f32, h: f32, scale: f32, pan_x: f32, pan_y: f32) [4][4]f32 {
    return .{
        .{ 2.0 * scale / w, 0, 0, 0 },
        .{ 0, -2.0 * scale / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1.0 + 2.0 * scale * pan_x / w, 1.0 + 2.0 * scale * pan_y / h, 0, 1 },
    };
}

/// Plain orthographic projection: maps (0,0)..(w,h) to Vulkan clip space.
fn orthoProjection(w: f32, h: f32) [4][4]f32 {
    return .{
        .{ 2.0 / w, 0, 0, 0 },
        .{ 0, -2.0 / h, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1, 1, 0, 1 },
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
    const font_ui = try text_renderer.loadFont("assets/Inter-Regular.otf", 24);

    // --- View state ---
    var scale: f32 = 1.0;
    var pan_x: f32 = 0;
    var pan_y: f32 = 0;
    var view_initialized = false;
    var dark_mode = false;
    var b_was_pressed = false;
    var r_was_pressed = false;
    var space_was_pressed = false;

    // --- Mouse state ---
    var left_down: bool = false;
    var right_down: bool = false;
    var dragged = false;
    var last_cursor: [2]f64 = .{ 0, 0 };
    var begin_cursor: [2]f64 = .{ 0, 0 };

    // --- Rotation / animation ---
    // Modeled on hb-gpu-demo: right-drag captures angular velocity,
    // release-with-speed starts spin animation. Left-click / Space toggles.
    var rotation_angle: f32 = 0;
    var rotation_speed: f32 = 1.0; // rad/s, default spin speed
    var animate = false;

    // Right-drag rotation tracking
    var last_drag_time: f64 = 0;
    var drag_angle_delta: f32 = 0;
    var drag_dt: f64 = 0;

    // --- FPS ---
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
            fps_timer -= 1.0;
        }

        const w: f32 = @floatFromInt(gctx.swapchain_extent.width);
        const h: f32 = @floatFromInt(gctx.swapchain_extent.height);

        // Content-fit on first frame.
        if (!view_initialized and w > 0 and h > 0) {
            const fit = contentFit(w, h);
            scale = fit.scale;
            pan_x = fit.pan_x;
            pan_y = fit.pan_y;
            view_initialized = true;
        }

        // --- Keyboard ---

        // Dark mode toggle (B key, edge-triggered).
        {
            const pressed = glfw.getKey(window, glfw.KEY_B);
            if (pressed and !b_was_pressed) {
                dark_mode = !dark_mode;
                gctx.clear_color = if (dark_mode) .{ 0, 0, 0, 1 } else .{ 1, 1, 1, 1 };
            }
            b_was_pressed = pressed;
        }

        // Reset (R key, edge-triggered).
        {
            const pressed = glfw.getKey(window, glfw.KEY_R);
            if (pressed and !r_was_pressed) {
                const fit = contentFit(w, h);
                scale = fit.scale;
                pan_x = fit.pan_x;
                pan_y = fit.pan_y;
                rotation_angle = 0;
                animate = false;
            }
            r_was_pressed = pressed;
        }

        // Space = toggle animation (edge-triggered).
        {
            const pressed = glfw.getKey(window, glfw.KEY_SPACE);
            if (pressed and !space_was_pressed) animate = !animate;
            space_was_pressed = pressed;
        }

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

        // Scroll zoom.
        const scroll = glfw.consumeScrollDelta();
        if (scroll != 0) {
            const factor: f32 = @floatCast(std.math.pow(f64, 1.1, scroll));
            scale = std.math.clamp(scale * factor, 0.1, 20.0);
        }

        // --- Mouse ---
        const cursor = glfw.getCursorPos(window);
        const left_now = glfw.getMouseButton(window, glfw.MOUSE_BUTTON_LEFT);
        const right_now = glfw.getMouseButton(window, glfw.MOUSE_BUTTON_RIGHT);

        // Left button press edge.
        if (left_now and !left_down) {
            begin_cursor = cursor;
            dragged = false;
        }

        // Left button hold: drag pan.
        if (left_now and left_down) {
            const dx = cursor[0] - last_cursor[0];
            const dy = cursor[1] - last_cursor[1];
            if (!dragged) {
                const total_dx = cursor[0] - begin_cursor[0];
                const total_dy = cursor[1] - begin_cursor[1];
                if (total_dx * total_dx + total_dy * total_dy > 25) dragged = true;
            }
            if (dragged) {
                pan_x += @as(f32, @floatCast(dx)) / scale;
                pan_y -= @as(f32, @floatCast(dy)) / scale;
            }
        }

        // Left button release: click = toggle animation (if not dragged).
        if (!left_now and left_down and !dragged) {
            animate = !animate;
        }

        // Right button press edge.
        if (right_now and !right_down) {
            if (animate) {
                // Right-click while animating: stop.
                animate = false;
            }
            begin_cursor = cursor;
            dragged = false;
            drag_angle_delta = 0;
            drag_dt = 0;
            last_drag_time = now;
        }

        // Right button hold: rotate by dragging.
        if (right_now and right_down) {
            if (!dragged) {
                const total_dx = cursor[0] - begin_cursor[0];
                const total_dy = cursor[1] - begin_cursor[1];
                if (total_dx * total_dx + total_dy * total_dy > 25) dragged = true;
            }
            if (dragged) {
                // Compute angular delta from cursor movement around screen center.
                const half_w: f64 = @as(f64, @floatFromInt(gctx.swapchain_extent.width)) * 0.5;
                const half_h: f64 = @as(f64, @floatFromInt(gctx.swapchain_extent.height)) * 0.5;
                const prev_angle = std.math.atan2(last_cursor[1] - half_h, last_cursor[0] - half_w);
                const curr_angle = std.math.atan2(cursor[1] - half_h, cursor[0] - half_w);
                const delta: f32 = @floatCast(curr_angle - prev_angle);
                rotation_angle += delta;
                drag_angle_delta = delta;
                drag_dt = now - last_drag_time;
            }
            last_drag_time = now;
        }

        // Right button release: fling-to-spin if fast enough.
        if (!right_now and right_down) {
            if (dragged and drag_dt > 0) {
                const speed: f32 = @abs(drag_angle_delta) / @as(f32, @floatCast(drag_dt));
                if (speed > 0.1) {
                    rotation_speed = if (drag_angle_delta >= 0) speed else -speed;
                    animate = true;
                }
            }
        }

        left_down = left_now;
        right_down = right_now;
        last_cursor = cursor;

        // --- Animation ---
        if (animate) rotation_angle += rotation_speed * dt;

        // --- Render ---
        const frame = try gctx.beginFrame() orelse {
            try gctx.recreateSwapchain(window);
            continue;
        };

        const viewport = [2]f32{ w, h };
        const fg: [4]f32 = if (dark_mode) .{ 1, 1, 1, 1 } else .{ 0, 0, 0, 1 };

        // Pass 1: Lorem ipsum with pan/zoom/rotation.
        // Rotation is baked into the projection via Motor.toMat():
        //   proj_final = viewProjection x motor_matrix
        // This rotates the entire scene in world space around the content center.
        const vp = viewProjection(w, h, scale, pan_x, pan_y);
        const rot_motor = pga.Motor.fromRotationAbout(rotation_angle, content_cx, content_cy);
        const proj = rot_motor.toMat(vp);

        text_renderer.begin();
        for (lorem_lines, 0..) |line, i| {
            if (line.len == 0) continue;
            const y = content_height - margin - @as(f32, @floatFromInt(i)) * line_height;
            try text_renderer.drawText(font, line, pga.Motor.fromTranslation(margin, y), fg);
        }
        text_renderer.flush(frame.cmd, proj, viewport);

        // Pass 2: FPS overlay — fixed screen position, no pan/zoom.
        if (fps_len > 0) {
            const fps_fg: [4]f32 = .{ 0.5, 0.5, 0.5, 1.0 };
            try text_renderer.drawText(font_ui, fps_buf[0..fps_len], pga.Motor.fromTranslation(w - 120, h - 30), fps_fg);
            text_renderer.flush(frame.cmd, orthoProjection(w, h), viewport);
        }

        try gctx.endFrame(frame);
    }
    gctx.demo_ddisp.deviceWaitIdle(gctx.device) catch {};
}
