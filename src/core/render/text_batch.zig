const std = @import("std");

pub fn TextBatch(comptime Command: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        commands: std.ArrayList(Command) = .empty,
        submitted: bool = false,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.commands.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn reset(self: *Self) void {
            self.commands.clearRetainingCapacity();
            self.submitted = false;
        }

        pub fn append(self: *Self, command: Command) !void {
            if (self.submitted) return error.FrameAlreadySubmitted;
            try self.commands.append(self.allocator, command);
        }

        pub fn slice(self: *const Self) []const Command {
            return self.commands.items;
        }

        pub fn markSubmitted(self: *Self) void {
            self.submitted = true;
        }
    };
}

test "TextBatch rejects appends after submit" {
    const Command = extern struct { value: u32 };
    var batch = TextBatch(Command).init(std.testing.allocator);
    defer batch.deinit();

    try batch.append(.{ .value = 1 });
    batch.markSubmitted();
    try std.testing.expectError(error.FrameAlreadySubmitted, batch.append(.{ .value = 2 }));
    try std.testing.expectEqual(@as(usize, 1), batch.slice().len);
}
