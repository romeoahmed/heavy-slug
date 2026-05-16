//! Borrowed per-frame glyph command storage.

pub fn TextBatch(comptime Command: type) type {
    return struct {
        const Self = @This();

        commands: []Command,
        len: u32 = 0,
        submitted: bool = false,

        pub fn init(commands: []Command) Self {
            return .{ .commands = commands };
        }

        pub fn reset(self: *Self) void {
            self.len = 0;
            self.submitted = false;
        }

        pub fn append(self: *Self, command: Command) !void {
            if (self.submitted) return error.FrameAlreadySubmitted;
            if (self.len >= self.commands.len) return error.GlyphCapacityExceeded;
            self.commands[self.len] = command;
            self.len += 1;
        }

        pub fn slice(self: *const Self) []const Command {
            return self.commands[0..self.len];
        }

        pub fn count(self: *const Self) u32 {
            return self.len;
        }

        pub fn markSubmitted(self: *Self) void {
            self.submitted = true;
        }
    };
}

const std = @import("std");

test "TextBatch writes into borrowed command storage" {
    const Command = extern struct { value: u32 };
    var storage: [2]Command = undefined;
    var batch = TextBatch(Command).init(&storage);

    try batch.append(.{ .value = 1 });
    try batch.append(.{ .value = 2 });
    try std.testing.expectError(error.GlyphCapacityExceeded, batch.append(.{ .value = 3 }));
    try std.testing.expectEqual(@as(u32, 2), batch.count());
    try std.testing.expectEqual(@as(u32, 1), batch.slice()[0].value);
}

test "TextBatch rejects appends after submit" {
    const Command = extern struct { value: u32 };
    var storage: [2]Command = undefined;
    var batch = TextBatch(Command).init(&storage);

    try batch.append(.{ .value = 1 });
    batch.markSubmitted();
    try std.testing.expectError(error.FrameAlreadySubmitted, batch.append(.{ .value = 2 }));
    try std.testing.expectEqual(@as(usize, 1), batch.slice().len);
}

test "TextBatch reset allows reuse after submit" {
    const Command = extern struct { value: u32 };
    var storage: [2]Command = undefined;
    var batch = TextBatch(Command).init(&storage);

    try batch.append(.{ .value = 1 });
    batch.markSubmitted();
    batch.reset();
    try batch.append(.{ .value = 2 });

    try std.testing.expectEqual(@as(u32, 1), batch.count());
    try std.testing.expectEqual(@as(u32, 2), batch.slice()[0].value);
}
