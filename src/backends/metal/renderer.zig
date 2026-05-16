const std = @import("std");
const heavy_slug = @import("heavy_slug");
const gpu_structs = @import("gpu_structs");
const metal_shaders = @import("metal_shaders");

const pool_mod = heavy_slug.core.cache.byte_pool;
const render = heavy_slug.core.render.renderer_core;
const core_types = heavy_slug.core.types;

pub const GlyphCommand = gpu_structs.GlyphCommand;
pub const PushConstants = gpu_structs.PushConstants;

const ContextHandle = opaque {};
const PipelineHandle = opaque {};
const BufferHandle = opaque {};
const FrameHandle = opaque {};
const TargetHandle = opaque {};
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

const ResourceIndices = extern struct {
    glyph_pool: u32,
    commands: u32,
    push_constants: u32,
};

extern fn hs_metal_get_resource_indices() ResourceIndices;

pub const Error = error{
    MetalInitFailed,
    MetalBufferCreateFailed,
    MetalDrawFailed,
};

pub const RendererOptions = render.RendererOptions;
pub const FontHandle = render.FontHandle;
pub const FrameToken = render.FrameToken;
pub const Stats = render.Stats;
pub const max_frames_in_flight = frames_in_flight;

pub const Target = struct {
    viewport: [2]u32,
    projection: [4][4]f32,
    clear_color: [4]f32,
};

const CommandBatch = heavy_slug.core.render.TextBatch(GlyphCommand);

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

pub const Frame = struct {
    renderer: *Renderer,
    batch: CommandBatch,
    submitted: bool = false,

    pub fn drawText(
        self: *Frame,
        run: heavy_slug.TextRun,
    ) !void {
        if (self.submitted) return error.FrameAlreadySubmitted;
        try self.renderer.core.appendRun(self.renderer, &self.batch, run);
    }

    pub fn submit(self: *Frame, target: Target) !render.FrameToken {
        if (self.submitted) return error.FrameAlreadySubmitted;
        const token = try self.renderer.submitFrame(target, self.batch.count());
        self.batch.markSubmitted();
        self.submitted = true;
        return token;
    }
};

pub const Renderer = struct {
    pub const GlyphRef = render.GlyphRef;
    pub const FrameToken = render.FrameToken;
    pub const Command = GlyphCommand;

    context: Context,
    core: render.RendererCore,
    pool_buffer: MappedBuffer,
    frame_slots: [frames_in_flight]FrameSlot,
    active_frame: u32,
    frame_reserved: bool,
    slot_tokens: [frames_in_flight]render.FrameToken,
    last_submitted_frame: render.FrameToken,
    completed_frame: render.FrameToken,
    allocator: std.mem.Allocator,

    pub fn init(
        context: Context,
        allocator: std.mem.Allocator,
        options: RendererOptions,
    ) !Renderer {
        var core = try render.RendererCore.init(allocator, options);
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
            .slot_tokens = .{0} ** frames_in_flight,
            .last_submitted_frame = 0,
            .completed_frame = 0,
            .allocator = allocator,
        };
    }

    pub fn loadFont(
        self: *Renderer,
        source: core_types.FontSource,
        options: core_types.FontOptions,
    ) !FontHandle {
        return self.core.loadFont(source, options);
    }

    pub fn unloadFont(self: *Renderer, handle: FontHandle) !void {
        self.core.setRetireAfterToken(self.last_submitted_frame);
        try self.core.unloadFont(handle);
    }

    fn reserveFrameSlot(self: *Renderer) Error!void {
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
        if (self.slot_tokens[self.active_frame] > self.completed_frame) {
            self.completed_frame = self.slot_tokens[self.active_frame];
        }
        self.frame_reserved = true;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        self.core.beginFrame(self.completed_frame, self);
    }

    pub fn beginFrame(self: *Renderer) Error!Frame {
        try self.reserveFrameSlot();
        const commands: [*]GlyphCommand = @ptrCast(@alignCast(self.frame_slots[self.active_frame].commands.mapped));
        const command_slice = commands[0..self.core.max_glyphs_per_frame];
        return .{
            .renderer = self,
            .batch = CommandBatch.init(command_slice),
        };
    }

    pub fn uploadBlob(self: *Renderer, pool_alloc: pool_mod.Allocation, data: []const u8) !GlyphRef {
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..data.len];
        @memcpy(dst, data);
        return GlyphRef.from(pool_alloc.offset);
    }

    pub fn retireBlob(self: *Renderer, _: GlyphRef) void {
        _ = self;
        // Metal stores glyph refs as byte offsets into one buffer; RendererCore
        // frees the paired pool allocation only after a completed frame token.
    }

    pub fn completedFrameToken(self: *const Renderer) render.FrameToken {
        return self.completed_frame;
    }

    fn submitFrame(self: *Renderer, target: Target, glyph_count: u32) Error!render.FrameToken {
        if (glyph_count == 0) {
            if (self.frame_reserved) {
                hs_metal_context_release_frame_slot(self.context.handle, self.active_frame);
                self.frame_reserved = false;
            }
            return self.last_submitted_frame;
        }

        const viewport = target.viewport;
        const proj = target.projection;
        const clear_color = target.clear_color;
        const proj_em = render.projectionToEm(proj);
        const frame_slot = &self.frame_slots[self.active_frame];

        const push = PushConstants{
            .proj = proj_em,
            .viewport_dim = .{ @floatFromInt(viewport[0]), @floatFromInt(viewport[1]) },
            .glyph_count = glyph_count,
            .glyph_base = 0,
        };
        const push_bytes = frame_slot.push_constants.mapped[0..@sizeOf(PushConstants)];
        @memcpy(push_bytes, std.mem.asBytes(&push));

        const workgroup_count = (glyph_count + 31) / 32;
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
            self.core.stats.glyphs_submitted += glyph_count;
            self.core.stats.pool_free_blocks = self.core.poolFreeBlockCount();
        }
        self.last_submitted_frame +%= 1;
        self.slot_tokens[self.active_frame] = self.last_submitted_frame;
        self.core.setRetireAfterToken(self.last_submitted_frame);
        return self.last_submitted_frame;
    }

    pub fn deinit(self: *Renderer) void {
        if (self.frame_reserved) {
            hs_metal_context_release_frame_slot(self.context.handle, self.active_frame);
            self.frame_reserved = false;
        }
        hs_metal_context_wait_submitted(self.context.handle);
        self.completed_frame = std.math.maxInt(render.FrameToken);
        self.core.retireCompleted(self.completed_frame, self);
        for (self.frame_slots) |slot| slot.deinit();
        self.pool_buffer.deinit();
        self.core.deinit();
        self.* = undefined;
    }
};

test "Metal renderer public API compiles" {
    _ = Context;
    _ = Renderer;
    try std.testing.expectEqual(@as(usize, 3), max_frames_in_flight);
    _ = @TypeOf(Context.init);
    _ = @TypeOf(Renderer.init);
    heavy_slug.core.render.BackendContract(Renderer);
}

test "Metal bridge resource indices match generated Slang MSL" {
    const indices = hs_metal_get_resource_indices();
    try std.testing.expectEqual(@as(u32, 0), indices.glyph_pool);
    try std.testing.expectEqual(@as(u32, 1), indices.commands);
    try std.testing.expectEqual(@as(u32, 2), indices.push_constants);

    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.task, "GlyphCommand_0 device* commands_1 [[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.task, "PushConstants_natural_0 constant* pc_1 [[buffer(2)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.mesh, "GlyphCommand_0 device* commands_1 [[buffer(1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.mesh, "PushConstants_natural_0 constant* pc_1 [[buffer(2)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.fragment, "glyphPool_0 [[buffer(0)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.mesh, "glyphRef_0 [[user(TEXCOORD_1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.fragment, "glyphRef_0 [[user(TEXCOORD_1)]]") != null);
    try std.testing.expect(std.mem.indexOf(u8, metal_shaders.fragment, "user(TEXCOORD__1)") == null);
}
