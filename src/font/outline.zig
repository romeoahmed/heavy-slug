const std = @import("std");
const hb = @import("hb.zig");
const c = hb.c;

pub const Error = error{
    HarfBuzzAllocationFailed,
    HarfBuzzDrawFailed,
    GlyphTooLarge,
    GlyphOffsetOverflow,
    OutOfMemory,
};

const units_per_em = 4.0;
const max_cubic_prepare_depth = 8;
const header_len = 4;
const blob_version = 3;
const curve_texel_len = 3;
const hband_height = 4.0;
const hband_height_q = @as(i16, @intFromFloat(hband_height * units_per_em));
const curve_ids_per_texel = 4;

pub const SegmentKind = enum(i16) {
    quad = 0,
    cubic = 1,
};

pub const Point = struct {
    x: f64,
    y: f64,
};

pub const Segment = struct {
    kind: SegmentKind,
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point = .{ .x = 0, .y = 0 },

    fn minX(self: Segment) f64 {
        return switch (self.kind) {
            .quad => @min(@min(self.p0.x, self.p1.x), self.p2.x),
            .cubic => @min(@min(self.p0.x, self.p1.x), @min(self.p2.x, self.p3.x)),
        };
    }

    fn maxX(self: Segment) f64 {
        return switch (self.kind) {
            .quad => @max(@max(self.p0.x, self.p1.x), self.p2.x),
            .cubic => @max(@max(self.p0.x, self.p1.x), @max(self.p2.x, self.p3.x)),
        };
    }

    fn minY(self: Segment) f64 {
        return switch (self.kind) {
            .quad => @min(@min(self.p0.y, self.p1.y), self.p2.y),
            .cubic => @min(@min(self.p0.y, self.p1.y), @min(self.p2.y, self.p3.y)),
        };
    }

    fn maxY(self: Segment) f64 {
        return switch (self.kind) {
            .quad => @max(@max(self.p0.y, self.p1.y), self.p2.y),
            .cubic => @max(@max(self.p0.y, self.p1.y), @max(self.p2.y, self.p3.y)),
        };
    }

    fn isHorizontal(self: Segment) bool {
        return switch (self.kind) {
            .quad => self.p0.y == self.p1.y and self.p1.y == self.p2.y,
            .cubic => self.p0.y == self.p1.y and self.p1.y == self.p2.y and self.p2.y == self.p3.y,
        };
    }

    fn isVertical(self: Segment) bool {
        return switch (self.kind) {
            .quad => self.p0.x == self.p1.x and self.p1.x == self.p2.x,
            .cubic => self.p0.x == self.p1.x and self.p1.x == self.p2.x and self.p2.x == self.p3.x,
        };
    }
};

fn lineAsCubic(p0: Point, p1: Point) Cubic {
    return .{
        .p0 = p0,
        .p1 = lerpPoint(p0, p1, 1.0 / 3.0),
        .p2 = lerpPoint(p0, p1, 2.0 / 3.0),
        .p3 = p1,
    };
}

fn quadAsCubic(p0: Point, control: Point, p1: Point) Cubic {
    return .{
        .p0 = p0,
        .p1 = .{
            .x = p0.x + (2.0 / 3.0) * (control.x - p0.x),
            .y = p0.y + (2.0 / 3.0) * (control.y - p0.y),
        },
        .p2 = .{
            .x = p1.x + (2.0 / 3.0) * (control.x - p1.x),
            .y = p1.y + (2.0 / 3.0) * (control.y - p1.y),
        },
        .p3 = p1,
    };
}

const Texel = extern struct {
    r: i16,
    g: i16,
    b: i16,
    a: i16,
};

pub const OutlineBuilder = struct {
    allocator: std.mem.Allocator,
    segments: std.ArrayListUnmanaged(Segment) = .empty,
    current: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    has_open_contour: bool = false,
    failed: bool = false,

    pub fn init(allocator: std.mem.Allocator) OutlineBuilder {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *OutlineBuilder) void {
        self.segments.deinit(self.allocator);
        self.* = undefined;
    }

    pub fn clear(self: *OutlineBuilder) void {
        self.segments.clearRetainingCapacity();
        self.current = .{ .x = 0, .y = 0 };
        self.start = .{ .x = 0, .y = 0 };
        self.has_open_contour = false;
        self.failed = false;
    }

    pub fn moveTo(self: *OutlineBuilder, p: Point) void {
        self.closePath();
        self.current = p;
        self.start = p;
        self.has_open_contour = true;
    }

    pub fn lineTo(self: *OutlineBuilder, p: Point) void {
        if (!self.has_open_contour) self.moveTo(self.current);
        if (samePoint(self.current, p)) return;
        const cubic = lineAsCubic(self.current, p);
        self.appendSplitCubic(cubic.p0, cubic.p1, cubic.p2, cubic.p3);
        self.current = p;
    }

    pub fn quadTo(self: *OutlineBuilder, control: Point, p: Point) void {
        if (!self.has_open_contour) self.moveTo(self.current);
        if (samePoint(self.current, p)) return;
        const cubic = quadAsCubic(self.current, control, p);
        self.appendSplitCubic(cubic.p0, cubic.p1, cubic.p2, cubic.p3);
        self.current = p;
    }

    pub fn cubicTo(self: *OutlineBuilder, c1: Point, c2: Point, p: Point) void {
        if (!self.has_open_contour) self.moveTo(self.current);
        if (samePoint(self.current, p) and samePoint(c1, p) and samePoint(c2, p)) return;
        self.appendSplitCubic(self.current, c1, c2, p);
        self.current = p;
    }

    pub fn closePath(self: *OutlineBuilder) void {
        if (self.has_open_contour and !samePoint(self.current, self.start)) {
            self.lineTo(self.start);
        }
        self.has_open_contour = false;
    }

    fn append(self: *OutlineBuilder, segment: Segment) void {
        self.segments.append(self.allocator, segment) catch {
            self.failed = true;
        };
    }

    fn appendSplitCubic(self: *OutlineBuilder, p0: Point, p1: Point, p2: Point, p3: Point) void {
        var roots: [8]f64 = undefined;
        var root_count: usize = 0;
        appendDerivativeRoots(&roots, &root_count, p0.x, p1.x, p2.x, p3.x);
        appendDerivativeRoots(&roots, &root_count, p0.y, p1.y, p2.y, p3.y);
        appendInflectionRoots(&roots, &root_count, p0, p1, p2, p3);
        std.mem.sort(f64, roots[0..root_count], {}, lessThan);

        var curve = Cubic{ .p0 = p0, .p1 = p1, .p2 = p2, .p3 = p3 };
        var previous_t: f64 = 0.0;
        for (roots[0..root_count]) |t| {
            if (t <= previous_t or t >= 1.0) continue;
            const local_t = (t - previous_t) / (1.0 - previous_t);
            const split = splitCubic(curve, local_t);
            self.appendPreparedCubic(split.left, 0);
            curve = split.right;
            previous_t = t;
        }
        self.appendPreparedCubic(curve, 0);
    }

    fn appendPreparedCubic(self: *OutlineBuilder, curve: Cubic, depth: u8) void {
        if (depth >= max_cubic_prepare_depth or cubicControlPolygonMonotoneAfterQuantize(curve)) {
            self.append(curve.segment());
            return;
        }

        const split = splitCubic(curve, 0.5);
        self.appendPreparedCubic(split.left, depth + 1);
        self.appendPreparedCubic(split.right, depth + 1);
    }
};

const Cubic = struct {
    p0: Point,
    p1: Point,
    p2: Point,
    p3: Point,

    fn segment(self: Cubic) Segment {
        return .{
            .kind = .cubic,
            .p0 = self.p0,
            .p1 = self.p1,
            .p2 = self.p2,
            .p3 = self.p3,
        };
    }

    fn minX(self: Cubic) f64 {
        return @min(@min(self.p0.x, self.p1.x), @min(self.p2.x, self.p3.x));
    }

    fn maxX(self: Cubic) f64 {
        return @max(@max(self.p0.x, self.p1.x), @max(self.p2.x, self.p3.x));
    }

    fn minY(self: Cubic) f64 {
        return @min(@min(self.p0.y, self.p1.y), @min(self.p2.y, self.p3.y));
    }

    fn maxY(self: Cubic) f64 {
        return @max(@max(self.p0.y, self.p1.y), @max(self.p2.y, self.p3.y));
    }
};

fn splitCubic(curve: Cubic, t: f64) struct { left: Cubic, right: Cubic } {
    const p01 = lerpPoint(curve.p0, curve.p1, t);
    const p12 = lerpPoint(curve.p1, curve.p2, t);
    const p23 = lerpPoint(curve.p2, curve.p3, t);
    const p012 = lerpPoint(p01, p12, t);
    const p123 = lerpPoint(p12, p23, t);
    const p0123 = lerpPoint(p012, p123, t);
    return .{
        .left = .{ .p0 = curve.p0, .p1 = p01, .p2 = p012, .p3 = p0123 },
        .right = .{ .p0 = p0123, .p1 = p123, .p2 = p23, .p3 = curve.p3 },
    };
}

fn lerpPoint(a: Point, b: Point, t: f64) Point {
    return .{
        .x = a.x + (b.x - a.x) * t,
        .y = a.y + (b.y - a.y) * t,
    };
}

fn appendDerivativeRoots(roots: *[8]f64, count: *usize, p0: f64, p1: f64, p2: f64, p3: f64) void {
    const a = -p0 + 3.0 * p1 - 3.0 * p2 + p3;
    const b = 2.0 * (p0 - 2.0 * p1 + p2);
    const cc = p1 - p0;
    appendQuadraticRoots01(roots, count, 3.0 * a, 3.0 * b, 3.0 * cc);
}

fn appendInflectionRoots(roots: *[8]f64, count: *usize, p0: Point, p1: Point, p2: Point, p3: Point) void {
    const ax = -p0.x + 3.0 * p1.x - 3.0 * p2.x + p3.x;
    const ay = -p0.y + 3.0 * p1.y - 3.0 * p2.y + p3.y;
    const bx = 3.0 * p0.x - 6.0 * p1.x + 3.0 * p2.x;
    const by = 3.0 * p0.y - 6.0 * p1.y + 3.0 * p2.y;
    const cx = -3.0 * p0.x + 3.0 * p1.x;
    const cy = -3.0 * p0.y + 3.0 * p1.y;

    appendQuadraticRoots01(
        roots,
        count,
        -6.0 * cross(.{ .x = ax, .y = ay }, .{ .x = bx, .y = by }),
        6.0 * cross(.{ .x = cx, .y = cy }, .{ .x = ax, .y = ay }),
        2.0 * cross(.{ .x = cx, .y = cy }, .{ .x = bx, .y = by }),
    );
}

fn appendQuadraticRoots01(roots: *[8]f64, count: *usize, a: f64, b: f64, cc: f64) void {
    const eps = 1.0e-9;
    if (@abs(a) <= eps) {
        if (@abs(b) > eps) appendRoot01(roots, count, -cc / b);
        return;
    }

    const disc = b * b - 4.0 * a * cc;
    if (disc < 0.0) return;
    const d = @sqrt(@max(disc, 0.0));
    appendRoot01(roots, count, (-b - d) / (2.0 * a));
    appendRoot01(roots, count, (-b + d) / (2.0 * a));
}

fn appendRoot01(roots: *[8]f64, count: *usize, t: f64) void {
    if (t <= 1.0e-6 or t >= 1.0 - 1.0e-6) return;
    for (roots[0..count.*]) |existing| {
        if (@abs(existing - t) < 1.0e-5) return;
    }
    if (count.* < roots.len) {
        roots[count.*] = t;
        count.* += 1;
    }
}

fn cross(a: Point, b: Point) f64 {
    return a.x * b.y - a.y * b.x;
}

fn lessThan(_: void, a: f64, b: f64) bool {
    return a < b;
}

fn cubicControlPolygonMonotoneAfterQuantize(curve: Cubic) bool {
    const x = quantizedAxis4(curve.p0.x, curve.p1.x, curve.p2.x, curve.p3.x) orelse return false;
    const y = quantizedAxis4(curve.p0.y, curve.p1.y, curve.p2.y, curve.p3.y) orelse return false;
    return monotone4(x) and monotone4(y);
}

fn quantizedAxis4(a: f64, b: f64, cc: f64, d: f64) ?[4]i32 {
    return .{
        quantizedAxis(a) orelse return null,
        quantizedAxis(b) orelse return null,
        quantizedAxis(cc) orelse return null,
        quantizedAxis(d) orelse return null,
    };
}

fn quantizedAxis(v: f64) ?i32 {
    const q = std.math.round(v * units_per_em);
    if (!std.math.isFinite(q) or q < std.math.minInt(i16) or q > std.math.maxInt(i16)) {
        return null;
    }
    return @intFromFloat(q);
}

fn monotone4(v: [4]i32) bool {
    return (v[0] <= v[1] and v[1] <= v[2] and v[2] <= v[3]) or
        (v[0] >= v[1] and v[1] >= v[2] and v[2] >= v[3]);
}

pub const Encoder = struct {
    allocator: std.mem.Allocator,
    funcs: *c.hb_draw_funcs_t,
    builder: OutlineBuilder,

    pub fn init(allocator: std.mem.Allocator) Error!Encoder {
        const funcs = c.hb_draw_funcs_create() orelse return error.HarfBuzzAllocationFailed;
        errdefer c.hb_draw_funcs_destroy(funcs);

        c.hb_draw_funcs_set_move_to_func(funcs, moveToCallback, null, null);
        c.hb_draw_funcs_set_line_to_func(funcs, lineToCallback, null, null);
        c.hb_draw_funcs_set_quadratic_to_func(funcs, quadToCallback, null, null);
        c.hb_draw_funcs_set_cubic_to_func(funcs, cubicToCallback, null, null);
        c.hb_draw_funcs_set_close_path_func(funcs, closePathCallback, null, null);
        c.hb_draw_funcs_make_immutable(funcs);

        return .{
            .allocator = allocator,
            .funcs = funcs,
            .builder = OutlineBuilder.init(allocator),
        };
    }

    pub fn deinit(self: *Encoder) void {
        self.builder.deinit();
        c.hb_draw_funcs_destroy(self.funcs);
        self.* = undefined;
    }

    pub fn encodeGlyph(self: *Encoder, font: hb.Font, glyph_id: u32) Error!hb.GpuDraw.Encoded {
        self.builder.clear();
        const drawn = c.hb_font_draw_glyph_or_fail(
            font.handle,
            glyph_id,
            self.funcs,
            &self.builder,
        );
        if (self.builder.failed) return error.HarfBuzzDrawFailed;
        self.builder.closePath();

        var extents: hb.GlyphExtents = .{
            .x_bearing = 0,
            .y_bearing = 0,
            .width = 0,
            .height = 0,
        };
        _ = c.hb_font_get_glyph_extents(font.handle, glyph_id, &extents);

        if (drawn == 0 or self.builder.segments.items.len == 0) {
            const empty = c.hb_blob_get_empty() orelse return error.HarfBuzzAllocationFailed;
            return .{ .blob = .{ .handle = empty }, .extents = extents };
        }

        const blob = try encodeSegments(self.allocator, self.builder.segments.items);
        return .{ .blob = blob, .extents = extents };
    }
};

pub fn encodeSegments(
    allocator: std.mem.Allocator,
    segments: []const Segment,
) Error!hb.Blob {
    if (segments.len == 0) {
        const empty = c.hb_blob_get_empty() orelse return error.HarfBuzzAllocationFailed;
        return .{ .handle = empty };
    }

    if (segments.len > std.math.maxInt(i16)) return error.GlyphOffsetOverflow;

    var min_x_f: f64 = std.math.inf(f64);
    var min_y_f: f64 = std.math.inf(f64);
    var max_x_f: f64 = -std.math.inf(f64);
    var max_y_f: f64 = -std.math.inf(f64);

    var curves = try allocator.alloc(Cubic, segments.len);
    defer allocator.free(curves);

    for (segments, 0..) |segment, i| {
        const curve = try quantizedCubic(canonicalCubic(segment));
        curves[i] = curve;
        min_x_f = @min(min_x_f, curve.minX());
        min_y_f = @min(min_y_f, curve.minY());
        max_x_f = @max(max_x_f, curve.maxX());
        max_y_f = @max(max_y_f, curve.maxY());
    }

    const min_x_q = try quantizeDown(min_x_f);
    const min_y_q = try quantizeDown(min_y_f);
    const max_x_q = try quantizeUp(max_x_f);
    const max_y_q = try quantizeUp(max_y_f);

    var hbands = try HBandIndex.init(allocator, curves, min_y_q, max_y_q);
    defer hbands.deinit(allocator);

    const curve_base: u32 = header_len;
    const band_base = try addU32(curve_base, try mulU32(@intCast(curves.len), curve_texel_len));
    const id_base = try addU32(band_base, hbands.band_count);
    const id_texel_count = divCeilU32(hbands.id_count, curve_ids_per_texel);
    const total_len = try addU32(id_base, id_texel_count);

    if (band_base > std.math.maxInt(i16) or id_base > std.math.maxInt(i16)) {
        return error.GlyphOffsetOverflow;
    }

    var texels = try std.ArrayListUnmanaged(Texel).initCapacity(allocator, total_len);
    defer texels.deinit(allocator);
    texels.appendNTimesAssumeCapacity(.{ .r = 0, .g = 0, .b = 0, .a = 0 }, total_len);

    texels.items[0] = .{ .r = min_x_q, .g = min_y_q, .b = max_x_q, .a = max_y_q };
    texels.items[1] = .{
        .r = @intCast(curves.len),
        .g = blob_version,
        .b = fillSignCubics(curves),
        .a = @intCast(curve_base),
    };
    texels.items[2] = .{
        .r = @intCast(hbands.band_min),
        .g = @intCast(hbands.band_count),
        .b = hband_height_q,
        .a = @intCast(band_base),
    };
    texels.items[3] = .{
        .r = @intCast(id_base),
        .g = @intCast(hbands.id_count),
        .b = 0,
        .a = 0,
    };

    var data_texel: u32 = curve_base;
    for (curves) |curve| {
        texels.items[data_texel] = .{
            .r = try quantize(curve.p0.x),
            .g = try quantize(curve.p0.y),
            .b = try quantize(curve.p1.x),
            .a = try quantize(curve.p1.y),
        };
        data_texel += 1;
        texels.items[data_texel] = .{
            .r = try quantize(curve.p2.x),
            .g = try quantize(curve.p2.y),
            .b = try quantize(curve.p3.x),
            .a = try quantize(curve.p3.y),
        };
        data_texel += 1;
        texels.items[data_texel] = .{
            .r = try quantizeDown(curve.minX()),
            .g = try quantizeUp(curve.maxX()),
            .b = try quantizeDown(curve.minY()),
            .a = try quantizeUp(curve.maxY()),
        };
        data_texel += 1;
    }

    std.debug.assert(data_texel == band_base);

    for (0..@intCast(hbands.band_count)) |band_i| {
        const start = hbands.band_starts[band_i];
        const count = hbands.band_counts[band_i];
        if (start > std.math.maxInt(i16) or count > std.math.maxInt(i16)) {
            return error.GlyphOffsetOverflow;
        }
        texels.items[data_texel] = .{
            .r = @intCast(start),
            .g = @intCast(count),
            .b = 0,
            .a = 0,
        };
        data_texel += 1;
    }

    std.debug.assert(data_texel == id_base);

    for (0..@intCast(id_texel_count)) |texel_i| {
        const id_i = texel_i * curve_ids_per_texel;
        texels.items[data_texel] = .{
            .r = idAtOrZero(hbands.ids, id_i),
            .g = idAtOrZero(hbands.ids, id_i + 1),
            .b = idAtOrZero(hbands.ids, id_i + 2),
            .a = idAtOrZero(hbands.ids, id_i + 3),
        };
        data_texel += 1;
    }

    std.debug.assert(data_texel == total_len);

    const bytes = std.mem.sliceAsBytes(texels.items);
    const blob = c.hb_blob_create_or_fail(
        bytes.ptr,
        @intCast(bytes.len),
        c.HB_MEMORY_MODE_DUPLICATE,
        null,
        null,
    ) orelse return error.HarfBuzzAllocationFailed;
    return .{ .handle = blob };
}

const HBandIndex = struct {
    band_min: i32,
    band_count: u32,
    id_count: u32,
    band_starts: []u32,
    band_counts: []u32,
    ids: []i16,

    fn init(
        allocator: std.mem.Allocator,
        curves: []const Cubic,
        min_y_q: i16,
        max_y_q: i16,
    ) Error!HBandIndex {
        const band_min = bandIndex(min_y_q);
        const band_max = bandIndex(max_y_q);
        const band_count_i32 = band_max - band_min + 1;
        if (band_count_i32 <= 0 or band_count_i32 > std.math.maxInt(i16)) {
            return error.GlyphOffsetOverflow;
        }
        const band_count: u32 = @intCast(band_count_i32);

        const band_counts = try allocator.alloc(u32, band_count);
        errdefer allocator.free(band_counts);
        @memset(band_counts, 0);

        for (curves) |curve| {
            const range = try curveBandRange(curve, band_min);
            for (range.lo..range.hi + 1) |band_i| {
                band_counts[band_i] += 1;
            }
        }

        const band_starts = try allocator.alloc(u32, band_count);
        errdefer allocator.free(band_starts);

        var id_count: u32 = 0;
        for (band_counts, 0..) |count, i| {
            band_starts[i] = id_count;
            id_count = try addU32(id_count, count);
        }
        if (id_count > std.math.maxInt(i16)) return error.GlyphOffsetOverflow;

        const ids = try allocator.alloc(i16, id_count);
        errdefer allocator.free(ids);

        const cursors = try allocator.dupe(u32, band_starts);
        defer allocator.free(cursors);

        for (curves, 0..) |curve, curve_i| {
            const range = try curveBandRange(curve, band_min);
            for (range.lo..range.hi + 1) |band_i| {
                const id_i = cursors[band_i];
                ids[id_i] = @intCast(curve_i);
                cursors[band_i] += 1;
            }
        }

        return .{
            .band_min = band_min,
            .band_count = band_count,
            .id_count = id_count,
            .band_starts = band_starts,
            .band_counts = band_counts,
            .ids = ids,
        };
    }

    fn deinit(self: *HBandIndex, allocator: std.mem.Allocator) void {
        allocator.free(self.band_starts);
        allocator.free(self.band_counts);
        allocator.free(self.ids);
        self.* = undefined;
    }
};

fn curveBandRange(curve: Cubic, band_min: i32) Error!struct { lo: usize, hi: usize } {
    const min_y = try quantizeDown(curve.minY());
    const max_y = try quantizeUp(curve.maxY());
    const lo_i32 = bandIndex(min_y) - band_min;
    const hi_i32 = bandIndex(max_y) - band_min;
    if (lo_i32 < 0 or hi_i32 < lo_i32) return error.GlyphOffsetOverflow;
    return .{ .lo = @intCast(lo_i32), .hi = @intCast(hi_i32) };
}

fn bandIndex(y_q: i16) i32 {
    return @divFloor(@as(i32, y_q), @as(i32, hband_height_q));
}

fn divCeilU32(a: u32, b: u32) u32 {
    return (a + b - 1) / b;
}

fn idAtOrZero(ids: []const i16, index: usize) i16 {
    return if (index < ids.len) ids[index] else 0;
}

fn samePoint(a: Point, b: Point) bool {
    return a.x == b.x and a.y == b.y;
}

fn canonicalCubic(segment: Segment) Cubic {
    return switch (segment.kind) {
        .quad => quadAsCubic(segment.p0, segment.p1, segment.p2),
        .cubic => .{ .p0 = segment.p0, .p1 = segment.p1, .p2 = segment.p2, .p3 = segment.p3 },
    };
}

fn quantizedCubic(curve: Cubic) Error!Cubic {
    return .{
        .p0 = try quantizedPoint(curve.p0),
        .p1 = try quantizedPoint(curve.p1),
        .p2 = try quantizedPoint(curve.p2),
        .p3 = try quantizedPoint(curve.p3),
    };
}

fn quantizedPoint(point: Point) Error!Point {
    return .{
        .x = dequantize(try quantize(point.x)),
        .y = dequantize(try quantize(point.y)),
    };
}

fn quantize(v: f64) Error!i16 {
    return quantized(std.math.round(v * units_per_em));
}

fn quantizeDown(v: f64) Error!i16 {
    return quantized(@floor(v * units_per_em));
}

fn quantizeUp(v: f64) Error!i16 {
    return quantized(@ceil(v * units_per_em));
}

fn quantized(v: f64) Error!i16 {
    if (!std.math.isFinite(v) or v < std.math.minInt(i16) or v > std.math.maxInt(i16)) {
        return error.GlyphTooLarge;
    }
    return @intFromFloat(v);
}

fn dequantize(v: i16) f64 {
    return @as(f64, @floatFromInt(v)) / units_per_em;
}

fn fillSignCubics(curves: []const Cubic) i16 {
    const area = signedAreaCubics(curves);
    return if (area < 0) -1 else 1;
}

fn signedAreaCubics(curves: []const Cubic) f64 {
    var area: f64 = 0;
    for (curves) |curve| area += cubicSignedArea(curve);
    return area;
}

fn cubicSignedArea(curve: Cubic) f64 {
    const mid: f64 = 0.5;
    const half: f64 = 0.5;
    const root: f64 = 0.7745966692414834;
    return half * (5.0 / 9.0 * greenIntegrand(curve, mid - half * root) +
        8.0 / 9.0 * greenIntegrand(curve, mid) +
        5.0 / 9.0 * greenIntegrand(curve, mid + half * root));
}

fn greenIntegrand(curve: Cubic, t: f64) f64 {
    const p = cubicPoint(curve, t);
    const d = cubicDerivative(curve, t);
    return 0.5 * (p.x * d.y - p.y * d.x);
}

fn cubicPoint(curve: Cubic, t: f64) Point {
    const a = lerpPoint(curve.p0, curve.p1, t);
    const b = lerpPoint(curve.p1, curve.p2, t);
    const c2 = lerpPoint(curve.p2, curve.p3, t);
    const d = lerpPoint(a, b, t);
    const e = lerpPoint(b, c2, t);
    return lerpPoint(d, e, t);
}

fn cubicDerivative(curve: Cubic, t: f64) Point {
    const u = 1.0 - t;
    return .{
        .x = 3.0 * (u * u * (curve.p1.x - curve.p0.x) +
            2.0 * u * t * (curve.p2.x - curve.p1.x) +
            t * t * (curve.p3.x - curve.p2.x)),
        .y = 3.0 * (u * u * (curve.p1.y - curve.p0.y) +
            2.0 * u * t * (curve.p2.y - curve.p1.y) +
            t * t * (curve.p3.y - curve.p2.y)),
    };
}

fn addU32(a: u32, b: u32) Error!u32 {
    return std.math.add(u32, a, b) catch error.GlyphOffsetOverflow;
}

fn mulU32(a: u32, b: u32) Error!u32 {
    return std.math.mul(u32, a, b) catch error.GlyphOffsetOverflow;
}

fn moveToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    builderFromData(draw_data).moveTo(.{ .x = to_x, .y = to_y });
}

fn lineToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    builderFromData(draw_data).lineTo(.{ .x = to_x, .y = to_y });
}

fn quadToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    control_x: f32,
    control_y: f32,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    builderFromData(draw_data).quadTo(
        .{ .x = control_x, .y = control_y },
        .{ .x = to_x, .y = to_y },
    );
}

fn cubicToCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    control1_x: f32,
    control1_y: f32,
    control2_x: f32,
    control2_y: f32,
    to_x: f32,
    to_y: f32,
    _: ?*anyopaque,
) callconv(.c) void {
    builderFromData(draw_data).cubicTo(
        .{ .x = control1_x, .y = control1_y },
        .{ .x = control2_x, .y = control2_y },
        .{ .x = to_x, .y = to_y },
    );
}

fn closePathCallback(
    _: ?*c.hb_draw_funcs_t,
    draw_data: ?*anyopaque,
    _: [*c]c.hb_draw_state_t,
    _: ?*anyopaque,
) callconv(.c) void {
    builderFromData(draw_data).closePath();
}

fn builderFromData(draw_data: ?*anyopaque) *OutlineBuilder {
    return @ptrCast(@alignCast(draw_data.?));
}

test "OutlineBuilder: records cubic segments for curves and close paths" {
    var builder = OutlineBuilder.init(std.testing.allocator);
    defer builder.deinit();

    builder.moveTo(.{ .x = 0, .y = 0 });
    builder.cubicTo(.{ .x = 1, .y = 2 }, .{ .x = 3, .y = 4 }, .{ .x = 5, .y = 6 });
    builder.closePath();

    try std.testing.expect(!builder.failed);
    try std.testing.expectEqual(@as(usize, 2), builder.segments.items.len);
    try std.testing.expectEqual(SegmentKind.cubic, builder.segments.items[0].kind);
    try std.testing.expectEqual(SegmentKind.cubic, builder.segments.items[1].kind);
}

test "OutlineBuilder: raises quadratic curves to cubic segments" {
    var builder = OutlineBuilder.init(std.testing.allocator);
    defer builder.deinit();

    builder.moveTo(.{ .x = 0, .y = 0 });
    builder.quadTo(.{ .x = 3, .y = 3 }, .{ .x = 9, .y = 6 });

    try std.testing.expect(!builder.failed);
    try std.testing.expectEqual(@as(usize, 1), builder.segments.items.len);
    const segment = builder.segments.items[0];
    try std.testing.expectEqual(SegmentKind.cubic, segment.kind);
    try std.testing.expectApproxEqAbs(@as(f64, 2), segment.p1.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 2), segment.p1.y, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 5), segment.p2.x, 1.0e-9);
    try std.testing.expectApproxEqAbs(@as(f64, 4), segment.p2.y, 1.0e-9);
}

test "OutlineBuilder: prepares cubic segments at axis extrema" {
    var builder = OutlineBuilder.init(std.testing.allocator);
    defer builder.deinit();

    builder.moveTo(.{ .x = 0, .y = 0 });
    builder.cubicTo(.{ .x = 100, .y = 200 }, .{ .x = -100, .y = 200 }, .{ .x = 0, .y = 0 });

    try std.testing.expect(!builder.failed);
    try std.testing.expect(builder.segments.items.len > 1);
    for (builder.segments.items) |segment| {
        if (segment.kind != .cubic) continue;
        try std.testing.expect(!hasInteriorAxisExtremum(segment.p0.x, segment.p1.x, segment.p2.x, segment.p3.x));
        try std.testing.expect(!hasInteriorAxisExtremum(segment.p0.y, segment.p1.y, segment.p2.y, segment.p3.y));
    }
}

test "OutlineBuilder: prepared cubic control polygons stay monotone after quantization" {
    var builder = OutlineBuilder.init(std.testing.allocator);
    defer builder.deinit();

    builder.moveTo(.{ .x = 0, .y = 0 });
    builder.cubicTo(.{ .x = 300, .y = 20 }, .{ .x = -280, .y = 22 }, .{ .x = 40, .y = 44 });

    try std.testing.expect(!builder.failed);
    for (builder.segments.items) |segment| {
        if (segment.kind != .cubic) continue;
        try std.testing.expect(cubicControlPolygonMonotoneAfterQuantize(.{
            .p0 = segment.p0,
            .p1 = segment.p1,
            .p2 = segment.p2,
            .p3 = segment.p3,
        }));
    }
}

test "encodeSegments: writes Coverage V3 cubic curve list" {
    const segments = [_]Segment{
        .{
            .kind = .quad,
            .p0 = .{ .x = 0, .y = 0 },
            .p1 = .{ .x = 0, .y = 1 },
            .p2 = .{ .x = 1, .y = 1 },
        },
        .{
            .kind = .cubic,
            .p0 = .{ .x = 1, .y = 1 },
            .p1 = .{ .x = 2, .y = 2 },
            .p2 = .{ .x = 3, .y = 2 },
            .p3 = .{ .x = 4, .y = 1 },
        },
    };

    const blob = try encodeSegments(std.testing.allocator, &segments);
    defer blob.destroy();

    const texels = std.mem.bytesAsSlice(Texel, blob.getData());
    try std.testing.expectEqual(@as(i16, 2), texels[1].r);
    try std.testing.expectEqual(@as(i16, blob_version), texels[1].g);
    try std.testing.expectEqual(@as(i16, header_len), texels[1].a);
    try std.testing.expect(texels.len > header_len + segments.len * curve_texel_len);

    const first_curve = texels[header_len..][0..curve_texel_len];
    try std.testing.expectEqual(@as(i16, 0), first_curve[0].r);
    try std.testing.expectEqual(@as(i16, 0), first_curve[0].g);
    try std.testing.expectEqual(@as(i16, 0), first_curve[0].b);
    try std.testing.expectEqual(@as(i16, 3), first_curve[0].a);
    try std.testing.expectEqual(@as(i16, 1), first_curve[1].r);
    try std.testing.expectEqual(@as(i16, 4), first_curve[1].g);
}

test "encodeSegments: writes h-band candidate index after curves" {
    const segments = [_]Segment{
        lineSegment(.{ .x = 0, .y = 0 }, .{ .x = 1, .y = 1 }),
        lineSegment(.{ .x = 1, .y = 1 }, .{ .x = 2, .y = 2 }),
    };

    const blob = try encodeSegments(std.testing.allocator, &segments);
    defer blob.destroy();

    const texels = std.mem.bytesAsSlice(Texel, blob.getData());
    const curve_base: usize = @intCast(texels[1].a);
    const band_min = texels[2].r;
    const band_count: usize = @intCast(texels[2].g);
    const band_height = texels[2].b;
    const band_base: usize = @intCast(texels[2].a);
    const id_base: usize = @intCast(texels[3].r);
    const id_count = texels[3].g;

    try std.testing.expectEqual(@as(usize, header_len), curve_base);
    try std.testing.expectEqual(@as(i16, 0), band_min);
    try std.testing.expectEqual(@as(usize, 1), band_count);
    try std.testing.expectEqual(@as(i16, hband_height_q), band_height);
    try std.testing.expectEqual(curve_base + segments.len * curve_texel_len, band_base);
    try std.testing.expectEqual(@as(i16, 2), id_count);

    const band = texels[band_base];
    try std.testing.expectEqual(@as(i16, 0), band.r);
    try std.testing.expectEqual(@as(i16, 2), band.g);

    const ids = texels[id_base];
    try std.testing.expectEqual(@as(i16, 0), ids.r);
    try std.testing.expectEqual(@as(i16, 1), ids.g);
}

test "encodeSegments: stores glyph fill direction in header" {
    const ccw = [_]Segment{
        lineSegment(.{ .x = 0, .y = 0 }, .{ .x = 2, .y = 0 }),
        lineSegment(.{ .x = 2, .y = 0 }, .{ .x = 2, .y = 2 }),
        lineSegment(.{ .x = 2, .y = 2 }, .{ .x = 0, .y = 2 }),
        lineSegment(.{ .x = 0, .y = 2 }, .{ .x = 0, .y = 0 }),
    };
    const cw = [_]Segment{
        lineSegment(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 2 }),
        lineSegment(.{ .x = 0, .y = 2 }, .{ .x = 2, .y = 2 }),
        lineSegment(.{ .x = 2, .y = 2 }, .{ .x = 2, .y = 0 }),
        lineSegment(.{ .x = 2, .y = 0 }, .{ .x = 0, .y = 0 }),
    };

    const ccw_blob = try encodeSegments(std.testing.allocator, &ccw);
    defer ccw_blob.destroy();
    const cw_blob = try encodeSegments(std.testing.allocator, &cw);
    defer cw_blob.destroy();

    const ccw_texels = std.mem.bytesAsSlice(Texel, ccw_blob.getData());
    const cw_texels = std.mem.bytesAsSlice(Texel, cw_blob.getData());
    try std.testing.expectEqual(@as(i16, 1), ccw_texels[1].b);
    try std.testing.expectEqual(@as(i16, -1), cw_texels[1].b);
}

test "encodeSegments: stores decoded-geometry bounds per curve" {
    const segments = [_]Segment{
        lineSegment(.{ .x = 0, .y = 0 }, .{ .x = 0, .y = 8 }),
    };

    const blob = try encodeSegments(std.testing.allocator, &segments);
    defer blob.destroy();

    const texels = std.mem.bytesAsSlice(Texel, blob.getData());
    const bbox = texels[header_len + 2];
    try std.testing.expectEqual(@as(i16, 0), bbox.r);
    try std.testing.expectEqual(@as(i16, 0), bbox.g);
    try std.testing.expectEqual(@as(i16, 0), bbox.b);
    try std.testing.expectEqual(@as(i16, 32), bbox.a);
}

test "coverage math: bracketed solver preserves exact linear roots" {
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), solveMonotoneCubicAtForTest(0, 1.0 / 3.0, 2.0 / 3.0, 1, 0.25), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), solveMonotoneCubicAtForTest(0, 1.0 / 3.0, 2.0 / 3.0, 1, 0.5), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.75), solveMonotoneCubicAtForTest(0, 1.0 / 3.0, 2.0 / 3.0, 1, 0.75), 1.0e-12);
    try std.testing.expectApproxEqAbs(@as(f64, 0.25), solveMonotoneCubicAtForTest(1, 2.0 / 3.0, 1.0 / 3.0, 0, 0.75), 1.0e-12);
}

test "coverage math: high zoom far-right edges are not dropped by parameter epsilon" {
    const y0: f64 = -10_000_000.0;
    const y3: f64 = 10_000_000.0;
    const ta = solveMonotoneCubicAtForTest(y0, y0 / 3.0, y3 / 3.0, y3, -0.5);
    const tb = solveMonotoneCubicAtForTest(y0, y0 / 3.0, y3 / 3.0, y3, 0.5);

    try std.testing.expect(tb - ta < 1.0e-6);
    try std.testing.expect(tb - ta > paramEpsilonForTest());
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), farRightContributionForTest(ta, tb, 1.0), 1.0e-12);
}

fn lineSegment(a: Point, b: Point) Segment {
    const cubic = lineAsCubic(a, b);
    return .{
        .kind = .cubic,
        .p0 = cubic.p0,
        .p1 = cubic.p1,
        .p2 = cubic.p2,
        .p3 = cubic.p3,
    };
}

fn hasInteriorAxisExtremum(p0: f64, p1: f64, p2: f64, p3: f64) bool {
    var roots: [8]f64 = undefined;
    var count: usize = 0;
    appendDerivativeRoots(&roots, &count, p0, p1, p2, p3);
    return count > 0;
}

fn solveMonotoneCubicAtForTest(p0: f64, p1: f64, p2: f64, p3: f64, value: f64) f64 {
    const eps = 1.0 / 1048576.0;
    const f0 = p0 - value;
    const f1 = p3 - value;
    if (@abs(f0) <= eps) return 0.0;
    if (@abs(f1) <= eps) return 1.0;

    var lo: f64 = 0.0;
    var hi: f64 = 1.0;
    var flo = f0;
    const denom = p3 - p0;
    var t = if (@abs(denom) > eps) std.math.clamp((value - p0) / denom, 0.0, 1.0) else 0.5;

    for (0..12) |_| {
        const f = cubicAtForTest(p0, p1, p2, p3, t) - value;
        if (@abs(f) <= eps) return std.math.clamp(t, 0.0, 1.0);

        const df = cubicDerivativeForTest(p0, p1, p2, p3, t);
        const same_side = (f <= 0.0 and flo <= 0.0) or (f >= 0.0 and flo >= 0.0);
        if (same_side) {
            lo = t;
            flo = f;
        } else {
            hi = t;
        }

        const newton = t - f / df;
        const use_bisect = @abs(df) < eps or newton <= lo or newton >= hi or !std.math.isFinite(newton);
        t = if (use_bisect) (lo + hi) * 0.5 else newton;
    }

    return std.math.clamp(t, 0.0, 1.0);
}

fn paramEpsilonForTest() f64 {
    return 1.0e-8;
}

fn farRightContributionForTest(ta: f64, tb: f64, x_mid: f64) f64 {
    const signed_clip_height: f64 = 1.0;
    if (tb <= ta + paramEpsilonForTest()) {
        if (x_mid >= 0.5) return signed_clip_height;
        if (x_mid <= -0.5) return 0.0;
        return std.math.clamp(x_mid + 0.5, 0.0, 1.0) * signed_clip_height;
    }
    return signed_clip_height;
}

fn cubicAtForTest(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const u = 1.0 - t;
    return ((p0 * u + p1 * t) * u + (p1 * u + p2 * t) * t) * u +
        ((p1 * u + p2 * t) * u + (p2 * u + p3 * t) * t) * t;
}

fn cubicDerivativeForTest(p0: f64, p1: f64, p2: f64, p3: f64, t: f64) f64 {
    const u = 1.0 - t;
    return 3.0 * (u * u * (p1 - p0) +
        2.0 * u * t * (p2 - p1) +
        t * t * (p3 - p2));
}
