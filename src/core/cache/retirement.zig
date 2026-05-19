//! Generic deferred retirement queue keyed by completed frame tokens.

const std = @import("std");

/// Stores resources until the host reports that their token has completed.
pub fn DeferredRetirementQueue(comptime FrameToken: type, comptime Resource: type) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            token: FrameToken,
            resource: Resource,
        };

        allocator: std.mem.Allocator,
        entries: std.ArrayList(Entry) = .empty,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .allocator = allocator };
        }

        pub fn deinit(self: *Self) void {
            self.entries.deinit(self.allocator);
            self.* = undefined;
        }

        pub fn reserve(self: *Self, capacity: u32) !void {
            try self.entries.ensureTotalCapacity(self.allocator, capacity);
        }

        pub fn push(self: *Self, token: FrameToken, resource: Resource) !void {
            try self.entries.append(self.allocator, .{ .token = token, .resource = resource });
        }

        pub fn retireCompleted(self: *Self, completed_token: FrameToken, retiree: anytype) u32 {
            var retired: u32 = 0;
            var write: usize = 0;
            var read: usize = 0;
            while (read < self.entries.items.len) : (read += 1) {
                const entry = self.entries.items[read];
                if (tokenLe(entry.token, completed_token)) {
                    retiree.retire(entry.resource);
                    retired += 1;
                } else {
                    self.entries.items[write] = entry;
                    write += 1;
                }
            }
            self.entries.shrinkRetainingCapacity(write);
            return retired;
        }

        fn tokenLe(a: FrameToken, b: FrameToken) bool {
            return switch (@typeInfo(FrameToken)) {
                .int, .comptime_int => a <= b,
                .@"struct" => if (@hasDecl(FrameToken, "lessThanOrEqual"))
                    FrameToken.lessThanOrEqual(a, b)
                else
                    @compileError("FrameToken struct must provide lessThanOrEqual(a, b)"),
                else => @compileError("FrameToken must be an integer or a struct with lessThanOrEqual"),
            };
        }
    };
}

test "DeferredRetirementQueue retires only completed resources" {
    const Queue = DeferredRetirementQueue(u64, u32);
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.push(1, 10);
    try queue.push(3, 30);
    try queue.push(2, 20);

    const Retire = struct {
        values: std.ArrayList(u32) = .empty,

        fn retire(self: *@This(), value: u32) void {
            self.values.append(std.testing.allocator, value) catch unreachable;
        }
    };
    var retire: Retire = .{};
    defer retire.values.deinit(std.testing.allocator);

    const retired = queue.retireCompleted(2, &retire);

    try std.testing.expectEqual(@as(usize, 1), queue.entries.items.len);
    try std.testing.expectEqual(@as(u32, 30), queue.entries.items[0].resource);
    try std.testing.expectEqual(@as(u32, 2), retired);
    try std.testing.expectEqual(@as(usize, 2), retire.values.items.len);
}

test "DeferredRetirementQueue preserves pending order while compacting" {
    const Queue = DeferredRetirementQueue(u64, u32);
    var queue = Queue.init(std.testing.allocator);
    defer queue.deinit();

    try queue.push(5, 50);
    try queue.push(1, 10);
    try queue.push(4, 40);
    try queue.push(2, 20);

    const Retire = struct {
        retired: u32 = 0,

        fn retire(self: *@This(), _: u32) void {
            self.retired += 1;
        }
    };
    var retire: Retire = .{};

    try std.testing.expectEqual(@as(u32, 2), queue.retireCompleted(2, &retire));
    try std.testing.expectEqual(@as(u32, 2), retire.retired);
    try std.testing.expectEqual(@as(usize, 2), queue.entries.items.len);
    try std.testing.expectEqual(@as(u32, 50), queue.entries.items[0].resource);
    try std.testing.expectEqual(@as(u32, 40), queue.entries.items[1].resource);
}
