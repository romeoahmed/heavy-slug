//! Compile-time shape checks for renderer backends used by `RendererCore`.
//!
//! Backend resource-lifetime invariant
//! ===================================
//!
//! `uploadBlob` is handed a `byte_pool.Allocation` carved from the renderer's
//! single glyph-pool buffer, plus the encoded blob bytes. It must return a
//! `GlyphBlobRef` that, together with the input allocation, identifies the
//! **same physical resource**: in the bundled Vulkan and Metal backends the
//! ref is literally the pool byte offset, so the pool allocation already
//! encodes the ref and no per-blob GPU object exists. Consequently
//! `retireBlob` is permitted to be a no-op — `GlyphStore.retireCompleted`
//! calls `pool_alloc.free(allocation)` alongside `retireBlob(ref)`, and the
//! pool free is the only mandatory step for a pool-resident backend.
//!
//! A backend that allocates a *separate* GPU object per blob (image,
//! descriptor, …) must release it in `retireBlob`; in that case `retireBlob`
//! and the matching `pool_alloc.free` together free both halves of the same
//! logical resource. Either way, `ensureGlyphCached` cleans up partial state
//! through `errdefer pool_alloc.free` + `errdefer backend.retireBlob`, so the
//! pair must be safe to call back-to-back on the same ref/allocation.

const std = @import("std");

pub fn checkBackend(comptime Backend: type) void {
    comptime {
        const Impl = backendImpl(Backend);
        requireDecl(Impl, "GlyphBlobRef");
        requireDecl(Impl, "FrameToken");
        requireDecl(Impl, "GlyphInstance");
        requireDecl(Impl, "GlyphMeshlet");
        requireFn(Impl, "uploadBlob");
        requireFn(Impl, "retireBlob");
    }
}

pub fn backendImpl(comptime Backend: type) type {
    return switch (@typeInfo(Backend)) {
        .pointer => |ptr| ptr.child,
        else => Backend,
    };
}

pub fn glyphInstanceType(comptime Backend: type) type {
    checkBackend(Backend);
    return backendImpl(Backend).GlyphInstance;
}

pub fn glyphMeshletType(comptime Backend: type) type {
    checkBackend(Backend);
    return backendImpl(Backend).GlyphMeshlet;
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

test "checkBackend accepts a complete backend shape" {
    checkBackend(GoodBackend);
    checkBackend(*GoodBackend);
    try std.testing.expect(true);
}
