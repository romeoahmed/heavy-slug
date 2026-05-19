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

const U8View = extern struct {
    data: ?[*]const U8,
    size: usize,
};

const U8Buffer = extern struct {
    data: ?[*]U8,
    size: usize,
};

const MetalHostAbi = extern struct {
    device: ?*anyopaque,
    command_queue: ?*anyopaque,
    layer: ?*anyopaque,
};

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
const cocoa_bool_size: usize = 1;
const key_count = @typeInfo(demo_input.Key).@"enum".fields.len;
const mouse_button_count = @typeInfo(demo_input.MouseButton).@"enum".fields.len;

const Snapshot = extern struct {
    keys: [cocoa_key_count]bool,
    mouse_buttons: [cocoa_mouse_button_count]bool,
    cursor_x: f64,
    cursor_y: f64,
    scroll_delta: f64,
    framebuffer_width: u32,
    framebuffer_height: u32,
    should_close: bool,
};

extern fn hs_demo_cocoa_window_create(
    out_window: *?*WindowHandle,
    width: u32,
    height: u32,
    title: U8View,
    error_buffer: U8Buffer,
) Status;
extern fn hs_demo_cocoa_window_destroy(host: ?*WindowHandle) void;
extern fn hs_demo_cocoa_window_poll_events(host: ?*WindowHandle) void;
extern fn hs_demo_cocoa_window_snapshot(host: ?*WindowHandle, snapshot: *Snapshot) void;
extern fn hs_demo_cocoa_window_time(host: ?*WindowHandle) f64;
extern fn hs_demo_cocoa_window_metal_host(host: ?*WindowHandle) MetalHostAbi;

pub const Error = error{
    InvalidWindowSize,
    WindowCreateFailed,
    MetalHostUnavailable,
};

fn u8View(bytes: []const u8) U8View {
    return .{ .data = bytes.ptr, .size = bytes.len };
}

fn u8Buffer(bytes: []u8) U8Buffer {
    return .{ .data = bytes.ptr, .size = bytes.len };
}

fn emptyDiagnostic() [diagnostic_capacity]u8 {
    return .{0} ** diagnostic_capacity;
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
            u8View(title),
            u8Buffer(error_buf[0..]),
        ) != .ok) {
            std.log.err("Cocoa host init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.WindowCreateFailed;
        }
        self.* = .{ .handle = handle orelse return Error.WindowCreateFailed };
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
        const host = hs_demo_cocoa_window_metal_host(self.handle);
        return .{
            .device = host.device orelse return Error.MetalHostUnavailable,
            .command_queue = host.command_queue orelse return Error.MetalHostUnavailable,
            .layer = host.layer orelse return Error.MetalHostUnavailable,
        };
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

fn validInitialExtent(width: c_int, height: c_int) bool {
    return width > 0 and height > 0;
}

comptime {
    if (key_count != cocoa_key_count)
        @compileError("demo_input.Key and demo/platform/cocoa.h key counts must stay in lockstep");
    if (mouse_button_count != cocoa_mouse_button_count)
        @compileError("demo_input.MouseButton and demo/platform/cocoa.h mouse counts must stay in lockstep");
}

test "Cocoa ABI input counts match shared demo input" {
    try std.testing.expectEqual(@as(c_int, 0), @intFromEnum(Status.ok));
    try std.testing.expectEqual(@as(c_int, 1), @intFromEnum(Status.err));
    try std.testing.expectEqual(@as(usize, 1), @sizeOf(U8));
    try std.testing.expectEqual(cocoa_bool_size, @sizeOf(bool));
    try std.testing.expectEqual(@sizeOf(?*anyopaque) + @sizeOf(usize), @sizeOf(U8View));
    try std.testing.expectEqual(@sizeOf(?*anyopaque) + @sizeOf(usize), @sizeOf(U8Buffer));
    try std.testing.expectEqual(@as(usize, @sizeOf(?*anyopaque)), @offsetOf(U8View, "size"));
    try std.testing.expectEqual(@as(usize, @sizeOf(?*anyopaque)), @offsetOf(U8Buffer, "size"));
    try std.testing.expectEqual(@as(usize, 3 * @sizeOf(?*anyopaque)), @sizeOf(MetalHostAbi));
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
