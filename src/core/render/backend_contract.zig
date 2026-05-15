const std = @import("std");

pub fn BackendContract(comptime Backend: type) void {
    comptime {
        const Impl = backendImplType(Backend);
        requireDecl(Impl, "GlyphRef");
        requireDecl(Impl, "FrameToken");
        requireDecl(Impl, "Command");
        requireFn(Impl, "uploadGlyphBlob");
        requireFn(Impl, "releaseGlyphRef");
        requireFn(Impl, "completedFrameToken");
    }
}

fn backendImplType(comptime Backend: type) type {
    return switch (@typeInfo(Backend)) {
        .pointer => |ptr| ptr.child,
        else => Backend,
    };
}

fn requireDecl(comptime T: type, comptime name: []const u8) void {
    if (!@hasDecl(T, name)) {
        @compileError(@typeName(T) ++ " must declare " ++ name);
    }
}

fn requireFn(comptime T: type, comptime name: []const u8) void {
    requireDecl(T, name);
    const decl = @field(T, name);
    if (@typeInfo(@TypeOf(decl)) != .@"fn") {
        @compileError(@typeName(T) ++ "." ++ name ++ " must be a function");
    }
}

const GoodBackend = struct {
    pub const GlyphRef = u32;
    pub const FrameToken = u64;
    pub const Command = extern struct { value: u32 };

    pub fn uploadGlyphBlob(_: *@This(), _: anytype, _: []const u8) !GlyphRef {
        return 0;
    }

    pub fn releaseGlyphRef(_: *@This(), _: GlyphRef) void {}

    pub fn completedFrameToken(_: *const @This()) FrameToken {
        return 0;
    }
};

test "BackendContract accepts a complete backend shape" {
    BackendContract(GoodBackend);
    BackendContract(*GoodBackend);
    try std.testing.expect(true);
}
