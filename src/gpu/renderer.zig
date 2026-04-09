const std = @import("std");
const vk = @import("vulkan");
const gpu_context = @import("context.zig");
const descriptors = @import("descriptors.zig");
const pipeline_mod = @import("pipeline.zig");
const pool_mod = @import("pool.zig");
const cache_mod = @import("cache.zig");
const ft = @import("../font/ft.zig");
const hb = @import("../font/hb.zig");
const glyph_mod = @import("../font/glyph.zig");
const pga = @import("../math/pga.zig");

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

const CachedGlyph = struct {
    slot: u32,
    em_box: cache_mod.EmBox,
};

pub const Error = error{
    NoSuitableMemoryType,
    GlyphCapacityExceeded,
    ShapingFailed,
    PoolExhausted,
    DescriptorSlotExhausted,
};

pub const InitOptions = struct {
    /// Maximum bindless glyph descriptors. 64K covers all Unicode BMP
    /// glyphs at one font size; increase for multi-font workloads.
    max_glyph_descriptors: u32 = 65_536,
    /// Maximum glyphs per frame across all drawText+flush passes.
    /// 16K covers ~6 full screens of dense English text at 24px.
    max_glyphs_per_frame: u32 = 16_384,
    /// Hot cache capacity: frequently used glyphs (ASCII, punctuation).
    /// 4K covers ASCII + common Latin/CJK subsets per font.
    hot_slab_count: u32 = 4_096,
    /// Cold LRU cache capacity: infrequently used glyphs.
    /// 8K provides headroom for CJK character coverage.
    cold_lru_count: u32 = 8_192,
    /// Consecutive frames of use before promoting cold → hot.
    promote_frames: u8 = 3,
    /// Pool buffer size for glyph blob storage. 32 MB supports ~100K
    /// cached glyphs at typical blob sizes (200-400 bytes each).
    pool_buffer_size: u32 = 32 * 1024 * 1024,
    /// Must match device's minStorageBufferOffsetAlignment. 256 is
    /// conservatively correct for all conformant Vulkan implementations.
    min_storage_alignment: u32 = 256,
};

/// A host-visible, host-coherent VkBuffer with persistently mapped memory.
const MappedBuffer = struct {
    buffer: vk.Buffer,
    memory: vk.DeviceMemory,
    mapped: [*]u8,
    size: vk.DeviceSize,
};

/// Find a memory type index that satisfies both the type filter (from
/// VkMemoryRequirements.memoryTypeBits) and the required property flags.
fn findMemoryType(
    properties: vk.PhysicalDeviceMemoryProperties,
    type_filter: u32,
    required: vk.MemoryPropertyFlags,
) ?u32 {
    const required_bits: u32 = @bitCast(required);
    for (0..properties.memory_type_count) |i| {
        if (type_filter & (@as(u32, 1) << @as(u5, @intCast(i))) != 0) {
            const flags_bits: u32 = @bitCast(properties.memory_types[i].property_flags);
            if (flags_bits & required_bits == required_bits) {
                return @intCast(i);
            }
        }
    }
    return null;
}

fn createMappedBuffer(
    ctx: gpu_context.VulkanContext,
    size: vk.DeviceSize,
    usage: vk.BufferUsageFlags,
) !MappedBuffer {
    const device = ctx.device;
    const dispatch = ctx.dispatch;
    const buffer_ci = vk.BufferCreateInfo{
        .s_type = .buffer_create_info,
        .flags = .{},
        .size = size,
        .usage = usage,
        .sharing_mode = .exclusive,
        .queue_family_index_count = 0,
        .p_queue_family_indices = null,
    };
    const buffer = try dispatch.createBuffer(device, &buffer_ci, null);

    const mem_req = dispatch.getBufferMemoryRequirements(device, buffer);

    const mem_type_index = findMemoryType(
        ctx.memory_properties,
        mem_req.memory_type_bits,
        .{ .host_visible_bit = true, .host_coherent_bit = true },
    ) orelse {
        dispatch.destroyBuffer(device, buffer, null);
        return Error.NoSuitableMemoryType;
    };

    const alloc_info = vk.MemoryAllocateInfo{
        .s_type = .memory_allocate_info,
        .allocation_size = mem_req.size,
        .memory_type_index = mem_type_index,
    };
    const memory = dispatch.allocateMemory(device, &alloc_info, null) catch |err| {
        dispatch.destroyBuffer(device, buffer, null);
        return err;
    };
    // Buffer and memory both exist; errdefer must destroy buffer before freeing memory.
    errdefer {
        dispatch.destroyBuffer(device, buffer, null);
        dispatch.freeMemory(device, memory, null);
    }

    try dispatch.bindBufferMemory(device, buffer, memory, 0);

    const mapped_ptr = try dispatch.mapMemory(device, memory, 0, size, .{});

    return .{
        .buffer = buffer,
        .memory = memory,
        .mapped = @ptrCast(mapped_ptr.?),
        .size = size,
    };
}

fn destroyMappedBuffer(self: MappedBuffer, device: vk.Device, dispatch: gpu_context.DeviceDispatch) void {
    dispatch.unmapMemory(device, self.memory);
    dispatch.destroyBuffer(device, self.buffer, null);
    dispatch.freeMemory(device, self.memory, null);
}

/// A handle to a loaded font. Invalidated by `unloadFont` — do not use after unloading.
pub const FontHandle = struct {
    id: u32,
    entry: *FontEntry,
};

const FontEntry = struct {
    id: u32,
    ctx: glyph_mod.FontContext,
};

/// GPU text renderer using the Slug algorithm for exact glyph coverage.
///
/// **Thread safety:** Not thread-safe. All calls (begin, drawText, flush,
/// loadFont, unloadFont) must be made from a single thread or externally
/// synchronized. The renderer mutates shared state (glyph cache, pool
/// allocator, command buffer) without synchronization.
pub const TextRenderer = struct {
    device: vk.Device,
    dispatch: gpu_context.DeviceDispatch,

    // Subsystems
    descriptor_table: descriptors.DescriptorTable,
    pip: pipeline_mod.Pipeline,
    glyph_cache: cache_mod.GlyphCache,
    pool_alloc: pool_mod.PoolAllocator,

    // Vulkan buffers
    pool_buffer: MappedBuffer,
    command_buffer: MappedBuffer,

    // Font management
    ft_library: ft.Library,
    fonts: std.AutoHashMap(u32, *FontEntry),
    next_font_id: u32,

    // Per-frame state
    glyph_count: u32,
    flush_base: u32,
    max_glyphs_per_frame: u32,

    // Reusable HarfBuzz buffer (zero-alloc render loop)
    shape_buffer: hb.Buffer,

    // Stored for future buffer creation
    memory_properties: vk.PhysicalDeviceMemoryProperties,
    allocator: std.mem.Allocator,

    pub fn init(
        ctx: gpu_context.VulkanContext,
        color_format: vk.Format,
        allocator: std.mem.Allocator,
        options: InitOptions,
    ) !TextRenderer {
        const device = ctx.device;
        const dispatch = ctx.dispatch;
        // 1. Descriptor table
        var desc_table = try descriptors.DescriptorTable.init(
            ctx,
            allocator,
            options.max_glyph_descriptors,
        );
        errdefer desc_table.deinit(allocator);

        // 2. Pipeline
        var pip = try pipeline_mod.Pipeline.init(
            ctx,
            desc_table.layout,
            color_format,
        );
        errdefer pip.deinit();

        // 3. Glyph cache (pre-allocate HashMap to avoid render-loop allocations)
        var glyph_cache = try cache_mod.GlyphCache.init(
            allocator,
            options.hot_slab_count,
            options.cold_lru_count,
            options.promote_frames,
        );
        errdefer glyph_cache.deinit();
        const total_cache_capacity = options.hot_slab_count + options.cold_lru_count;
        try glyph_cache.map.ensureTotalCapacity(total_cache_capacity);

        // 4. Pool allocator (pre-allocate free list to avoid render-loop allocations)
        var pool_alloc = pool_mod.PoolAllocator.init(
            allocator,
            options.pool_buffer_size,
            options.min_storage_alignment,
        );
        errdefer pool_alloc.deinit();
        try pool_alloc.free_blocks.ensureTotalCapacity(allocator, total_cache_capacity);

        // 5. Pool buffer (glyph blob storage, GPU reads as storage buffer)
        const pool_buf = try createMappedBuffer(
            ctx,
            options.pool_buffer_size,
            .{ .storage_buffer_bit = true },
        );
        errdefer destroyMappedBuffer(pool_buf, device, dispatch);

        // 6. Command buffer (GlyphCommand[] per frame, GPU reads as storage buffer)
        const cmd_buf_size = @as(vk.DeviceSize, options.max_glyphs_per_frame) *
            @sizeOf(descriptors.GlyphCommand);
        const cmd_buf = try createMappedBuffer(
            ctx,
            cmd_buf_size,
            .{ .storage_buffer_bit = true },
        );
        errdefer destroyMappedBuffer(cmd_buf, device, dispatch);

        // Bind command buffer descriptor once for the full allocation.
        // Per-pass offsets are handled via glyph_base in push constants.
        desc_table.updateCommandBuffer(cmd_buf.buffer, 0, cmd_buf_size);

        // 7. FreeType library
        const ft_library = try ft.Library.init();
        errdefer ft_library.deinit();

        // 8. Reusable shaping buffer
        const shape_buffer = try hb.Buffer.create();
        errdefer shape_buffer.destroy();

        return .{
            .device = device,
            .dispatch = dispatch,
            .descriptor_table = desc_table,
            .pip = pip,
            .glyph_cache = glyph_cache,
            .pool_alloc = pool_alloc,
            .pool_buffer = pool_buf,
            .command_buffer = cmd_buf,
            .ft_library = ft_library,
            // AutoHashMap.init does not allocate; no errdefer needed
            .fonts = std.AutoHashMap(u32, *FontEntry).init(allocator),
            .next_font_id = 0,
            .glyph_count = 0,
            .flush_base = 0,
            .max_glyphs_per_frame = options.max_glyphs_per_frame,
            .shape_buffer = shape_buffer,
            .memory_properties = ctx.memory_properties,
            .allocator = allocator,
        };
    }

    /// Load a font from a file path at the given pixel size.
    /// Returns a FontHandle used in drawText calls.
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

    /// Unload a font and evict all its cached glyphs.
    /// Caller must ensure the GPU has finished consuming any commands that
    /// reference this font's glyphs before calling this function.
    pub fn unloadFont(self: *TextRenderer, handle: FontHandle) void {
        // Evict all cache entries for this font
        const evicted = self.glyph_cache.removeFont(self.allocator, handle.id) catch &.{};
        for (evicted) |e| {
            self.descriptor_table.nullSlot(e.slot);
            self.descriptor_table.freeSlot(e.slot);
            self.pool_alloc.free(e.pool_alloc);
        }
        if (evicted.len > 0) self.allocator.free(evicted);

        // Destroy font resources
        handle.entry.ctx.deinit();
        self.allocator.destroy(handle.entry);
        _ = self.fonts.remove(handle.id);
    }

    /// Reset per-frame state. Call once at the start of each frame.
    /// Multiple flush() calls may follow; each dispatches only the glyphs
    /// appended since the previous flush (or since begin).
    pub fn begin(self: *TextRenderer) void {
        self.glyph_count = 0;
        self.flush_base = 0;
        self.glyph_cache.advanceFrame();
    }

    /// Shape text and append glyph commands for GPU rendering.
    /// Call between begin() and flush(). Zero Zig allocations on cache hit.
    pub fn drawText(
        self: *TextRenderer,
        font: FontHandle,
        text: []const u8,
        motor: pga.Motor,
        color: [4]f32,
    ) (Error || error{OutOfMemory})!void {
        // Validate font handle — guards against use-after-unloadFont().
        if (!self.fonts.contains(font.id)) return Error.ShapingFailed;

        self.shape_buffer.reset();
        self.shape_buffer.addUtf8(text);
        self.shape_buffer.guessSegmentProperties();
        hb.shape(font.entry.ctx.hb_font, self.shape_buffer);

        const infos = self.shape_buffer.getGlyphInfos();
        const positions = self.shape_buffer.getGlyphPositions();

        const new_count = std.math.add(u32, self.glyph_count, @as(u32, @intCast(infos.len))) catch
            return Error.GlyphCapacityExceeded;
        if (new_count > self.max_glyphs_per_frame) return Error.GlyphCapacityExceeded;

        // Command buffer as a typed slice
        const commands: [*]descriptors.GlyphCommand = @ptrCast(@alignCast(self.command_buffer.mapped));

        // Convert caller's pixel-space motor to em-space (26.6 fixed-point).
        // Em-box extents and blob curve data are in 26.6 units from HarfBuzz;
        // motor translations must match so motor.apply(em_corner) is consistent.
        const em_motor = pga.Motor{ .m = .{
            motor.m[0],
            motor.m[1],
            motor.m[2] * 64.0,
            motor.m[3] * 64.0,
        } };

        // HarfBuzz positions are in 26.6 fixed-point; keep them as-is to match em-space.
        var pen_x: f32 = 0;
        var pen_y: f32 = 0;

        for (infos, positions) |info, pos| {
            const glyph_x = pen_x + @as(f32, @floatFromInt(pos.x_offset));
            const glyph_y = pen_y + @as(f32, @floatFromInt(pos.y_offset));

            // Compose caller's motor with per-glyph translation (both in 26.6)
            const glyph_motor = em_motor.composeTranslation(glyph_x, glyph_y);

            const cache_key = cache_mod.CacheKey{
                .font_id = font.id,
                .glyph_id = info.codepoint,
            };

            const cached_glyph: CachedGlyph = if (self.glyph_cache.lookup(cache_key)) |entry|
                .{ .slot = entry.slot, .em_box = entry.em_box }
            else
                try self.ensureGlyphCached(font, cache_key);

            commands[self.glyph_count] = .{
                .motor = glyph_motor.m,
                .color = color,
                .em_x_min = cached_glyph.em_box.x_min,
                .em_y_min = cached_glyph.em_box.y_min,
                .em_x_max = cached_glyph.em_box.x_max,
                .em_y_max = cached_glyph.em_box.y_max,
                .descriptor_index = cached_glyph.slot,
                .flags = 0,
            };
            self.glyph_count += 1;

            // Advance pen (26.6 units)
            pen_x += @as(f32, @floatFromInt(pos.x_advance));
            pen_y += @as(f32, @floatFromInt(pos.y_advance));
        }
    }

    /// Encode a glyph, upload to pool buffer, allocate descriptor slot,
    /// and insert into the cold cache. Returns the descriptor slot index and em-box.
    fn ensureGlyphCached(
        self: *TextRenderer,
        font: FontHandle,
        cache_key: cache_mod.CacheKey,
    ) (Error || error{OutOfMemory})!CachedGlyph {
        // Encode glyph
        const encoded = font.entry.ctx.encodeGlyph(cache_key.glyph_id) catch
            return Error.ShapingFailed;
        defer encoded.destroy();

        const em_box = emBoxFromExtents(encoded.extents);

        // Evict if cold cache is full
        if (self.glyph_cache.cold_count >= self.glyph_cache.cold_capacity) {
            if (self.glyph_cache.evictLru()) |evicted| {
                self.descriptor_table.nullSlot(evicted.slot);
                self.descriptor_table.freeSlot(evicted.slot);
                self.pool_alloc.free(evicted.pool_alloc);
            }
        }

        // Empty glyphs (e.g. space): cache with a null descriptor, no pool allocation.
        if (encoded.data.len == 0) {
            const slot = self.descriptor_table.allocSlot() orelse
                return Error.DescriptorSlotExhausted;
            self.descriptor_table.nullSlot(slot);
            try self.glyph_cache.insertCold(cache_key, slot, .{ .offset = 0, .size = 0 }, em_box);
            return .{ .slot = slot, .em_box = em_box };
        }

        // Allocate pool space
        const pool_alloc = self.pool_alloc.alloc(@intCast(encoded.data.len)) orelse
            return Error.PoolExhausted;
        errdefer self.pool_alloc.free(pool_alloc);

        // Copy blob data to mapped pool buffer
        const dst = self.pool_buffer.mapped[pool_alloc.offset..][0..encoded.data.len];
        @memcpy(dst, encoded.data);

        // Allocate descriptor slot
        const slot = self.descriptor_table.allocSlot() orelse
            return Error.DescriptorSlotExhausted;
        errdefer {
            self.descriptor_table.nullSlot(slot);
            self.descriptor_table.freeSlot(slot);
        }

        // Update descriptor to point at this glyph's blob in the pool buffer
        self.descriptor_table.updateSlot(
            slot,
            self.pool_buffer.buffer,
            @as(vk.DeviceSize, pool_alloc.offset),
            @as(vk.DeviceSize, encoded.data.len),
        );

        // Insert into cold cache (HashMap pre-allocated, should not alloc)
        try self.glyph_cache.insertCold(cache_key, slot, pool_alloc, em_box);

        return .{ .slot = slot, .em_box = em_box };
    }

    /// Record GPU commands into the caller's command buffer.
    /// The command buffer must be in a recording state inside a dynamic
    /// rendering pass. The caller is responsible for starting/ending the
    /// render pass and submitting the command buffer.
    ///
    /// `proj`: column-major 4×4 projection matrix (e.g. orthographic).
    /// `viewport`: viewport dimensions in pixels [width, height].
    pub fn flush(
        self: *TextRenderer,
        cmd_buf: vk.CommandBuffer,
        proj: [4][4]f32,
        viewport: [2]f32,
    ) void {
        const pass_count = self.glyph_count - self.flush_base;
        if (pass_count == 0) return;

        // Set dynamic viewport state
        const vk_viewport = vk.Viewport{
            .x = 0,
            .y = 0,
            .width = viewport[0],
            .height = viewport[1],
            .min_depth = 0,
            .max_depth = 1,
        };
        self.dispatch.cmdSetViewport(cmd_buf, 0, &.{vk_viewport});

        const vk_scissor = vk.Rect2D{
            .offset = .{ .x = 0, .y = 0 },
            .extent = .{
                .width = @intFromFloat(viewport[0]),
                .height = @intFromFloat(viewport[1]),
            },
        };
        self.dispatch.cmdSetScissor(cmd_buf, 0, &.{vk_scissor});

        // Bind pipeline
        self.dispatch.cmdBindPipeline(cmd_buf, .graphics, self.pip.pipeline);

        // Bind descriptor set
        self.dispatch.cmdBindDescriptorSets(
            cmd_buf,
            .graphics,
            self.pip.pipeline_layout,
            0,
            &.{self.descriptor_table.set},
            null,
        );

        // Scale projection from pixel-space to 26.6 em-space.
        // Motor translations and em-box extents are in 26.6 units (64x pixels).
        // Dividing columns 0 and 1 by 64 maps 26.6 world coords to clip space.
        var proj_em = proj;
        for (0..4) |j| {
            proj_em[0][j] /= 64.0;
            proj_em[1][j] /= 64.0;
        }

        // Push constants
        const push = descriptors.PushConstants{
            .proj = proj_em,
            .viewport_dim = viewport,
            .glyph_count = pass_count,
            .glyph_base = self.flush_base,
        };
        self.dispatch.cmdPushConstants(
            cmd_buf,
            self.pip.pipeline_layout,
            .{ .task_bit_ext = true, .mesh_bit_ext = true, .fragment_bit = true },
            0,
            @sizeOf(descriptors.PushConstants),
            @ptrCast(&push),
        );

        // Dispatch mesh shader workgroups (32 threads per workgroup in task shader)
        const workgroup_count = (pass_count + 31) / 32;
        self.dispatch.cmdDrawMeshTasksEXT(cmd_buf, workgroup_count, 1, 1);

        // Advance flush base for the next pass within this frame
        self.flush_base = self.glyph_count;
    }

    pub fn deinit(self: *TextRenderer) void {
        // Destroy fonts first (they hold FT/HB resources)
        var font_it = self.fonts.valueIterator();
        while (font_it.next()) |entry_ptr| {
            entry_ptr.*.ctx.deinit();
            self.allocator.destroy(entry_ptr.*);
        }
        self.fonts.deinit();

        // Destroy reusable shaping buffer
        self.shape_buffer.destroy();

        // Destroy FreeType library (after all faces are freed)
        self.ft_library.deinit();

        // Destroy Vulkan buffers (unmap + destroy buffer + free memory)
        destroyMappedBuffer(self.command_buffer, self.device, self.dispatch);
        destroyMappedBuffer(self.pool_buffer, self.device, self.dispatch);

        // Destroy subsystems (reverse init order)
        self.pool_alloc.deinit();
        self.glyph_cache.deinit();
        self.pip.deinit();
        self.descriptor_table.deinit(self.allocator);

        self.* = undefined;
    }
};

test "InitOptions has correct defaults" {
    const opts = InitOptions{};
    try std.testing.expectEqual(@as(u32, 65_536), opts.max_glyph_descriptors);
    try std.testing.expectEqual(@as(u32, 16_384), opts.max_glyphs_per_frame);
    try std.testing.expectEqual(@as(u32, 4_096), opts.hot_slab_count);
    try std.testing.expectEqual(@as(u32, 8_192), opts.cold_lru_count);
    try std.testing.expectEqual(@as(u8, 3), opts.promote_frames);
    try std.testing.expectEqual(@as(u32, 32 * 1024 * 1024), opts.pool_buffer_size);
    try std.testing.expectEqual(@as(u32, 256), opts.min_storage_alignment);
}

test "findMemoryType selects correct memory type" {
    var props = std.mem.zeroes(vk.PhysicalDeviceMemoryProperties);
    props.memory_type_count = 3;
    // Type 0: device-local only
    props.memory_types[0].property_flags = .{ .device_local_bit = true };
    // Type 1: host-visible only
    props.memory_types[1].property_flags = .{ .host_visible_bit = true };
    // Type 2: host-visible + host-coherent
    props.memory_types[2].property_flags = .{ .host_visible_bit = true, .host_coherent_bit = true };

    const filter: u32 = 0b111;

    // Require host-visible + host-coherent → type 2
    const result = findMemoryType(props, filter, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try std.testing.expectEqual(@as(?u32, 2), result);

    // Require device-local → type 0
    const dl = findMemoryType(props, filter, .{ .device_local_bit = true });
    try std.testing.expectEqual(@as(?u32, 0), dl);

    // Require something unavailable → null
    const none = findMemoryType(props, filter, .{ .protected_bit = true });
    try std.testing.expectEqual(@as(?u32, null), none);

    // Type filter excludes type 2 → null for host-visible + host-coherent
    const filtered = findMemoryType(props, 0b011, .{ .host_visible_bit = true, .host_coherent_bit = true });
    try std.testing.expectEqual(@as(?u32, null), filtered);
}

test "TextRenderer type compiles with expected fields" {
    _ = TextRenderer;
    try std.testing.expect(@hasField(TextRenderer, "device"));
    try std.testing.expect(@hasField(TextRenderer, "dispatch"));
    try std.testing.expect(@hasField(TextRenderer, "descriptor_table"));
    try std.testing.expect(@hasField(TextRenderer, "pip"));
    try std.testing.expect(@hasField(TextRenderer, "glyph_cache"));
    try std.testing.expect(@hasField(TextRenderer, "pool_alloc"));
    try std.testing.expect(@hasField(TextRenderer, "pool_buffer"));
    try std.testing.expect(@hasField(TextRenderer, "command_buffer"));
    try std.testing.expect(@hasField(TextRenderer, "ft_library"));
    try std.testing.expect(@hasField(TextRenderer, "fonts"));
    try std.testing.expect(@hasField(TextRenderer, "glyph_count"));
    try std.testing.expect(@hasField(TextRenderer, "flush_base"));
    try std.testing.expect(@hasField(TextRenderer, "shape_buffer"));
}

test "TextRenderer.init compiles" {
    // Type-check only — cannot call without a live Vulkan device
    _ = @TypeOf(TextRenderer.init);
}
