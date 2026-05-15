const std = @import("std");
const heavy_slug = @import("heavy_slug");
const gpu_structs = @import("gpu_structs");
const metal_shaders = @import("metal_shaders");

const pool_mod = heavy_slug.pool;
const cache_mod = heavy_slug.cache;
const ft = heavy_slug.font.ft;
const hb = heavy_slug.font.hb;
const glyph_mod = heavy_slug.font.glyph;
const pga = heavy_slug.pga;

pub const GlyphCommand = gpu_structs.GlyphCommand;
pub const PushConstants = gpu_structs.PushConstants;

const ContextHandle = opaque {};
const BufferHandle = opaque {};

extern fn hs_metal_context_create_from_cocoa_window(
    ns_window: *anyopaque,
    task_source: [*]const u8,
    task_source_len: usize,
    mesh_source: [*]const u8,
    mesh_source_len: usize,
    fragment_source: [*]const u8,
    fragment_source_len: usize,
    error_buffer: [*]u8,
    error_buffer_len: usize,
) ?*ContextHandle;

extern fn hs_metal_context_create_from_glfw_window(
    window: *anyopaque,
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
    error_buffer: [*]u8,
    error_buffer_len: usize,
) c_int;

fn emBoxFromExtents(ext: hb.GlyphExtents) cache_mod.EmBox {
    const x0: f32 = @floatFromInt(ext.x_bearing);
    const y0: f32 = @floatFromInt(ext.y_bearing);
    const x1 = x0 + @as(f32, @floatFromInt(ext.width));
    const y1 = y0 + @as(f32, @floatFromInt(ext.height));
    return .{
        .x_min = @min(x0, x1),
        .y_min = @min(y0, y1),
        .x_max = @max(x0, x1),
        .y_max = @max(y0, y1),
    };
}

pub const Error = error{
    MetalInitFailed,
    MetalBufferCreateFailed,
    MetalDrawFailed,
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
};

const empty_glyph_offset = std.math.maxInt(u32);

const CachedGlyph = struct {
    offset: u32,
    em_box: cache_mod.EmBox,
};

pub const Stats = if (@import("builtin").mode == .Debug) struct {
    cache_hits: u32 = 0,
    cache_misses: u32 = 0,
    evictions: u32 = 0,
    glyphs_submitted: u32 = 0,
    pool_free_blocks: u32 = 0,

    pub fn reset(self: *@This()) void {
        self.* = .{};
    }

    pub fn log(self: *const @This()) void {
        std.log.scoped(.metal_renderer).debug(
            "frame stats: hits={d} misses={d} evictions={d} glyphs={d} free_blocks={d}",
            .{ self.cache_hits, self.cache_misses, self.evictions, self.glyphs_submitted, self.pool_free_blocks },
        );
    }
} else struct {
    pub fn reset(_: *@This()) void {}
    pub fn log(_: *const @This()) void {}
};

pub const InitOptions = struct {
    max_glyphs_per_frame: u32 = 16_384,
    hot_slab_count: u32 = 4_096,
    cold_lru_count: u32 = 8_192,
    promote_frames: u8 = 3,
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    min_storage_alignment: u32 = 256,
};

pub const Context = struct {
    handle: *ContextHandle,

    pub fn initForCocoaWindow(ns_window: *anyopaque) !Context {
        return initWithWindow(hs_metal_context_create_from_cocoa_window, ns_window);
    }

    pub fn initForGlfwWindow(window: *anyopaque) !Context {
        return initWithWindow(hs_metal_context_create_from_glfw_window, window);
    }

    fn initWithWindow(
        comptime create: fn (
            *anyopaque,
            [*]const u8,
            usize,
            [*]const u8,
            usize,
            [*]const u8,
            usize,
            [*]u8,
            usize,
        ) callconv(.c) ?*ContextHandle,
        window: *anyopaque,
    ) !Context {
        var error_buf: [2048]u8 = undefined;
        const handle = create(
            window,
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

pub const FontHandle = struct {
    id: u32,
    entry: *FontEntry,
};

const FontEntry = struct {
    id: u32,
    ctx: glyph_mod.FontContext,
};

pub const TextRenderer = struct {
    context: Context,
    glyph_cache: cache_mod.GlyphCache,
    pool_alloc: pool_mod.PoolAllocator,
    pool_buffer: MappedBuffer,
    command_buffer: MappedBuffer,
    push_constants: MappedBuffer,
    ft_library: ft.Library,
    fonts: std.AutoHashMap(u32, *FontEntry),
    next_font_id: u32,
    glyph_count: u32,
    flush_base: u32,
    max_glyphs_per_frame: u32,
    shape_buffer: hb.Buffer,
    stats: Stats,
    allocator: std.mem.Allocator,

    pub fn init(
        context: Context,
        allocator: std.mem.Allocator,
        options: InitOptions,
    ) !TextRenderer {
        var glyph_cache = try cache_mod.GlyphCache.init(
            allocator,
            options.hot_slab_count,
            options.cold_lru_count,
            options.promote_frames,
        );
        errdefer glyph_cache.deinit();
        const total_cache_capacity = options.hot_slab_count + options.cold_lru_count;
        try glyph_cache.map.ensureTotalCapacity(total_cache_capacity);

        var pool_alloc = pool_mod.PoolAllocator.init(
            allocator,
            options.pool_buffer_size,
            options.min_storage_alignment,
        );
        errdefer pool_alloc.deinit();
        try pool_alloc.free_blocks.ensureTotalCapacity(allocator, total_cache_capacity);

        const pool_buf = try MappedBuffer.init(context, options.pool_buffer_size);
        errdefer pool_buf.deinit();

        const cmd_buf_size = @as(usize, options.max_glyphs_per_frame) * @sizeOf(GlyphCommand);
        const cmd_buf = try MappedBuffer.init(context, cmd_buf_size);
        errdefer cmd_buf.deinit();

        const push_buf = try MappedBuffer.init(context, @sizeOf(PushConstants));
        errdefer push_buf.deinit();

        const ft_library = try ft.Library.init();
        errdefer ft_library.deinit();

        const shape_buffer = try hb.Buffer.create();
        errdefer shape_buffer.destroy();

        return .{
            .context = context,
            .glyph_cache = glyph_cache,
            .pool_alloc = pool_alloc,
            .pool_buffer = pool_buf,
            .command_buffer = cmd_buf,
            .push_constants = push_buf,
            .ft_library = ft_library,
            .fonts = std.AutoHashMap(u32, *FontEntry).init(allocator),
            .next_font_id = 0,
            .glyph_count = 0,
            .flush_base = 0,
            .max_glyphs_per_frame = options.max_glyphs_per_frame,
            .shape_buffer = shape_buffer,
            .stats = .{},
            .allocator = allocator,
        };
    }

    pub fn loadFont(self: *TextRenderer, path: [*:0]const u8, size_px: u32) !FontHandle {
        const entry = try self.allocator.create(FontEntry);
        errdefer self.allocator.destroy(entry);

        entry.* = .{
            .id = self.next_font_id,
            .ctx = try glyph_mod.FontContext.init(self.ft_library, path, size_px),
        };
        errdefer entry.ctx.deinit();

        try self.fonts.put(self.next_font_id, entry);
        const id = self.next_font_id;
        self.next_font_id += 1;

        return .{ .id = id, .entry = entry };
    }

    pub fn unloadFont(self: *TextRenderer, handle: FontHandle) void {
        const evicted = self.glyph_cache.removeFont(self.allocator, handle.id) catch &.{};
        for (evicted) |e| {
            if (e.pool_alloc.size > 0) self.pool_alloc.free(e.pool_alloc);
        }
        if (evicted.len > 0) self.allocator.free(evicted);

        handle.entry.ctx.deinit();
        self.allocator.destroy(handle.entry);
        _ = self.fonts.remove(handle.id);
    }

    pub fn begin(self: *TextRenderer) void {
        self.glyph_count = 0;
        self.flush_base = 0;
        self.glyph_cache.advanceFrame();
        self.stats.reset();
    }

    pub fn drawText(
        self: *TextRenderer,
        font: FontHandle,
        text: []const u8,
        motor: pga.Motor,
        color: [4]f32,
    ) (Error || error{OutOfMemory})!void {
        if (!self.fonts.contains(font.id)) return Error.ShapingFailed;

        self.shape_buffer.reset();
        self.shape_buffer.addUtf8(text);
        self.shape_buffer.guessSegmentProperties();
        hb.shape(font.entry.ctx.hb_font, self.shape_buffer);

        const infos = self.shape_buffer.getGlyphInfos();
        const positions = self.shape_buffer.getGlyphPositions();
        if (self.glyph_count + infos.len > self.max_glyphs_per_frame) {
            return Error.GlyphCapacityExceeded;
        }

        const commands: [*]GlyphCommand = @ptrCast(@alignCast(self.command_buffer.mapped));
        const em_motor = pga.Motor{ .m = .{
            motor.m[0],
            motor.m[1],
            motor.m[2] * 64.0,
            motor.m[3] * 64.0,
        } };

        var pen_x: f32 = 0;
        var pen_y: f32 = 0;

        for (infos, positions) |info, pos| {
            const glyph_x = pen_x + @as(f32, @floatFromInt(pos.x_offset));
            const glyph_y = pen_y + @as(f32, @floatFromInt(pos.y_offset));
            const glyph_motor = em_motor.composeTranslation(glyph_x, glyph_y);

            const cache_key = cache_mod.CacheKey{
                .font_id = font.id,
                .glyph_id = info.codepoint,
            };

            const cached_glyph: CachedGlyph = if (self.glyph_cache.lookup(cache_key)) |entry| blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_hits += 1;
                break :blk .{ .offset = entry.slot, .em_box = entry.em_box };
            } else blk: {
                if (@import("builtin").mode == .Debug) self.stats.cache_misses += 1;
                break :blk try self.ensureGlyphCached(font, cache_key);
            };

            if (cached_glyph.offset != empty_glyph_offset) {
                commands[self.glyph_count] = .{
                    .motor = glyph_motor.m,
                    .color = color,
                    .em_x_min = cached_glyph.em_box.x_min,
                    .em_y_min = cached_glyph.em_box.y_min,
                    .em_x_max = cached_glyph.em_box.x_max,
                    .em_y_max = cached_glyph.em_box.y_max,
                    .descriptor_index = cached_glyph.offset,
                    .flags = 0,
                };
                self.glyph_count += 1;
            }

            pen_x += @as(f32, @floatFromInt(pos.x_advance));
            pen_y += @as(f32, @floatFromInt(pos.y_advance));
        }
    }

    fn ensureGlyphCached(
        self: *TextRenderer,
        font: FontHandle,
        cache_key: cache_mod.CacheKey,
    ) (Error || error{OutOfMemory})!CachedGlyph {
        const encoded = font.entry.ctx.encodeGlyph(cache_key.glyph_id) catch
            return Error.ShapingFailed;
        defer encoded.destroy();

        const em_box = emBoxFromExtents(encoded.extents);

        if (self.glyph_cache.cold_count >= self.glyph_cache.cold_capacity) {
            if (self.glyph_cache.evictLru()) |evicted| {
                if (@import("builtin").mode == .Debug) self.stats.evictions += 1;
                if (evicted.pool_alloc.size > 0) self.pool_alloc.free(evicted.pool_alloc);
            }
        }

        if (encoded.data.len == 0) {
            try self.glyph_cache.insertCold(cache_key, empty_glyph_offset, .{ .offset = 0, .size = 0 }, em_box);
            return .{ .offset = empty_glyph_offset, .em_box = em_box };
        }

        const pool_alloc = self.pool_alloc.alloc(@intCast(encoded.data.len)) orelse
            return Error.PoolExhausted;
        errdefer self.pool_alloc.free(pool_alloc);

        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..encoded.data.len];
        @memcpy(dst, encoded.data);

        try self.glyph_cache.insertCold(cache_key, pool_alloc.offset, pool_alloc, em_box);

        return .{ .offset = pool_alloc.offset, .em_box = em_box };
    }

    pub fn flush(
        self: *TextRenderer,
        viewport: [2]u32,
        proj: [4][4]f32,
        clear_color: [4]f32,
    ) Error!void {
        const pass_count = self.glyph_count - self.flush_base;
        if (pass_count == 0) return;

        var proj_em = proj;
        for (0..4) |j| {
            proj_em[0][j] /= 64.0;
            proj_em[1][j] /= 64.0;
        }

        const push = PushConstants{
            .proj = proj_em,
            .viewport_dim = .{ @floatFromInt(viewport[0]), @floatFromInt(viewport[1]) },
            .glyph_count = pass_count,
            .glyph_base = self.flush_base,
        };
        const push_bytes = self.push_constants.mapped[0..@sizeOf(PushConstants)];
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
            self.command_buffer.handle,
            self.push_constants.handle,
            self.pool_buffer.handle,
            workgroup_count,
            &error_buf,
            error_buf.len,
        ) == 0) {
            std.log.err("Metal draw failed: {s}", .{std.mem.sliceTo(&error_buf, 0)});
            return Error.MetalDrawFailed;
        }

        if (@import("builtin").mode == .Debug) {
            self.stats.glyphs_submitted += pass_count;
            self.stats.pool_free_blocks = @intCast(self.pool_alloc.free_blocks.items.len);
        }
        self.flush_base = self.glyph_count;
    }

    pub fn deinit(self: *TextRenderer) void {
        var font_it = self.fonts.valueIterator();
        while (font_it.next()) |entry_ptr| {
            entry_ptr.*.ctx.deinit();
            self.allocator.destroy(entry_ptr.*);
        }
        self.fonts.deinit();

        self.shape_buffer.destroy();
        self.ft_library.deinit();
        self.push_constants.deinit();
        self.command_buffer.deinit();
        self.pool_buffer.deinit();
        self.pool_alloc.deinit();
        self.glyph_cache.deinit();
        self.* = undefined;
    }
};

test "Metal renderer public API compiles" {
    _ = Context;
    _ = TextRenderer;
    _ = @TypeOf(Context.initForGlfwWindow);
    _ = @TypeOf(TextRenderer.init);
}
