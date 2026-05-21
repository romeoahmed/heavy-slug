//! Shared demo scene state, sample content, FPS display, and input handling.

const std = @import("std");
const heavy_slug = @import("heavy_slug");
const demo_input = @import("demo_input");

pub const font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";
pub const font_size_px: u32 = 24;
pub const window_width: c_int = 1280;
pub const window_height: c_int = 720;

const content_margin: f64 = 48;
const content_width: f64 = 1180;
const body_advance: f64 = 34;
const title_advance: f64 = 54;
const subtitle_advance: f64 = 34;
const group_gap: f64 = 20;

const overlay_margin: f64 = 24;
const overlay_baseline_from_top: f64 = 28;
const overlay_scale: f64 = 0.76;

const TextTone = enum {
    title,
    subtitle,
    body,
    accent,
};

const TextLine = struct {
    text: []const u8,
    advance: f64 = body_advance,
    scale: f64 = 1.0,
    tone: TextTone = .body,
};

const sample_lines = [_]TextLine{
    .{
        .text = "heavy-slug multilingual demo",
        .advance = title_advance,
        .scale = 1.42,
        .tone = .title,
    },
    .{
        .text = "Noto Sans JP · analytic glyph coverage · pan, zoom, rotate",
        .advance = subtitle_advance,
        .scale = 0.86,
        .tone = .subtitle,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "English: resolution-independent text remains crisp while the view moves.",
        .tone = .body,
    },
    .{
        .text = "日本語: かなと漢字を同じパイプラインで描画します。",
        .tone = .accent,
    },
    .{
        .text = "中文: 漢字、假名、Latin、数字 0123456789。",
        .tone = .body,
    },
    .{
        .text = "Русский: кириллица проверяет контуры и кернинг.",
        .tone = .body,
    },
    .{
        .text = "Ελληνικά: γεωμετρία, χρώμα, κίνηση.",
        .tone = .body,
    },
    .{
        .text = "Español Français Português Deutsch: acción, façade, coração, Größe.",
        .tone = .body,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "Controls: drag to pan, right-drag to spin, wheel or +/- to zoom, B toggles appearance.",
        .advance = subtitle_advance,
        .scale = 0.84,
        .tone = .subtitle,
    },
};

const content_height: f64 = measureContentHeight();
const content_cx: f64 = content_width / 2;
const content_cy: f64 = content_height / 2;

pub const ColorScheme = enum {
    light,
    dark,

    pub fn isDark(self: ColorScheme) bool {
        return self == .dark;
    }

    fn toggled(self: ColorScheme) ColorScheme {
        return switch (self) {
            .light => .dark,
            .dark => .light,
        };
    }

    fn clearColor(self: ColorScheme) [4]f32 {
        return switch (self) {
            .light => .{ 0.965, 0.972, 0.965, 1 },
            .dark => .{ 0.026, 0.029, 0.032, 1 },
        };
    }

    fn color(self: ColorScheme, tone: TextTone) heavy_slug.Color {
        return switch (self) {
            .light => switch (tone) {
                .title => heavy_slug.Color.fromRgba(0.055, 0.07, 0.065, 1),
                .subtitle => heavy_slug.Color.fromRgba(0.33, 0.38, 0.36, 1),
                .body => heavy_slug.Color.fromRgba(0.105, 0.12, 0.112, 1),
                .accent => heavy_slug.Color.fromRgba(0.02, 0.34, 0.38, 1),
            },
            .dark => switch (tone) {
                .title => heavy_slug.Color.fromRgba(0.92, 0.95, 0.92, 1),
                .subtitle => heavy_slug.Color.fromRgba(0.63, 0.69, 0.66, 1),
                .body => heavy_slug.Color.fromRgba(0.82, 0.86, 0.83, 1),
                .accent => heavy_slug.Color.fromRgba(0.48, 0.86, 0.9, 1),
            },
        };
    }

    fn overlayColor(self: ColorScheme) heavy_slug.Color {
        return switch (self) {
            .light => heavy_slug.Color.fromRgba(0.06, 0.16, 0.16, 1),
            .dark => heavy_slug.Color.fromRgba(0.7, 0.92, 0.86, 1),
        };
    }
};

const ViewState = struct {
    scale: f64 = 1.0,
    pan_x: f64 = 0,
    pan_y: f64 = 0,
};

const FpsMeter = struct {
    sample_seconds: f64 = 0,
    sample_frames: u32 = 0,
    displayed_fps: f64 = 0,

    const sample_period_s: f64 = 0.5;

    fn update(self: *FpsMeter, dt: f64) void {
        if (!std.math.isFinite(dt) or dt <= 0) return;

        self.sample_seconds += dt;
        self.sample_frames += 1;
        if (self.sample_seconds >= sample_period_s) {
            self.publish();
        } else if (self.displayed_fps == 0) {
            self.displayed_fps = self.sampleRate();
        }
    }

    fn fps(self: FpsMeter) f64 {
        if (self.displayed_fps > 0) return self.displayed_fps;
        return self.sampleRate();
    }

    fn writeLabel(self: FpsMeter, buffer: []u8) []const u8 {
        const value = self.fps();
        if (!std.math.isFinite(value) or value <= 0) return "FPS --";
        return std.fmt.bufPrint(buffer, "FPS {d:.1}", .{value}) catch "FPS --";
    }

    fn publish(self: *FpsMeter) void {
        self.displayed_fps = self.sampleRate();
        self.sample_seconds = 0;
        self.sample_frames = 0;
    }

    fn sampleRate(self: FpsMeter) f64 {
        if (self.sample_seconds <= 0 or self.sample_frames == 0) return 0;
        return @as(f64, @floatFromInt(self.sample_frames)) / self.sample_seconds;
    }
};

pub const Scene = struct {
    view: ViewState = .{},
    view_initialized: bool = false,
    color_scheme: ColorScheme = .light,
    fps_meter: FpsMeter = .{},
    color_scheme_key_was_pressed: bool = false,
    r_was_pressed: bool = false,
    space_was_pressed: bool = false,

    left_down: bool = false,
    right_down: bool = false,
    dragged: bool = false,
    last_cursor: [2]f64 = .{ 0, 0 },
    begin_cursor: [2]f64 = .{ 0, 0 },

    rotation_angle: f64 = 0,
    rotation_speed: f64 = 1.0,
    animate: bool = false,
    last_drag_time: f64 = 0,
    drag_angle_delta: f64 = 0,
    drag_dt: f64 = 0,

    pub fn update(self: *Scene, input: *demo_input.State, dt: f32, now: f64, width: f32, height: f32) void {
        if (width <= 0 or height <= 0) return;
        const width64: f64 = width;
        const height64: f64 = height;
        const dt64: f64 = dt;
        self.fps_meter.update(dt64);

        if (!self.view_initialized) {
            self.view = contentFit(width64, height64);
            self.view_initialized = true;
        }

        self.updateColorScheme(input);

        const r_pressed = input.getKey(.r);
        if (r_pressed and !self.r_was_pressed) {
            self.view = contentFit(width64, height64);
            self.rotation_angle = 0;
            self.animate = false;
        }
        self.r_was_pressed = r_pressed;

        const space_pressed = input.getKey(.space);
        if (space_pressed and !self.space_was_pressed) self.animate = !self.animate;
        self.space_was_pressed = space_pressed;

        const pan_speed: f64 = 400 / self.view.scale;
        if (input.getKey(.up)) self.view.pan_y += pan_speed * dt64;
        if (input.getKey(.down)) self.view.pan_y -= pan_speed * dt64;
        if (input.getKey(.left)) self.view.pan_x += pan_speed * dt64;
        if (input.getKey(.right)) self.view.pan_x -= pan_speed * dt64;

        const keyboard_zoom = 2.0 * dt64;
        if (input.getKey(.equal)) self.zoomAt(width64 * 0.5, height64 * 0.5, 1.0 + keyboard_zoom);
        if (input.getKey(.minus)) self.zoomAt(width64 * 0.5, height64 * 0.5, @max(1.0 - keyboard_zoom, 0.001));

        const scroll = input.consumeScrollDelta();
        if (scroll != 0) {
            const cur = input.cursor;
            const factor: f64 = std.math.pow(f64, 1.1, scroll);
            self.zoomAt(cur[0], height64 - cur[1], factor);
        }

        self.updateMouse(input, now, width, height);
        if (self.animate) self.rotation_angle += self.rotation_speed * dt64;
    }

    pub fn darkModeEnabled(self: Scene) bool {
        return self.color_scheme.isDark();
    }

    pub fn clearColor(self: Scene) [4]f32 {
        return self.color_scheme.clearColor();
    }

    pub fn textColor(self: Scene) heavy_slug.Color {
        return self.color_scheme.color(.body);
    }

    pub fn currentFps(self: Scene) f64 {
        return self.fps_meter.fps();
    }

    pub fn frameView(self: Scene, width: f64, height: f64) heavy_slug.View {
        const view = viewTransform(self.view);
        const rotation = heavy_slug.Transform.rotationAbout(self.rotation_angle, content_cx, content_cy);
        return heavy_slug.View.init(width, height, heavy_slug.Transform.compose(view, rotation));
    }

    pub fn draw(self: Scene, renderer: anytype, font: anytype, view: heavy_slug.View) !void {
        try self.drawContent(renderer, font);
        try self.drawOverlay(renderer, font, view);
    }

    fn drawContent(self: Scene, renderer: anytype, font: anytype) !void {
        var y = content_height - content_margin;
        for (sample_lines) |line| {
            if (line.text.len != 0) {
                const text_from_local = heavy_slug.Transform.scale(line.scale, line.scale);
                const world_from_text = heavy_slug.Transform.compose(
                    heavy_slug.Transform.translation(content_margin, y),
                    text_from_local,
                );
                try renderer.drawText(.{
                    .font = font,
                    .text = line.text,
                    .transform = world_from_text,
                    .color = self.color_scheme.color(line.tone),
                });
            }
            y -= line.advance;
        }
    }

    fn drawOverlay(self: Scene, renderer: anytype, font: anytype, view: heavy_slug.View) !void {
        var label_buffer: [32]u8 = undefined;
        const label = self.fps_meter.writeLabel(&label_buffer);
        const screen_from_text = heavy_slug.Transform.compose(
            heavy_slug.Transform.translation(overlay_margin, view.height - overlay_baseline_from_top),
            heavy_slug.Transform.scale(overlay_scale, overlay_scale),
        );
        const world_from_text = screenSpaceTextTransform(view, screen_from_text) orelse return;
        try renderer.drawText(.{
            .font = font,
            .text = label,
            .transform = world_from_text,
            .color = self.color_scheme.overlayColor(),
        });
    }

    fn updateColorScheme(self: *Scene, input: *const demo_input.State) void {
        const pressed = input.getKey(.b);
        if (pressed and !self.color_scheme_key_was_pressed) {
            self.color_scheme = self.color_scheme.toggled();
        }
        self.color_scheme_key_was_pressed = pressed;
    }

    fn updateMouse(self: *Scene, input: *const demo_input.State, now: f64, width: f32, height: f32) void {
        const cursor = input.cursor;
        const left_now = input.getMouseButton(.left);
        const right_now = input.getMouseButton(.right);

        if (left_now and !self.left_down) {
            self.begin_cursor = cursor;
            self.dragged = false;
        }

        if (left_now and self.left_down) {
            const dx = cursor[0] - self.last_cursor[0];
            const dy = cursor[1] - self.last_cursor[1];
            self.updateDragState(cursor);
            if (self.dragged) {
                self.view.pan_x += dx / self.view.scale;
                self.view.pan_y -= dy / self.view.scale;
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
                const delta: f64 = curr_angle - prev_angle;
                self.rotation_angle += delta;
                self.drag_angle_delta = delta;
                self.drag_dt = now - self.last_drag_time;
            }
            self.last_drag_time = now;
        }

        if (!right_now and self.right_down and self.dragged and self.drag_dt > 0) {
            const speed: f64 = @abs(self.drag_angle_delta) / self.drag_dt;
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

    fn zoomAt(self: *Scene, screen_x: f64, screen_y_up: f64, factor: f64) void {
        if (!std.math.isFinite(factor) or factor <= 0) return;
        const old_scale = self.view.scale;
        const new_scale = old_scale * factor;
        if (!std.math.isFinite(new_scale) or new_scale <= 0) return;

        self.view.scale = new_scale;
        const inv_delta = 1.0 / new_scale - 1.0 / old_scale;
        self.view.pan_x += screen_x * inv_delta;
        self.view.pan_y += screen_y_up * inv_delta;
    }
};

fn measureContentHeight() f64 {
    var total = content_margin * 2;
    for (sample_lines) |line| total += line.advance;
    return total;
}

fn contentFit(width: f64, height: f64) ViewState {
    const s = 0.9 * @min(width / content_width, height / content_height);
    return .{
        .scale = s,
        .pan_x = width / (2 * s) - content_width / 2,
        .pan_y = height / (2 * s) - content_height / 2,
    };
}

fn viewTransform(view: ViewState) heavy_slug.Transform {
    return .{
        .xx = view.scale,
        .xy = 0,
        .yx = 0,
        .yy = view.scale,
        .tx = view.scale * view.pan_x,
        .ty = view.scale * view.pan_y,
    };
}

fn screenSpaceTextTransform(view: heavy_slug.View, screen_from_text: heavy_slug.Transform) ?heavy_slug.Transform {
    const world_from_screen = view.screen_from_world.inverse() orelse return null;
    return heavy_slug.Transform.compose(world_from_screen, screen_from_text);
}

test "demo scene exposes shared content settings" {
    try std.testing.expect(sample_lines.len > 1);
    try std.testing.expect(content_width > 0);
    try std.testing.expect(content_height > 0);
}

test "demo scene uses the multilingual Noto Sans JP asset" {
    try std.testing.expectEqualStrings("assets/NotoSansJP-Regular.otf", std.mem.span(font_path));
}

test "demo scene sample text covers supported scripts" {
    var saw_latin = false;
    var saw_japanese = false;
    var saw_cyrillic = false;
    var saw_greek = false;

    for (sample_lines) |line| {
        saw_latin = saw_latin or std.mem.indexOf(u8, line.text, "English") != null;
        saw_japanese = saw_japanese or std.mem.indexOf(u8, line.text, "日本語") != null;
        saw_cyrillic = saw_cyrillic or std.mem.indexOf(u8, line.text, "Русский") != null;
        saw_greek = saw_greek or std.mem.indexOf(u8, line.text, "Ελληνικά") != null;
    }

    try std.testing.expect(saw_latin);
    try std.testing.expect(saw_japanese);
    try std.testing.expect(saw_cyrillic);
    try std.testing.expect(saw_greek);
}

test "demo scene Noto font covers all sample text" {
    var system = try heavy_slug.core.font.FontSystem.init(std.testing.allocator);
    defer system.deinit();

    var loaded = try system.load(.{ .path = font_path }, .{ .size_px = font_size_px });
    defer loaded.deinit();

    var shape_plan = try heavy_slug.core.font.ShapePlan.init();
    defer shape_plan.deinit();

    for (sample_lines) |line| {
        if (line.text.len == 0) continue;
        const shaped = try loaded.shape(&shape_plan, line.text, .{});
        for (shaped.infos) |info| {
            try std.testing.expect(info.codepoint != 0);
        }
    }
}

test "demo scene frame view keeps glyph outlines y-up" {
    const view = contentFit(window_width, window_height);
    const frame_view = (Scene{ .view = view }).frameView(window_width, window_height);
    try std.testing.expect(frame_view.screen_from_world.yy > 0);
}

test "demo scene starts light and toggles color scheme only on B key edges" {
    var scene: Scene = .{};
    var input: demo_input.State = .{};

    try std.testing.expectEqual(ColorScheme.light, scene.color_scheme);
    try std.testing.expect(!scene.darkModeEnabled());
    try std.testing.expectEqual(ColorScheme.light.clearColor(), scene.clearColor());

    input.setKey(.b, true);
    scene.update(&input, 0, 0, window_width, window_height);
    try std.testing.expectEqual(ColorScheme.dark, scene.color_scheme);
    try std.testing.expect(scene.darkModeEnabled());

    scene.update(&input, 0, 0, window_width, window_height);
    try std.testing.expectEqual(ColorScheme.dark, scene.color_scheme);

    input.setKey(.b, false);
    scene.update(&input, 0, 0, window_width, window_height);
    input.setKey(.b, true);
    scene.update(&input, 0, 0, window_width, window_height);
    try std.testing.expectEqual(ColorScheme.light, scene.color_scheme);
    try std.testing.expect(!scene.darkModeEnabled());
}

test "demo scene fps meter reports sampled rate without allocating" {
    var meter: FpsMeter = .{};
    for (0..30) |_| meter.update(1.0 / 60.0);

    try std.testing.expectApproxEqAbs(@as(f64, 60), meter.fps(), 1.0e-9);

    var label_buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("FPS 60.0", meter.writeLabel(&label_buffer));
}

test "demo scene screen-space overlay cancels content transform" {
    const scene = Scene{
        .view = contentFit(window_width, window_height),
        .rotation_angle = 0.35,
    };
    const frame_view = scene.frameView(window_width, window_height);
    const screen_from_text = heavy_slug.Transform.compose(
        heavy_slug.Transform.translation(overlay_margin, @as(f64, @floatFromInt(window_height)) - overlay_baseline_from_top),
        heavy_slug.Transform.scale(overlay_scale, overlay_scale),
    );
    const world_from_text = screenSpaceTextTransform(frame_view, screen_from_text).?;
    const actual = heavy_slug.Transform.compose(frame_view.screen_from_world, world_from_text).apply(.{ 0, 0 });
    const expected = screen_from_text.apply(.{ 0, 0 });

    try std.testing.expectApproxEqAbs(expected[0], actual[0], 1.0e-9);
    try std.testing.expectApproxEqAbs(expected[1], actual[1], 1.0e-9);
}

test "demo scene zoom keeps the requested screen anchor stable" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
    };
    const anchor = [2]f64{
        @as(f64, @floatFromInt(window_width)) * 0.5,
        @as(f64, @floatFromInt(window_height)) * 0.5,
    };
    const world = viewTransform(scene.view).inverse().?.apply(anchor);

    scene.zoomAt(anchor[0], anchor[1], 0.5);

    const screen = viewTransform(scene.view).apply(world);
    try std.testing.expectApproxEqAbs(anchor[0], screen[0], 1.0e-9);
    try std.testing.expectApproxEqAbs(anchor[1], screen[1], 1.0e-9);
}
