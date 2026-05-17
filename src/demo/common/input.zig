//! Backend-neutral demo input state.

const std = @import("std");

pub const Key = enum(u8) {
    escape,
    space,
    equal,
    minus,
    b,
    r,
    up,
    down,
    left,
    right,
};

pub const MouseButton = enum(u8) {
    left,
    right,
};

pub const State = struct {
    keys: [key_count]bool = .{false} ** key_count,
    mouse_buttons: [mouse_button_count]bool = .{false} ** mouse_button_count,
    cursor: [2]f64 = .{ 0, 0 },
    scroll_delta: f64 = 0,

    const key_count = @typeInfo(Key).@"enum".fields.len;
    const mouse_button_count = @typeInfo(MouseButton).@"enum".fields.len;

    pub fn setKey(self: *State, key: Key, down: bool) void {
        self.keys[@intFromEnum(key)] = down;
    }

    pub fn clearKeys(self: *State) void {
        @memset(&self.keys, false);
    }

    pub fn getKey(self: State, key: Key) bool {
        return self.keys[@intFromEnum(key)];
    }

    pub fn setMouseButton(self: *State, button: MouseButton, down: bool) void {
        self.mouse_buttons[@intFromEnum(button)] = down;
    }

    pub fn clearMouseButtons(self: *State) void {
        @memset(&self.mouse_buttons, false);
    }

    pub fn getMouseButton(self: State, button: MouseButton) bool {
        return self.mouse_buttons[@intFromEnum(button)];
    }

    pub fn setCursor(self: *State, x: f64, y: f64) void {
        self.cursor = .{ x, y };
    }

    pub fn addScroll(self: *State, delta: f64) void {
        self.scroll_delta += delta;
    }

    pub fn consumeScrollDelta(self: *State) f64 {
        const delta = self.scroll_delta;
        self.scroll_delta = 0;
        return delta;
    }
};

test "input state tracks keys buttons and scroll" {
    var input: State = .{};
    input.setKey(.escape, true);
    input.setMouseButton(.left, true);
    input.addScroll(1.5);

    try std.testing.expect(input.getKey(.escape));
    try std.testing.expect(input.getMouseButton(.left));
    try std.testing.expectEqual(@as(f64, 1.5), input.consumeScrollDelta());
    try std.testing.expectEqual(@as(f64, 0), input.consumeScrollDelta());

    input.clearKeys();
    input.clearMouseButtons();
    try std.testing.expect(!input.getKey(.escape));
    try std.testing.expect(!input.getMouseButton(.left));
}
