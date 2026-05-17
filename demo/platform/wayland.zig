//! Wayland demo window, input, and Vulkan surface glue.

const std = @import("std");
const c = @import("wayland_c");
const vk = @import("vulkan");
const demo_input = @import("demo_input");

const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_wayland_surface",
};

var vulkan_loader: ?std.DynLib = null;
var vk_get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null;

const seat_capability_pointer: u32 = 1;
const seat_capability_keyboard: u32 = 2;
const key_state_pressed: u32 = 1;
const pointer_button_pressed: u32 = 1;
const pointer_axis_vertical_scroll: u32 = 0;
const btn_left: u32 = 0x110;
const btn_right: u32 = 0x111;
const xkb_keycode_offset: u32 = 8;
const fractional_scale_denominator: u32 = 120;
const resize_edge_top: u32 = 1;
const resize_edge_bottom: u32 = 2;
const resize_edge_left: u32 = 4;
const resize_edge_top_left: u32 = 5;
const resize_edge_bottom_left: u32 = 6;
const resize_edge_right: u32 = 8;
const resize_edge_top_right: u32 = 9;
const resize_edge_bottom_right: u32 = 10;

const csd_border: i32 = 6;
const csd_titlebar_height: i32 = 34;
const csd_corner_extent: f64 = 24;
const csd_close_size: f64 = 14;
const csd_close_margin: f64 = 10;
const decoration_buffer_count = 3;

const linux_key = struct {
    const esc = 1;
    const minus = 12;
    const equal = 13;
    const r = 19;
    const b = 48;
    const space = 57;
    const up = 103;
    const left = 105;
    const right = 106;
    const down = 108;
};

const PointerSurface = enum {
    content,
    titlebar,
    left_border,
    right_border,
    bottom_border,
};

const DecorationPartRole = enum {
    titlebar,
    left_border,
    right_border,
    bottom_border,
};

const ClientDecorations = struct {
    titlebar: DecorationPart = .{ .role = .titlebar },
    left: DecorationPart = .{ .role = .left_border },
    right: DecorationPart = .{ .role = .right_border },
    bottom: DecorationPart = .{ .role = .bottom_border },

    fn paint(self: *ClientDecorations, window: *Window) !void {
        const content_width = window.content_width;
        const content_height = window.content_height;
        const outer_width = content_width + 2 * csd_border;

        try self.titlebar.paint(window, -csd_border, -csd_titlebar_height, outer_width, csd_titlebar_height);
        try self.left.paint(window, -csd_border, 0, csd_border, content_height);
        try self.right.paint(window, content_width, 0, csd_border, content_height);
        try self.bottom.paint(window, -csd_border, content_height, outer_width, csd_border);
    }

    fn deinit(self: *ClientDecorations) void {
        self.titlebar.deinit();
        self.left.deinit();
        self.right.deinit();
        self.bottom.deinit();
    }

    fn roleForSurface(self: *const ClientDecorations, surface: *c.struct_wl_surface) ?PointerSurface {
        if (self.titlebar.surface != null and self.titlebar.surface.? == surface) return .titlebar;
        if (self.left.surface != null and self.left.surface.? == surface) return .left_border;
        if (self.right.surface != null and self.right.surface.? == surface) return .right_border;
        if (self.bottom.surface != null and self.bottom.surface.? == surface) return .bottom_border;
        return null;
    }
};

const DecorationBuffer = struct {
    buffer: *c.struct_wl_buffer,
    pixels: []align(std.heap.page_size_min) u8,
    width: i32,
    height: i32,
    busy: bool = false,
    retired: bool = false,

    fn create(window: *Window, width: i32, height: i32) !*DecorationBuffer {
        const state = try std.heap.page_allocator.create(DecorationBuffer);
        errdefer std.heap.page_allocator.destroy(state);

        const stride_i32 = width * 4;
        const size: usize = @intCast(stride_i32 * height);
        const fd = try std.posix.memfd_create("heavy-slug-wayland-decoration", std.os.linux.MFD.CLOEXEC);
        defer std.posix.close(fd);

        try resizeMemfd(fd, size);
        const memory = try std.posix.mmap(
            null,
            size,
            .{ .READ = true, .WRITE = true },
            .{ .TYPE = .SHARED },
            fd,
            0,
        );
        errdefer std.posix.munmap(memory);

        const pool = c.wl_shm_create_pool(window.shm.?, fd, @intCast(size)) orelse return error.WaylandBufferFailed;
        defer c.wl_shm_pool_destroy(pool);

        const wl_buffer = c.wl_shm_pool_create_buffer(
            pool,
            0,
            width,
            height,
            stride_i32,
            c.WL_SHM_FORMAT_ARGB8888,
        ) orelse return error.WaylandBufferFailed;
        errdefer c.wl_buffer_destroy(wl_buffer);

        state.* = .{
            .buffer = wl_buffer,
            .pixels = memory,
            .width = width,
            .height = height,
        };
        if (c.wl_buffer_add_listener(wl_buffer, &decoration_buffer_listener, state) != 0) {
            return error.WaylandListenerFailed;
        }
        return state;
    }

    fn retire(self: *DecorationBuffer) void {
        self.retired = true;
        if (!self.busy) self.destroy();
    }

    fn destroy(self: *DecorationBuffer) void {
        c.wl_buffer_destroy(self.buffer);
        std.posix.munmap(self.pixels);
        std.heap.page_allocator.destroy(self);
    }
};

const decoration_buffer_listener = std.mem.zeroInit(c.wl_buffer_listener, .{
    .release = decorationBufferRelease,
});

fn decorationBufferRelease(data: ?*anyopaque, buffer: ?*c.struct_wl_buffer) callconv(.c) void {
    _ = buffer;
    const decoration_buffer: *DecorationBuffer = @ptrCast(@alignCast(data.?));
    decoration_buffer.busy = false;
    if (decoration_buffer.retired) decoration_buffer.destroy();
}

const DecorationPart = struct {
    role: DecorationPartRole,
    surface: ?*c.struct_wl_surface = null,
    subsurface: ?*c.struct_wl_subsurface = null,
    viewport: ?*c.struct_wp_viewport = null,
    buffers: [decoration_buffer_count]?*DecorationBuffer = .{null} ** decoration_buffer_count,
    active_buffer: ?*DecorationBuffer = null,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    buffer_width: i32 = 0,
    buffer_height: i32 = 0,
    painted_dark_mode: ?bool = null,
    painted_scale_numerator: u32 = 0,

    fn paint(self: *DecorationPart, window: *Window, x: i32, y: i32, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0) return;
        if (self.surface == null) try self.createSurface(window);

        const scale_numerator = window.effectiveScaleNumerator();
        const pixel_width = @as(i32, @intCast(scaleDimension(width, scale_numerator)));
        const pixel_height = @as(i32, @intCast(scaleDimension(height, scale_numerator)));
        const needs_repaint = self.active_buffer == null or
            self.logical_width != width or
            self.logical_height != height or
            self.buffer_width != pixel_width or
            self.buffer_height != pixel_height or
            self.painted_dark_mode == null or
            self.painted_dark_mode.? != window.dark_mode or
            self.painted_scale_numerator != scale_numerator;
        if (needs_repaint) {
            const decoration_buffer = (try self.acquireWritableBuffer(window, pixel_width, pixel_height)) orelse {
                window.csd_repaint_deferred = true;
                return;
            };
            self.logical_width = width;
            self.logical_height = height;
            self.buffer_width = pixel_width;
            self.buffer_height = pixel_height;
            self.painted_scale_numerator = scale_numerator;
            self.paintPixels(window, decoration_buffer);
            self.active_buffer = decoration_buffer;
            self.painted_dark_mode = window.dark_mode;
        }

        const active_buffer = self.active_buffer orelse return;
        try self.applySurfaceScale(window, width, height);
        c.wl_subsurface_set_position(self.subsurface.?, x, y);
        c.wl_surface_attach(self.surface.?, active_buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface.?, 0, 0, pixel_width, pixel_height);
        active_buffer.busy = true;
        c.wl_surface_commit(self.surface.?);
    }

    fn createSurface(self: *DecorationPart, window: *Window) !void {
        const surface = c.wl_compositor_create_surface(window.compositor.?) orelse return error.WaylandSurfaceFailed;
        errdefer c.wl_surface_destroy(surface);

        const subsurface = c.wl_subcompositor_get_subsurface(
            window.subcompositor.?,
            surface,
            window.surface.?,
        ) orelse return error.WaylandSurfaceFailed;
        c.wl_subsurface_set_desync(subsurface);

        self.surface = surface;
        self.subsurface = subsurface;
    }

    fn applySurfaceScale(self: *DecorationPart, window: *Window, width: i32, height: i32) !void {
        const surface = self.surface.?;
        c.wl_surface_set_buffer_scale(surface, 1);
        if (self.viewport == null) {
            self.viewport = c.wp_viewporter_get_viewport(window.viewporter.?, surface) orelse return error.WaylandViewportFailed;
        }
        c.wp_viewport_set_destination(self.viewport.?, width, height);
    }

    fn acquireWritableBuffer(self: *DecorationPart, window: *Window, width: i32, height: i32) !?*DecorationBuffer {
        for (self.buffers) |maybe_buffer| {
            if (maybe_buffer) |buffer| {
                if (!buffer.busy and buffer.width == width and buffer.height == height) return buffer;
            }
        }

        for (&self.buffers) |*slot| {
            if (slot.* == null) {
                slot.* = try DecorationBuffer.create(window, width, height);
                return slot.*.?;
            }
        }

        for (&self.buffers) |*slot| {
            const buffer = slot.*.?;
            if (!buffer.busy) {
                buffer.destroy();
                slot.* = try DecorationBuffer.create(window, width, height);
                return slot.*.?;
            }
        }

        return null;
    }

    fn paintPixels(self: *DecorationPart, window: *const Window, decoration_buffer: *DecorationBuffer) void {
        const pixels = std.mem.bytesAsSlice(u32, decoration_buffer.pixels);
        const colors = decorationColors(window.dark_mode);
        const fill = switch (self.role) {
            .titlebar => colors.titlebar,
            else => colors.border,
        };
        @memset(pixels, fill);

        if (self.role != .titlebar) return;

        const width: usize = @intCast(self.buffer_width);
        const height: usize = @intCast(self.buffer_height);
        if (width == 0 or height == 0) return;

        for (0..width) |x| {
            pixels[(height - 1) * width + x] = colors.border;
        }

        const scale = scaleFloat(self.painted_scale_numerator);
        const close_left = roundPositiveToI32((@as(f64, @floatFromInt(self.logical_width)) - csd_close_margin - csd_close_size) * scale);
        const close_top = roundPositiveToI32((@as(f64, @floatFromInt(self.logical_height)) - csd_close_size) * 0.5 * scale);
        const close_extent = @max(roundPositiveToI32(csd_close_size * scale), 1);
        const close_right = close_left + close_extent;
        const close_bottom = close_top + close_extent;
        const diagonal_thickness = @max(roundPositiveToI32(scale), 1);
        const close_left_u: usize = @intCast(@max(close_left, 0));
        const close_top_u: usize = @intCast(@max(close_top, 0));
        const close_right_u: usize = @intCast(@min(close_right, self.buffer_width));
        const close_bottom_u: usize = @intCast(@min(close_bottom, self.buffer_height));

        for (close_top_u..close_bottom_u) |uy| {
            for (close_left_u..close_right_u) |ux| {
                const x: i32 = @intCast(ux);
                const y: i32 = @intCast(uy);
                const dx = x - close_left;
                const dy = y - close_top;
                const max = close_extent - 1;
                const on_x = @abs(dx - dy) <= diagonal_thickness or @abs(dx + dy - max) <= diagonal_thickness;
                if (on_x) pixels[uy * width + ux] = colors.close_glyph;
            }
        }
    }

    fn destroyBuffer(self: *DecorationPart) void {
        for (&self.buffers) |*slot| {
            const buffer = slot.* orelse continue;
            if (buffer.busy) {
                buffer.retire();
            } else {
                buffer.destroy();
            }
            slot.* = null;
        }
        self.active_buffer = null;
        self.logical_width = 0;
        self.logical_height = 0;
        self.buffer_width = 0;
        self.buffer_height = 0;
        self.painted_dark_mode = null;
        self.painted_scale_numerator = 0;
    }

    fn deinit(self: *DecorationPart) void {
        self.destroyBuffer();
        if (self.viewport) |viewport| c.wp_viewport_destroy(viewport);
        if (self.subsurface) |subsurface| c.wl_subsurface_destroy(subsurface);
        if (self.surface) |surface| c.wl_surface_destroy(surface);
        self.viewport = null;
        self.subsurface = null;
        self.surface = null;
    }
};

const DecorationColors = struct {
    titlebar: u32,
    border: u32,
    close_glyph: u32,
};

fn decorationColors(dark: bool) DecorationColors {
    return if (dark)
        .{
            .titlebar = 0xff202124,
            .border = 0xff3c4043,
            .close_glyph = 0xfff1f3f4,
        }
    else
        .{
            .titlebar = 0xfff1f3f4,
            .border = 0xffc7c9cc,
            .close_glyph = 0xff202124,
        };
}

fn scaleDimension(logical: i32, scale_numerator: u32) u32 {
    const clamped: u64 = @intCast(@max(logical, 1));
    const numerator: u64 = @intCast(@max(scale_numerator, 1));
    const denominator: u64 = fractional_scale_denominator;
    const rounded = (clamped * numerator + denominator / 2) / denominator;
    return @intCast(@max(rounded, 1));
}

fn scaleFloat(scale_numerator: u32) f64 {
    return @as(f64, @floatFromInt(@max(scale_numerator, 1))) /
        @as(f64, @floatFromInt(fractional_scale_denominator));
}

fn roundPositiveToI32(value: f64) i32 {
    return @intFromFloat(@floor(@max(value, 0) + 0.5));
}

fn resizeMemfd(fd: std.posix.fd_t, size: usize) !void {
    const rc = std.os.linux.ftruncate(fd, @intCast(size));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.WaylandBufferFailed,
    }
}

pub const Window = struct {
    display: *c.struct_wl_display = undefined,
    registry: ?*c.struct_wl_registry = null,
    compositor: ?*c.struct_wl_compositor = null,
    subcompositor: ?*c.struct_wl_subcompositor = null,
    shm: ?*c.struct_wl_shm = null,
    surface: ?*c.struct_wl_surface = null,
    viewporter: ?*c.struct_wp_viewporter = null,
    main_viewport: ?*c.struct_wp_viewport = null,
    fractional_scale_manager: ?*c.struct_wp_fractional_scale_manager_v1 = null,
    fractional_scale: ?*c.struct_wp_fractional_scale_v1 = null,
    seat: ?*c.struct_wl_seat = null,
    pointer: ?*c.struct_wl_pointer = null,
    keyboard: ?*c.struct_wl_keyboard = null,
    xkb_context: ?*c.struct_xkb_context = null,
    xkb_keymap: ?*c.struct_xkb_keymap = null,
    xkb_state: ?*c.struct_xkb_state = null,
    wm_base: ?*c.struct_xdg_wm_base = null,
    xdg_surface: ?*c.struct_xdg_surface = null,
    toplevel: ?*c.struct_xdg_toplevel = null,
    decorations: ClientDecorations = .{},
    pointer_surface: PointerSurface = .content,
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    input_state: demo_input.State = .{},
    content_width: i32 = 0,
    content_height: i32 = 0,
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,
    configured: bool = false,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    preferred_fractional_scale: u32 = fractional_scale_denominator,
    csd_repaint_deferred: bool = false,
    dark_mode: bool = false,
    start_time: f64 = 0,

    pub fn init(self: *Window, allocator: std.mem.Allocator, width: c_int, height: c_int, title: []const u8) !void {
        try loadVulkanLoader();

        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);

        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        self.* = .{
            .display = display,
            .content_width = @max(width, 1),
            .content_height = @max(height, 1),
            .start_time = monotonicSeconds(),
        };
        self.recomputeFramebufferSize();
        errdefer self.deinit();

        self.registry = c.wl_display_get_registry(display) orelse return error.WaylandRegistryUnavailable;
        if (c.wl_registry_add_listener(self.registry, &registry_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        try self.roundtrip();

        if (self.compositor == null or
            self.subcompositor == null or
            self.shm == null or
            self.wm_base == null or
            self.viewporter == null or
            self.fractional_scale_manager == null)
        {
            return error.WaylandGlobalsMissing;
        }

        self.surface = c.wl_compositor_create_surface(self.compositor) orelse return error.WaylandSurfaceFailed;
        try self.createScaleObjects();

        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm_base, self.surface) orelse return error.WaylandSurfaceFailed;
        if (c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }

        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.WaylandSurfaceFailed;
        if (c.xdg_toplevel_add_listener(self.toplevel, &xdg_toplevel_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        c.xdg_toplevel_set_title(self.toplevel, title_z.ptr);
        c.xdg_toplevel_set_app_id(self.toplevel, "heavy-slug");
        self.updateWindowGeometry();
        c.wl_surface_commit(self.surface);

        while (!self.configured and !self.should_close) {
            if (c.wl_display_dispatch(display) < 0) return error.WaylandDispatchFailed;
        }
    }

    pub fn deinit(self: *Window) void {
        self.decorations.deinit();
        if (self.keyboard) |keyboard| c.wl_keyboard_destroy(keyboard);
        self.releaseKeymap();
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        if (self.pointer) |pointer| c.wl_pointer_destroy(pointer);
        if (self.seat) |seat| c.wl_seat_destroy(seat);
        if (self.toplevel) |toplevel| c.xdg_toplevel_destroy(toplevel);
        if (self.xdg_surface) |xdg_surface| c.xdg_surface_destroy(xdg_surface);
        if (self.fractional_scale) |scale| c.wp_fractional_scale_v1_destroy(scale);
        if (self.main_viewport) |viewport| c.wp_viewport_destroy(viewport);
        if (self.surface) |surface| c.wl_surface_destroy(surface);
        if (self.fractional_scale_manager) |manager| c.wp_fractional_scale_manager_v1_destroy(manager);
        if (self.viewporter) |viewporter| c.wp_viewporter_destroy(viewporter);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.shm) |shm| c.wl_shm_destroy(shm);
        if (self.subcompositor) |subcompositor| c.wl_subcompositor_destroy(subcompositor);
        if (self.compositor) |compositor| c.wl_compositor_destroy(compositor);
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        c.wl_display_disconnect(self.display);
    }

    pub fn pollEvents(self: *Window) void {
        self.pollEventsTimeout(0);
    }

    pub fn pollEventsTimeout(self: *Window, timeout_ms: i32) void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            _ = c.wl_display_dispatch_pending(self.display);
        }

        _ = c.wl_display_flush(self.display);
        var fds = [_]std.posix.pollfd{.{
            .fd = c.wl_display_get_fd(self.display),
            .events = std.os.linux.POLL.IN,
            .revents = 0,
        }};

        const ready = std.posix.poll(&fds, timeout_ms) catch 0;
        const fatal_events = std.os.linux.POLL.ERR | std.os.linux.POLL.HUP | std.os.linux.POLL.NVAL;
        if ((fds[0].revents & fatal_events) != 0) {
            c.wl_display_cancel_read(self.display);
            self.should_close = true;
        } else if (ready > 0 and (fds[0].revents & std.os.linux.POLL.IN) != 0) {
            if (c.wl_display_read_events(self.display) < 0) {
                self.should_close = true;
            }
        } else {
            c.wl_display_cancel_read(self.display);
        }
        _ = c.wl_display_dispatch_pending(self.display);
        if (self.configured and self.csd_repaint_deferred) {
            self.refreshClientDecorations() catch {
                self.should_close = true;
            };
        }
    }

    pub fn input(self: *Window) *demo_input.State {
        return &self.input_state;
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ self.framebuffer_width, self.framebuffer_height };
    }

    pub fn time(self: *const Window) f64 {
        return monotonicSeconds() - self.start_time;
    }

    pub fn setDarkMode(self: *Window, enabled: bool) void {
        if (self.dark_mode == enabled) return;
        self.dark_mode = enabled;
        self.refreshClientDecorations() catch {
            self.should_close = true;
        };
    }

    pub fn createSurface(self: *const Window, instance: vk.Instance, idisp: anytype) !vk.SurfaceKHR {
        const create_info = vk.WaylandSurfaceCreateInfoKHR{
            .display = @ptrCast(self.display),
            .surface = @ptrCast(self.surface.?),
        };
        return idisp.createWaylandSurfaceKHR(instance, &create_info, null) catch error.SurfaceCreationFailed;
    }

    fn roundtrip(self: *Window) !void {
        if (c.wl_display_roundtrip(self.display) < 0) return error.WaylandDispatchFailed;
    }

    fn createScaleObjects(self: *Window) !void {
        const surface = self.surface.?;
        self.main_viewport = c.wp_viewporter_get_viewport(self.viewporter.?, surface) orelse return error.WaylandViewportFailed;
        self.fractional_scale = c.wp_fractional_scale_manager_v1_get_fractional_scale(
            self.fractional_scale_manager.?,
            surface,
        ) orelse return error.WaylandFractionalScaleFailed;
        if (c.wp_fractional_scale_v1_add_listener(self.fractional_scale.?, &fractional_scale_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        self.applySurfaceScale();
    }

    fn applyConfiguredSize(self: *Window, width: i32, height: i32) void {
        if (width > 0) {
            const content_width = width - 2 * csd_border;
            self.content_width = @max(content_width, 1);
        }
        if (height > 0) {
            const content_height = height - csd_titlebar_height - csd_border;
            self.content_height = @max(content_height, 1);
        }
        self.recomputeFramebufferSize();
        self.applySurfaceScale();
        self.updateWindowGeometry();
        self.refreshClientDecorations() catch {
            self.should_close = true;
        };
    }

    fn rememberConfiguredSize(self: *Window, width: i32, height: i32) void {
        self.pending_width = width;
        self.pending_height = height;
    }

    fn effectiveScaleNumerator(self: *const Window) u32 {
        return @max(self.preferred_fractional_scale, 1);
    }

    fn recomputeFramebufferSize(self: *Window) void {
        const scale = self.effectiveScaleNumerator();
        self.framebuffer_width = scaleDimension(self.content_width, scale);
        self.framebuffer_height = scaleDimension(self.content_height, scale);
        if (self.pointer_surface == .content) self.setContentCursor(self.pointer_x, self.pointer_y);
    }

    fn applySurfaceScale(self: *Window) void {
        const surface = self.surface orelse return;
        c.wl_surface_set_buffer_scale(surface, 1);
        c.wp_viewport_set_destination(self.main_viewport.?, self.content_width, self.content_height);
    }

    fn applyScaleChange(self: *Window) void {
        self.recomputeFramebufferSize();
        self.applySurfaceScale();
        self.updateWindowGeometry();
        if (self.configured) {
            self.refreshClientDecorations() catch {
                self.should_close = true;
            };
        }
    }

    fn updateWindowGeometry(self: *Window) void {
        const xdg_surface = self.xdg_surface orelse return;
        const width = self.content_width;
        const height = self.content_height;
        c.xdg_surface_set_window_geometry(
            xdg_surface,
            -csd_border,
            -csd_titlebar_height,
            width + 2 * csd_border,
            height + csd_titlebar_height + csd_border,
        );
    }

    fn refreshClientDecorations(self: *Window) !void {
        if (self.compositor == null or self.subcompositor == null or self.shm == null or self.surface == null) return;
        self.csd_repaint_deferred = false;
        try self.decorations.paint(self);
        c.wl_surface_commit(self.surface.?);
    }

    fn roleForSurface(self: *const Window, surface: ?*c.struct_wl_surface) PointerSurface {
        const surface_ptr = surface orelse return .content;
        if (self.surface != null and surface_ptr == self.surface.?) return .content;
        return self.decorations.roleForSurface(surface_ptr) orelse .content;
    }

    fn rememberPointer(self: *Window, surface: ?*c.struct_wl_surface, x: f64, y: f64) void {
        self.pointer_surface = self.roleForSurface(surface);
        self.pointer_x = x;
        self.pointer_y = y;
        if (self.pointer_surface == .content) self.setContentCursor(x, y);
    }

    fn setContentCursor(self: *Window, x: f64, y: f64) void {
        const scale = scaleFloat(self.effectiveScaleNumerator());
        self.input_state.setCursor(x * scale, y * scale);
    }

    fn handlePointerButton(self: *Window, serial: u32, button: u32, pressed: bool) void {
        if (self.pointer_surface == .content) {
            switch (button) {
                btn_left => self.input_state.setMouseButton(.left, pressed),
                btn_right => self.input_state.setMouseButton(.right, pressed),
                else => {},
            }
            return;
        }

        if (!pressed or button != btn_left) return;
        if (self.toplevel == null or self.seat == null) return;

        switch (self.pointer_surface) {
            .content => unreachable,
            .titlebar => {
                if (self.pointerHitsCloseButton()) {
                    self.should_close = true;
                } else if (self.titlebarResizeEdge()) |edge| {
                    c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, edge);
                } else {
                    c.xdg_toplevel_move(self.toplevel.?, self.seat.?, serial);
                }
            },
            .left_border => c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, self.sideResizeEdge(.left_border)),
            .right_border => c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, self.sideResizeEdge(.right_border)),
            .bottom_border => c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, self.bottomResizeEdge()),
        }
    }

    fn pointerHitsCloseButton(self: *const Window) bool {
        const width = @as(f64, @floatFromInt(self.content_width)) +
            2.0 * @as(f64, @floatFromInt(csd_border));
        const left = width - csd_close_margin - csd_close_size;
        const top = (@as(f64, @floatFromInt(csd_titlebar_height)) - csd_close_size) * 0.5;
        return self.pointer_x >= left and self.pointer_x <= left + csd_close_size and
            self.pointer_y >= top and self.pointer_y <= top + csd_close_size;
    }

    fn titlebarResizeEdge(self: *const Window) ?u32 {
        const width = @as(f64, @floatFromInt(self.content_width)) +
            2.0 * @as(f64, @floatFromInt(csd_border));
        if (self.pointer_y > @as(f64, @floatFromInt(csd_border))) return null;
        if (self.pointer_x <= csd_corner_extent) return resize_edge_top_left;
        if (self.pointer_x >= width - csd_corner_extent) return resize_edge_top_right;
        return resize_edge_top;
    }

    fn sideResizeEdge(self: *const Window, surface_role: PointerSurface) u32 {
        const height = @as(f64, @floatFromInt(self.content_height));
        if (surface_role == .left_border and self.pointer_y >= height - csd_corner_extent) {
            return resize_edge_bottom_left;
        }
        if (surface_role == .right_border and self.pointer_y >= height - csd_corner_extent) {
            return resize_edge_bottom_right;
        }
        return if (surface_role == .left_border) resize_edge_left else resize_edge_right;
    }

    fn bottomResizeEdge(self: *const Window) u32 {
        const width = @as(f64, @floatFromInt(self.content_width)) +
            2.0 * @as(f64, @floatFromInt(csd_border));
        if (self.pointer_x <= csd_corner_extent) return resize_edge_bottom_left;
        if (self.pointer_x >= width - csd_corner_extent) return resize_edge_bottom_right;
        return resize_edge_bottom;
    }

    fn installKeymap(self: *Window, fd: std.posix.fd_t, size: u32) !void {
        if (size == 0) return error.WaylandKeymapFailed;

        const context = self.xkb_context orelse blk: {
            const new_context = c.xkb_context_new(c.XKB_CONTEXT_NO_FLAGS) orelse return error.WaylandKeymapFailed;
            self.xkb_context = new_context;
            break :blk new_context;
        };

        const keymap_bytes = try std.posix.mmap(
            null,
            @intCast(size),
            .{ .READ = true },
            .{ .TYPE = .PRIVATE },
            fd,
            0,
        );
        defer std.posix.munmap(keymap_bytes);

        const keymap = c.xkb_keymap_new_from_string(
            context,
            @ptrCast(keymap_bytes.ptr),
            c.XKB_KEYMAP_FORMAT_TEXT_V1,
            c.XKB_KEYMAP_COMPILE_NO_FLAGS,
        ) orelse return error.WaylandKeymapFailed;
        errdefer c.xkb_keymap_unref(keymap);

        const state = c.xkb_state_new(keymap) orelse return error.WaylandKeymapFailed;
        self.releaseKeymap();
        self.xkb_keymap = keymap;
        self.xkb_state = state;
    }

    fn releaseKeymap(self: *Window) void {
        if (self.xkb_state) |state| c.xkb_state_unref(state);
        if (self.xkb_keymap) |keymap| c.xkb_keymap_unref(keymap);
        self.xkb_state = null;
        self.xkb_keymap = null;
    }

    fn mapKeyboardKey(self: *Window, key: u32) ?demo_input.Key {
        if (self.xkb_state) |state| {
            const keycode: c.xkb_keycode_t = @intCast(key + xkb_keycode_offset);
            if (mapKeysym(c.xkb_state_key_get_one_sym(state, keycode))) |mapped| return mapped;
        }
        return mapRawKey(key);
    }

    fn updateXkbModifiers(
        self: *Window,
        mods_depressed: u32,
        mods_latched: u32,
        mods_locked: u32,
        group: u32,
    ) void {
        const state = self.xkb_state orelse return;
        _ = c.xkb_state_update_mask(
            state,
            mods_depressed,
            mods_latched,
            mods_locked,
            0,
            0,
            group,
        );
    }
};

pub fn getRequiredInstanceExtensions() []const [*:0]const u8 {
    return &required_instance_extensions;
}

pub fn getInstanceProcAddress(instance: vk.Instance, name: [*:0]const u8) vk.PfnVoidFunction {
    const get_proc = vk_get_instance_proc_addr orelse return null;
    return get_proc(instance, name);
}

fn loadVulkanLoader() !void {
    if (vk_get_instance_proc_addr != null) return;

    var loader = std.DynLib.open("libvulkan.so.1") catch
        std.DynLib.open("libvulkan.so") catch return error.VulkanLoaderUnavailable;
    const get_proc = loader.lookup(vk.PfnGetInstanceProcAddr, "vkGetInstanceProcAddr") orelse {
        loader.close();
        return error.VulkanLoaderUnavailable;
    };
    vulkan_loader = loader;
    vk_get_instance_proc_addr = get_proc;
}

const registry_listener = std.mem.zeroInit(c.wl_registry_listener, .{
    .global = registryGlobal,
    .global_remove = registryGlobalRemove,
});

fn registryGlobal(
    data: ?*anyopaque,
    registry: ?*c.struct_wl_registry,
    name: u32,
    interface: [*:0]const u8,
    version: u32,
) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(data.?));
    const registry_ptr = registry.?;
    const iface = std.mem.span(interface);
    if (std.mem.eql(u8, iface, "wl_compositor")) {
        if (version < 4) return;
        window.compositor = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.wl_compositor_interface, @min(version, 6)));
    } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
        window.subcompositor = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.wl_subcompositor_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        window.shm = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.wl_shm_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        window.wm_base = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.xdg_wm_base_interface, @min(version, 6)));
        if (window.wm_base) |wm_base| {
            _ = c.xdg_wm_base_add_listener(wm_base, &wm_base_listener, window);
        }
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        window.seat = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.wl_seat_interface, @min(version, 8)));
        if (window.seat) |seat| {
            _ = c.wl_seat_add_listener(seat, &seat_listener, window);
        }
    } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
        window.viewporter = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.wp_viewporter_interface, @min(version, 1)));
    } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
        window.fractional_scale_manager = @ptrCast(c.wl_registry_bind(registry_ptr, name, &c.wp_fractional_scale_manager_v1_interface, @min(version, 1)));
    }
}

fn registryGlobalRemove(data: ?*anyopaque, registry: ?*c.struct_wl_registry, name: u32) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

const wm_base_listener = std.mem.zeroInit(c.xdg_wm_base_listener, .{
    .ping = wmBasePing,
});

fn wmBasePing(data: ?*anyopaque, wm_base: ?*c.struct_xdg_wm_base, serial: u32) callconv(.c) void {
    _ = data;
    c.xdg_wm_base_pong(wm_base.?, serial);
}

const fractional_scale_listener = std.mem.zeroInit(c.wp_fractional_scale_v1_listener, .{
    .preferred_scale = fractionalScalePreferredScale,
});

fn fractionalScalePreferredScale(
    data: ?*anyopaque,
    fractional_scale: ?*c.struct_wp_fractional_scale_v1,
    scale: u32,
) callconv(.c) void {
    _ = fractional_scale;
    if (scale == 0) return;

    const window: *Window = @ptrCast(@alignCast(data.?));
    if (window.preferred_fractional_scale == scale) return;
    window.preferred_fractional_scale = scale;
    window.applyScaleChange();
}

const xdg_surface_listener = std.mem.zeroInit(c.xdg_surface_listener, .{
    .configure = xdgSurfaceConfigure,
});

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface.?, serial);
    window.configured = true;
    window.applyConfiguredSize(window.pending_width, window.pending_height);
    window.pending_width = 0;
    window.pending_height = 0;
}

const xdg_toplevel_listener = std.mem.zeroInit(c.xdg_toplevel_listener, .{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
});

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
    states: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = toplevel;
    _ = states;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.rememberConfiguredSize(width, height);
}

fn xdgToplevelClose(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.should_close = true;
}

const seat_listener = std.mem.zeroInit(c.wl_seat_listener, .{
    .capabilities = seatCapabilities,
    .name = seatName,
});

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(data.?));
    if ((capabilities & seat_capability_pointer) != 0 and window.pointer == null) {
        window.pointer = c.wl_seat_get_pointer(seat.?);
        if (window.pointer) |pointer| _ = c.wl_pointer_add_listener(pointer, &pointer_listener, window);
    } else if ((capabilities & seat_capability_pointer) == 0 and window.pointer != null) {
        c.wl_pointer_destroy(window.pointer.?);
        window.pointer = null;
        window.input_state.clearMouseButtons();
    }

    if ((capabilities & seat_capability_keyboard) != 0 and window.keyboard == null) {
        window.keyboard = c.wl_seat_get_keyboard(seat.?);
        if (window.keyboard) |keyboard| _ = c.wl_keyboard_add_listener(keyboard, &keyboard_listener, window);
    } else if ((capabilities & seat_capability_keyboard) == 0 and window.keyboard != null) {
        c.wl_keyboard_destroy(window.keyboard.?);
        window.keyboard = null;
        window.releaseKeymap();
        window.input_state.clearKeys();
    }
}

fn seatName(data: ?*anyopaque, seat: ?*c.struct_wl_seat, name: [*:0]const u8) callconv(.c) void {
    _ = data;
    _ = seat;
    _ = name;
}

const pointer_listener = std.mem.zeroInit(c.wl_pointer_listener, .{
    .enter = pointerEnter,
    .leave = pointerLeave,
    .motion = pointerMotion,
    .button = pointerButton,
    .axis = pointerAxis,
});

fn pointerEnter(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    serial: u32,
    surface: ?*c.struct_wl_surface,
    surface_x: c.wl_fixed_t,
    surface_y: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.rememberPointer(
        surface,
        c.wl_fixed_to_double(surface_x),
        c.wl_fixed_to_double(surface_y),
    );
}

fn pointerLeave(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    serial: u32,
    surface: ?*c.struct_wl_surface,
) callconv(.c) void {
    _ = pointer;
    _ = serial;
    _ = surface;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.pointer_surface = .content;
    window.input_state.clearMouseButtons();
}

fn pointerMotion(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    time_ms: u32,
    surface_x: c.wl_fixed_t,
    surface_y: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = time_ms;
    const window: *Window = @ptrCast(@alignCast(data.?));
    const x = c.wl_fixed_to_double(surface_x);
    const y = c.wl_fixed_to_double(surface_y);
    window.pointer_x = x;
    window.pointer_y = y;
    if (window.pointer_surface == .content) window.setContentCursor(x, y);
}

fn pointerButton(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    serial: u32,
    time_ms: u32,
    button: u32,
    state: u32,
) callconv(.c) void {
    _ = pointer;
    _ = time_ms;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.handlePointerButton(serial, button, state == pointer_button_pressed);
}

fn pointerAxis(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    time_ms: u32,
    axis: u32,
    value: c.wl_fixed_t,
) callconv(.c) void {
    _ = pointer;
    _ = time_ms;
    if (axis != pointer_axis_vertical_scroll) return;
    const window: *Window = @ptrCast(@alignCast(data.?));
    if (window.pointer_surface != .content) return;
    window.input_state.addScroll(-c.wl_fixed_to_double(value) / 120.0);
}

const keyboard_listener = std.mem.zeroInit(c.wl_keyboard_listener, .{
    .keymap = keyboardKeymap,
    .enter = keyboardEnter,
    .leave = keyboardLeave,
    .key = keyboardKey,
    .modifiers = keyboardModifiers,
    .repeat_info = keyboardRepeatInfo,
});

fn keyboardKeymap(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    format: u32,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = keyboard;
    defer if (fd >= 0) std.posix.close(fd);
    if (fd < 0) return;
    if (format != c.WL_KEYBOARD_KEYMAP_FORMAT_XKB_V1) return;

    const window: *Window = @ptrCast(@alignCast(data.?));
    window.installKeymap(fd, size) catch {
        window.releaseKeymap();
    };
}

fn keyboardEnter(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    surface: ?*c.struct_wl_surface,
    keys: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    _ = keys;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.input_state.clearKeys();
}

fn keyboardLeave(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    surface: ?*c.struct_wl_surface,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = surface;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.input_state.clearKeys();
}

fn keyboardKey(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    time_ms: u32,
    key: u32,
    state: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    _ = time_ms;
    const window: *Window = @ptrCast(@alignCast(data.?));
    const pressed = state == key_state_pressed;
    if (window.mapKeyboardKey(key)) |mapped| window.input_state.setKey(mapped, pressed);
}

fn keyboardModifiers(
    data: ?*anyopaque,
    keyboard: ?*c.struct_wl_keyboard,
    serial: u32,
    mods_depressed: u32,
    mods_latched: u32,
    mods_locked: u32,
    group: u32,
) callconv(.c) void {
    _ = keyboard;
    _ = serial;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.updateXkbModifiers(mods_depressed, mods_latched, mods_locked, group);
}

fn keyboardRepeatInfo(data: ?*anyopaque, keyboard: ?*c.struct_wl_keyboard, rate: i32, delay: i32) callconv(.c) void {
    _ = data;
    _ = keyboard;
    _ = rate;
    _ = delay;
}

fn mapRawKey(key: u32) ?demo_input.Key {
    return switch (key) {
        linux_key.esc => .escape,
        linux_key.space => .space,
        linux_key.equal => .equal,
        linux_key.minus => .minus,
        linux_key.b => .b,
        linux_key.r => .r,
        linux_key.up => .up,
        linux_key.down => .down,
        linux_key.left => .left,
        linux_key.right => .right,
        else => null,
    };
}

fn mapKeysym(sym: c.xkb_keysym_t) ?demo_input.Key {
    return switch (sym) {
        c.XKB_KEY_Escape => .escape,
        c.XKB_KEY_space => .space,
        c.XKB_KEY_equal, c.XKB_KEY_plus => .equal,
        c.XKB_KEY_minus, c.XKB_KEY_underscore => .minus,
        c.XKB_KEY_b, c.XKB_KEY_B => .b,
        c.XKB_KEY_r, c.XKB_KEY_R => .r,
        c.XKB_KEY_Up => .up,
        c.XKB_KEY_Down => .down,
        c.XKB_KEY_Left => .left,
        c.XKB_KEY_Right => .right,
        else => null,
    };
}

fn monotonicSeconds() f64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(f64, @floatFromInt(ts.sec)) +
        @as(f64, @floatFromInt(ts.nsec)) / @as(f64, @floatFromInt(std.time.ns_per_s));
}
