/// tools/layout_gen.zig
///
/// Reads a slangc -reflection-json output, extracts GlyphCommand and
/// PushConstants struct definitions, and emits a Zig source file with
/// `extern struct` types for direct use on the CPU side.
///
/// Convention: Slang fields with names starting with `_` (e.g. `_pad`)
/// get zero default values in the generated Zig struct, so callers don't
/// need to set padding fields explicitly.
///
/// Usage:
///   zig run tools/layout_gen.zig -- <reflection.json>
///   zig test tools/layout_gen.zig
const std = @import("std");

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

const ScalarType = enum {
    float32,
    uint32,
    int32,

    fn zigName(self: ScalarType) []const u8 {
        return switch (self) {
            .float32 => "f32",
            .uint32 => "u32",
            .int32 => "i32",
        };
    }
};

const FieldType = union(enum) {
    scalar: ScalarType,
    vector: struct { count: u32, element: ScalarType },
    matrix: struct { rows: u32, cols: u32, element: ScalarType },
};

const FieldLayout = struct {
    name: []const u8,
    offset: u32,
    size: u32,
    field_type: FieldType,
};

const StructLayout = struct {
    name: []const u8,
    size: u32,
    fields: []const FieldLayout,
};

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

fn freeStructContents(allocator: std.mem.Allocator, s: *const StructLayout) void {
    allocator.free(s.name);
    for (s.fields) |f| allocator.free(f.name);
    allocator.free(s.fields);
}

fn freeStructs(allocator: std.mem.Allocator, structs: []StructLayout) void {
    for (structs) |*s| freeStructContents(allocator, s);
    allocator.free(structs);
}

// ---------------------------------------------------------------------------
// Type parsing
// ---------------------------------------------------------------------------

fn parseScalarType(str: []const u8) !ScalarType {
    if (std.mem.eql(u8, str, "float32")) return .float32;
    if (std.mem.eql(u8, str, "uint32")) return .uint32;
    if (std.mem.eql(u8, str, "int32")) return .int32;
    return error.UnsupportedScalarType;
}

fn getJsonString(obj: std.json.ObjectMap, key: []const u8) ![]const u8 {
    const val = obj.get(key) orelse return error.MissingKey;
    return switch (val) {
        .string => |s| s,
        else => error.NotString,
    };
}

fn getJsonInt(obj: std.json.ObjectMap, key: []const u8) !u32 {
    const val = obj.get(key) orelse return error.MissingKey;
    return switch (val) {
        .integer => |i| @intCast(i),
        else => error.NotInteger,
    };
}

fn getJsonObject(obj: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const val = obj.get(key) orelse return error.MissingKey;
    return switch (val) {
        .object => |o| o,
        else => error.NotObject,
    };
}

fn parseFieldType(type_obj: std.json.ObjectMap) !FieldType {
    const kind = try getJsonString(type_obj, "kind");

    if (std.mem.eql(u8, kind, "scalar")) {
        const scalar_type = try getJsonString(type_obj, "scalarType");
        return .{ .scalar = try parseScalarType(scalar_type) };
    }

    if (std.mem.eql(u8, kind, "vector")) {
        const count = try getJsonInt(type_obj, "elementCount");
        const elem_type_obj = try getJsonObject(type_obj, "elementType");
        const scalar_type = try getJsonString(elem_type_obj, "scalarType");
        return .{ .vector = .{
            .count = count,
            .element = try parseScalarType(scalar_type),
        } };
    }

    if (std.mem.eql(u8, kind, "matrix")) {
        const rows = try getJsonInt(type_obj, "rowCount");
        const cols = try getJsonInt(type_obj, "columnCount");
        const elem_type_obj = try getJsonObject(type_obj, "elementType");
        const scalar_type = try getJsonString(elem_type_obj, "scalarType");
        return .{ .matrix = .{
            .rows = rows,
            .cols = cols,
            .element = try parseScalarType(scalar_type),
        } };
    }

    return error.UnsupportedTypeKind;
}

// ---------------------------------------------------------------------------
// Struct extraction
// ---------------------------------------------------------------------------

fn extractStruct(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    size_override: ?u32,
) !StructLayout {
    const name_str = try getJsonString(obj, "name");

    const fields_val = obj.get("fields") orelse return error.MissingFields;
    const fields_arr = switch (fields_val) {
        .array => |a| a,
        else => return error.FieldsNotArray,
    };

    var field_list: std.ArrayList(FieldLayout) = .empty;
    errdefer {
        for (field_list.items) |f| allocator.free(f.name);
        field_list.deinit(allocator);
    }

    var computed_size: u32 = 0;

    for (fields_arr.items) |field_val| {
        const field_obj = switch (field_val) {
            .object => |o| o,
            else => return error.FieldNotObject,
        };

        const fname_str = try getJsonString(field_obj, "name");
        const fbinding_obj = try getJsonObject(field_obj, "binding");
        const offset = try getJsonInt(fbinding_obj, "offset");
        const size = try getJsonInt(fbinding_obj, "size");

        const ftype_obj = try getJsonObject(field_obj, "type");
        const field_type = try parseFieldType(ftype_obj);

        const end = offset + size;
        if (end > computed_size) computed_size = end;

        const name_owned = try allocator.dupe(u8, fname_str);
        errdefer allocator.free(name_owned);

        try field_list.append(allocator, .{
            .name = name_owned,
            .offset = offset,
            .size = size,
            .field_type = field_type,
        });
    }

    // Sort by offset for correct padding detection
    std.mem.sort(FieldLayout, field_list.items, {}, struct {
        fn f(_: void, a: FieldLayout, b: FieldLayout) bool {
            return a.offset < b.offset;
        }
    }.f);

    const total_size = size_override orelse computed_size;
    const name_owned = try allocator.dupe(u8, name_str);
    errdefer allocator.free(name_owned);

    return .{
        .name = name_owned,
        .size = total_size,
        .fields = try field_list.toOwnedSlice(allocator),
    };
}

/// Parse a slangc reflection JSON blob and return owned StructLayout slices.
/// Caller frees via freeStructs().
fn parseReflection(allocator: std.mem.Allocator, json_bytes: []const u8) ![]StructLayout {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root_obj = switch (parsed.value) {
        .object => |o| o,
        else => return error.RootNotObject,
    };

    const params_val = root_obj.get("parameters") orelse return error.MissingParameters;
    const params_arr = switch (params_val) {
        .array => |a| a,
        else => return error.ParametersNotArray,
    };

    var result: std.ArrayList(StructLayout) = .empty;
    errdefer {
        for (result.items) |*s| freeStructContents(allocator, s);
        result.deinit(allocator);
    }

    for (params_arr.items) |param_val| {
        const param_obj = switch (param_val) {
            .object => |o| o,
            else => continue,
        };

        const type_obj = getJsonObject(param_obj, "type") catch continue;
        const kind_str = getJsonString(type_obj, "kind") catch continue;

        if (std.mem.eql(u8, kind_str, "resource")) {
            // GlyphCommand from StructuredBuffer<GlyphCommand>
            const base_shape = getJsonString(type_obj, "baseShape") catch continue;
            if (!std.mem.eql(u8, base_shape, "structuredBuffer")) continue;

            const result_type_obj = getJsonObject(type_obj, "resultType") catch continue;
            const inner_kind = getJsonString(result_type_obj, "kind") catch continue;
            if (!std.mem.eql(u8, inner_kind, "struct")) continue;

            const s = try extractStruct(allocator, result_type_obj, null);
            errdefer freeStructContents(allocator, &s);
            try result.append(allocator, s);
        } else if (std.mem.eql(u8, kind_str, "constantBuffer")) {
            // PushConstants from push constant buffer
            const elem_layout_obj = getJsonObject(type_obj, "elementVarLayout") catch continue;
            const inner_type_obj = getJsonObject(elem_layout_obj, "type") catch continue;
            const inner_kind = getJsonString(inner_type_obj, "kind") catch continue;
            if (!std.mem.eql(u8, inner_kind, "struct")) continue;

            // Total size from elementVarLayout.binding.size
            const elem_binding_obj = getJsonObject(elem_layout_obj, "binding") catch continue;
            const size_override: ?u32 = getJsonInt(elem_binding_obj, "size") catch null;

            const s = try extractStruct(allocator, inner_type_obj, size_override);
            errdefer freeStructContents(allocator, &s);
            try result.append(allocator, s);
        }
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Code generation
// ---------------------------------------------------------------------------

fn writeZigType(writer: *std.Io.Writer, ft: FieldType) !void {
    switch (ft) {
        .scalar => |s| try writer.writeAll(s.zigName()),
        .vector => |v| try writer.print("[{d}]{s}", .{ v.count, v.element.zigName() }),
        .matrix => |m| try writer.print("[{d}][{d}]{s}", .{ m.cols, m.rows, m.element.zigName() }),
    }
}

fn writeDefault(writer: *std.Io.Writer, ft: FieldType) !void {
    switch (ft) {
        .scalar => try writer.writeAll(" = 0"),
        .vector => |v| try writer.print(" = .{{0}} ** {d}", .{v.count}),
        .matrix => |m| try writer.print(" = .{{.{{0}} ** {d}}} ** {d}", .{ m.rows, m.cols }),
    }
}

fn emitZig(writer: *std.Io.Writer, structs: []const StructLayout) !void {
    try writer.writeAll(
        \\// AUTO-GENERATED by tools/layout_gen.zig — DO NOT EDIT.
        \\// Source: slangc -reflection-json output.
        \\
    );

    for (structs) |s| {
        try writer.print("\npub const {s} = extern struct {{\n", .{s.name});

        var cursor: u32 = 0;
        var pad_index: u32 = 0;

        for (s.fields) |f| {
            // Insert gap padding if needed
            if (f.offset > cursor) {
                const gap = f.offset - cursor;
                try writer.print("    _gap{d}: [{d}]u8 = .{{0}} ** {d},\n", .{ pad_index, gap, gap });
                pad_index += 1;
            }

            // Field declaration
            try writer.print("    {s}: ", .{f.name});
            try writeZigType(writer, f.field_type);

            // Fields starting with '_' get zero defaults
            if (f.name.len > 0 and f.name[0] == '_') {
                try writeDefault(writer, f.field_type);
            }

            try writer.writeAll(",\n");
            cursor = f.offset + f.size;
        }

        // Tail padding if struct size exceeds last field end
        if (s.size > cursor) {
            const gap = s.size - cursor;
            try writer.print("    _tail{d}: [{d}]u8 = .{{0}} ** {d},\n", .{ pad_index, gap, gap });
        }

        try writer.writeAll("};\n");
    }
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    if (args.len < 2) {
        var stderr_buf: [256]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_writer.interface.writeAll("Usage: layout_gen <reflection.json>\n");
        try stderr_writer.interface.flush();
        std.process.exit(1);
    }

    const json_path = args[1];
    const json_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        json_path,
        allocator,
        .limited(16 * 1024 * 1024),
    ) catch |err| {
        var stderr_buf: [512]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buf);
        try stderr_writer.interface.print("error: cannot read '{s}': {}\n", .{ json_path, err });
        try stderr_writer.interface.flush();
        std.process.exit(1);
    };
    defer allocator.free(json_bytes);

    const structs = try parseReflection(allocator, json_bytes);
    defer freeStructs(allocator, structs);

    var stdout_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buf);
    try emitZig(&stdout_writer.interface, structs);
    try stdout_writer.interface.flush();
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

test "parseReflection extracts GlyphCommand with field types" {
    const json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "commands",
        \\      "binding": {"kind": "descriptorTableSlot", "index": 1},
        \\      "type": {
        \\        "kind": "resource",
        \\        "baseShape": "structuredBuffer",
        \\        "resultType": {
        \\          "kind": "struct",
        \\          "name": "GlyphCommand",
        \\          "fields": [
        \\            {
        \\              "name": "motor",
        \\              "type": {"kind": "vector", "elementCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
        \\              "binding": {"kind": "uniform", "offset": 0, "size": 16, "elementStride": 4}
        \\            },
        \\            {
        \\              "name": "flags",
        \\              "type": {"kind": "scalar", "scalarType": "uint32"},
        \\              "binding": {"kind": "uniform", "offset": 52, "size": 4, "elementStride": 0}
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    const structs = try parseReflection(std.testing.allocator, json);
    defer freeStructs(std.testing.allocator, structs);

    try std.testing.expectEqual(@as(usize, 1), structs.len);
    try std.testing.expectEqualStrings("GlyphCommand", structs[0].name);
    try std.testing.expectEqual(@as(u32, 56), structs[0].size);
    try std.testing.expectEqual(@as(usize, 2), structs[0].fields.len);

    // motor: [4]f32
    try std.testing.expectEqualStrings("motor", structs[0].fields[0].name);
    try std.testing.expectEqual(@as(u32, 0), structs[0].fields[0].offset);
    try std.testing.expectEqual(@as(u32, 16), structs[0].fields[0].size);
    try std.testing.expectEqual(FieldType{ .vector = .{ .count = 4, .element = .float32 } }, structs[0].fields[0].field_type);

    // flags: u32
    try std.testing.expectEqualStrings("flags", structs[0].fields[1].name);
    try std.testing.expectEqual(@as(u32, 52), structs[0].fields[1].offset);
    try std.testing.expectEqual(FieldType{ .scalar = .uint32 }, structs[0].fields[1].field_type);
}

test "parseReflection extracts PushConstants with matrix type" {
    const json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "pc",
        \\      "binding": {"kind": "pushConstantBuffer", "index": 0},
        \\      "type": {
        \\        "kind": "constantBuffer",
        \\        "elementVarLayout": {
        \\          "type": {
        \\            "kind": "struct",
        \\            "name": "PushConstants",
        \\            "fields": [
        \\              {
        \\                "name": "proj",
        \\                "type": {"kind": "matrix", "rowCount": 4, "columnCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
        \\                "binding": {"kind": "uniform", "offset": 0, "size": 64, "elementStride": 0}
        \\              },
        \\              {
        \\                "name": "glyph_count",
        \\                "type": {"kind": "scalar", "scalarType": "uint32"},
        \\                "binding": {"kind": "uniform", "offset": 72, "size": 4, "elementStride": 0}
        \\              }
        \\            ]
        \\          },
        \\          "binding": {"kind": "uniform", "offset": 0, "size": 80, "elementStride": 0}
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    const structs = try parseReflection(std.testing.allocator, json);
    defer freeStructs(std.testing.allocator, structs);

    try std.testing.expectEqual(@as(usize, 1), structs.len);
    try std.testing.expectEqualStrings("PushConstants", structs[0].name);
    try std.testing.expectEqual(@as(u32, 80), structs[0].size);

    // proj: [4][4]f32
    try std.testing.expectEqual(FieldType{ .matrix = .{ .rows = 4, .cols = 4, .element = .float32 } }, structs[0].fields[0].field_type);
}

test "parseReflection extracts both structs" {
    const json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "commands",
        \\      "binding": {"kind": "descriptorTableSlot", "index": 1},
        \\      "type": {
        \\        "kind": "resource",
        \\        "baseShape": "structuredBuffer",
        \\        "resultType": {
        \\          "kind": "struct",
        \\          "name": "GlyphCommand",
        \\          "fields": [
        \\            {
        \\              "name": "motor",
        \\              "type": {"kind": "vector", "elementCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
        \\              "binding": {"kind": "uniform", "offset": 0, "size": 16, "elementStride": 4}
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    },
        \\    {
        \\      "name": "pc",
        \\      "binding": {"kind": "pushConstantBuffer", "index": 0},
        \\      "type": {
        \\        "kind": "constantBuffer",
        \\        "elementVarLayout": {
        \\          "type": {
        \\            "kind": "struct",
        \\            "name": "PushConstants",
        \\            "fields": [
        \\              {
        \\                "name": "proj",
        \\                "type": {"kind": "matrix", "rowCount": 4, "columnCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
        \\                "binding": {"kind": "uniform", "offset": 0, "size": 64, "elementStride": 0}
        \\              }
        \\            ]
        \\          },
        \\          "binding": {"kind": "uniform", "offset": 0, "size": 80, "elementStride": 0}
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    const structs = try parseReflection(std.testing.allocator, json);
    defer freeStructs(std.testing.allocator, structs);

    try std.testing.expectEqual(@as(usize, 2), structs.len);
    try std.testing.expectEqualStrings("GlyphCommand", structs[0].name);
    try std.testing.expectEqualStrings("PushConstants", structs[1].name);
}

test "emitZig produces extern struct definitions" {
    const fields_gc = [_]FieldLayout{
        .{ .name = "motor", .offset = 0, .size = 16, .field_type = .{ .vector = .{ .count = 4, .element = .float32 } } },
        .{ .name = "flags", .offset = 52, .size = 4, .field_type = .{ .scalar = .uint32 } },
        .{ .name = "_pad", .offset = 56, .size = 8, .field_type = .{ .vector = .{ .count = 2, .element = .uint32 } } },
    };
    const fields_pc = [_]FieldLayout{
        .{ .name = "proj", .offset = 0, .size = 64, .field_type = .{ .matrix = .{ .rows = 4, .cols = 4, .element = .float32 } } },
        .{ .name = "glyph_count", .offset = 72, .size = 4, .field_type = .{ .scalar = .uint32 } },
    };
    const structs = [_]StructLayout{
        .{ .name = "GlyphCommand", .size = 64, .fields = &fields_gc },
        .{ .name = "PushConstants", .size = 80, .fields = &fields_pc },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitZig(&aw.writer, &structs);
    const output = try aw.toOwnedSlice();
    defer std.testing.allocator.free(output);

    // Header
    try std.testing.expect(std.mem.indexOf(u8, output, "AUTO-GENERATED") != null);

    // GlyphCommand extern struct
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const GlyphCommand = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "motor: [4]f32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "flags: u32,") != null);
    // _pad gets a zero default
    try std.testing.expect(std.mem.indexOf(u8, output, "_pad: [2]u32 = .{0} ** 2,") != null);

    // PushConstants extern struct
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const PushConstants = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "proj: [4][4]f32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "glyph_count: u32,") != null);
}

test "emitZig: non-square matrix emits [cols][rows] (column-major)" {
    const fields = [_]FieldLayout{
        .{ .name = "m", .offset = 0, .size = 48, .field_type = .{ .matrix = .{ .rows = 3, .cols = 4, .element = .float32 } } },
    };
    const structs = [_]StructLayout{
        .{ .name = "Test", .size = 48, .fields = &fields },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitZig(&aw.writer, &structs);
    const output = try aw.toOwnedSlice();
    defer std.testing.allocator.free(output);

    // Column-major: [cols][rows], so float3x4 → [4][3]f32
    try std.testing.expect(std.mem.indexOf(u8, output, "m: [4][3]f32,") != null);
}

test "emitZig inserts gap padding" {
    // Field at offset 0 size 4, next at offset 8 size 4 → 4-byte gap
    const fields = [_]FieldLayout{
        .{ .name = "a", .offset = 0, .size = 4, .field_type = .{ .scalar = .uint32 } },
        .{ .name = "b", .offset = 8, .size = 4, .field_type = .{ .scalar = .uint32 } },
    };
    const structs = [_]StructLayout{
        .{ .name = "Test", .size = 16, .fields = &fields },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitZig(&aw.writer, &structs);
    const output = try aw.toOwnedSlice();
    defer std.testing.allocator.free(output);

    // Gap padding between a (end=4) and b (offset=8)
    try std.testing.expect(std.mem.indexOf(u8, output, "_gap0: [4]u8 = .{0} ** 4,") != null);
    // Tail padding after b (end=12) to struct size 16
    try std.testing.expect(std.mem.indexOf(u8, output, "_tail") != null);
}

test "parseReflection: empty parameters produces empty slice" {
    const json =
        \\{
        \\  "parameters": [],
        \\  "entryPoints": []
        \\}
    ;

    const structs = try parseReflection(std.testing.allocator, json);
    defer freeStructs(std.testing.allocator, structs);

    try std.testing.expectEqual(@as(usize, 0), structs.len);
}

test "freeStructs handles empty slice" {
    const empty = try std.testing.allocator.alloc(StructLayout, 0);
    freeStructs(std.testing.allocator, empty);
}
