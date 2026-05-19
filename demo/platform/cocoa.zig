//! Cocoa demo window and Metal host object access.

const std = @import("std");
const demo_input = @import("demo_input");

const WindowHandle = opaque {};
const diagnostic_capacity = 2048;

const Status = enum(c_int) {
    ok = 0,
    err = 1,
};

const U8 = u8;

pub const MetalHost = struct {
    device: *anyopaque,
    command_queue: *anyopaque,
    layer: *anyopaque,
};

const key_escape: u32 = 0;
const key_space: u32 = 1;
const key_equal: u32 = 2;
const key_minus: u32 = 3;
const key_b: u32 = 4;
const key_r: u32 = 5;
const key_up: u32 = 6;
const key_down: u32 = 7;
const key_left: u32 = 8;
const key_right: u32 = 9;
const cocoa_key_count: usize = 10;
const mouse_left: u32 = 0;
const mouse_right: u32 = 1;
const cocoa_mouse_button_count: usize = 2;
const key_count = @typeInfo(demo_input.Key).@"enum".fields.len;
const mouse_button_count = @typeInfo(demo_input.MouseButton).@"enum".fields.len;

extern fn hs_demo_cocoa_window_create(
    out_window: *?*WindowHandle,
    width: u32,
    height: u32,
    title_data: ?[*]const U8,
    title_size: usize,
    error_data: ?[*]U8,
    error_size: usize,
) Status;
extern fn hs_demo_cocoa_window_destroy(host: ?*WindowHandle) void;
extern fn hs_demo_cocoa_window_poll_events(host: ?*WindowHandle) void;
extern fn hs_demo_cocoa_window_set_dark_mode(host: ?*WindowHandle, enabled: U8) void;
extern fn hs_demo_cocoa_window_snapshot(
    host: ?*WindowHandle,
    keys: ?[*]U8,
    key_capacity: usize,
    mouse_buttons: ?[*]U8,
    mouse_button_capacity: usize,
    cursor_x: ?*f64,
    cursor_y: ?*f64,
    scroll_delta: ?*f64,
    framebuffer_width: ?*u32,
    framebuffer_height: ?*u32,
    should_close: ?*U8,
) void;
extern fn hs_demo_cocoa_window_time(host: ?*WindowHandle) f64;
extern fn hs_demo_cocoa_window_metal_host(
    host: ?*WindowHandle,
    out_device: *?*anyopaque,
    out_command_queue: *?*anyopaque,
    out_layer: *?*anyopaque,
) Status;

pub const Error = error{
    InvalidWindowSize,
    WindowCreateFailed,
    MetalHostUnavailable,
};

fn emptyDiagnostic() [diagnostic_capacity]u8 {
    return .{0} ** diagnostic_capacity;
}

fn dataPtr(bytes: []const u8) ?[*]const U8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

fn bufferPtr(bytes: []u8) ?[*]U8 {
    return if (bytes.len == 0) null else bytes.ptr;
}

fn boolByte(value: bool) U8 {
    return @intFromBool(value);
}

pub const Window = struct {
    handle: *WindowHandle = undefined,
    input_state: demo_input.State = .{},
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,

    pub fn init(self: *Window, width: c_int, height: c_int, title: []const u8) Error!void {
        if (!validInitialExtent(width, height)) return Error.InvalidWindowSize;

        var error_buf = emptyDiagnostic();
        var handle: ?*WindowHandle = null;
        if (hs_demo_cocoa_window_create(
            &handle,
            @intCast(width),
            @intCast(height),
            dataPtr(title),
            title.len,
            bufferPtr(error_buf[0..]),
            error_buf.len,
        ) != .ok) {
            std.log.err("Cocoa host init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.WindowCreateFailed;
        }
        self.* = .{ .handle = handle orelse return Error.WindowCreateFailed };
        self.setDarkMode(false);
        self.refreshSnapshot();
    }

    pub fn deinit(self: *Window) void {
        hs_demo_cocoa_window_destroy(self.handle);
        self.* = undefined;
    }

    pub fn pollEvents(self: *Window) void {
        hs_demo_cocoa_window_poll_events(self.handle);
        self.refreshSnapshot();
    }

    pub fn setDarkMode(self: *Window, enabled: bool) void {
        hs_demo_cocoa_window_set_dark_mode(self.handle, boolByte(enabled));
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

    pub fn metalHost(self: *const Window) Error!MetalHost {
        var device: ?*anyopaque = null;
        var command_queue: ?*anyopaque = null;
        var layer: ?*anyopaque = null;
        if (hs_demo_cocoa_window_metal_host(
            self.handle,
            &device,
            &command_queue,
            &layer,
        ) != .ok) return Error.MetalHostUnavailable;

        return .{
            .device = device orelse return Error.MetalHostUnavailable,
            .command_queue = command_queue orelse return Error.MetalHostUnavailable,
            .layer = layer orelse return Error.MetalHostUnavailable,
        };
    }

    fn refreshSnapshot(self: *Window) void {
        var keys: [cocoa_key_count]U8 = undefined;
        var mouse_buttons: [cocoa_mouse_button_count]U8 = undefined;
        var cursor_x: f64 = 0;
        var cursor_y: f64 = 0;
        var scroll_delta: f64 = 0;
        var framebuffer_width: u32 = 0;
        var framebuffer_height: u32 = 0;
        var should_close: U8 = 0;
        hs_demo_cocoa_window_snapshot(
            self.handle,
            keys[0..].ptr,
            keys.len,
            mouse_buttons[0..].ptr,
            mouse_buttons.len,
            &cursor_x,
            &cursor_y,
            &scroll_delta,
            &framebuffer_width,
            &framebuffer_height,
            &should_close,
        );
        for (keys, 0..) |pressed, index| {
            self.input_state.keys[index] = pressed != 0;
        }
        for (mouse_buttons, 0..) |pressed, index| {
            self.input_state.mouse_buttons[index] = pressed != 0;
        }
        self.input_state.cursor = .{ cursor_x, cursor_y };
        self.input_state.addScroll(scroll_delta);
        self.framebuffer_width = framebuffer_width;
        self.framebuffer_height = framebuffer_height;
        self.should_close = should_close != 0;
    }
};

fn validInitialExtent(width: c_int, height: c_int) bool {
    return width > 0 and height > 0;
}

comptime {
    if (key_count != cocoa_key_count)
        @compileError("demo_input.Key and demo/platform/cocoa.swift key counts must stay in lockstep");
    if (mouse_button_count != cocoa_mouse_button_count)
        @compileError("demo_input.MouseButton and demo/platform/cocoa.swift mouse counts must stay in lockstep");
}

test "Cocoa ABI input counts match shared demo input" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(Status.err));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(U8));
    try std.testing.expectEqual(@as(usize, cocoa_key_count), key_count);
    try std.testing.expectEqual(@as(usize, cocoa_mouse_button_count), mouse_button_count);
}

test "Cocoa ABI input constants match shared demo input order" {
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.escape), @as(u8, @intCast(key_escape)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.space), @as(u8, @intCast(key_space)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.equal), @as(u8, @intCast(key_equal)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.minus), @as(u8, @intCast(key_minus)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.b), @as(u8, @intCast(key_b)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.r), @as(u8, @intCast(key_r)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.up), @as(u8, @intCast(key_up)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.down), @as(u8, @intCast(key_down)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.left), @as(u8, @intCast(key_left)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.right), @as(u8, @intCast(key_right)));
    try std.testing.expectEqual(@intFromEnum(demo_input.MouseButton.left), @as(u8, @intCast(mouse_left)));
    try std.testing.expectEqual(@intFromEnum(demo_input.MouseButton.right), @as(u8, @intCast(mouse_right)));
}

test "Cocoa window requires positive initial extents" {
    try std.testing.expect(validInitialExtent(1, 1));
    try std.testing.expect(!validInitialExtent(0, 1));
    try std.testing.expect(!validInitialExtent(1, 0));
    try std.testing.expect(!validInitialExtent(-1, 1));
    try std.testing.expect(!validInitialExtent(1, -1));
}

test "Cocoa ABI encodes bools as byte flags" {
    try std.testing.expectEqual(@as(U8, 0), boolByte(false));
    try std.testing.expectEqual(@as(U8, 1), boolByte(true));
}
