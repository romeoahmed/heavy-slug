/// tools/layout_gen.zig
///
/// Reads a slangc -reflection-json output, extracts GlyphCommand and
/// PushConstants struct field offsets/sizes, and emits a Zig source file
/// with pub constants for CPU/GPU layout validation.
///
/// Usage:
///   zig run tools/layout_gen.zig -- <reflection.json>
///   zig test tools/layout_gen.zig
const std = @import("std");

// ---------------------------------------------------------------------------
// Data types
// ---------------------------------------------------------------------------

pub const FieldLayout = struct {
    name: []const u8,
    offset: u32,
    size: u32,
};

pub const StructLayout = struct {
    name: []const u8,
    size: u32,
    fields: []const FieldLayout,
};

// ---------------------------------------------------------------------------
// Memory management
// ---------------------------------------------------------------------------

/// Free all memory owned by a []StructLayout returned from parseReflection.
pub fn freeStructs(allocator: std.mem.Allocator, structs: []StructLayout) void {
    for (structs) |*s| {
        allocator.free(s.name);
        for (s.fields) |f| {
            allocator.free(f.name);
        }
        allocator.free(s.fields);
    }
    allocator.free(structs);
}

// ---------------------------------------------------------------------------
// Parsing
// ---------------------------------------------------------------------------

/// Extract a StructLayout from a JSON struct-kind object.
/// `obj` must be a .object with "name" and "fields" keys.
/// `size_override` provides the total struct size when known externally
/// (e.g. from elementVarLayout.binding.size for push-constant buffers).
fn extractStruct(
    allocator: std.mem.Allocator,
    obj: std.json.ObjectMap,
    size_override: ?u32,
) !StructLayout {
    const name_val = obj.get("name") orelse return error.MissingName;
    const name_str = switch (name_val) {
        .string => |s| s,
        else => return error.NameNotString,
    };

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

        const fname_val = field_obj.get("name") orelse return error.FieldMissingName;
        const fname_str = switch (fname_val) {
            .string => |s| s,
            else => return error.FieldNameNotString,
        };

        // binding: { "kind": "uniform", "offset": N, "size": N, ... }
        const fbinding_val = field_obj.get("binding") orelse return error.FieldMissingBinding;
        const fbinding_obj = switch (fbinding_val) {
            .object => |o| o,
            else => return error.FieldBindingNotObject,
        };

        const offset = blk: {
            const v = fbinding_obj.get("offset") orelse return error.FieldMissingOffset;
            break :blk switch (v) {
                .integer => |i| @as(u32, @intCast(i)),
                else => return error.FieldOffsetNotInteger,
            };
        };
        const size = blk: {
            const v = fbinding_obj.get("size") orelse return error.FieldMissingSize;
            break :blk switch (v) {
                .integer => |i| @as(u32, @intCast(i)),
                else => return error.FieldSizeNotInteger,
            };
        };

        const end = offset + size;
        if (end > computed_size) computed_size = end;

        const name_owned = try allocator.dupe(u8, fname_str);
        errdefer allocator.free(name_owned);

        try field_list.append(allocator, .{
            .name = name_owned,
            .offset = offset,
            .size = size,
        });
    }

    const total_size = size_override orelse computed_size;
    const name_owned = try allocator.dupe(u8, name_str);
    errdefer allocator.free(name_owned);

    return .{
        .name = name_owned,
        .size = total_size,
        .fields = try field_list.toOwnedSlice(allocator),
    };
}

/// Parse a slangc reflection JSON blob and return owned StructLayout slices
/// for GlyphCommand and PushConstants. Caller frees via freeStructs().
pub fn parseReflection(allocator: std.mem.Allocator, json_bytes: []const u8) ![]StructLayout {
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
        for (result.items) |*s| {
            allocator.free(s.name);
            for (s.fields) |f| allocator.free(f.name);
            allocator.free(s.fields);
        }
        result.deinit(allocator);
    }

    for (params_arr.items) |param_val| {
        const param_obj = switch (param_val) {
            .object => |o| o,
            else => continue,
        };

        const type_val = param_obj.get("type") orelse continue;
        const type_obj = switch (type_val) {
            .object => |o| o,
            else => continue,
        };

        const kind_val = type_obj.get("kind") orelse continue;
        const kind_str = switch (kind_val) {
            .string => |s| s,
            else => continue,
        };

        if (std.mem.eql(u8, kind_str, "resource")) {
            // GlyphCommand from StructuredBuffer<GlyphCommand>
            const base_shape_val = type_obj.get("baseShape") orelse continue;
            const base_shape = switch (base_shape_val) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, base_shape, "structuredBuffer")) continue;

            const result_type_val = type_obj.get("resultType") orelse continue;
            const result_type_obj = switch (result_type_val) {
                .object => |o| o,
                else => continue,
            };

            const inner_kind_val = result_type_obj.get("kind") orelse continue;
            const inner_kind = switch (inner_kind_val) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, inner_kind, "struct")) continue;

            const s = try extractStruct(allocator, result_type_obj, null);
            errdefer {
                allocator.free(s.name);
                for (s.fields) |f| allocator.free(f.name);
                allocator.free(s.fields);
            }
            try result.append(allocator, s);
        } else if (std.mem.eql(u8, kind_str, "constantBuffer")) {
            // PushConstants from push constant buffer
            const elem_layout_val = type_obj.get("elementVarLayout") orelse continue;
            const elem_layout_obj = switch (elem_layout_val) {
                .object => |o| o,
                else => continue,
            };

            const inner_type_val = elem_layout_obj.get("type") orelse continue;
            const inner_type_obj = switch (inner_type_val) {
                .object => |o| o,
                else => continue,
            };

            const inner_kind_val = inner_type_obj.get("kind") orelse continue;
            const inner_kind = switch (inner_kind_val) {
                .string => |s| s,
                else => continue,
            };
            if (!std.mem.eql(u8, inner_kind, "struct")) continue;

            // Total size comes from elementVarLayout.binding.size
            const elem_binding_val = elem_layout_obj.get("binding") orelse continue;
            const elem_binding_obj = switch (elem_binding_val) {
                .object => |o| o,
                else => continue,
            };
            const size_override: ?u32 = blk: {
                const sv = elem_binding_obj.get("size") orelse break :blk null;
                break :blk switch (sv) {
                    .integer => |i| @as(u32, @intCast(i)),
                    else => null,
                };
            };

            const s = try extractStruct(allocator, inner_type_obj, size_override);
            errdefer {
                allocator.free(s.name);
                for (s.fields) |f| allocator.free(f.name);
                allocator.free(s.fields);
            }
            try result.append(allocator, s);
        }
    }

    return result.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// Code generation
// ---------------------------------------------------------------------------

/// Emit a Zig source file of pub constants to `writer`.
/// `writer` must be a `*std.Io.Writer` (from File.writer or Allocating.writer).
pub fn emitZig(writer: *std.Io.Writer, structs: []const StructLayout) !void {
    try writer.writeAll(
        \\// AUTO-GENERATED by tools/layout_gen.zig — DO NOT EDIT.
        \\// Source: slangc -reflection-json output.
        \\
    );

    for (structs) |s| {
        try writer.print("\npub const {s}_size: u32 = {};\n", .{ s.name, s.size });
        for (s.fields) |f| {
            try writer.print("pub const {s}_{s}_offset: u32 = {};\n", .{ s.name, f.name, f.offset });
            try writer.print("pub const {s}_{s}_size: u32 = {};\n", .{ s.name, f.name, f.size });
        }
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

test "parseReflection extracts GlyphCommand fields" {
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
        \\              "type": {"kind": "vector"},
        \\              "binding": {"kind": "uniform", "offset": 0, "size": 16, "elementStride": 4}
        \\            },
        \\            {
        \\              "name": "flags",
        \\              "type": {"kind": "scalar"},
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
    // size is computed as max(offset+size) across fields: max(0+16, 52+4) = 56
    try std.testing.expectEqual(@as(u32, 56), structs[0].size);
    try std.testing.expectEqual(@as(usize, 2), structs[0].fields.len);

    // first field: motor
    try std.testing.expectEqualStrings("motor", structs[0].fields[0].name);
    try std.testing.expectEqual(@as(u32, 0), structs[0].fields[0].offset);
    try std.testing.expectEqual(@as(u32, 16), structs[0].fields[0].size);

    // second field: flags
    try std.testing.expectEqualStrings("flags", structs[0].fields[1].name);
    try std.testing.expectEqual(@as(u32, 52), structs[0].fields[1].offset);
    try std.testing.expectEqual(@as(u32, 4), structs[0].fields[1].size);
}

test "parseReflection extracts PushConstants from constantBuffer" {
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
        \\                "type": {"kind": "matrix"},
        \\                "binding": {"kind": "uniform", "offset": 0, "size": 64, "elementStride": 0}
        \\              },
        \\              {
        \\                "name": "glyph_count",
        \\                "type": {"kind": "scalar"},
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
    // size comes from elementVarLayout.binding.size = 80
    try std.testing.expectEqual(@as(u32, 80), structs[0].size);
    try std.testing.expectEqual(@as(usize, 2), structs[0].fields.len);

    try std.testing.expectEqualStrings("proj", structs[0].fields[0].name);
    try std.testing.expectEqual(@as(u32, 0), structs[0].fields[0].offset);
    try std.testing.expectEqual(@as(u32, 64), structs[0].fields[0].size);
}

test "parseReflection extracts both structs from combined JSON" {
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
        \\              "type": {"kind": "vector"},
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
        \\                "type": {"kind": "matrix"},
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

test "emitZig produces GPU layout constants" {
    const fields_gc = [_]FieldLayout{
        .{ .name = "motor", .offset = 0, .size = 16 },
        .{ .name = "flags", .offset = 52, .size = 4 },
    };
    const fields_pc = [_]FieldLayout{
        .{ .name = "proj", .offset = 0, .size = 64 },
        .{ .name = "glyph_count", .offset = 72, .size = 4 },
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

    // Header comment
    try std.testing.expect(std.mem.indexOf(u8, output, "AUTO-GENERATED") != null);

    // GlyphCommand constants
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_size: u32 = 64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_motor_offset: u32 = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_motor_size: u32 = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_flags_offset: u32 = 52") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_flags_size: u32 = 4") != null);

    // PushConstants constants
    try std.testing.expect(std.mem.indexOf(u8, output, "PushConstants_size: u32 = 80") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PushConstants_proj_offset: u32 = 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PushConstants_proj_size: u32 = 64") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "PushConstants_glyph_count_offset: u32 = 72") != null);
}

test "emitZig output has pub const declarations" {
    const fields = [_]FieldLayout{
        .{ .name = "color", .offset = 16, .size = 16 },
    };
    const structs = [_]StructLayout{
        .{ .name = "GlyphCommand", .size = 64, .fields = &fields },
    };

    var aw: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer aw.deinit();
    try emitZig(&aw.writer, &structs);
    const output = try aw.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "pub const") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_color_offset: u32 = 16") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "GlyphCommand_color_size: u32 = 16") != null);
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
    // Must not crash or leak — allocate via allocator so leak detection works
    const empty = try std.testing.allocator.alloc(StructLayout, 0);
    freeStructs(std.testing.allocator, empty);
}
