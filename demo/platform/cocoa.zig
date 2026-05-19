//! Cocoa demo window and Metal host object access.

const std = @import("std");
const c = @import("cocoa_c");
const demo_input = @import("demo_input");

const CocoaWindowHandle = c.hs_demo_cocoa_window;
const Snapshot = c.hs_demo_cocoa_snapshot;
const cocoa_key_count: usize = @intCast(c.HS_DEMO_KEY_COUNT);
const cocoa_mouse_button_count: usize = @intCast(c.HS_DEMO_MOUSE_COUNT);
const key_count = @typeInfo(demo_input.Key).@"enum".fields.len;
const mouse_button_count = @typeInfo(demo_input.MouseButton).@"enum".fields.len;

pub const Window = struct {
    handle: *CocoaWindowHandle = undefined,
    input_state: demo_input.State = .{},
    framebuffer_width: u32 = 0,
    framebuffer_height: u32 = 0,
    should_close: bool = false,

    pub fn init(self: *Window, allocator: std.mem.Allocator, width: c_int, height: c_int, title: []const u8) !void {
        _ = allocator;
        if (!validInitialExtent(width, height)) return error.InvalidWindowSize;

        var error_buf: [2048]u8 = undefined;
        @memset(&error_buf, 0);
        const handle = c.hs_demo_cocoa_window_create(
            @intCast(width),
            @intCast(height),
            .{ .data = title.ptr, .len = title.len },
            .{ .data = error_buf[0..].ptr, .len = error_buf.len },
        ) orelse {
            std.log.err("Cocoa host init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return error.CocoaHostInitFailed;
        };
        self.* = .{ .handle = handle };
        self.refreshSnapshot();
    }

    pub fn deinit(self: *Window) void {
        c.hs_demo_cocoa_window_destroy(self.handle);
    }

    pub fn pollEvents(self: *Window) void {
        c.hs_demo_cocoa_window_poll_events(self.handle);
        self.refreshSnapshot();
    }

    pub fn input(self: *Window) *demo_input.State {
        return &self.input_state;
    }

    pub fn framebufferSize(self: *const Window) [2]u32 {
        return .{ self.framebuffer_width, self.framebuffer_height };
    }

    pub fn time(self: *const Window) f64 {
        return c.hs_demo_cocoa_window_time(self.handle);
    }

    pub fn device(self: *const Window) *anyopaque {
        return c.hs_demo_cocoa_window_device(self.handle).?;
    }

    pub fn commandQueue(self: *const Window) *anyopaque {
        return c.hs_demo_cocoa_window_command_queue(self.handle).?;
    }

    pub fn layer(self: *const Window) *anyopaque {
        return c.hs_demo_cocoa_window_layer(self.handle).?;
    }

    fn refreshSnapshot(self: *Window) void {
        var snapshot: Snapshot = undefined;
        c.hs_demo_cocoa_window_snapshot(self.handle, &snapshot);
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
    try std.testing.expectEqual(@as(usize, cocoa_key_count), key_count);
    try std.testing.expectEqual(@as(usize, cocoa_mouse_button_count), mouse_button_count);
}

test "Cocoa ABI input constants match shared demo input order" {
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.escape), @as(u8, @intCast(c.HS_DEMO_KEY_ESCAPE)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.space), @as(u8, @intCast(c.HS_DEMO_KEY_SPACE)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.equal), @as(u8, @intCast(c.HS_DEMO_KEY_EQUAL)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.minus), @as(u8, @intCast(c.HS_DEMO_KEY_MINUS)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.b), @as(u8, @intCast(c.HS_DEMO_KEY_B)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.r), @as(u8, @intCast(c.HS_DEMO_KEY_R)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.up), @as(u8, @intCast(c.HS_DEMO_KEY_UP)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.down), @as(u8, @intCast(c.HS_DEMO_KEY_DOWN)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.left), @as(u8, @intCast(c.HS_DEMO_KEY_LEFT)));
    try std.testing.expectEqual(@intFromEnum(demo_input.Key.right), @as(u8, @intCast(c.HS_DEMO_KEY_RIGHT)));
    try std.testing.expectEqual(@intFromEnum(demo_input.MouseButton.left), @as(u8, @intCast(c.HS_DEMO_MOUSE_LEFT)));
    try std.testing.expectEqual(@intFromEnum(demo_input.MouseButton.right), @as(u8, @intCast(c.HS_DEMO_MOUSE_RIGHT)));
}

test "Cocoa window requires positive initial extents" {
    try std.testing.expect(validInitialExtent(1, 1));
    try std.testing.expect(!validInitialExtent(0, 1));
    try std.testing.expect(!validInitialExtent(1, 0));
    try std.testing.expect(!validInitialExtent(-1, 1));
    try std.testing.expect(!validInitialExtent(1, -1));
}
