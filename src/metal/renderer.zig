const std = @import("std");
const heavy_slug = @import("heavy_slug");
const gpu_structs = @import("gpu_structs");
const metal_shaders = @import("metal_shaders");

const pool_mod = heavy_slug.pool;
const render = heavy_slug.render;
const pga = heavy_slug.pga;

pub const GlyphCommand = gpu_structs.GlyphCommand;
pub const PushConstants = gpu_structs.PushConstants;

const ContextHandle = opaque {};
const BufferHandle = opaque {};
const frames_in_flight = 3;

pub const HostObjects = extern struct {
    /// Host-owned id<MTLDevice>. Must outlive Context.
    device: *anyopaque,
    /// Host-owned id<MTLCommandQueue>. Must belong to device and outlive Context.
    command_queue: *anyopaque,
    /// Host-owned CAMetalLayer with device and pixelFormat already configured.
    layer: *anyopaque,
};

extern fn hs_metal_context_create(
    host: HostObjects,
    task_source: [*]const u8,
    task_source_len: usize,
    mesh_source: [*]const u8,
    mesh_source_len: usize,
    fragment_source: [*]const u8,
    fragment_source_len: usize,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) ?*ContextHandle;

extern fn hs_metal_context_destroy(context: *ContextHandle) void;
extern fn hs_metal_context_wait_frame_slot(
    context: *ContextHandle,
    slot_index: u32,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) c_int;
extern fn hs_metal_context_release_frame_slot(context: *ContextHandle, slot_index: u32) void;
extern fn hs_metal_context_wait_submitted(context: *ContextHandle) void;
extern fn hs_metal_buffer_create(context: *ContextHandle, size: usize) ?*BufferHandle;
extern fn hs_metal_buffer_destroy(buffer: *BufferHandle) void;
extern fn hs_metal_buffer_contents(buffer: *BufferHandle) ?[*]u8;
extern fn hs_metal_context_draw(
    context: *ContextHandle,
    width: u32,
    height: u32,
    clear_r: f32,
    clear_g: f32,
    clear_b: f32,
    clear_a: f32,
    commands: *BufferHandle,
    push_constants: *BufferHandle,
    glyph_pool: *BufferHandle,
    workgroup_count: u32,
    slot_index: u32,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) c_int;

pub const Error = error{
    MetalInitFailed,
    MetalBufferCreateFailed,
    MetalDrawFailed,
};

pub const Options = render.Options;
pub const InitOptions = Options;
pub const FontHandle = render.FontHandle;
pub const Stats = render.Stats;
pub const max_frames_in_flight = frames_in_flight;

pub const Context = struct {
    handle: *ContextHandle,

    pub fn init(host: HostObjects) !Context {
        var error_buf: [2048]u8 = undefined;
        const handle = hs_metal_context_create(
            host,
            metal_shaders.task.ptr,
            metal_shaders.task.len,
            metal_shaders.mesh.ptr,
            metal_shaders.mesh.len,
            metal_shaders.fragment.ptr,
            metal_shaders.fragment.len,
            &error_buf,
            error_buf.len,
        ) orelse {
            std.log.err("Metal init failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.MetalInitFailed;
        };
        return .{ .handle = handle };
    }

    pub fn deinit(self: *Context) void {
        hs_metal_context_destroy(self.handle);
        self.* = undefined;
    }
};

const MappedBuffer = struct {
    handle: *BufferHandle,
    mapped: [*]u8,
    size: usize,

    fn init(ctx: Context, size: usize) !MappedBuffer {
        const handle = hs_metal_buffer_create(ctx.handle, size) orelse
            return Error.MetalBufferCreateFailed;
        errdefer hs_metal_buffer_destroy(handle);

        const mapped = hs_metal_buffer_contents(handle) orelse
            return Error.MetalBufferCreateFailed;

        return .{
            .handle = handle,
            .mapped = mapped,
            .size = size,
        };
    }

    fn deinit(self: MappedBuffer) void {
        hs_metal_buffer_destroy(self.handle);
    }
};

const FrameSlot = struct {
    commands: MappedBuffer,
    push_constants: MappedBuffer,

    fn deinit(self: FrameSlot) void {
        self.push_constants.deinit();
        self.commands.deinit();
    }
};

pub const TextRenderer = struct {
    context: Context,
    core: render.TextCore,
    pool_buffer: MappedBuffer,
    frame_slots: [frames_in_flight]FrameSlot,
    active_frame: u32,
    frame_reserved: bool,
    allocator: std.mem.Allocator,

    pub fn init(
        context: Context,
        allocator: std.mem.Allocator,
        options: InitOptions,
    ) !TextRenderer {
        var core = try render.TextCore.init(allocator, options);
        errdefer core.deinit();

        const pool_buf = try MappedBuffer.init(context, options.pool_buffer_size);
        errdefer pool_buf.deinit();

        const cmd_buf_size = @as(usize, options.max_glyphs_per_frame) * @sizeOf(GlyphCommand);
        var frame_slots: [frames_in_flight]FrameSlot = undefined;
        var initialized_slots: usize = 0;
        errdefer {
            for (frame_slots[0..initialized_slots]) |slot| slot.deinit();
        }
        for (&frame_slots) |*slot| {
            const cmd_buf = try MappedBuffer.init(context, cmd_buf_size);
            errdefer cmd_buf.deinit();

            const push_buf = try MappedBuffer.init(context, @sizeOf(PushConstants));
            errdefer push_buf.deinit();

            slot.* = .{
                .commands = cmd_buf,
                .push_constants = push_buf,
            };
            initialized_slots += 1;
        }

        return .{
            .context = context,
            .core = core,
            .pool_buffer = pool_buf,
            .frame_slots = frame_slots,
            .active_frame = frames_in_flight - 1,
            .frame_reserved = false,
            .allocator = allocator,
        };
    }

    pub fn loadFont(self: *TextRenderer, path: [*:0]const u8, size_px: u32) !FontHandle {
        return self.core.loadFont(path, size_px);
    }

    pub fn unloadFont(self: *TextRenderer, handle: FontHandle) void {
        self.core.unloadFont(self, handle);
    }

    pub fn begin(self: *TextRenderer) Error!void {
        if (self.frame_reserved) {
            hs_metal_context_release_frame_slot(self.context.handle, self.active_frame);
            self.frame_reserved = false;
        }

        self.active_frame = (self.active_frame + 1) % frames_in_flight;
        var error_buf: [2048]u8 = undefined;
        if (hs_metal_context_wait_frame_slot(
            self.context.handle,
            self.active_frame,
            &error_buf,
            error_buf.len,
        ) == 0) {
            std.log.err("Metal frame slot wait failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.MetalDrawFailed;
        }
        self.frame_reserved = true;
        self.core.begin();
    }

    pub fn drawText(
        self: *TextRenderer,
        font: FontHandle,
        text: []const u8,
        motor: pga.Motor,
        color: [4]f32,
    ) !void {
        const commands: [*]GlyphCommand = @ptrCast(@alignCast(self.frame_slots[self.active_frame].commands.mapped));
        try self.core.appendText(self, GlyphCommand, commands, font, text, motor, color);
    }

    pub fn uploadGlyphBlob(self: *TextRenderer, pool_alloc: pool_mod.Allocation, data: []const u8) !u32 {
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..data.len];
        @memcpy(dst, data);
        return pool_alloc.offset;
    }

    pub fn releaseGlyphRef(self: *TextRenderer, _: u32) void {
        // Metal stores glyph refs as byte offsets into one buffer; freeing the
        // pool allocation is enough, and TextCore handles that. Wait for
        // submitted frames first so a reused offset cannot race GPU reads.
        hs_metal_context_wait_submitted(self.context.handle);
    }

    pub fn flush(
        self: *TextRenderer,
        viewport: [2]u32,
        proj: [4][4]f32,
        clear_color: [4]f32,
    ) Error!void {
        const pass_count = self.core.passCount();
        if (pass_count == 0) {
            if (self.frame_reserved) {
                hs_metal_context_release_frame_slot(self.context.handle, self.active_frame);
                self.frame_reserved = false;
            }
            return;
        }

        const proj_em = render.projectionToEm(proj);
        const frame_slot = &self.frame_slots[self.active_frame];

        const push = PushConstants{
            .proj = proj_em,
            .viewport_dim = .{ @floatFromInt(viewport[0]), @floatFromInt(viewport[1]) },
            .glyph_count = pass_count,
            .glyph_base = self.core.flush_base,
        };
        const push_bytes = frame_slot.push_constants.mapped[0..@sizeOf(PushConstants)];
        @memcpy(push_bytes, std.mem.asBytes(&push));

        const workgroup_count = (pass_count + 31) / 32;
        var error_buf: [2048]u8 = undefined;
        if (hs_metal_context_draw(
            self.context.handle,
            viewport[0],
            viewport[1],
            clear_color[0],
            clear_color[1],
            clear_color[2],
            clear_color[3],
            frame_slot.commands.handle,
            frame_slot.push_constants.handle,
            self.pool_buffer.handle,
            workgroup_count,
            self.active_frame,
            &error_buf,
            error_buf.len,
        ) == 0) {
            std.log.err("Metal draw failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            hs_metal_context_release_frame_slot(self.context.handle, self.active_frame);
            self.frame_reserved = false;
            return Error.MetalDrawFailed;
        }
        self.frame_reserved = false;

        if (@import("builtin").mode == .Debug) {
            self.core.stats.glyphs_submitted += pass_count;
            self.core.stats.pool_free_blocks = @intCast(self.core.pool_alloc.free_blocks.items.len);
        }
        self.core.finishPass();
    }

    pub fn deinit(self: *TextRenderer) void {
        if (self.frame_reserved) {
            hs_metal_context_release_frame_slot(self.context.handle, self.active_frame);
            self.frame_reserved = false;
        }
        hs_metal_context_wait_submitted(self.context.handle);
        for (self.frame_slots) |slot| slot.deinit();
        self.pool_buffer.deinit();
        self.core.deinit();
        self.* = undefined;
    }
};

test "Metal renderer public API compiles" {
    _ = Context;
    _ = TextRenderer;
    try std.testing.expectEqual(@as(usize, 3), max_frames_in_flight);
    _ = @TypeOf(Context.init);
    _ = @TypeOf(TextRenderer.init);
}
