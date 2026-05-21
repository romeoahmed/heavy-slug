//! Shared demo scene state, sample content, FPS display, and input handling.

const std = @import("std");
const heavy_slug = @import("heavy_slug");
const demo_input = @import("demo_input");

pub const font_path: [*:0]const u8 = "assets/NotoSansJP-Regular.otf";
pub const font_size_px: u32 = 24;
pub const window_width: c_int = 1280;
pub const window_height: c_int = 720;

const content_margin: f64 = 48;
const content_width: f64 = 1220;
const body_advance: f64 = 28;
const title_advance: f64 = 50;
const section_advance: f64 = 34;
const subtitle_advance: f64 = 30;
const group_gap: f64 = 18;
const body_scale: f64 = 0.84;

const overlay_margin: f64 = 24;
const overlay_baseline_from_top: f64 = 28;
const overlay_scale: f64 = 0.76;
const warning_first_baseline_from_top: f64 = 66;
const warning_line_advance: f64 = 26;
const warning_scale: f64 = 0.98;

const TextTone = enum {
    title,
    subtitle,
    body,
    accent,
};

const TextLine = struct {
    text: []const u8,
    advance: f64 = body_advance,
    scale: f64 = body_scale,
    tone: TextTone = .body,
};

const sample_lines = [_]TextLine{
    .{
        .text = "heavy-slug sample corpus",
        .advance = title_advance,
        .scale = 1.36,
        .tone = .title,
    },
    .{
        .text = "Noto Sans JP · analytic glyph coverage · multilingual outlines · pan, zoom, rotate",
        .advance = subtitle_advance,
        .scale = 0.76,
        .tone = .subtitle,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "Latin, spacing, punctuation",
        .advance = section_advance,
        .scale = 1.02,
        .tone = .accent,
    },
    .{
        .text = "English: resolution-independent text remains crisp while the view moves.",
        .tone = .body,
    },
    .{
        .text = "Kerning: AV WA To Yo Ta LT, VAWa, ToTo, office affine flow.",
        .tone = .body,
    },
    .{
        .text = "Ligatures: fi fl ffi, affine, office, efficient, shuffle, cliff.",
        .tone = .body,
    },
    .{
        .text = "Numbers: 0123456789 12.345e-6 1/2 3/4 99.9%.",
        .tone = .body,
    },
    .{
        .text = "Accents: naïve façade coöperate São Tomé Ångström; Größe, cœur, mañana.",
        .tone = .body,
    },
    .{
        .text = "Punctuation: “quotes” ‘marks’ — – … · • ※ 〒 〆 々.",
        .tone = .body,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "CJK and kana",
        .advance = section_advance,
        .scale = 1.02,
        .tone = .accent,
    },
    .{
        .text = "日本語: 回転・拡大・縮小しても輪郭は滑らかです。",
        .tone = .body,
    },
    .{
        .text = "かな: あいうえお アイウエオ ぱぴぷぺぽ キャッシュ、ビュー、メッシュ。",
        .tone = .body,
    },
    .{
        .text = "中文: 高精度向量文字，平移、縮放、旋轉都清晰。",
        .tone = .body,
    },
    .{
        .text = "繁體: 解析式覆蓋、曲線細分、像素中心與填充規則。",
        .tone = .body,
    },
    .{
        .text = "Fullwidth: ＡＢＣ１２３，。、：；？！「heavy-slug」《輪郭》【解析】",
        .tone = .body,
    },
    .{
        .text = "Counters: 一二三四五 六七八九十 百千万億兆、日月火水木金土。",
        .tone = .body,
    },
    .{
        .text = "Dense CJK: 永字八法、骨格、筆画、重心、曲率、輪郭、隙間。",
        .tone = .body,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "Greek and Cyrillic",
        .advance = section_advance,
        .scale = 1.02,
        .tone = .accent,
    },
    .{
        .text = "Greek: Ελληνικά γεωμετρία, τόνος, κύβος, Ωμέγα, π≈3.14159.",
        .tone = .body,
    },
    .{
        .text = "Cyrillic: Русский текст проверяет кернинг, контуры и движение.",
        .tone = .body,
    },
    .{
        .text = "Caps: ΑΒΓΔΕΖΗΘ ΙΚΛΜΝΞΟΠ ΡΣΤΥΦΧΨΩ · АБВГДЕЖЗ ИКЛМНОП РСТУФХЦЧШЩ.",
        .tone = .body,
    },
    .{
        .text = "Mixed cache: あああ 漢漢漢 ααα ЖЖЖ 000 OOO lIl, small kana ぁぃぅぇぉ.",
        .tone = .body,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "Symbols and outline stress",
        .advance = section_advance,
        .scale = 1.02,
        .tone = .accent,
    },
    .{
        .text = "Math: ∂x/∂t ∇·v ∑i √2 ∞ ≤ ≥ ≠ ≈ ±×÷, brackets 〈〉《》【】.",
        .tone = .body,
    },
    .{
        .text = "Scientific: matrix ATA, x^2+y^2=r^2, μm, nm, kg, ms, Hz, deg C.",
        .tone = .body,
    },
    .{
        .text = "Arrows: ← ↑ → ↓ ↔ ↕ ⇐ ⇒ ⇧ ⇩, pixel centers, h-bands, cubic spans.",
        .tone = .body,
    },
    .{
        .text = "Scale: tiny stems, large bowls, fractional DPI, subpixel motion, high zoom.",
        .tone = .body,
    },
    .{
        .text = "Diagnostics: glyph ids, byte offsets, meshlets, frame tokens, GPU stats.",
        .tone = .body,
    },
    .{
        .text = "Stress: IIIlll111, O0〇○, rn/m, cl/d, punctuation density !!! ??? ;;;.",
        .tone = .body,
    },
    .{ .text = "", .advance = group_gap },
    .{
        .text = "Controls",
        .advance = section_advance,
        .scale = 1.02,
        .tone = .accent,
    },
    .{
        .text = "Drag to pan, right-drag to spin, wheel or +/- to zoom.",
        .tone = .body,
    },
    .{
        .text = "B toggles light/dark, Space animates, R resets view, Esc quits.",
        .tone = .body,
    },
    .{
        .text = "Date: 2026-05-21 16:09:37 +08:00, #heavy-slug.",
        .tone = .body,
    },
};

const content_height: f64 = measureContentHeight();
const content_cx: f64 = content_width / 2;
const content_cy: f64 = content_height / 2;

pub const FrameMetrics = struct {
    framebuffer_width: u32,
    framebuffer_height: u32,
    display_scale: f64,

    pub fn init(framebuffer_width: u32, framebuffer_height: u32, display_scale: f64) ?FrameMetrics {
        if (framebuffer_width == 0 or framebuffer_height == 0) return null;
        return .{
            .framebuffer_width = framebuffer_width,
            .framebuffer_height = framebuffer_height,
            .display_scale = sanitizeDisplayScale(display_scale),
        };
    }

    pub fn width(self: FrameMetrics) f64 {
        return @floatFromInt(self.framebuffer_width);
    }

    pub fn height(self: FrameMetrics) f64 {
        return @floatFromInt(self.framebuffer_height);
    }
};

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

    fn alertColor(self: ColorScheme) heavy_slug.Color {
        return switch (self) {
            .light => heavy_slug.Color.fromRgba(0.82, 0.05, 0.02, 1),
            .dark => heavy_slug.Color.fromRgba(1.0, 0.36, 0.12, 1),
        };
    }
};

const ViewState = struct {
    scale: f64 = 1.0,
    fit_scale: f64 = 1.0,
    pan_x: f64 = 0,
    pan_y: f64 = 0,

    fn zoom(self: ViewState) f64 {
        if (!std.math.isFinite(self.scale) or
            !std.math.isFinite(self.fit_scale) or
            self.scale <= 0 or
            self.fit_scale <= 0)
        {
            return 1.0;
        }
        const value = self.scale / self.fit_scale;
        return if (std.math.isFinite(value) and value > 0) value else 1.0;
    }
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

    pub fn update(self: *Scene, input: *demo_input.State, dt: f64, now: f64, frame: FrameMetrics) void {
        const width64 = frame.width();
        const height64 = frame.height();
        const frame_dt = if (std.math.isFinite(dt) and dt > 0) dt else 0;
        self.fps_meter.update(frame_dt);

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
        if (input.getKey(.up)) self.view.pan_y += pan_speed * frame_dt;
        if (input.getKey(.down)) self.view.pan_y -= pan_speed * frame_dt;
        if (input.getKey(.left)) self.view.pan_x += pan_speed * frame_dt;
        if (input.getKey(.right)) self.view.pan_x -= pan_speed * frame_dt;

        const keyboard_zoom = 2.0 * frame_dt;
        if (input.getKey(.equal)) self.zoomAt(width64 * 0.5, height64 * 0.5, 1.0 + keyboard_zoom);
        if (input.getKey(.minus)) self.zoomAt(width64 * 0.5, height64 * 0.5, @max(1.0 - keyboard_zoom, 0.001));

        const scroll = input.consumeScrollDelta();
        if (scroll != 0) {
            const cur = input.cursor;
            const factor: f64 = std.math.pow(f64, 1.1, scroll);
            self.zoomAt(cur[0], height64 - cur[1], factor);
        }

        self.updateMouse(input, now, width64, height64);
        if (self.animate) self.rotation_angle += self.rotation_speed * frame_dt;
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

    pub fn currentZoom(self: Scene) f64 {
        return self.view.zoom();
    }

    pub fn frameView(self: Scene, frame: FrameMetrics) heavy_slug.View {
        const view = viewTransform(self.view);
        const rotation = heavy_slug.Transform.rotationAbout(self.rotation_angle, content_cx, content_cy);
        return heavy_slug.View.init(frame.width(), frame.height(), heavy_slug.Transform.compose(view, rotation));
    }

    pub fn draw(self: *Scene, renderer: anytype, font: anytype, view: heavy_slug.View, frame: FrameMetrics) !void {
        try self.drawContent(renderer, font);
        const warnings = renderer.diagnostics().warnings();
        try self.drawOverlay(renderer, font, view, frame, warnings);
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
                _ = try renderer.drawText(.{
                    .font = font,
                    .text = line.text,
                    .transform = world_from_text,
                    .color = self.color_scheme.color(line.tone),
                });
            }
            y -= line.advance;
        }
    }

    fn drawOverlay(self: Scene, renderer: anytype, font: anytype, view: heavy_slug.View, frame: FrameMetrics, warnings: heavy_slug.FrameWarnings) !void {
        try self.drawMetricsOverlay(renderer, font, view, frame);
        try self.drawWarnings(renderer, font, view, warnings);
    }

    fn drawMetricsOverlay(self: Scene, renderer: anytype, font: anytype, view: heavy_slug.View, frame: FrameMetrics) !void {
        var label_buffer: [96]u8 = undefined;
        const label = self.writeOverlayLabel(frame, &label_buffer);
        const screen_from_text = heavy_slug.Transform.compose(
            heavy_slug.Transform.translation(overlay_margin, view.height - overlay_baseline_from_top),
            heavy_slug.Transform.scale(overlay_scale, overlay_scale),
        );
        _ = try renderer.drawScreenText(.{
            .font = font,
            .text = label,
            .screen_from_text = screen_from_text,
            .color = self.color_scheme.overlayColor(),
        });
    }

    fn drawWarnings(self: Scene, renderer: anytype, font: anytype, view: heavy_slug.View, warnings: heavy_slug.FrameWarnings) !void {
        var baseline = view.height - warning_first_baseline_from_top;
        for (warnings.slice()) |warning| {
            const screen_from_text = heavy_slug.Transform.compose(
                heavy_slug.Transform.translation(overlay_margin, baseline),
                heavy_slug.Transform.scale(warning_scale, warning_scale),
            );
            _ = try renderer.drawScreenText(.{
                .font = font,
                .text = warningText(warning),
                .screen_from_text = screen_from_text,
                .color = self.color_scheme.alertColor(),
            });
            baseline -= warning_line_advance;
        }
    }

    fn writeOverlayLabel(self: Scene, frame: FrameMetrics, buffer: []u8) []const u8 {
        const zoom = self.view.zoom();
        const display_scale = frame.display_scale;
        const fps = self.fps_meter.fps();
        if (std.math.isFinite(fps) and fps > 0) {
            return std.fmt.bufPrint(
                buffer,
                "FPS {d:.1}  Zoom {d:.2}x  Display {d:.2}x",
                .{ fps, zoom, display_scale },
            ) catch "FPS --  Zoom --  Display --";
        }
        return std.fmt.bufPrint(
            buffer,
            "FPS --  Zoom {d:.2}x  Display {d:.2}x",
            .{ zoom, display_scale },
        ) catch "FPS --  Zoom --  Display --";
    }

    fn updateColorScheme(self: *Scene, input: *const demo_input.State) void {
        const pressed = input.getKey(.b);
        if (pressed and !self.color_scheme_key_was_pressed) {
            self.color_scheme = self.color_scheme.toggled();
        }
        self.color_scheme_key_was_pressed = pressed;
    }

    fn updateMouse(self: *Scene, input: *const demo_input.State, now: f64, width: f64, height: f64) void {
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
                const half_w = width * 0.5;
                const half_h = height * 0.5;
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
        .fit_scale = s,
        .pan_x = width / (2 * s) - content_width / 2,
        .pan_y = height / (2 * s) - content_height / 2,
    };
}

fn sanitizeDisplayScale(value: f64) f64 {
    return if (std.math.isFinite(value) and value > 0) value else 1.0;
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

fn warningText(warning: heavy_slug.FrameWarning) []const u8 {
    return switch (warning) {
        .invalid_world_transform => "INVALID WORLD TRANSFORM: reset with R",
        .invalid_transform => "INVALID TRANSFORM: reset with R",
        .precision_unsupported => "PRECISION LIMIT: zoom out or press R",
        .cache_encode_unsupported => "GLYPH ENCODE LIMIT: unsupported outline at this scale",
        .nonfinite_bounds => "NONFINITE BOUNDS: reset view with R",
        .f32_chart_overflow => "F32 CHART LIMIT: reset view or reduce pan",
        .meshlet_empty => "MESHLET LIMIT: visible glyph produced no meshlets",
        .empty_after_blocking_rejects => "TEXT EMPTY AFTER REJECTS: reset view with R",
    };
}

const FakeRenderFrame = struct {
    diagnostics_value: heavy_slug.core.render.FrameDiagnostics = .{},
    fail_next: ?anyerror = null,
    draw_count: u32 = 0,
    screen_draw_count: u32 = 0,
    warning_draw_count: u32 = 0,

    fn drawText(self: *FakeRenderFrame, run: anytype) !heavy_slug.DrawTextResult {
        self.draw_count += 1;
        if (self.fail_next) |err| {
            self.fail_next = null;
            return err;
        }
        return .{ .shaped_glyphs = @intCast(run.text.len), .emitted_glyphs = @intCast(run.text.len), .emitted_meshlets = @intCast(run.text.len) };
    }

    fn drawScreenText(self: *FakeRenderFrame, run: anytype) !heavy_slug.DrawTextResult {
        self.screen_draw_count += 1;
        if (isWarningText(run.text)) self.warning_draw_count += 1;
        return .{ .shaped_glyphs = @intCast(run.text.len), .emitted_glyphs = @intCast(run.text.len), .emitted_meshlets = @intCast(run.text.len) };
    }

    fn diagnostics(self: *const FakeRenderFrame) heavy_slug.core.render.FrameDiagnostics {
        return self.diagnostics_value;
    }
};

fn isWarningText(text: []const u8) bool {
    inline for (@typeInfo(heavy_slug.FrameWarning).@"enum".fields) |field| {
        const warning: heavy_slug.FrameWarning = @enumFromInt(field.value);
        if (std.mem.eql(u8, text, warningText(warning))) return true;
    }
    return false;
}

test "demo scene exposes shared content settings" {
    var visible_lines: usize = 0;
    var section_breaks: usize = 0;
    for (sample_lines) |line| {
        if (line.text.len == 0) {
            section_breaks += 1;
        } else {
            visible_lines += 1;
        }
    }

    try std.testing.expect(visible_lines >= 28);
    try std.testing.expect(section_breaks >= 5);
    try std.testing.expect(content_width > 0);
    try std.testing.expect(content_height > 0);
}

test "demo scene content fit math is stable" {
    try std.testing.expectApproxEqAbs(@as(f64, 1164), content_height, 1.0e-12);
    const fit = contentFit(window_width, window_height);
    try std.testing.expectApproxEqAbs(@as(f64, 0.556701030927835), fit.fit_scale, 1.0e-15);
    try std.testing.expectApproxEqAbs(fit.fit_scale, fit.scale, 1.0e-15);
}

test "demo scene uses the multilingual Noto Sans JP asset" {
    try std.testing.expectEqualStrings("assets/NotoSansJP-Regular.otf", std.mem.span(font_path));
}

test "demo scene sample text covers supported scripts" {
    var saw_latin = false;
    var saw_japanese = false;
    var saw_chinese = false;
    var saw_cyrillic = false;
    var saw_greek = false;
    var saw_symbols = false;
    var saw_fullwidth = false;

    for (sample_lines) |line| {
        saw_latin = saw_latin or std.mem.indexOf(u8, line.text, "Latin") != null;
        saw_japanese = saw_japanese or std.mem.indexOf(u8, line.text, "日本語") != null;
        saw_chinese = saw_chinese or std.mem.indexOf(u8, line.text, "中文") != null;
        saw_cyrillic = saw_cyrillic or std.mem.indexOf(u8, line.text, "Русский") != null;
        saw_greek = saw_greek or std.mem.indexOf(u8, line.text, "Ελληνικά") != null;
        saw_symbols = saw_symbols or std.mem.indexOf(u8, line.text, "Math") != null;
        saw_fullwidth = saw_fullwidth or std.mem.indexOf(u8, line.text, "Fullwidth") != null;
    }

    try std.testing.expect(saw_latin);
    try std.testing.expect(saw_japanese);
    try std.testing.expect(saw_chinese);
    try std.testing.expect(saw_cyrillic);
    try std.testing.expect(saw_greek);
    try std.testing.expect(saw_symbols);
    try std.testing.expect(saw_fullwidth);
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
    const frame_view = (Scene{ .view = view }).frameView(testFrame());
    try std.testing.expect(frame_view.screen_from_world.yy > 0);
}

test "demo scene rotation linear norm is bounded by sqrt2" {
    const angles = [_]f64{ 0, 0.17, 0.5, 1.0, 1.7, std.math.pi };
    for (angles) |angle| {
        const rotation = heavy_slug.Transform.rotation(angle);
        try std.testing.expect(rotation.linearNormInf() <= @sqrt(@as(f64, 2.0)) + 1.0e-12);
    }
}

test "demo scene frame metrics keep framebuffer pixels and display scale explicit" {
    const frame = FrameMetrics.init(1920, 1080, 1.5).?;
    try std.testing.expectEqual(@as(u32, 1920), frame.framebuffer_width);
    try std.testing.expectEqual(@as(u32, 1080), frame.framebuffer_height);
    try std.testing.expectApproxEqAbs(@as(f64, 1.5), frame.display_scale, 1.0e-12);
    try std.testing.expect(FrameMetrics.init(0, 1080, 1.5) == null);
    try std.testing.expectApproxEqAbs(@as(f64, 1), FrameMetrics.init(1280, 720, std.math.nan(f64)).?.display_scale, 1.0e-12);
}

test "demo scene overlay label reports fps zoom and platform display scale" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
    };
    scene.fps_meter.displayed_fps = 60;
    scene.zoomAt(640, 360, 2);

    const frame = FrameMetrics.init(window_width, window_height, 2).?;
    var label_buffer: [96]u8 = undefined;
    const label = scene.writeOverlayLabel(frame, &label_buffer);
    try std.testing.expectEqualStrings("FPS 60.0  Zoom 2.00x  Display 2.00x", label);
}

test "demo scene screen-space overlay precision selects the minimum tier" {
    const policy = heavy_slug.PrecisionPolicy{};
    const overlay = heavy_slug.Transform.scale(overlay_scale, overlay_scale)
        .scaleLinear(1.0 / heavy_slug.core.units.hb_subpixels_per_pixel_f64);
    const warning = heavy_slug.Transform.scale(warning_scale, warning_scale)
        .scaleLinear(1.0 / heavy_slug.core.units.hb_subpixels_per_pixel_f64);

    try std.testing.expectEqual(policy.min_fraction_bits, (try policy.selectFractionBits(overlay)).supported.fraction_bits);
    try std.testing.expectEqual(policy.min_fraction_bits, (try policy.selectFractionBits(warning)).supported.fraction_bits);
}

test "demo scene draws all public warnings from frame diagnostics" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
    };
    const frame_metrics = testFrame();
    const view = scene.frameView(frame_metrics);
    var frame = FakeRenderFrame{
        .diagnostics_value = .{
            .run_rejects = .{ .invalid_world_transform = 1 },
            .glyph_rejects = .{
                .invalid_transform = 1,
                .precision_unsupported = 1,
                .cache_encode_unsupported = 1,
                .nonfinite_bounds = 1,
                .f32_chart_overflow = 1,
                .meshlet_empty = 1,
            },
        },
    };

    try scene.draw(&frame, testFont(), view, frame_metrics);

    try std.testing.expectEqual(@as(u32, heavy_slug.max_frame_warnings), frame.warning_draw_count);
    try std.testing.expectEqual(@as(u32, heavy_slug.max_frame_warnings + 1), frame.screen_draw_count);
}

test "demo scene propagates draw errors before overlay" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
    };
    const frame_metrics = testFrame();
    const view = scene.frameView(frame_metrics);
    var frame = FakeRenderFrame{
        .fail_next = error.GlyphCapacityExceeded,
    };

    try std.testing.expectError(error.GlyphCapacityExceeded, scene.draw(&frame, testFont(), view, frame_metrics));
    try std.testing.expectEqual(@as(u32, 0), frame.screen_draw_count);
}

test "demo scene ignores invalid frame dt for motion state" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
        .animate = true,
    };
    const before = scene.view;
    var input: demo_input.State = .{};
    input.setKey(.right, true);

    scene.update(&input, std.math.nan(f64), 0, testFrame());

    try std.testing.expectApproxEqAbs(before.pan_x, scene.view.pan_x, 1.0e-12);
    try std.testing.expectApproxEqAbs(before.pan_y, scene.view.pan_y, 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0), scene.rotation_angle, 1.0e-12);
}

test "demo scene starts light and toggles color scheme only on B key edges" {
    var scene: Scene = .{};
    var input: demo_input.State = .{};

    try std.testing.expectEqual(ColorScheme.light, scene.color_scheme);
    try std.testing.expect(!scene.darkModeEnabled());
    try std.testing.expectEqual(ColorScheme.light.clearColor(), scene.clearColor());

    input.setKey(.b, true);
    scene.update(&input, 0, 0, testFrame());
    try std.testing.expectEqual(ColorScheme.dark, scene.color_scheme);
    try std.testing.expect(scene.darkModeEnabled());

    scene.update(&input, 0, 0, testFrame());
    try std.testing.expectEqual(ColorScheme.dark, scene.color_scheme);

    input.setKey(.b, false);
    scene.update(&input, 0, 0, testFrame());
    input.setKey(.b, true);
    scene.update(&input, 0, 0, testFrame());
    try std.testing.expectEqual(ColorScheme.light, scene.color_scheme);
    try std.testing.expect(!scene.darkModeEnabled());
}

test "demo scene fps meter reports sampled rate without allocating" {
    var meter: FpsMeter = .{};
    for (0..30) |_| meter.update(1.0 / 60.0);

    try std.testing.expectApproxEqAbs(@as(f64, 60), meter.fps(), 1.0e-9);
}

test "demo scene draws overlay through native screen-space text" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
        .rotation_angle = 0.35,
    };
    const frame_view = scene.frameView(testFrame());
    var frame = FakeRenderFrame{};

    try scene.draw(&frame, testFont(), frame_view, testFrame());

    try std.testing.expect(frame.draw_count > 0);
    try std.testing.expectEqual(@as(u32, 1), frame.screen_draw_count);
    try std.testing.expectEqual(@as(u32, 0), frame.warning_draw_count);
}

test "demo scene zoom keeps the requested screen anchor stable through rotation" {
    var scene = Scene{
        .view = contentFit(window_width, window_height),
        .view_initialized = true,
        .rotation_angle = 0.37,
    };
    const anchor = [2]f64{
        @as(f64, @floatFromInt(window_width)) * 0.5,
        @as(f64, @floatFromInt(window_height)) * 0.5,
    };
    const before = scene.frameView(testFrame()).screen_from_world;
    const world = before.inverse().?.apply(anchor);

    scene.zoomAt(anchor[0], anchor[1], 0.5);

    const screen = scene.frameView(testFrame()).screen_from_world.apply(world);
    try std.testing.expectApproxEqAbs(anchor[0], screen[0], 1.0e-9);
    try std.testing.expectApproxEqAbs(anchor[1], screen[1], 1.0e-9);
}

fn testFrame() FrameMetrics {
    return FrameMetrics.init(window_width, window_height, 1.0).?;
}

fn testFont() heavy_slug.FontHandle {
    return .{ .id = 0 };
}
