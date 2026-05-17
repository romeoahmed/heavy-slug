//! Cocoa demo window and Metal host object access.

const std = @import("std");
const demo_input = @import("demo_input");

const CocoaWindowHandle = opaque {};

const key_count = @typeInfo(demo_input.Key).@"enum".fields.len;
const mouse_button_count = @typeInfo(demo_input.MouseButton).@"enum".fields.len;

const Snapshot = extern struct {
    keys: [key_count]bool,
    mouse_buttons: [mouse_button_count]bool,
    cursor_x: f64,
    cursor_y: f64,
    scroll_delta: f64,
    framebuffer_width: u32,
    framebuffer_height: u32,
    should_close: bool,
};

extern fn hs_demo_cocoa_window_create(
    width: c_int,
    height: c_int,
    title: [*:0]const u8,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) ?*CocoaWindowHandle;
extern fn hs_demo_cocoa_window_destroy(host: *CocoaWindowHandle) void;
extern fn hs_demo_cocoa_window_poll_events(host: *CocoaWindowHandle) void;
extern fn hs_demo_cocoa_window_snapshot(host: *CocoaWindowHandle, snapshot: *Snapshot) void;
extern fn hs_demo_cocoa_window_time(host: *CocoaWindowHandle) f64;
extern fn hs_demo_cocoa_window_device(host: *CocoaWindowHandle) *anyopaque;
extern fn hs_demo_cocoa_window_command_queue(host: *CocoaWindowHandle) *anyopaque;
extern fn hs_demo_cocoa_window_layer(host: *CocoaWindowHandle) *anyopaque;

pub const Window = struct {
    handle: *CocoaWindowHandle = undefined,
    input_state: demo_input.State = .{},
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,

    pub fn init(self: *Window, allocator: std.mem.Allocator, width: c_int, height: c_int, title: []const u8) !void {
        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);

        var error_buf: [2048]u8 = undefined;
        @memset(&error_buf, 0);
        const handle = hs_demo_cocoa_window_create(width, height, title_z.ptr, &error_buf, error_buf.len) orelse {
            std.log.err("Cocoa host init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return error.CocoaHostInitFailed;
        };
        self.* = .{ .handle = handle };
        self.refreshSnapshot();
    }

    pub fn deinit(self: *Window) void {
        hs_demo_cocoa_window_destroy(self.handle);
    }

    pub fn pollEvents(self: *Window) void {
        hs_demo_cocoa_window_poll_events(self.handle);
        self.refreshSnapshot();
    }

    pub fn input(self: *Window) *demo_input.State {
        return &self.input_state;
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ self.framebuffer_width, self.framebuffer_height };
    }

    pub fn time(self: *const Window) f64 {
        return hs_demo_cocoa_window_time(self.handle);
    }

    pub fn device(self: *const Window) *anyopaque {
        return hs_demo_cocoa_window_device(self.handle);
    }

    pub fn commandQueue(self: *const Window) *anyopaque {
        return hs_demo_cocoa_window_command_queue(self.handle);
    }

    pub fn layer(self: *const Window) *anyopaque {
        return hs_demo_cocoa_window_layer(self.handle);
    }

    fn refreshSnapshot(self: *Window) void {
        var snapshot: Snapshot = undefined;
        hs_demo_cocoa_window_snapshot(self.handle, &snapshot);
        self.input_state.keys = snapshot.keys;
        self.input_state.mouse_buttons = snapshot.mouse_buttons;
        self.input_state.cursor = .{ snapshot.cursor_x, snapshot.cursor_y };
        self.input_state.addScroll(snapshot.scroll_delta);
        self.framebuffer_width = snapshot.framebuffer_width;
        self.framebuffer_height = snapshot.framebuffer_height;
        self.should_close = snapshot.should_close;
    }
};
