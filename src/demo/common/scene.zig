//! Shared demo scene state and input handling.

const std = @import("std");
const heavy_slug = @import("heavy_slug");
const glfw = @import("demo_glfw");

pub const font_path: [*:0]const u8 = "assets/Inter-Regular.otf";
pub const font_size_px: u32 = 24;
pub const window_width: c_int = 1280;
pub const window_height: c_int = 720;

const lines = [_][]const u8{
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
const content_height: f32 = @as(f32, @floatFromInt(lines.len)) * line_height + 2 * margin;
const content_cx: f32 = content_width / 2;
const content_cy: f32 = content_height / 2;

const ViewState = struct {
    scale: f32 = 1.0,
    pan_x: f32 = 0,
    pan_y: f32 = 0,
};

pub const Scene = struct {
    view: ViewState = .{},
    view_initialized: bool = false,
    dark_mode: bool = false,
    b_was_pressed: bool = false,
    r_was_pressed: bool = false,
    space_was_pressed: bool = false,

    left_down: bool = false,
    right_down: bool = false,
    dragged: bool = false,
    last_cursor: [2]f64 = .{ 0, 0 },
    begin_cursor: [2]f64 = .{ 0, 0 },

    rotation_angle: f32 = 0,
    rotation_speed: f32 = 1.0,
    animate: bool = false,
    last_drag_time: f64 = 0,
    drag_angle_delta: f32 = 0,
    drag_dt: f64 = 0,

    pub fn update(self: *Scene, window: glfw.Window, dt: f32, now: f64, width: f32, height: f32) void {
        if (width <= 0 or height <= 0) return;

        if (!self.view_initialized) {
            self.view = contentFit(width, height);
            self.view_initialized = true;
        }

        const b_pressed = glfw.getKey(window, glfw.KEY_B);
        if (b_pressed and !self.b_was_pressed) self.dark_mode = !self.dark_mode;
        self.b_was_pressed = b_pressed;

        const r_pressed = glfw.getKey(window, glfw.KEY_R);
        if (r_pressed and !self.r_was_pressed) {
            self.view = contentFit(width, height);
            self.rotation_angle = 0;
            self.animate = false;
        }
        self.r_was_pressed = r_pressed;

        const space_pressed = glfw.getKey(window, glfw.KEY_SPACE);
        if (space_pressed and !self.space_was_pressed) self.animate = !self.animate;
        self.space_was_pressed = space_pressed;

        const pan_speed: f32 = 400 / self.view.scale;
        if (glfw.getKey(window, glfw.KEY_UP)) self.view.pan_y += pan_speed * dt;
        if (glfw.getKey(window, glfw.KEY_DOWN)) self.view.pan_y -= pan_speed * dt;
        if (glfw.getKey(window, glfw.KEY_LEFT)) self.view.pan_x += pan_speed * dt;
        if (glfw.getKey(window, glfw.KEY_RIGHT)) self.view.pan_x -= pan_speed * dt;

        if (glfw.getKey(window, glfw.KEY_EQUAL)) self.view.scale *= 1.0 + 2.0 * dt;
        if (glfw.getKey(window, glfw.KEY_MINUS)) self.view.scale *= 1.0 - 2.0 * dt;

        const scroll = glfw.consumeScrollDelta();
        if (scroll != 0) {
            const cur = glfw.getCursorPos(window);
            const sx: f32 = @floatCast(cur[0]);
            const sy: f32 = @floatCast(cur[1]);
            const old_scale = self.view.scale;
            const factor: f32 = @floatCast(std.math.pow(f64, 1.1, scroll));
            self.view.scale *= factor;
            const inv_new = 1.0 / self.view.scale;
            const inv_old = 1.0 / old_scale;
            self.view.pan_x += sx * (inv_new - inv_old);
            self.view.pan_y += (height - sy) * (inv_new - inv_old);
        }

        self.updateMouse(window, now, width, height);
        if (self.animate) self.rotation_angle += self.rotation_speed * dt;
    }

    pub fn clearColor(self: Scene) [4]f32 {
        return if (self.dark_mode) .{ 0, 0, 0, 1 } else .{ 1, 1, 1, 1 };
    }

    pub fn textColor(self: Scene) heavy_slug.Color {
        return if (self.dark_mode) .white else .black;
    }

    pub fn projection(self: Scene, width: f32, height: f32) [4][4]f32 {
        const vp = viewProjection(width, height, self.view);
        return heavy_slug.Transform.rotationAbout(self.rotation_angle, content_cx, content_cy)
            .toProjectionMatrix(vp);
    }

    pub fn draw(self: Scene, renderer: anytype, font: anytype) !void {
        const fg = self.textColor();
        for (lines, 0..) |line, i| {
            if (line.len == 0) continue;
            const y = content_height - margin - @as(f32, @floatFromInt(i)) * line_height;
            try renderer.drawText(.{
                .font = font,
                .text = line,
                .transform = heavy_slug.Transform.translation(margin, y),
                .color = fg,
            });
        }
    }

    fn updateMouse(self: *Scene, window: glfw.Window, now: f64, width: f32, height: f32) void {
        const cursor = glfw.getCursorPos(window);
        const left_now = glfw.getMouseButton(window, glfw.MOUSE_BUTTON_LEFT);
        const right_now = glfw.getMouseButton(window, glfw.MOUSE_BUTTON_RIGHT);

        if (left_now and !self.left_down) {
            self.begin_cursor = cursor;
            self.dragged = false;
        }

        if (left_now and self.left_down) {
            const dx = cursor[0] - self.last_cursor[0];
            const dy = cursor[1] - self.last_cursor[1];
            self.updateDragState(cursor);
            if (self.dragged) {
                self.view.pan_x += @as(f32, @floatCast(dx)) / self.view.scale;
                self.view.pan_y -= @as(f32, @floatCast(dy)) / self.view.scale;
            }
        }

        if (!left_now and self.left_down and !self.dragged) self.animate = !self.animate;

        if (right_now and !self.right_down) {
            if (self.animate) self.animate = false;
            self.begin_cursor = cursor;
            self.dragged = false;
            self.drag_angle_delta = 0;
            self.drag_dt = 0;
            self.last_drag_time = now;
        }

        if (right_now and self.right_down) {
            self.updateDragState(cursor);
            if (self.dragged) {
                const half_w: f64 = @as(f64, width) * 0.5;
                const half_h: f64 = @as(f64, height) * 0.5;
                const prev_angle = std.math.atan2(self.last_cursor[1] - half_h, self.last_cursor[0] - half_w);
                const curr_angle = std.math.atan2(cursor[1] - half_h, cursor[0] - half_w);
                const delta: f32 = @floatCast(curr_angle - prev_angle);
                self.rotation_angle += delta;
                self.drag_angle_delta = delta;
                self.drag_dt = now - self.last_drag_time;
            }
            self.last_drag_time = now;
        }

        if (!right_now and self.right_down and self.dragged and self.drag_dt > 0) {
            const speed: f32 = @abs(self.drag_angle_delta) / @as(f32, @floatCast(self.drag_dt));
            if (speed > 0.1) {
                self.rotation_speed = if (self.drag_angle_delta >= 0) speed else -speed;
                self.animate = true;
            }
        }

        self.left_down = left_now;
        self.right_down = right_now;
        self.last_cursor = cursor;
    }

    fn updateDragState(self: *Scene, cursor: [2]f64) void {
        if (self.dragged) return;
        const total_dx = cursor[0] - self.begin_cursor[0];
        const total_dy = cursor[1] - self.begin_cursor[1];
        if (total_dx * total_dx + total_dy * total_dy > 25) self.dragged = true;
    }
};

fn contentFit(width: f32, height: f32) ViewState {
    const s = 0.9 * @min(width / content_width, height / content_height);
    return .{
        .scale = s,
        .pan_x = width / (2 * s) - content_width / 2,
        .pan_y = height / (2 * s) - content_height / 2,
    };
}

fn viewProjection(width: f32, height: f32, view: ViewState) [4][4]f32 {
    return .{
        .{ 2.0 * view.scale / width, 0, 0, 0 },
        .{ 0, 2.0 * view.scale / height, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ -1.0 + 2.0 * view.scale * view.pan_x / width, -1.0 + 2.0 * view.scale * view.pan_y / height, 0, 1 },
    };
}

test "demo scene exposes shared content settings" {
    try std.testing.expect(lines.len > 1);
    try std.testing.expect(content_width > 0);
    try std.testing.expect(content_height > 0);
}

test "demo scene projection keeps glyph outlines y-up" {
    const view = contentFit(window_width, window_height);
    const proj = viewProjection(window_width, window_height, view);
    try std.testing.expect(proj[1][1] > 0);
}
