//! Compile-time shape checks for renderer backends used by `RendererCore`.

const std = @import("std");

pub fn BackendContract(comptime Backend: type) void {
    comptime {
        const Impl = BackendImpl(Backend);
        requireDecl(Impl, "GlyphBlobRef");
        requireDecl(Impl, "FrameToken");
        requireDecl(Impl, "GlyphInstance");
        requireDecl(Impl, "GlyphMeshlet");
        requireFn(Impl, "uploadBlob");
        requireFn(Impl, "retireBlob");
    }
}

pub fn BackendImpl(comptime Backend: type) type {
    return switch (@typeInfo(Backend)) {
        .pointer => |ptr| ptr.child,
        else => Backend,
    };
}

pub fn GlyphInstanceType(comptime Backend: type) type {
    BackendContract(Backend);
    return BackendImpl(Backend).GlyphInstance;
}

pub fn GlyphMeshletType(comptime Backend: type) type {
    BackendContract(Backend);
    return BackendImpl(Backend).GlyphMeshlet;
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
    pub const GlyphBlobRef = u32;
    pub const FrameToken = u64;
    pub const GlyphInstance = extern struct { value: u32 };
    pub const GlyphMeshlet = extern struct { glyph_index: u32 };

    pub fn uploadBlob(_: *@This(), _: anytype, _: []const u8) !GlyphBlobRef {
        return 0;
    }

    pub fn retireBlob(_: *@This(), _: GlyphBlobRef) void {}
};

test "BackendContract accepts a complete backend shape" {
    BackendContract(GoodBackend);
    BackendContract(*GoodBackend);
    try std.testing.expect(true);
}
