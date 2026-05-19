//! Cocoa demo window, input snapshot, and Metal host object access.

const std = @import("std");
const heavy_slug = @import("heavy_slug");
const demo_input = @import("demo_input");

const WindowHandle = opaque {};
const diagnostic_capacity = 2048;
const ProtocolVersion = heavy_slug.core.protocol.ProtocolVersion;

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

const window_protocol_version = ProtocolVersion.init(1, 0);
const window_protocol_version_word: u32 = window_protocol_version.word();

const HostPointers = extern struct {
    device: ?*anyopaque,
    command_queue: ?*anyopaque,
    layer: ?*anyopaque,
};

const ColorScheme = enum(u32) {
    light = 0,
    dark = 1,
};

const CreateRequest = extern struct {
    protocol_version: u32,
    width: u32,
    height: u32,
    reserved0: u32 = 0,
    title_data: ?[*]const U8,
    title_size: usize,

    fn init(width: c_int, height: c_int, title: []const u8) CreateRequest {
        return .{
            .protocol_version = window_protocol_version_word,
            .width = @intCast(width),
            .height = @intCast(height),
            .title_data = dataPtr(title),
            .title_size = title.len,
        };
    }
};

const Snapshot = extern struct {
    protocol_version: u32 = window_protocol_version_word,
    reserved0: u32 = 0,
    reserved1: u32 = 0,
    reserved2: u32 = 0,
    keys: [cocoa_key_count]U8 = .{0} ** cocoa_key_count,
    mouse_buttons: [cocoa_mouse_button_count]U8 = .{0} ** cocoa_mouse_button_count,
    should_close: U8 = 0,
    reserved3: [3]U8 = .{0} ** 3,
    cursor_x: f64 = 0,
    cursor_y: f64 = 0,
    scroll_delta: f64 = 0,
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
};

extern fn hs_demo_cocoa_window_create(
    out_window: *?*WindowHandle,
    request_data: *const CreateRequest,
    request_size: usize,
    error_data: ?[*]U8,
    error_size: usize,
) Status;
extern fn hs_demo_cocoa_window_destroy(host: ?*WindowHandle) void;
extern fn hs_demo_cocoa_window_poll_events(host: ?*WindowHandle) void;
extern fn hs_demo_cocoa_window_set_color_scheme(host: ?*WindowHandle, scheme: u32) void;
extern fn hs_demo_cocoa_window_snapshot(
    host: ?*WindowHandle,
    out_snapshot: *Snapshot,
    snapshot_size: usize,
) Status;
extern fn hs_demo_cocoa_window_time(host: ?*WindowHandle) f64;
extern fn hs_demo_cocoa_window_metal_host(
    host: ?*WindowHandle,
    out_host: *HostPointers,
    host_size: usize,
) Status;

pub const Error = error{
    InvalidWindowSize,
    WindowCreateFailed,
    WindowSnapshotFailed,
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

fn colorSchemeFromDarkMode(enabled: bool) ColorScheme {
    return if (enabled) .dark else .light;
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
        const request = CreateRequest.init(width, height, title);
        var handle: ?*WindowHandle = null;
        if (hs_demo_cocoa_window_create(
            &handle,
            &request,
            @sizeOf(CreateRequest),
            bufferPtr(error_buf[0..]),
            error_buf.len,
        ) != .ok) {
            std.log.err("Cocoa host init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.WindowCreateFailed;
        }
        self.* = .{ .handle = handle orelse return Error.WindowCreateFailed };
        self.setDarkMode(false);
        try self.refreshSnapshot();
    }

    pub fn deinit(self: *Window) void {
        hs_demo_cocoa_window_destroy(self.handle);
        self.* = undefined;
    }

    pub fn pollEvents(self: *Window) Error!void {
        hs_demo_cocoa_window_poll_events(self.handle);
        try self.refreshSnapshot();
    }

    pub fn setDarkMode(self: *Window, enabled: bool) void {
        hs_demo_cocoa_window_set_color_scheme(
            self.handle,
            @intFromEnum(colorSchemeFromDarkMode(enabled)),
        );
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
        var host: HostPointers = .{
            .device = null,
            .command_queue = null,
            .layer = null,
        };
        if (hs_demo_cocoa_window_metal_host(
            self.handle,
            &host,
            @sizeOf(HostPointers),
        ) != .ok) return Error.MetalHostUnavailable;

        return .{
            .device = host.device orelse return Error.MetalHostUnavailable,
            .command_queue = host.command_queue orelse return Error.MetalHostUnavailable,
            .layer = host.layer orelse return Error.MetalHostUnavailable,
        };
    }

    fn refreshSnapshot(self: *Window) Error!void {
        var snapshot: Snapshot = .{};
        if (hs_demo_cocoa_window_snapshot(
            self.handle,
            &snapshot,
            @sizeOf(Snapshot),
        ) != .ok) return Error.WindowSnapshotFailed;
        for (snapshot.keys, 0..) |pressed, index| {
            self.input_state.keys[index] = pressed != 0;
        }
        for (snapshot.mouse_buttons, 0..) |pressed, index| {
            self.input_state.mouse_buttons[index] = pressed != 0;
        }
        self.input_state.cursor = .{ snapshot.cursor_x, snapshot.cursor_y };
        self.input_state.addScroll(snapshot.scroll_delta);
        self.framebuffer_width = snapshot.framebuffer_width;
        self.framebuffer_height = snapshot.framebuffer_height;
        self.should_close = snapshot.should_close != 0;
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

test "Cocoa window protocol uses shared major minor encoding" {
    try std.testing.expectEqual(ProtocolVersion.init(1, 0).word(), window_protocol_version_word);
    try std.testing.expectEqual(ColorScheme.light, colorSchemeFromDarkMode(false));
    try std.testing.expectEqual(ColorScheme.dark, colorSchemeFromDarkMode(true));
}

test "Cocoa create request ABI layout is explicit" {
    try std.testing.expectEqual(@as(usize, 8), @alignOf(CreateRequest));
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(CreateRequest));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CreateRequest, "protocol_version"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CreateRequest, "width"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CreateRequest, "height"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(CreateRequest, "reserved0"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(CreateRequest, "title_data"));
    try std.testing.expectEqual(@as(usize, 24), @offsetOf(CreateRequest, "title_size"));
}

test "Cocoa snapshot ABI layout is explicit" {
    try std.testing.expectEqual(@as(usize, 8), @alignOf(Snapshot));
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(Snapshot));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(Snapshot, "protocol_version"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(Snapshot, "keys"));
    try std.testing.expectEqual(@as(usize, 26), @offsetOf(Snapshot, "mouse_buttons"));
    try std.testing.expectEqual(@as(usize, 28), @offsetOf(Snapshot, "should_close"));
    try std.testing.expectEqual(@as(usize, 32), @offsetOf(Snapshot, "cursor_x"));
    try std.testing.expectEqual(@as(usize, 40), @offsetOf(Snapshot, "cursor_y"));
    try std.testing.expectEqual(@as(usize, 48), @offsetOf(Snapshot, "scroll_delta"));
    try std.testing.expectEqual(@as(usize, 56), @offsetOf(Snapshot, "framebuffer_width"));
    try std.testing.expectEqual(@as(usize, 60), @offsetOf(Snapshot, "framebuffer_height"));
}

test "Cocoa Metal host ABI layout is explicit" {
    try std.testing.expectEqual(@as(usize, 8), @alignOf(HostPointers));
    try std.testing.expectEqual(@as(usize, 24), @sizeOf(HostPointers));
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(HostPointers, "device"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(HostPointers, "command_queue"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(HostPointers, "layer"));
}
