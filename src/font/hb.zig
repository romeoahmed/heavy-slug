const std = @import("std");
const c = @cImport({
    @cInclude("hb.h");
});

pub const Error = error{
    BufferCreateFailed,
    AllocationFailed,
};

pub const Buffer = struct {
    handle: *c.hb_buffer_t,

    pub fn create() Error!Buffer {
        const buf = c.hb_buffer_create() orelse return error.BufferCreateFailed;
        if (c.hb_buffer_allocation_successful(buf) == 0) {
            c.hb_buffer_destroy(buf);
            return error.AllocationFailed;
        }
        return .{ .handle = buf };
    }

    pub fn destroy(self: Buffer) void {
        c.hb_buffer_destroy(self.handle);
    }

    pub fn addUtf8(self: Buffer, text: []const u8) void {
        c.hb_buffer_add_utf8(
            self.handle,
            text.ptr,
            @intCast(text.len),
            0,
            @intCast(text.len),
        );
    }

    pub fn getLength(self: Buffer) u32 {
        return c.hb_buffer_get_length(self.handle);
    }

    pub fn setDirection(self: Buffer, dir: c.hb_direction_t) void {
        c.hb_buffer_set_direction(self.handle, dir);
    }

    pub fn setScript(self: Buffer, script: c.hb_script_t) void {
        c.hb_buffer_set_script(self.handle, script);
    }
};

/// Re-export C constants for callers that need direction/script values.
pub const Direction = c.hb_direction_t;
pub const Script = c.hb_script_t;
pub const HB_DIRECTION_LTR = c.HB_DIRECTION_LTR;
pub const HB_SCRIPT_LATIN = c.HB_SCRIPT_LATIN;

test "create and destroy HarfBuzz buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
}

test "add UTF-8 text to buffer" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.addUtf8("hello");
    try std.testing.expectEqual(@as(u32, 5), buf.getLength());
}

test "set direction and script" {
    const buf = try Buffer.create();
    defer buf.destroy();
    buf.setDirection(c.HB_DIRECTION_LTR);
    buf.setScript(c.HB_SCRIPT_LATIN);
    buf.addUtf8("test");
    try std.testing.expectEqual(@as(u32, 4), buf.getLength());
}
