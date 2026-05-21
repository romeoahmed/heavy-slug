//! Wayland demo window, input, and Vulkan surface glue.

const std = @import("std");
const c = @import("wayland_c");
const vk = @import("vulkan");
const demo_input = @import("demo_input");
const demo_title = @import("demo_title");
const wayland_title = @import("wayland_title.zig");

const required_instance_extensions = [_][*:0]const u8{
    "VK_KHR_surface",
    "VK_KHR_wayland_surface",
};

var vulkan_loader: ?std.DynLib = null;
var vk_get_instance_proc_addr: ?vk.PfnGetInstanceProcAddr = null;

const app_id = "io.github.heavyslug.Demo";

const window_limits = struct {
    const min_content_width: i32 = 320;
    const min_content_height: i32 = 200;
};

const csd = struct {
    const resize_border: i32 = 6;
    const titlebar_height: i32 = 48;
    const resize_corner_extent: f64 = 24;
    const corner_radius: f64 = 12;
    const buffer_count = 3;

    const close = struct {
        const button_size: f64 = 34;
        const icon_size: f64 = 14;
        const margin: f64 = 6;
    };

    const color = struct {
        const transparent: u32 = 0x00000000;

        const light = struct {
            const headerbar_bg: u32 = 0xffffffff;
            const headerbar_backdrop: u32 = 0xfffafafa;
            const headerbar_fg: u32 = 0xff333333;
            const headerbar_backdrop_fg: u32 = 0xff77767b;
            const headerbar_shade: u32 = 0xffd9d9d9;
            const button_hover: u32 = 0xfff2f2f2;
        };

        const dark = struct {
            const headerbar_bg: u32 = 0xff303030;
            const headerbar_backdrop: u32 = 0xff242424;
            const headerbar_fg: u32 = 0xffffffff;
            const headerbar_backdrop_fg: u32 = 0xffc0bfbc;
            const headerbar_shade: u32 = 0xff4d4d4d;
            const button_hover: u32 = 0xff454545;
        };
    };
};

const wl = struct {
    const compositor = struct {
        const latest_xml_version: u32 = 7;
        const version: u32 = 6;
    };

    const shm = struct {
        const version: u32 = 2;
    };

    const subcompositor = struct {
        const version: u32 = 1;
    };

    const seat = struct {
        const version: u32 = 10;

        const capability = struct {
            const pointer: u32 = 1;
            const keyboard: u32 = 2;
        };
    };

    const pointer = struct {
        const button_state = struct {
            const pressed: u32 = c.WL_POINTER_BUTTON_STATE_PRESSED;
        };

        const axis = struct {
            const vertical_scroll: u32 = c.WL_POINTER_AXIS_VERTICAL_SCROLL;
            const value120_units_per_step: f64 = 120.0;
        };
    };

    const keyboard = struct {
        const keycode_offset: u32 = 8;

        const state = struct {
            const pressed: u32 = c.WL_KEYBOARD_KEY_STATE_PRESSED;
            const repeated: u32 = c.WL_KEYBOARD_KEY_STATE_REPEATED;
        };
    };
};

const xdg = struct {
    const wm_base = struct {
        const version: u32 = 7;
    };

    const toplevel = struct {
        const state = struct {
            const maximized: u32 = c.XDG_TOPLEVEL_STATE_MAXIMIZED;
            const fullscreen: u32 = c.XDG_TOPLEVEL_STATE_FULLSCREEN;
            const resizing: u32 = c.XDG_TOPLEVEL_STATE_RESIZING;
            const activated: u32 = c.XDG_TOPLEVEL_STATE_ACTIVATED;
            const tiled_left: u32 = c.XDG_TOPLEVEL_STATE_TILED_LEFT;
            const tiled_right: u32 = c.XDG_TOPLEVEL_STATE_TILED_RIGHT;
            const tiled_top: u32 = c.XDG_TOPLEVEL_STATE_TILED_TOP;
            const tiled_bottom: u32 = c.XDG_TOPLEVEL_STATE_TILED_BOTTOM;
            const suspended: u32 = c.XDG_TOPLEVEL_STATE_SUSPENDED;
            const constrained_left: u32 = c.XDG_TOPLEVEL_STATE_CONSTRAINED_LEFT;
            const constrained_right: u32 = c.XDG_TOPLEVEL_STATE_CONSTRAINED_RIGHT;
            const constrained_top: u32 = c.XDG_TOPLEVEL_STATE_CONSTRAINED_TOP;
            const constrained_bottom: u32 = c.XDG_TOPLEVEL_STATE_CONSTRAINED_BOTTOM;
        };

        const wm_capability = struct {
            const window_menu: u32 = c.XDG_TOPLEVEL_WM_CAPABILITIES_WINDOW_MENU;
        };

        const resize_edge = struct {
            const top: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_TOP;
            const bottom: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM;
            const left: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_LEFT;
            const top_left: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_TOP_LEFT;
            const bottom_left: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_LEFT;
            const right: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_RIGHT;
            const top_right: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_TOP_RIGHT;
            const bottom_right: u32 = c.XDG_TOPLEVEL_RESIZE_EDGE_BOTTOM_RIGHT;
        };
    };
};

const wp = struct {
    const viewporter = struct {
        const version: u32 = 1;
    };

    const fractional_scale = struct {
        const manager_version: u32 = 1;
        const denominator: u32 = 120;
    };

    const cursor_shape = struct {
        const manager_version: u32 = 2;

        const default: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DEFAULT;
        const context_menu: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CONTEXT_MENU;
        const help: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_HELP;
        const pointer: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_POINTER;
        const progress: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_PROGRESS;
        const wait: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_WAIT;
        const cell: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CELL;
        const crosshair: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_CROSSHAIR;
        const text: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_TEXT;
        const vertical_text: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_VERTICAL_TEXT;
        const alias: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALIAS;
        const copy: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COPY;
        const move: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_MOVE;
        const no_drop: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NO_DROP;
        const not_allowed: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NOT_ALLOWED;
        const grab: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRAB;
        const grabbing: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_GRABBING;
        const e_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_E_RESIZE;
        const n_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_N_RESIZE;
        const ne_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NE_RESIZE;
        const nw_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NW_RESIZE;
        const s_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_S_RESIZE;
        const se_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SE_RESIZE;
        const sw_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_SW_RESIZE;
        const w_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_W_RESIZE;
        const ew_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_EW_RESIZE;
        const ns_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NS_RESIZE;
        const nesw_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NESW_RESIZE;
        const nwse_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_NWSE_RESIZE;
        const col_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_COL_RESIZE;
        const row_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ROW_RESIZE;
        const all_scroll: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_SCROLL;
        const zoom_in: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_IN;
        const zoom_out: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ZOOM_OUT;
        const dnd_ask: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_DND_ASK;
        const all_resize: u32 = c.WP_CURSOR_SHAPE_DEVICE_V1_SHAPE_ALL_RESIZE;
    };
};

const zwp = struct {
    const linux_dmabuf = struct {
        const version: u32 = 5;
    };
};

const linux_input = struct {
    const key = struct {
        const esc = c.KEY_ESC;
        const minus = c.KEY_MINUS;
        const equal = c.KEY_EQUAL;
        const r = c.KEY_R;
        const b = c.KEY_B;
        const space = c.KEY_SPACE;
        const up = c.KEY_UP;
        const left = c.KEY_LEFT;
        const right = c.KEY_RIGHT;
        const down = c.KEY_DOWN;
    };

    const button = struct {
        const left: u32 = c.BTN_LEFT;
        const right: u32 = c.BTN_RIGHT;
    };
};

pub const SurfaceCapabilities = struct {
    direct_swapchain: bool = true,
    /// The rendered content uses VK_KHR_wayland_surface. linux-dmabuf feedback
    /// is tracked for compositor GPU-import capability, while Vulkan WSI owns
    /// swapchain image allocation and present.
    linux_dmabuf: LinuxDmaBuf = .unavailable,
    decorations: DecorationMemory = .shared_memfd_wl_shm,

    pub const LinuxDmaBuf = enum {
        unavailable,
        advertised,
        surface_feedback_pending,
        surface_feedback_received,
    };

    pub const DecorationMemory = enum {
        none,
        shared_memfd_wl_shm,
    };

    pub fn supportsDirectSwapchain(self: SurfaceCapabilities) bool {
        return self.direct_swapchain;
    }
};

const PointerSurface = enum {
    content,
    titlebar,
    left_border,
    right_border,
    bottom_border,
};

const CursorShape = enum(u32) {
    default = wp.cursor_shape.default,
    context_menu = wp.cursor_shape.context_menu,
    help = wp.cursor_shape.help,
    pointer = wp.cursor_shape.pointer,
    progress = wp.cursor_shape.progress,
    wait = wp.cursor_shape.wait,
    cell = wp.cursor_shape.cell,
    crosshair = wp.cursor_shape.crosshair,
    text = wp.cursor_shape.text,
    vertical_text = wp.cursor_shape.vertical_text,
    alias = wp.cursor_shape.alias,
    copy = wp.cursor_shape.copy,
    move = wp.cursor_shape.move,
    no_drop = wp.cursor_shape.no_drop,
    not_allowed = wp.cursor_shape.not_allowed,
    grab = wp.cursor_shape.grab,
    grabbing = wp.cursor_shape.grabbing,
    n_resize = wp.cursor_shape.n_resize,
    e_resize = wp.cursor_shape.e_resize,
    s_resize = wp.cursor_shape.s_resize,
    w_resize = wp.cursor_shape.w_resize,
    ne_resize = wp.cursor_shape.ne_resize,
    nw_resize = wp.cursor_shape.nw_resize,
    se_resize = wp.cursor_shape.se_resize,
    sw_resize = wp.cursor_shape.sw_resize,
    ew_resize = wp.cursor_shape.ew_resize,
    ns_resize = wp.cursor_shape.ns_resize,
    nesw_resize = wp.cursor_shape.nesw_resize,
    nwse_resize = wp.cursor_shape.nwse_resize,
    col_resize = wp.cursor_shape.col_resize,
    row_resize = wp.cursor_shape.row_resize,
    all_scroll = wp.cursor_shape.all_scroll,
    zoom_in = wp.cursor_shape.zoom_in,
    zoom_out = wp.cursor_shape.zoom_out,
    dnd_ask = wp.cursor_shape.dnd_ask,
    all_resize = wp.cursor_shape.all_resize,
};

const DecorationPartRole = enum {
    titlebar,
    left_border,
    right_border,
    bottom_border,
};

const ToplevelState = struct {
    maximized: bool = false,
    fullscreen: bool = false,
    resizing: bool = false,
    activated: bool = false,
    suspended: bool = false,
    tiled_left: bool = false,
    tiled_right: bool = false,
    tiled_top: bool = false,
    tiled_bottom: bool = false,
    constrained_left: bool = false,
    constrained_right: bool = false,
    constrained_top: bool = false,
    constrained_bottom: bool = false,

    fn fromWire(states: []const u32) ToplevelState {
        var state: ToplevelState = .{};
        for (states) |wire_state| {
            switch (wire_state) {
                xdg.toplevel.state.maximized => state.maximized = true,
                xdg.toplevel.state.fullscreen => state.fullscreen = true,
                xdg.toplevel.state.resizing => state.resizing = true,
                xdg.toplevel.state.activated => state.activated = true,
                xdg.toplevel.state.tiled_left => state.tiled_left = true,
                xdg.toplevel.state.tiled_right => state.tiled_right = true,
                xdg.toplevel.state.tiled_top => state.tiled_top = true,
                xdg.toplevel.state.tiled_bottom => state.tiled_bottom = true,
                xdg.toplevel.state.suspended => state.suspended = true,
                xdg.toplevel.state.constrained_left => state.constrained_left = true,
                xdg.toplevel.state.constrained_right => state.constrained_right = true,
                xdg.toplevel.state.constrained_top => state.constrained_top = true,
                xdg.toplevel.state.constrained_bottom => state.constrained_bottom = true,
                else => {},
            }
        }
        return state;
    }

    fn canResize(self: ToplevelState) bool {
        return !self.maximized and !self.fullscreen;
    }

    fn canResizeLeft(self: ToplevelState) bool {
        return self.canResize() and !self.constrained_left;
    }

    fn canResizeRight(self: ToplevelState) bool {
        return self.canResize() and !self.constrained_right;
    }

    fn canResizeTop(self: ToplevelState) bool {
        return self.canResize() and !self.constrained_top;
    }

    fn canResizeBottom(self: ToplevelState) bool {
        return self.canResize() and !self.constrained_bottom;
    }
};

const WmCapabilities = struct {
    window_menu: bool = false,

    fn fromWire(capabilities: []const u32) WmCapabilities {
        var result: WmCapabilities = .{};
        for (capabilities) |capability| {
            switch (capability) {
                xdg.toplevel.wm_capability.window_menu => result.window_menu = true,
                else => {},
            }
        }
        return result;
    }
};

const ConfigureBounds = struct {
    width: i32 = 0,
    height: i32 = 0,
};

const ScaleState = struct {
    numerator: u32 = wp.fractional_scale.denominator,

    fn update(self: *ScaleState, scale_numerator: u32) bool {
        if (scale_numerator == 0 or self.numerator == scale_numerator) return false;
        self.numerator = scale_numerator;
        return true;
    }
};

const DecorationMetrics = struct {
    titlebar_height: i32 = csd.titlebar_height,
    left_border: i32 = csd.resize_border,
    right_border: i32 = csd.resize_border,
    bottom_border: i32 = csd.resize_border,

    fn forState(state: ToplevelState) DecorationMetrics {
        if (state.fullscreen) return .{
            .titlebar_height = 0,
            .left_border = 0,
            .right_border = 0,
            .bottom_border = 0,
        };

        if (state.maximized) return .{
            .left_border = 0,
            .right_border = 0,
            .bottom_border = 0,
        };

        return .{
            .left_border = if (state.tiled_left or state.constrained_left) 0 else csd.resize_border,
            .right_border = if (state.tiled_right or state.constrained_right) 0 else csd.resize_border,
            .bottom_border = if (state.tiled_bottom or state.constrained_bottom) 0 else csd.resize_border,
        };
    }

    fn outerWidth(self: DecorationMetrics, content_width: i32) i32 {
        return content_width + self.left_border + self.right_border;
    }

    fn outerHeight(self: DecorationMetrics, content_height: i32) i32 {
        return content_height + self.titlebar_height + self.bottom_border;
    }

    fn minWidth(self: DecorationMetrics) i32 {
        return self.outerWidth(window_limits.min_content_width);
    }

    fn minHeight(self: DecorationMetrics) i32 {
        return self.outerHeight(window_limits.min_content_height);
    }

    fn contentWidthFromOuter(self: DecorationMetrics, outer_width: i32) i32 {
        return @max(outer_width - self.left_border - self.right_border, 1);
    }

    fn contentHeightFromOuter(self: DecorationMetrics, outer_height: i32) i32 {
        return @max(outer_height - self.titlebar_height - self.bottom_border, 1);
    }
};

const PointerAxisFrame = struct {
    continuous_y: f64 = 0,
    value120_y: i32 = 0,
    has_continuous_y: bool = false,
    has_value120_y: bool = false,

    fn addAxis(self: *PointerAxisFrame, axis: u32, value: c.wl_fixed_t) void {
        if (axis != wl.pointer.axis.vertical_scroll) return;
        self.continuous_y += c.wl_fixed_to_double(value);
        self.has_continuous_y = true;
    }

    fn addValue120(self: *PointerAxisFrame, axis: u32, value120: i32) void {
        if (axis != wl.pointer.axis.vertical_scroll) return;
        self.value120_y += value120;
        self.has_value120_y = true;
    }

    fn flush(self: *PointerAxisFrame, window: *Window) void {
        defer self.* = .{};
        if (window.pointer_surface != .content) return;
        if (self.has_value120_y) {
            window.input_state.addScroll(-@as(f64, @floatFromInt(self.value120_y)) / wl.pointer.axis.value120_units_per_step);
        } else if (self.has_continuous_y) {
            window.input_state.addScroll(-self.continuous_y / wl.pointer.axis.value120_units_per_step);
        }
    }
};

const ClientDecorations = struct {
    titlebar: DecorationPart = .{ .role = .titlebar },
    left: DecorationPart = .{ .role = .left_border },
    right: DecorationPart = .{ .role = .right_border },
    bottom: DecorationPart = .{ .role = .bottom_border },

    fn paint(self: *ClientDecorations, window: *Window) !void {
        const content_width = window.content_width;
        const content_height = window.content_height;
        const metrics = window.decorationMetrics();
        const outer_width = metrics.outerWidth(content_width);

        try self.titlebar.paint(window, -metrics.left_border, -metrics.titlebar_height, outer_width, metrics.titlebar_height);
        try self.left.paint(window, -metrics.left_border, 0, metrics.left_border, content_height);
        try self.right.paint(window, content_width, 0, metrics.right_border, content_height);
        try self.bottom.paint(window, -metrics.left_border, content_height, outer_width, metrics.bottom_border);
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
    buffers: [csd.buffer_count]?*DecorationBuffer = .{null} ** csd.buffer_count,
    active_buffer: ?*DecorationBuffer = null,
    logical_width: i32 = 0,
    logical_height: i32 = 0,
    buffer_width: i32 = 0,
    buffer_height: i32 = 0,
    painted_dark_mode: ?bool = null,
    painted_active: ?bool = null,
    painted_close_hover: ?bool = null,
    painted_scale_numerator: u32 = 0,

    fn paint(self: *DecorationPart, window: *Window, x: i32, y: i32, width: i32, height: i32) !void {
        if (width <= 0 or height <= 0) {
            self.hide();
            return;
        }
        if (self.surface == null) try self.createSurface(window);

        const scale_numerator = window.effectiveScaleNumerator();
        const pixel_width = @as(i32, @intCast(scaleDimension(width, scale_numerator)));
        const pixel_height = @as(i32, @intCast(scaleDimension(height, scale_numerator)));
        const close_hover_changed = self.role == .titlebar and
            (self.painted_close_hover == null or self.painted_close_hover.? != window.close_button_hover);
        const needs_repaint = self.active_buffer == null or
            self.logical_width != width or
            self.logical_height != height or
            self.buffer_width != pixel_width or
            self.buffer_height != pixel_height or
            self.painted_dark_mode == null or
            self.painted_dark_mode.? != window.dark_mode or
            self.painted_active == null or
            self.painted_active.? != window.toplevel_state.activated or
            close_hover_changed or
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
            self.painted_active = window.toplevel_state.activated;
            self.painted_close_hover = window.close_button_hover;
        }

        const active_buffer = self.active_buffer orelse return;
        try self.applySurfaceScale(window, width, height);
        c.wl_subsurface_set_position(self.subsurface.?, x, y);
        c.wl_surface_attach(self.surface.?, active_buffer.buffer, 0, 0);
        c.wl_surface_damage_buffer(self.surface.?, 0, 0, pixel_width, pixel_height);
        active_buffer.busy = true;
        c.wl_surface_commit(self.surface.?);
    }

    fn hide(self: *DecorationPart) void {
        self.destroyBuffer();
        const surface = self.surface orelse return;
        c.wl_surface_attach(surface, null, 0, 0);
        c.wl_surface_commit(surface);
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
        const colors = decorationColors(window.dark_mode, window.toplevel_state.activated);
        const fill = switch (self.role) {
            .titlebar => colors.titlebar,
            else => csd.color.transparent,
        };
        @memset(pixels, fill);

        const width: usize = @intCast(self.buffer_width);
        const height: usize = @intCast(self.buffer_height);
        if (width == 0 or height == 0) return;

        switch (self.role) {
            .titlebar => self.paintTitlebarPixels(window, pixels, width, height, colors),
            .left_border, .right_border, .bottom_border => self.paintResizeBorderPixels(pixels, width, height, colors),
        }
    }

    fn paintResizeBorderPixels(
        self: *const DecorationPart,
        pixels: []u32,
        width: usize,
        height: usize,
        colors: DecorationColors,
    ) void {
        switch (self.role) {
            .left_border => for (0..height) |y| {
                pixels[y * width + width - 1] = colors.border;
            },
            .right_border => for (0..height) |y| {
                pixels[y * width] = colors.border;
            },
            .bottom_border => for (0..width) |x| {
                pixels[x] = colors.border;
            },
            .titlebar => unreachable,
        }
    }

    fn paintTitlebarPixels(
        self: *const DecorationPart,
        window: *const Window,
        pixels: []u32,
        width: usize,
        height: usize,
        colors: DecorationColors,
    ) void {
        if (window.roundedTitlebarCorners()) {
            self.clearRoundedTitlebarCorners(window, pixels, width, height);
        }

        for (0..width) |x| {
            pixels[(height - 1) * width + x] = colors.border;
        }

        const scale = scaleFloat(self.painted_scale_numerator);
        const button = closeButtonRect(self.logical_width, self.logical_height);
        const button_left = roundPositiveToI32(button.x * scale);
        const button_top = roundPositiveToI32(button.y * scale);
        const button_extent = @max(roundPositiveToI32(button.size * scale), 1);
        if (window.title) |title| {
            if (wayland_title.layout(self.buffer_width, self.buffer_height, button_left, scale, title)) |layout| {
                wayland_title.paint(pixels, width, title, layout, colors.foreground);
            }
        }
        if (window.close_button_hover and window.toplevel_state.activated) {
            self.paintRoundButton(pixels, width, button_left, button_top, button_extent, colors.button_hover);
        }

        const icon_extent = @max(roundPositiveToI32(csd.close.icon_size * scale), 1);
        const icon_left = button_left + @divTrunc(button_extent - icon_extent, 2);
        const icon_top = button_top + @divTrunc(button_extent - icon_extent, 2);
        const icon_right = icon_left + icon_extent;
        const icon_bottom = icon_top + icon_extent;
        const diagonal_thickness = @max(roundPositiveToI32(scale), 1);
        const icon_left_u: usize = @intCast(@max(icon_left, 0));
        const icon_top_u: usize = @intCast(@max(icon_top, 0));
        const icon_right_u: usize = @intCast(@min(icon_right, self.buffer_width));
        const icon_bottom_u: usize = @intCast(@min(icon_bottom, self.buffer_height));

        for (icon_top_u..icon_bottom_u) |uy| {
            for (icon_left_u..icon_right_u) |ux| {
                const x: i32 = @intCast(ux);
                const y: i32 = @intCast(uy);
                const dx = x - icon_left;
                const dy = y - icon_top;
                const max = icon_extent - 1;
                const on_x = @abs(dx - dy) <= diagonal_thickness or @abs(dx + dy - max) <= diagonal_thickness;
                if (on_x) pixels[uy * width + ux] = colors.foreground;
            }
        }
    }

    fn paintRoundButton(
        self: *const DecorationPart,
        pixels: []u32,
        width: usize,
        left: i32,
        top: i32,
        extent: i32,
        color: u32,
    ) void {
        _ = self;
        if (extent <= 0) return;
        const height: i32 = @intCast(pixels.len / width);
        const left_u: usize = @intCast(@max(left, 0));
        const top_u: usize = @intCast(@max(top, 0));
        const right_u: usize = @intCast(@max(@min(left + extent, @as(i32, @intCast(width))), 0));
        const bottom_u: usize = @intCast(@max(@min(top + extent, height), 0));
        if (left_u >= right_u or top_u >= bottom_u) return;
        const radius = @divTrunc(extent, 2);
        const radius_sq = @as(i64, radius) * @as(i64, radius);

        for (top_u..bottom_u) |uy| {
            for (left_u..right_u) |ux| {
                const dx = @as(i32, @intCast(ux)) - left - radius;
                const dy = @as(i32, @intCast(uy)) - top - radius;
                if (@as(i64, dx) * @as(i64, dx) + @as(i64, dy) * @as(i64, dy) <= radius_sq) {
                    pixels[uy * width + ux] = color;
                }
            }
        }
    }

    fn clearRoundedTitlebarCorners(
        self: *const DecorationPart,
        window: *const Window,
        pixels: []u32,
        width: usize,
        height: usize,
    ) void {
        _ = self;
        const scale = scaleFloat(window.effectiveScaleNumerator());
        const radius = @min(roundPositiveToI32(csd.corner_radius * scale), @as(i32, @intCast(@min(width, height))));
        if (radius <= 0) return;

        const state = window.toplevel_state;
        const round_left = !state.tiled_left and !state.constrained_left;
        const round_right = !state.tiled_right and !state.constrained_right;
        const radius_sq = @as(i64, radius) * @as(i64, radius);
        const radius_u: usize = @intCast(radius);

        for (0..radius_u) |uy| {
            for (0..radius_u) |ux| {
                const dx = radius - 1 - @as(i32, @intCast(ux));
                const dy = radius - 1 - @as(i32, @intCast(uy));
                if (@as(i64, dx) * @as(i64, dx) + @as(i64, dy) * @as(i64, dy) < radius_sq) continue;
                if (round_left) pixels[uy * width + ux] = csd.color.transparent;
                if (round_right) pixels[uy * width + (width - 1 - ux)] = csd.color.transparent;
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
        self.painted_active = null;
        self.painted_close_hover = null;
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
    foreground: u32,
    button_hover: u32,
};

fn decorationColors(dark: bool, active: bool) DecorationColors {
    return if (dark)
        .{
            .titlebar = if (active) csd.color.dark.headerbar_bg else csd.color.dark.headerbar_backdrop,
            .border = csd.color.dark.headerbar_shade,
            .foreground = if (active) csd.color.dark.headerbar_fg else csd.color.dark.headerbar_backdrop_fg,
            .button_hover = csd.color.dark.button_hover,
        }
    else
        .{
            .titlebar = if (active) csd.color.light.headerbar_bg else csd.color.light.headerbar_backdrop,
            .border = csd.color.light.headerbar_shade,
            .foreground = if (active) csd.color.light.headerbar_fg else csd.color.light.headerbar_backdrop_fg,
            .button_hover = csd.color.light.button_hover,
        };
}

const CloseButtonRect = struct {
    x: f64,
    y: f64,
    size: f64,
};

fn closeButtonRect(width: i32, height: i32) CloseButtonRect {
    const content_height = @as(f64, @floatFromInt(@max(height, 1)));
    const size = @min(csd.close.button_size, @max(content_height - 8, csd.close.icon_size));
    return .{
        .x = @as(f64, @floatFromInt(width)) - csd.close.margin - size,
        .y = (content_height - size) * 0.5,
        .size = size,
    };
}

fn scaleDimension(logical: i32, scale_numerator: u32) u32 {
    const clamped: u64 = @intCast(@max(logical, 1));
    const numerator: u64 = @intCast(@max(scale_numerator, 1));
    const denominator: u64 = wp.fractional_scale.denominator;
    const rounded = (clamped * numerator + denominator / 2) / denominator;
    return @intCast(@max(rounded, 1));
}

fn scaleFloat(scale_numerator: u32) f64 {
    return @as(f64, @floatFromInt(@max(scale_numerator, 1))) /
        @as(f64, @floatFromInt(wp.fractional_scale.denominator));
}

fn roundPositiveToI32(value: f64) i32 {
    return @intFromFloat(@floor(@max(value, 0) + 0.5));
}

fn cursorShapeForResizeEdge(edge: u32) CursorShape {
    return switch (edge) {
        xdg.toplevel.resize_edge.top => .n_resize,
        xdg.toplevel.resize_edge.bottom => .s_resize,
        xdg.toplevel.resize_edge.left => .w_resize,
        xdg.toplevel.resize_edge.right => .e_resize,
        xdg.toplevel.resize_edge.top_left => .nw_resize,
        xdg.toplevel.resize_edge.top_right => .ne_resize,
        xdg.toplevel.resize_edge.bottom_left => .sw_resize,
        xdg.toplevel.resize_edge.bottom_right => .se_resize,
        else => .default,
    };
}

fn bindVersion(advertised: u32, required: u32) u32 {
    std.debug.assert(advertised >= required);
    return required;
}

fn bindExactVersion(advertised: u32, required: u32) ?u32 {
    if (advertised < required) return null;
    return required;
}

fn supportsVersion(advertised: u32, required: u32) bool {
    return advertised >= required;
}

const FlushResult = enum {
    flushed,
    blocked,
};

fn flushDisplay(display: *c.struct_wl_display) !FlushResult {
    const rc = c.wl_display_flush(display);
    return switch (std.c.errno(rc)) {
        .SUCCESS => .flushed,
        .AGAIN => .blocked,
        else => error.WaylandDispatchFailed,
    };
}

fn resizeMemfd(fd: std.posix.fd_t, size: usize) !void {
    const rc = std.os.linux.ftruncate(fd, @intCast(size));
    switch (std.posix.errno(rc)) {
        .SUCCESS => {},
        else => return error.WaylandBufferFailed,
    }
}

pub const Window = struct {
    allocator: ?std.mem.Allocator = null,
    title: ?[:0]u8 = null,
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
    linux_dmabuf: ?*c.struct_zwp_linux_dmabuf_v1 = null,
    linux_dmabuf_version: u32 = 0,
    dmabuf_surface_feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1 = null,
    dmabuf_feedback_received: bool = false,
    dmabuf_format_table_size: u32 = 0,
    cursor_shape_manager: ?*c.struct_wp_cursor_shape_manager_v1 = null,
    cursor_shape_device: ?*c.struct_wp_cursor_shape_device_v1 = null,
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
    pointer_enter_serial: u32 = 0,
    pointer_axis_frame: PointerAxisFrame = .{},
    last_cursor_shape: ?CursorShape = null,
    input_state: demo_input.State = .{},
    content_width: i32 = 0,
    content_height: i32 = 0,
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,
    configured: bool = false,
    pending_width: i32 = 0,
    pending_height: i32 = 0,
    toplevel_state: ToplevelState = .{},
    pending_toplevel_state: ToplevelState = .{},
    pending_toplevel_state_dirty: bool = false,
    wm_capabilities: WmCapabilities = .{},
    pending_wm_capabilities: WmCapabilities = .{},
    pending_wm_capabilities_dirty: bool = false,
    configure_bounds: ConfigureBounds = .{},
    pending_configure_bounds: ConfigureBounds = .{},
    pending_configure_bounds_dirty: bool = false,
    scale_state: ScaleState = .{},
    csd_repaint_deferred: bool = false,
    close_button_hover: bool = false,
    dark_mode: bool = false,
    start_time: f64 = 0,

    pub fn init(self: *Window, allocator: std.mem.Allocator, width: c_int, height: c_int, title: []const u8) !void {
        const title_z = try demo_title.allocUtf8Z(allocator, title);
        var title_transferred = false;
        errdefer if (!title_transferred) allocator.free(title_z);

        try loadVulkanLoader();

        const display = c.wl_display_connect(null) orelse return error.WaylandConnectFailed;
        var display_transferred = false;
        errdefer if (!display_transferred) c.wl_display_disconnect(display);

        self.* = .{
            .allocator = allocator,
            .title = title_z,
            .display = display,
            .content_width = @max(width, 1),
            .content_height = @max(height, 1),
            .start_time = monotonicSeconds(),
        };
        display_transferred = true;
        title_transferred = true;
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
            self.fractional_scale_manager == null or
            self.cursor_shape_manager == null)
        {
            return error.WaylandGlobalsMissing;
        }

        self.surface = c.wl_compositor_create_surface(self.compositor) orelse return error.WaylandSurfaceFailed;
        if (c.wl_surface_add_listener(self.surface.?, &surface_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        try self.createScaleObjects();
        try self.createDmaBufFeedback();

        self.xdg_surface = c.xdg_wm_base_get_xdg_surface(self.wm_base, self.surface) orelse return error.WaylandSurfaceFailed;
        if (c.xdg_surface_add_listener(self.xdg_surface, &xdg_surface_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }

        self.toplevel = c.xdg_surface_get_toplevel(self.xdg_surface) orelse return error.WaylandSurfaceFailed;
        if (c.xdg_toplevel_add_listener(self.toplevel, &xdg_toplevel_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        c.xdg_toplevel_set_title(self.toplevel, self.title.?.ptr);
        c.xdg_toplevel_set_app_id(self.toplevel, app_id);
        self.updateMinimumSize();
        self.updateWindowGeometry();
        c.wl_surface_commit(self.surface);

        while (!self.configured and !self.should_close) {
            if (c.wl_display_dispatch(display) < 0) return error.WaylandDispatchFailed;
        }
    }

    pub fn deinit(self: *Window) void {
        self.decorations.deinit();
        self.destroyCursorShapeDevice();
        if (self.keyboard) |keyboard| c.wl_keyboard_release(keyboard);
        self.releaseKeymap();
        if (self.xkb_context) |context| c.xkb_context_unref(context);
        if (self.pointer) |pointer| c.wl_pointer_release(pointer);
        if (self.seat) |seat| c.wl_seat_release(seat);
        if (self.toplevel) |toplevel| c.xdg_toplevel_destroy(toplevel);
        if (self.xdg_surface) |xdg_surface| c.xdg_surface_destroy(xdg_surface);
        if (self.fractional_scale) |scale| c.wp_fractional_scale_v1_destroy(scale);
        if (self.main_viewport) |viewport| c.wp_viewport_destroy(viewport);
        if (self.dmabuf_surface_feedback) |feedback| c.zwp_linux_dmabuf_feedback_v1_destroy(feedback);
        if (self.surface) |surface| c.wl_surface_destroy(surface);
        if (self.cursor_shape_manager) |manager| c.wp_cursor_shape_manager_v1_destroy(manager);
        if (self.linux_dmabuf) |dmabuf| c.zwp_linux_dmabuf_v1_destroy(dmabuf);
        if (self.fractional_scale_manager) |manager| c.wp_fractional_scale_manager_v1_destroy(manager);
        if (self.viewporter) |viewporter| c.wp_viewporter_destroy(viewporter);
        if (self.wm_base) |wm_base| c.xdg_wm_base_destroy(wm_base);
        if (self.shm) |shm| c.wl_shm_release(shm);
        if (self.subcompositor) |subcompositor| c.wl_subcompositor_destroy(subcompositor);
        if (self.compositor) |compositor| c.wl_proxy_destroy(@ptrCast(compositor));
        if (self.registry) |registry| c.wl_registry_destroy(registry);
        c.wl_display_disconnect(self.display);
        if (self.title) |title| {
            self.allocator.?.free(title);
        }
        self.title = null;
        self.allocator = null;
    }

    pub fn pollEvents(self: *Window) void {
        self.pollEventsTimeout(0);
    }

    pub fn pollEventsTimeout(self: *Window, timeout_ms: i32) void {
        self.dispatchEvents(timeout_ms) catch {
            self.should_close = true;
            return;
        };
        if (self.configured and self.csd_repaint_deferred) {
            self.refreshClientDecorations() catch {
                self.should_close = true;
            };
        }
    }

    fn dispatchEvents(self: *Window, timeout_ms: i32) !void {
        while (c.wl_display_prepare_read(self.display) != 0) {
            if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatchFailed;
        }

        var prepared_read = true;
        defer if (prepared_read) c.wl_display_cancel_read(self.display);

        var poll_events = std.posix.POLL.IN;
        if (try flushDisplay(self.display) == .blocked) {
            poll_events |= std.posix.POLL.OUT;
        }
        var fds = [_]std.posix.pollfd{.{
            .fd = c.wl_display_get_fd(self.display),
            .events = poll_events,
            .revents = 0,
        }};

        const ready = try std.posix.poll(&fds, timeout_ms);
        const fatal_events = std.posix.POLL.ERR | std.posix.POLL.HUP | std.posix.POLL.NVAL;
        if ((fds[0].revents & fatal_events) != 0) {
            c.wl_display_cancel_read(self.display);
            prepared_read = false;
            return error.WaylandDispatchFailed;
        }

        if (ready == 0) return;

        if ((fds[0].revents & std.posix.POLL.IN) != 0) {
            const rc = c.wl_display_read_events(self.display);
            prepared_read = false;
            if (rc < 0) return error.WaylandDispatchFailed;
        } else {
            c.wl_display_cancel_read(self.display);
            prepared_read = false;
        }

        if ((fds[0].revents & std.posix.POLL.OUT) != 0) {
            _ = try flushDisplay(self.display);
        }

        if (c.wl_display_dispatch_pending(self.display) < 0) return error.WaylandDispatchFailed;
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

    pub fn surfaceCapabilities(self: *const Window) SurfaceCapabilities {
        return .{
            .linux_dmabuf = self.linuxDmaBufState(),
            .decorations = .shared_memfd_wl_shm,
        };
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

    fn createDmaBufFeedback(self: *Window) !void {
        const dmabuf = self.linux_dmabuf orelse return;
        if (self.linux_dmabuf_version < zwp.linux_dmabuf.version) return;
        const surface = self.surface orelse return;
        const feedback = c.zwp_linux_dmabuf_v1_get_surface_feedback(dmabuf, surface) orelse {
            return error.WaylandDmaBufFeedbackFailed;
        };
        errdefer c.zwp_linux_dmabuf_feedback_v1_destroy(feedback);
        if (c.zwp_linux_dmabuf_feedback_v1_add_listener(feedback, &dmabuf_feedback_listener, self) != 0) {
            return error.WaylandListenerFailed;
        }
        self.dmabuf_surface_feedback = feedback;
    }

    fn linuxDmaBufState(self: *const Window) SurfaceCapabilities.LinuxDmaBuf {
        if (self.linux_dmabuf == null) return .unavailable;
        if (self.dmabuf_surface_feedback == null) return .advertised;
        return if (self.dmabuf_feedback_received) .surface_feedback_received else .surface_feedback_pending;
    }

    fn decorationMetrics(self: *const Window) DecorationMetrics {
        return DecorationMetrics.forState(self.toplevel_state);
    }

    fn roundedTitlebarCorners(self: *const Window) bool {
        const state = self.toplevel_state;
        return !state.maximized and
            !state.fullscreen and
            !state.tiled_top and
            !state.constrained_top;
    }

    fn applyPendingConfigure(self: *Window) void {
        if (self.pending_toplevel_state_dirty) {
            self.toplevel_state = self.pending_toplevel_state;
            self.pending_toplevel_state_dirty = false;
        }
        if (self.pending_wm_capabilities_dirty) {
            self.wm_capabilities = self.pending_wm_capabilities;
            self.pending_wm_capabilities_dirty = false;
        }
        if (self.pending_configure_bounds_dirty) {
            self.configure_bounds = self.pending_configure_bounds;
            self.pending_configure_bounds_dirty = false;
        }

        self.applyConfiguredSize(self.pending_width, self.pending_height);
        self.pending_width = 0;
        self.pending_height = 0;
        self.updateCursorShape();
    }

    fn applyConfiguredSize(self: *Window, width: i32, height: i32) void {
        const metrics = self.decorationMetrics();
        if (width > 0) {
            self.content_width = metrics.contentWidthFromOuter(width);
        } else if (self.configure_bounds.width > 0 and metrics.outerWidth(self.content_width) > self.configure_bounds.width) {
            self.content_width = metrics.contentWidthFromOuter(self.configure_bounds.width);
        }
        if (height > 0) {
            self.content_height = metrics.contentHeightFromOuter(height);
        } else if (self.configure_bounds.height > 0 and metrics.outerHeight(self.content_height) > self.configure_bounds.height) {
            self.content_height = metrics.contentHeightFromOuter(self.configure_bounds.height);
        }
        self.recomputeFramebufferSize();
        self.applySurfaceScale();
        self.updateMinimumSize();
        self.updateWindowGeometry();
        self.refreshClientDecorations() catch {
            self.should_close = true;
        };
    }

    fn rememberConfiguredSize(self: *Window, width: i32, height: i32) void {
        self.pending_width = width;
        self.pending_height = height;
    }

    fn rememberToplevelState(self: *Window, states: []const u32) void {
        self.pending_toplevel_state = ToplevelState.fromWire(states);
        self.pending_toplevel_state_dirty = true;
    }

    fn rememberWmCapabilities(self: *Window, capabilities: []const u32) void {
        self.pending_wm_capabilities = WmCapabilities.fromWire(capabilities);
        self.pending_wm_capabilities_dirty = true;
    }

    fn rememberConfigureBounds(self: *Window, width: i32, height: i32) void {
        self.pending_configure_bounds = .{ .width = width, .height = height };
        self.pending_configure_bounds_dirty = true;
    }

    fn effectiveScaleNumerator(self: *const Window) u32 {
        return @max(self.scale_state.numerator, 1);
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
        const metrics = self.decorationMetrics();
        const width = self.content_width;
        const height = self.content_height;
        c.xdg_surface_set_window_geometry(
            xdg_surface,
            -metrics.left_border,
            -metrics.titlebar_height,
            metrics.outerWidth(width),
            metrics.outerHeight(height),
        );
    }

    fn updateMinimumSize(self: *Window) void {
        const toplevel = self.toplevel orelse return;
        const metrics = self.decorationMetrics();
        c.xdg_toplevel_set_min_size(toplevel, metrics.minWidth(), metrics.minHeight());
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
        self.updateCloseButtonHover();
        self.updateCursorShape();
    }

    fn setContentCursor(self: *Window, x: f64, y: f64) void {
        const scale = scaleFloat(self.effectiveScaleNumerator());
        self.input_state.setCursor(x * scale, y * scale);
    }

    fn ensureCursorShapeDevice(self: *Window) void {
        if (self.cursor_shape_device != null) return;
        const manager = self.cursor_shape_manager orelse return;
        const pointer = self.pointer orelse return;
        self.cursor_shape_device = c.wp_cursor_shape_manager_v1_get_pointer(manager, pointer);
        self.last_cursor_shape = null;
        self.updateCursorShape();
    }

    fn destroyCursorShapeDevice(self: *Window) void {
        if (self.cursor_shape_device) |device| c.wp_cursor_shape_device_v1_destroy(device);
        self.cursor_shape_device = null;
        self.last_cursor_shape = null;
    }

    fn updateCursorShape(self: *Window) void {
        const device = self.cursor_shape_device orelse return;
        if (self.pointer_enter_serial == 0) return;
        const shape = self.cursorShapeForPointer();
        if (self.last_cursor_shape != null and self.last_cursor_shape.? == shape) return;
        c.wp_cursor_shape_device_v1_set_shape(device, self.pointer_enter_serial, @intFromEnum(shape));
        self.last_cursor_shape = shape;
    }

    fn cursorShapeForPointer(self: *const Window) CursorShape {
        return switch (self.pointer_surface) {
            .content => .default,
            .titlebar => blk: {
                if (self.pointerHitsCloseButton()) break :blk .pointer;
                if (self.titlebarResizeEdge()) |edge| break :blk cursorShapeForResizeEdge(edge);
                break :blk .default;
            },
            .left_border => if (self.sideResizeEdge(.left_border)) |edge| cursorShapeForResizeEdge(edge) else .default,
            .right_border => if (self.sideResizeEdge(.right_border)) |edge| cursorShapeForResizeEdge(edge) else .default,
            .bottom_border => if (self.bottomResizeEdge()) |edge| cursorShapeForResizeEdge(edge) else .default,
        };
    }

    fn updateCloseButtonHover(self: *Window) void {
        const hover = self.pointerHitsCloseButton();
        if (self.close_button_hover == hover) return;
        self.close_button_hover = hover;
        if (!self.configured) return;
        self.refreshClientDecorations() catch {
            self.should_close = true;
        };
    }

    fn handlePointerButton(self: *Window, serial: u32, button: u32, pressed: bool) void {
        if (self.pointer_surface == .content) {
            switch (button) {
                linux_input.button.left => self.input_state.setMouseButton(.left, pressed),
                linux_input.button.right => self.input_state.setMouseButton(.right, pressed),
                else => {},
            }
            return;
        }

        if (!pressed) return;
        if (self.toplevel == null or self.seat == null) return;
        if (button == linux_input.button.right and self.wm_capabilities.window_menu) {
            const pos = self.parentSurfacePointerPosition();
            c.xdg_toplevel_show_window_menu(self.toplevel.?, self.seat.?, serial, pos[0], pos[1]);
            return;
        }
        if (button != linux_input.button.left) return;

        switch (self.pointer_surface) {
            .content => unreachable,
            .titlebar => {
                if (self.pointerHitsCloseButton()) {
                    self.should_close = true;
                } else if (self.titlebarResizeEdge()) |edge| {
                    c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, edge);
                } else if (!self.toplevel_state.fullscreen) {
                    c.xdg_toplevel_move(self.toplevel.?, self.seat.?, serial);
                }
            },
            .left_border => if (self.sideResizeEdge(.left_border)) |edge| c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, edge),
            .right_border => if (self.sideResizeEdge(.right_border)) |edge| c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, edge),
            .bottom_border => if (self.bottomResizeEdge()) |edge| c.xdg_toplevel_resize(self.toplevel.?, self.seat.?, serial, edge),
        }
    }

    fn pointerHitsCloseButton(self: *const Window) bool {
        const metrics = self.decorationMetrics();
        if (metrics.titlebar_height <= 0 or self.pointer_surface != .titlebar) return false;
        const button = closeButtonRect(metrics.outerWidth(self.content_width), metrics.titlebar_height);
        return self.pointer_x >= button.x and self.pointer_x <= button.x + button.size and
            self.pointer_y >= button.y and self.pointer_y <= button.y + button.size;
    }

    fn titlebarResizeEdge(self: *const Window) ?u32 {
        if (!self.toplevel_state.canResizeTop()) return null;
        const metrics = self.decorationMetrics();
        if (metrics.titlebar_height <= 0) return null;
        const width = @as(f64, @floatFromInt(metrics.outerWidth(self.content_width)));
        if (self.pointer_y > @as(f64, @floatFromInt(csd.resize_border))) return null;
        if (self.pointer_x <= csd.resize_corner_extent and self.toplevel_state.canResizeLeft()) return xdg.toplevel.resize_edge.top_left;
        if (self.pointer_x >= width - csd.resize_corner_extent and self.toplevel_state.canResizeRight()) return xdg.toplevel.resize_edge.top_right;
        return xdg.toplevel.resize_edge.top;
    }

    fn sideResizeEdge(self: *const Window, surface_role: PointerSurface) ?u32 {
        const height = @as(f64, @floatFromInt(self.content_height));
        if (surface_role == .left_border and !self.toplevel_state.canResizeLeft()) return null;
        if (surface_role == .right_border and !self.toplevel_state.canResizeRight()) return null;
        if (surface_role == .left_border and self.pointer_y >= height - csd.resize_corner_extent) {
            return if (self.toplevel_state.canResizeBottom()) xdg.toplevel.resize_edge.bottom_left else xdg.toplevel.resize_edge.left;
        }
        if (surface_role == .right_border and self.pointer_y >= height - csd.resize_corner_extent) {
            return if (self.toplevel_state.canResizeBottom()) xdg.toplevel.resize_edge.bottom_right else xdg.toplevel.resize_edge.right;
        }
        return if (surface_role == .left_border) xdg.toplevel.resize_edge.left else xdg.toplevel.resize_edge.right;
    }

    fn bottomResizeEdge(self: *const Window) ?u32 {
        if (!self.toplevel_state.canResizeBottom()) return null;
        const metrics = self.decorationMetrics();
        const width = @as(f64, @floatFromInt(metrics.outerWidth(self.content_width)));
        if (self.pointer_x <= csd.resize_corner_extent and self.toplevel_state.canResizeLeft()) return xdg.toplevel.resize_edge.bottom_left;
        if (self.pointer_x >= width - csd.resize_corner_extent and self.toplevel_state.canResizeRight()) return xdg.toplevel.resize_edge.bottom_right;
        return xdg.toplevel.resize_edge.bottom;
    }

    fn parentSurfacePointerPosition(self: *const Window) [2]i32 {
        const metrics = self.decorationMetrics();
        const offset: [2]f64 = switch (self.pointer_surface) {
            .content => .{ @as(f64, 0), @as(f64, 0) },
            .titlebar => .{
                -@as(f64, @floatFromInt(metrics.left_border)),
                -@as(f64, @floatFromInt(metrics.titlebar_height)),
            },
            .left_border => .{
                -@as(f64, @floatFromInt(metrics.left_border)),
                @as(f64, 0),
            },
            .right_border => .{
                @as(f64, @floatFromInt(self.content_width)),
                @as(f64, 0),
            },
            .bottom_border => .{
                -@as(f64, @floatFromInt(metrics.left_border)),
                @as(f64, @floatFromInt(self.content_height)),
            },
        };
        return .{
            @intFromFloat(@round(offset[0] + self.pointer_x)),
            @intFromFloat(@round(offset[1] + self.pointer_y)),
        };
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
            const keycode: c.xkb_keycode_t = @intCast(key + wl.keyboard.keycode_offset);
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
        if (!supportsVersion(version, wl.compositor.version)) return;
        if (window.compositor != null) return;
        window.compositor = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wl_compositor_interface,
            bindVersion(version, wl.compositor.version),
        ));
    } else if (std.mem.eql(u8, iface, "wl_subcompositor")) {
        if (!supportsVersion(version, wl.subcompositor.version)) return;
        if (window.subcompositor != null) return;
        window.subcompositor = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wl_subcompositor_interface,
            bindVersion(version, wl.subcompositor.version),
        ));
    } else if (std.mem.eql(u8, iface, "wl_shm")) {
        if (!supportsVersion(version, wl.shm.version)) return;
        if (window.shm != null) return;
        window.shm = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wl_shm_interface,
            bindVersion(version, wl.shm.version),
        ));
    } else if (std.mem.eql(u8, iface, "xdg_wm_base")) {
        if (!supportsVersion(version, xdg.wm_base.version)) return;
        if (window.wm_base != null) return;
        window.wm_base = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.xdg_wm_base_interface,
            bindVersion(version, xdg.wm_base.version),
        ));
        if (window.wm_base) |wm_base| {
            _ = c.xdg_wm_base_add_listener(wm_base, &wm_base_listener, window);
        }
    } else if (std.mem.eql(u8, iface, "wl_seat")) {
        if (!supportsVersion(version, wl.seat.version)) return;
        if (window.seat != null) return;
        window.seat = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wl_seat_interface,
            bindVersion(version, wl.seat.version),
        ));
        if (window.seat) |seat| {
            _ = c.wl_seat_add_listener(seat, &seat_listener, window);
        }
    } else if (std.mem.eql(u8, iface, "wp_viewporter")) {
        if (!supportsVersion(version, wp.viewporter.version)) return;
        if (window.viewporter != null) return;
        window.viewporter = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wp_viewporter_interface,
            bindVersion(version, wp.viewporter.version),
        ));
    } else if (std.mem.eql(u8, iface, "wp_fractional_scale_manager_v1")) {
        if (!supportsVersion(version, wp.fractional_scale.manager_version)) return;
        if (window.fractional_scale_manager != null) return;
        window.fractional_scale_manager = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wp_fractional_scale_manager_v1_interface,
            bindVersion(version, wp.fractional_scale.manager_version),
        ));
    } else if (std.mem.eql(u8, iface, "zwp_linux_dmabuf_v1")) {
        const bind_version = bindExactVersion(version, zwp.linux_dmabuf.version) orelse return;
        if (window.linux_dmabuf != null) return;
        window.linux_dmabuf = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.zwp_linux_dmabuf_v1_interface,
            bind_version,
        ));
        window.linux_dmabuf_version = bind_version;
    } else if (std.mem.eql(u8, iface, "wp_cursor_shape_manager_v1")) {
        if (!supportsVersion(version, wp.cursor_shape.manager_version)) return;
        if (window.cursor_shape_manager != null) return;
        window.cursor_shape_manager = @ptrCast(c.wl_registry_bind(
            registry_ptr,
            name,
            &c.wp_cursor_shape_manager_v1_interface,
            bindVersion(version, wp.cursor_shape.manager_version),
        ));
        window.ensureCursorShapeDevice();
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

fn wlArrayU32Slice(array: ?*c.struct_wl_array) []const u32 {
    const wl_array = array orelse return &.{};
    if (wl_array.size == 0 or wl_array.data == null) return &.{};
    const len = wl_array.size / @sizeOf(u32);
    const data: [*]const u32 = @ptrCast(@alignCast(wl_array.data.?));
    return data[0..len];
}

const surface_listener = std.mem.zeroInit(c.wl_surface_listener, .{
    .enter = surfaceEnter,
    .leave = surfaceLeave,
    .preferred_buffer_scale = surfacePreferredBufferScale,
    .preferred_buffer_transform = surfacePreferredBufferTransform,
});

fn surfaceEnter(
    data: ?*anyopaque,
    surface: ?*c.struct_wl_surface,
    output: ?*c.struct_wl_output,
) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = output;
}

fn surfaceLeave(
    data: ?*anyopaque,
    surface: ?*c.struct_wl_surface,
    output: ?*c.struct_wl_output,
) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = output;
}

fn surfacePreferredBufferScale(
    data: ?*anyopaque,
    surface: ?*c.struct_wl_surface,
    factor: i32,
) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = factor;
}

fn surfacePreferredBufferTransform(
    data: ?*anyopaque,
    surface: ?*c.struct_wl_surface,
    transform: u32,
) callconv(.c) void {
    _ = data;
    _ = surface;
    _ = transform;
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
    if (window.scale_state.update(scale)) window.applyScaleChange();
}

const dmabuf_feedback_listener = std.mem.zeroInit(c.zwp_linux_dmabuf_feedback_v1_listener, .{
    .done = dmaBufFeedbackDone,
    .format_table = dmaBufFeedbackFormatTable,
    .main_device = dmaBufFeedbackMainDevice,
    .tranche_done = dmaBufFeedbackTrancheDone,
    .tranche_target_device = dmaBufFeedbackTrancheTargetDevice,
    .tranche_formats = dmaBufFeedbackTrancheFormats,
    .tranche_flags = dmaBufFeedbackTrancheFlags,
});

fn dmaBufFeedbackDone(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
) callconv(.c) void {
    _ = feedback;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.dmabuf_feedback_received = true;
}

fn dmaBufFeedbackFormatTable(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
    fd: i32,
    size: u32,
) callconv(.c) void {
    _ = feedback;
    defer if (fd >= 0) std.posix.close(fd);
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.dmabuf_format_table_size = size;
}

fn dmaBufFeedbackMainDevice(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
    device: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = data;
    _ = feedback;
    _ = device;
}

fn dmaBufFeedbackTrancheDone(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
) callconv(.c) void {
    _ = data;
    _ = feedback;
}

fn dmaBufFeedbackTrancheTargetDevice(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
    device: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = data;
    _ = feedback;
    _ = device;
}

fn dmaBufFeedbackTrancheFormats(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
    indices: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = data;
    _ = feedback;
    _ = indices;
}

fn dmaBufFeedbackTrancheFlags(
    data: ?*anyopaque,
    feedback: ?*c.struct_zwp_linux_dmabuf_feedback_v1,
    flags: u32,
) callconv(.c) void {
    _ = data;
    _ = feedback;
    _ = flags;
}

const xdg_surface_listener = std.mem.zeroInit(c.xdg_surface_listener, .{
    .configure = xdgSurfaceConfigure,
});

fn xdgSurfaceConfigure(data: ?*anyopaque, xdg_surface: ?*c.struct_xdg_surface, serial: u32) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(data.?));
    c.xdg_surface_ack_configure(xdg_surface.?, serial);
    window.configured = true;
    window.applyPendingConfigure();
}

const xdg_toplevel_listener = std.mem.zeroInit(c.xdg_toplevel_listener, .{
    .configure = xdgToplevelConfigure,
    .close = xdgToplevelClose,
    .configure_bounds = xdgToplevelConfigureBounds,
    .wm_capabilities = xdgToplevelWmCapabilities,
});

fn xdgToplevelConfigure(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
    states: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = toplevel;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.rememberConfiguredSize(width, height);
    window.rememberToplevelState(wlArrayU32Slice(states));
}

fn xdgToplevelClose(data: ?*anyopaque, toplevel: ?*c.struct_xdg_toplevel) callconv(.c) void {
    _ = toplevel;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.should_close = true;
}

fn xdgToplevelConfigureBounds(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    width: i32,
    height: i32,
) callconv(.c) void {
    _ = toplevel;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.rememberConfigureBounds(width, height);
}

fn xdgToplevelWmCapabilities(
    data: ?*anyopaque,
    toplevel: ?*c.struct_xdg_toplevel,
    capabilities: ?*c.struct_wl_array,
) callconv(.c) void {
    _ = toplevel;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.rememberWmCapabilities(wlArrayU32Slice(capabilities));
}

const seat_listener = std.mem.zeroInit(c.wl_seat_listener, .{
    .capabilities = seatCapabilities,
    .name = seatName,
});

fn seatCapabilities(data: ?*anyopaque, seat: ?*c.struct_wl_seat, capabilities: u32) callconv(.c) void {
    const window: *Window = @ptrCast(@alignCast(data.?));
    if ((capabilities & wl.seat.capability.pointer) != 0 and window.pointer == null) {
        window.pointer = c.wl_seat_get_pointer(seat.?);
        if (window.pointer) |pointer| {
            _ = c.wl_pointer_add_listener(pointer, &pointer_listener, window);
            window.ensureCursorShapeDevice();
        }
    } else if ((capabilities & wl.seat.capability.pointer) == 0 and window.pointer != null) {
        window.destroyCursorShapeDevice();
        c.wl_pointer_release(window.pointer.?);
        window.pointer = null;
        window.pointer_enter_serial = 0;
        window.pointer_axis_frame = .{};
        window.input_state.clearMouseButtons();
    }

    if ((capabilities & wl.seat.capability.keyboard) != 0 and window.keyboard == null) {
        window.keyboard = c.wl_seat_get_keyboard(seat.?);
        if (window.keyboard) |keyboard| _ = c.wl_keyboard_add_listener(keyboard, &keyboard_listener, window);
    } else if ((capabilities & wl.seat.capability.keyboard) == 0 and window.keyboard != null) {
        c.wl_keyboard_release(window.keyboard.?);
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
    .frame = pointerFrame,
    .axis_source = pointerAxisSource,
    .axis_stop = pointerAxisStop,
    .axis_discrete = pointerAxisDiscrete,
    .axis_value120 = pointerAxisValue120,
    .axis_relative_direction = pointerAxisRelativeDirection,
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
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.pointer_enter_serial = serial;
    window.last_cursor_shape = null;
    window.ensureCursorShapeDevice();
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
    window.pointer_enter_serial = 0;
    window.last_cursor_shape = null;
    window.updateCloseButtonHover();
    window.pointer_axis_frame = .{};
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
    window.updateCloseButtonHover();
    window.updateCursorShape();
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
    window.handlePointerButton(serial, button, state == wl.pointer.button_state.pressed);
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
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.pointer_axis_frame.addAxis(axis, value);
}

fn pointerFrame(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer) callconv(.c) void {
    _ = pointer;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.pointer_axis_frame.flush(window);
}

fn pointerAxisSource(data: ?*anyopaque, pointer: ?*c.struct_wl_pointer, axis_source: u32) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis_source;
}

fn pointerAxisStop(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    time_ms: u32,
    axis: u32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = time_ms;
    _ = axis;
}

fn pointerAxisDiscrete(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    axis: u32,
    discrete: i32,
) callconv(.c) void {
    _ = pointer;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.pointer_axis_frame.addValue120(axis, discrete * 120);
}

fn pointerAxisValue120(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    axis: u32,
    value120: i32,
) callconv(.c) void {
    _ = pointer;
    const window: *Window = @ptrCast(@alignCast(data.?));
    window.pointer_axis_frame.addValue120(axis, value120);
}

fn pointerAxisRelativeDirection(
    data: ?*anyopaque,
    pointer: ?*c.struct_wl_pointer,
    axis: u32,
    direction: u32,
) callconv(.c) void {
    _ = data;
    _ = pointer;
    _ = axis;
    _ = direction;
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
    const pressed = keyboardStateDown(state);
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
        linux_input.key.esc => .escape,
        linux_input.key.space => .space,
        linux_input.key.equal => .equal,
        linux_input.key.minus => .minus,
        linux_input.key.b => .b,
        linux_input.key.r => .r,
        linux_input.key.up => .up,
        linux_input.key.down => .down,
        linux_input.key.left => .left,
        linux_input.key.right => .right,
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

fn keyboardStateDown(state: u32) bool {
    return state == wl.keyboard.state.pressed or state == wl.keyboard.state.repeated;
}

fn monotonicSeconds() f64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(f64, @floatFromInt(ts.sec)) +
        @as(f64, @floatFromInt(ts.nsec)) / @as(f64, @floatFromInt(std.time.ns_per_s));
}

test "Wayland: fractional scale dimensions round to compositor buffer pixels" {
    try std.testing.expectEqual(@as(u32, 100), scaleDimension(100, wp.fractional_scale.denominator));
    try std.testing.expectEqual(@as(u32, 150), scaleDimension(100, 180));
    try std.testing.expectEqual(@as(u32, 13), scaleDimension(10, 150));
    try std.testing.expectEqual(@as(u32, 1), scaleDimension(0, wp.fractional_scale.denominator));
}

test "Wayland: protocol constants match generated XML headers" {
    try std.testing.expectEqual(@as(u32, 7), wl.compositor.latest_xml_version);
    try std.testing.expectEqual(@as(u32, 6), wl.compositor.version);
    try std.testing.expectEqual(@as(u32, 2), wl.shm.version);
    try std.testing.expectEqual(@as(u32, 10), wl.seat.version);
    try std.testing.expectEqual(@as(u32, 1), wl.subcompositor.version);
    try std.testing.expectEqual(@as(u32, 7), xdg.wm_base.version);
    try std.testing.expectEqual(@as(u32, 1), wp.viewporter.version);
    try std.testing.expectEqual(@as(u32, 1), wp.fractional_scale.manager_version);
    try std.testing.expectEqual(@as(u32, 2), wp.cursor_shape.manager_version);
    try std.testing.expectEqual(@as(u32, 5), zwp.linux_dmabuf.version);

    const cursor_shapes = [_]struct {
        shape: CursorShape,
        value: u32,
    }{
        .{ .shape = .default, .value = 1 },
        .{ .shape = .context_menu, .value = 2 },
        .{ .shape = .help, .value = 3 },
        .{ .shape = .pointer, .value = 4 },
        .{ .shape = .progress, .value = 5 },
        .{ .shape = .wait, .value = 6 },
        .{ .shape = .cell, .value = 7 },
        .{ .shape = .crosshair, .value = 8 },
        .{ .shape = .text, .value = 9 },
        .{ .shape = .vertical_text, .value = 10 },
        .{ .shape = .alias, .value = 11 },
        .{ .shape = .copy, .value = 12 },
        .{ .shape = .move, .value = 13 },
        .{ .shape = .no_drop, .value = 14 },
        .{ .shape = .not_allowed, .value = 15 },
        .{ .shape = .grab, .value = 16 },
        .{ .shape = .grabbing, .value = 17 },
        .{ .shape = .e_resize, .value = 18 },
        .{ .shape = .n_resize, .value = 19 },
        .{ .shape = .ne_resize, .value = 20 },
        .{ .shape = .nw_resize, .value = 21 },
        .{ .shape = .s_resize, .value = 22 },
        .{ .shape = .se_resize, .value = 23 },
        .{ .shape = .sw_resize, .value = 24 },
        .{ .shape = .w_resize, .value = 25 },
        .{ .shape = .ew_resize, .value = 26 },
        .{ .shape = .ns_resize, .value = 27 },
        .{ .shape = .nesw_resize, .value = 28 },
        .{ .shape = .nwse_resize, .value = 29 },
        .{ .shape = .col_resize, .value = 30 },
        .{ .shape = .row_resize, .value = 31 },
        .{ .shape = .all_scroll, .value = 32 },
        .{ .shape = .zoom_in, .value = 33 },
        .{ .shape = .zoom_out, .value = 34 },
        .{ .shape = .dnd_ask, .value = 35 },
        .{ .shape = .all_resize, .value = 36 },
    };
    for (cursor_shapes) |entry| {
        try std.testing.expectEqual(entry.value, @intFromEnum(entry.shape));
    }
}

test "Wayland: registry binding requires the configured protocol version" {
    try std.testing.expect(!supportsVersion(wl.compositor.version - 1, wl.compositor.version));
    try std.testing.expect(supportsVersion(wl.compositor.version, wl.compositor.version));
    try std.testing.expect(supportsVersion(99, wl.compositor.version));
    try std.testing.expectEqual(wl.compositor.version, bindVersion(99, wl.compositor.version));
    try std.testing.expect(bindExactVersion(zwp.linux_dmabuf.version - 1, zwp.linux_dmabuf.version) == null);
    try std.testing.expectEqual(zwp.linux_dmabuf.version, bindExactVersion(zwp.linux_dmabuf.version, zwp.linux_dmabuf.version).?);
    try std.testing.expectEqual(zwp.linux_dmabuf.version, bindExactVersion(99, zwp.linux_dmabuf.version).?);
}

test "Wayland: surface capabilities expose direct WSI and dmabuf feedback state" {
    var window: Window = .{};
    try std.testing.expect(window.surfaceCapabilities().supportsDirectSwapchain());
    try std.testing.expectEqual(SurfaceCapabilities.LinuxDmaBuf.unavailable, window.surfaceCapabilities().linux_dmabuf);
    try std.testing.expectEqual(SurfaceCapabilities.DecorationMemory.shared_memfd_wl_shm, window.surfaceCapabilities().decorations);

    window.linux_dmabuf = @ptrFromInt(4096);
    window.linux_dmabuf_version = zwp.linux_dmabuf.version;
    try std.testing.expectEqual(SurfaceCapabilities.LinuxDmaBuf.advertised, window.surfaceCapabilities().linux_dmabuf);

    window.dmabuf_surface_feedback = @ptrFromInt(8192);
    try std.testing.expectEqual(SurfaceCapabilities.LinuxDmaBuf.surface_feedback_pending, window.surfaceCapabilities().linux_dmabuf);

    window.dmabuf_feedback_received = true;
    try std.testing.expectEqual(SurfaceCapabilities.LinuxDmaBuf.surface_feedback_received, window.surfaceCapabilities().linux_dmabuf);
}

test "Wayland: xdg parser tracks v7 edge constraints and v5 capabilities" {
    const state = ToplevelState.fromWire(&.{
        xdg.toplevel.state.activated,
        xdg.toplevel.state.tiled_left,
        xdg.toplevel.state.constrained_left,
        xdg.toplevel.state.constrained_bottom,
        0xffff,
    });

    try std.testing.expect(state.activated);
    try std.testing.expect(state.tiled_left);
    try std.testing.expect(state.constrained_left);
    try std.testing.expect(state.constrained_bottom);
    try std.testing.expect(!state.maximized);
    try std.testing.expect(!state.canResizeLeft());
    try std.testing.expect(!state.canResizeBottom());
    try std.testing.expect(state.canResizeRight());

    const capabilities = WmCapabilities.fromWire(&.{ 0xffff, xdg.toplevel.wm_capability.window_menu });
    try std.testing.expect(capabilities.window_menu);
}

test "Wayland: decoration metrics collapse fullscreen and constrained edges" {
    const normal = DecorationMetrics.forState(.{});
    try std.testing.expectEqual(@as(i32, csd.titlebar_height), normal.titlebar_height);
    try std.testing.expectEqual(@as(i32, csd.resize_border), normal.left_border);
    try std.testing.expectEqual(@as(i32, window_limits.min_content_width + 2 * csd.resize_border), normal.minWidth());

    const fullscreen = DecorationMetrics.forState(.{ .fullscreen = true });
    try std.testing.expectEqual(@as(i32, 0), fullscreen.titlebar_height);
    try std.testing.expectEqual(@as(i32, 0), fullscreen.left_border);
    try std.testing.expectEqual(@as(i32, window_limits.min_content_width), fullscreen.minWidth());

    const constrained = DecorationMetrics.forState(.{
        .tiled_left = true,
        .constrained_bottom = true,
    });
    try std.testing.expectEqual(@as(i32, 0), constrained.left_border);
    try std.testing.expectEqual(@as(i32, csd.resize_border), constrained.right_border);
    try std.testing.expectEqual(@as(i32, 0), constrained.bottom_border);
}

test "Wayland: client decorations follow Adwaita headerbar states" {
    const light_active = decorationColors(false, true);
    try std.testing.expectEqual(@as(u32, csd.color.light.headerbar_bg), light_active.titlebar);
    try std.testing.expectEqual(@as(u32, csd.color.light.headerbar_fg), light_active.foreground);

    const light_backdrop = decorationColors(false, false);
    try std.testing.expectEqual(@as(u32, csd.color.light.headerbar_backdrop), light_backdrop.titlebar);
    try std.testing.expectEqual(@as(u32, csd.color.light.headerbar_backdrop_fg), light_backdrop.foreground);

    const dark_active = decorationColors(true, true);
    try std.testing.expectEqual(@as(u32, csd.color.dark.headerbar_bg), dark_active.titlebar);
    try std.testing.expectEqual(@as(u32, csd.color.dark.headerbar_fg), dark_active.foreground);

    const close = closeButtonRect(640, csd.titlebar_height);
    try std.testing.expect(close.x > 0);
    try std.testing.expect(close.size >= csd.close.icon_size);

    var window: Window = .{};
    try std.testing.expect(window.roundedTitlebarCorners());
    window.toplevel_state = .{ .maximized = true };
    try std.testing.expect(!window.roundedTitlebarCorners());
    window.toplevel_state = .{ .tiled_top = true };
    try std.testing.expect(!window.roundedTitlebarCorners());
}

test "Wayland: cursor shapes and keyboard state follow latest input protocol" {
    try std.testing.expectEqual(CursorShape.n_resize, cursorShapeForResizeEdge(xdg.toplevel.resize_edge.top));
    try std.testing.expectEqual(CursorShape.se_resize, cursorShapeForResizeEdge(xdg.toplevel.resize_edge.bottom_right));
    try std.testing.expectEqual(CursorShape.default, cursorShapeForResizeEdge(0));

    try std.testing.expect(!keyboardStateDown(0));
    try std.testing.expect(keyboardStateDown(wl.keyboard.state.pressed));
    try std.testing.expect(keyboardStateDown(wl.keyboard.state.repeated));
}

test "Wayland: fractional scale owns buffer sizing" {
    var scale: ScaleState = .{};
    try std.testing.expectEqual(@as(u32, wp.fractional_scale.denominator), scale.numerator);
    try std.testing.expect(scale.update(150));
    try std.testing.expectEqual(@as(u32, 150), scale.numerator);
    try std.testing.expect(!scale.update(150));
    try std.testing.expect(!scale.update(0));
    try std.testing.expectEqual(@as(u32, 150), scale.numerator);
}
