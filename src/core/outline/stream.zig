const std = @import("std");

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Segment = union(enum) {
    move_to: Point,
    line_to: Point,
    quad_to: struct { control: Point, to: Point },
    cubic_to: struct { control1: Point, control2: Point, to: Point },
    close,
};

pub const OutlineStream = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayList(Segment) = .empty,

    pub fn init(allocator: std.mem.Allocator) OutlineStream {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OutlineStream) void {
        self.segments.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *OutlineStream) void {
        self.segments.clearRetainingCapacity();
    }

    pub fn moveTo(self: *OutlineStream, p: Point) !void {
        try self.segments.append(self.allocator, .{ .move_to = p });
    }

    pub fn lineTo(self: *OutlineStream, p: Point) !void {
        try self.segments.append(self.allocator, .{ .line_to = p });
    }

    pub fn quadTo(self: *OutlineStream, control: Point, to: Point) !void {
        try self.segments.append(self.allocator, .{ .quad_to = .{ .control = control, .to = to } });
    }

    pub fn cubicTo(self: *OutlineStream, control1: Point, control2: Point, to: Point) !void {
        try self.segments.append(self.allocator, .{ .cubic_to = .{ .control1 = control1, .control2 = control2, .to = to } });
    }

    pub fn close(self: *OutlineStream) !void {
        try self.segments.append(self.allocator, .close);
    }
};

test "OutlineStream records native segment variants" {
    var outline = OutlineStream.init(std.testing.allocator);
    defer outline.deinit();

    try outline.moveTo(.{ .x = 0, .y = 0 });
    try outline.lineTo(.{ .x = 1, .y = 0 });
    try outline.quadTo(.{ .x = 2, .y = 1 }, .{ .x = 3, .y = 0 });
    try outline.cubicTo(.{ .x = 4, .y = 1 }, .{ .x = 5, .y = 1 }, .{ .x = 6, .y = 0 });
    try outline.close();

    try std.testing.expectEqual(@as(usize, 5), outline.segments.items.len);
    try std.testing.expect(outline.segments.items[2] == .quad_to);
    try std.testing.expect(outline.segments.items[3] == .cubic_to);
}
