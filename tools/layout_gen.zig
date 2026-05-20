//! Generate CPU-side Zig `extern struct` layouts from `slangc -reflection-json`.
//!
//! The generator is intentionally strict at the CPU/GPU ABI boundary:
//! - the build graph must name every struct it wants emitted,
//! - reflected field byte ranges must be non-overlapping,
//! - reflected names must be valid plain Zig identifiers, and
//! - generated padding is explicit so `@sizeOf` and `@offsetOf` tests catch
//!   reflection/schema drift during normal backend builds.

const std = @import("std");

const max_reflection_json_bytes = 16 * 1024 * 1024;
const generated_padding_prefix = "__hs_pad";

const ScalarType = enum {
    float32,
    uint32,
    int32,

    fn byteSize(_: ScalarType) u32 {
        return 4;
    }

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
    vector: Vector,
    matrix: Matrix,

    const Vector = struct {
        count: u32,
        element: ScalarType,
    };

    const Matrix = struct {
        rows: u32,
        cols: u32,
        element: ScalarType,
    };

    fn byteSize(self: FieldType) !u32 {
        return switch (self) {
            .scalar => |scalar| scalar.byteSize(),
            .vector => |vector| checkedMulU32(vector.count, vector.element.byteSize()),
            .matrix => |matrix| try checkedMulU32(
                try checkedMulU32(matrix.rows, matrix.cols),
                matrix.element.byteSize(),
            ),
        };
    }
};

const FieldLayout = struct {
    name: []const u8,
    offset: u32,
    storage_size: u32,
    type_size: u32,
    field_type: FieldType,
};

const StructLayout = struct {
    name: []const u8,
    size: u32,
    fields: []const FieldLayout,
};

const ReflectionLayout = struct {
    structs: []StructLayout,

    fn deinit(self: ReflectionLayout, allocator: std.mem.Allocator) void {
        for (self.structs) |*layout| freeStructContents(allocator, layout);
        allocator.free(self.structs);
    }

    fn find(self: ReflectionLayout, name: []const u8) ?StructLayout {
        for (self.structs) |layout| {
            if (std.mem.eql(u8, layout.name, name)) return layout;
        }
        return null;
    }
};

const Binding = struct {
    kind: []const u8,
    offset: u32,
    size: u32,
};

fn checkedAddU32(a: u32, b: u32) !u32 {
    return std.math.add(u32, a, b) catch error.IntegerOverflow;
}

fn checkedMulU32(a: u32, b: u32) !u32 {
    return std.math.mul(u32, a, b) catch error.IntegerOverflow;
}

fn freeStructContents(allocator: std.mem.Allocator, layout: *const StructLayout) void {
    allocator.free(layout.name);
    for (layout.fields) |field| allocator.free(field.name);
    allocator.free(layout.fields);
}

fn fieldTypesEqual(a: FieldType, b: FieldType) bool {
    return std.meta.eql(a, b);
}

fn fieldsEqual(a: []const FieldLayout, b: []const FieldLayout) bool {
    if (a.len != b.len) return false;
    for (a, b) |af, bf| {
        if (!std.mem.eql(u8, af.name, bf.name)) return false;
        if (af.offset != bf.offset) return false;
        if (af.storage_size != bf.storage_size) return false;
        if (af.type_size != bf.type_size) return false;
        if (!fieldTypesEqual(af.field_type, bf.field_type)) return false;
    }
    return true;
}

fn structsEqual(a: StructLayout, b: StructLayout) bool {
    return std.mem.eql(u8, a.name, b.name) and
        a.size == b.size and
        fieldsEqual(a.fields, b.fields);
}

fn appendUniqueStruct(
    allocator: std.mem.Allocator,
    layouts: *std.ArrayList(StructLayout),
    layout: StructLayout,
) !void {
    for (layouts.items) |existing| {
        if (!std.mem.eql(u8, existing.name, layout.name)) continue;
        if (!structsEqual(existing, layout)) return error.ConflictingStructLayout;
        freeStructContents(allocator, &layout);
        return;
    }

    try layouts.append(allocator, layout);
}

fn expectObject(value: std.json.Value) !std.json.ObjectMap {
    return switch (value) {
        .object => |object| object,
        else => error.NotObject,
    };
}

fn expectArray(value: std.json.Value) !std.json.Array {
    return switch (value) {
        .array => |array| array,
        else => error.NotArray,
    };
}

fn readRequiredValue(object: std.json.ObjectMap, key: []const u8) !std.json.Value {
    return object.get(key) orelse error.MissingKey;
}

fn readRequiredObject(object: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    return expectObject(try readRequiredValue(object, key));
}

fn readRequiredArray(object: std.json.ObjectMap, key: []const u8) !std.json.Array {
    return expectArray(try readRequiredValue(object, key));
}

fn readRequiredString(object: std.json.ObjectMap, key: []const u8) ![]const u8 {
    return switch (try readRequiredValue(object, key)) {
        .string => |string| string,
        else => error.NotString,
    };
}

fn readRequiredU32(object: std.json.ObjectMap, key: []const u8) !u32 {
    return switch (try readRequiredValue(object, key)) {
        .integer => |integer| {
            if (integer < 0) return error.IntegerOutOfRange;
            if (integer > std.math.maxInt(u32)) return error.IntegerOutOfRange;
            return @intCast(integer);
        },
        else => error.NotInteger,
    };
}

fn readBinding(object: std.json.ObjectMap) !Binding {
    const binding = try readRequiredObject(object, "binding");
    return .{
        .kind = try readRequiredString(binding, "kind"),
        .offset = try readRequiredU32(binding, "offset"),
        .size = try readRequiredU32(binding, "size"),
    };
}

fn parseScalarName(name: []const u8) !ScalarType {
    if (std.mem.eql(u8, name, "float32")) return .float32;
    if (std.mem.eql(u8, name, "uint32")) return .uint32;
    if (std.mem.eql(u8, name, "int32")) return .int32;
    return error.UnsupportedScalarType;
}

fn parseScalarType(object: std.json.ObjectMap) !ScalarType {
    const kind = try readRequiredString(object, "kind");
    if (!std.mem.eql(u8, kind, "scalar")) return error.ExpectedScalarType;
    return parseScalarName(try readRequiredString(object, "scalarType"));
}

fn readPositiveCount(object: std.json.ObjectMap, key: []const u8) !u32 {
    const count = try readRequiredU32(object, key);
    if (count == 0) return error.InvalidTypeDimension;
    return count;
}

fn parseFieldType(object: std.json.ObjectMap) !FieldType {
    const kind = try readRequiredString(object, "kind");

    if (std.mem.eql(u8, kind, "scalar")) {
        return .{ .scalar = try parseScalarType(object) };
    }

    if (std.mem.eql(u8, kind, "vector")) {
        const element = try parseScalarType(try readRequiredObject(object, "elementType"));
        return .{ .vector = .{
            .count = try readPositiveCount(object, "elementCount"),
            .element = element,
        } };
    }

    if (std.mem.eql(u8, kind, "matrix")) {
        const element = try parseScalarType(try readRequiredObject(object, "elementType"));
        return .{ .matrix = .{
            .rows = try readPositiveCount(object, "rowCount"),
            .cols = try readPositiveCount(object, "columnCount"),
            .element = element,
        } };
    }

    return error.UnsupportedTypeKind;
}

fn isIdentStart(byte: u8) bool {
    return byte == '_' or
        (byte >= 'A' and byte <= 'Z') or
        (byte >= 'a' and byte <= 'z');
}

fn isIdentContinue(byte: u8) bool {
    return isIdentStart(byte) or (byte >= '0' and byte <= '9');
}

fn isZigKeyword(name: []const u8) bool {
    const keywords = [_][]const u8{
        "_",
        "addrspace",
        "align",
        "allowzero",
        "and",
        "anyframe",
        "anytype",
        "asm",
        "async",
        "await",
        "break",
        "callconv",
        "catch",
        "comptime",
        "const",
        "continue",
        "defer",
        "else",
        "enum",
        "errdefer",
        "error",
        "export",
        "extern",
        "false",
        "fn",
        "for",
        "if",
        "inline",
        "linksection",
        "noalias",
        "noinline",
        "nosuspend",
        "null",
        "opaque",
        "or",
        "orelse",
        "packed",
        "pub",
        "resume",
        "return",
        "struct",
        "suspend",
        "switch",
        "test",
        "threadlocal",
        "true",
        "try",
        "undefined",
        "union",
        "unreachable",
        "usingnamespace",
        "var",
        "volatile",
        "while",
    };

    for (keywords) |keyword| {
        if (std.mem.eql(u8, keyword, name)) return true;
    }
    return false;
}

fn validateIdentifier(name: []const u8) !void {
    if (name.len == 0) return error.EmptyIdentifier;
    if (!isIdentStart(name[0])) return error.InvalidIdentifier;
    for (name[1..]) |byte| {
        if (!isIdentContinue(byte)) return error.InvalidIdentifier;
    }
    if (isZigKeyword(name)) return error.ReservedIdentifier;
    if (std.mem.startsWith(u8, name, generated_padding_prefix)) {
        return error.ReservedGeneratedIdentifier;
    }
}

fn parseField(allocator: std.mem.Allocator, field_object: std.json.ObjectMap) !FieldLayout {
    const name = try readRequiredString(field_object, "name");
    try validateIdentifier(name);

    const binding = try readBinding(field_object);
    if (!std.mem.eql(u8, binding.kind, "uniform")) return error.UnsupportedFieldBinding;

    const field_type = try parseFieldType(try readRequiredObject(field_object, "type"));
    const type_size = try field_type.byteSize();
    if (binding.size < type_size) return error.ReflectedFieldSizeTooSmall;

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    return .{
        .name = owned_name,
        .offset = binding.offset,
        .storage_size = binding.size,
        .type_size = type_size,
        .field_type = field_type,
    };
}

fn extractStruct(
    allocator: std.mem.Allocator,
    struct_object: std.json.ObjectMap,
    size_override: ?u32,
) !StructLayout {
    const kind = try readRequiredString(struct_object, "kind");
    if (!std.mem.eql(u8, kind, "struct")) return error.ExpectedStructType;

    const name = try readRequiredString(struct_object, "name");
    try validateIdentifier(name);

    const owned_name = try allocator.dupe(u8, name);
    errdefer allocator.free(owned_name);

    const field_values = try readRequiredArray(struct_object, "fields");
    var fields: std.ArrayList(FieldLayout) = .empty;
    errdefer {
        for (fields.items) |field| allocator.free(field.name);
        fields.deinit(allocator);
    }

    var computed_size: u32 = 0;
    for (field_values.items) |field_value| {
        const field = try parseField(allocator, try expectObject(field_value));
        errdefer allocator.free(field.name);

        computed_size = @max(
            computed_size,
            try checkedAddU32(field.offset, field.storage_size),
        );
        try fields.append(allocator, field);
    }

    std.mem.sort(FieldLayout, fields.items, {}, struct {
        fn lessThan(_: void, a: FieldLayout, b: FieldLayout) bool {
            if (a.offset != b.offset) return a.offset < b.offset;
            return std.mem.lessThan(u8, a.name, b.name);
        }
    }.lessThan);

    var cursor: u32 = 0;
    for (fields.items) |field| {
        if (field.offset < cursor) return error.OverlappingField;
        cursor = try checkedAddU32(field.offset, field.storage_size);
    }

    const struct_size = size_override orelse computed_size;
    if (struct_size < cursor) return error.StructSizeTooSmall;

    return .{
        .name = owned_name,
        .size = struct_size,
        .fields = try fields.toOwnedSlice(allocator),
    };
}

fn parseResourceParameter(
    allocator: std.mem.Allocator,
    layouts: *std.ArrayList(StructLayout),
    type_object: std.json.ObjectMap,
) !void {
    const base_shape = try readRequiredString(type_object, "baseShape");
    if (!std.mem.eql(u8, base_shape, "structuredBuffer")) return;

    var layout = try extractStruct(
        allocator,
        try readRequiredObject(type_object, "resultType"),
        null,
    );
    var consumed = false;
    errdefer if (!consumed) freeStructContents(allocator, &layout);

    try appendUniqueStruct(allocator, layouts, layout);
    consumed = true;
}

fn parseConstantBufferParameter(
    allocator: std.mem.Allocator,
    layouts: *std.ArrayList(StructLayout),
    type_object: std.json.ObjectMap,
) !void {
    const element_layout = try readRequiredObject(type_object, "elementVarLayout");
    const element_binding = try readBinding(element_layout);
    if (!std.mem.eql(u8, element_binding.kind, "uniform")) {
        return error.UnsupportedConstantBufferBinding;
    }

    var layout = try extractStruct(
        allocator,
        try readRequiredObject(element_layout, "type"),
        element_binding.size,
    );
    var consumed = false;
    errdefer if (!consumed) freeStructContents(allocator, &layout);

    try appendUniqueStruct(allocator, layouts, layout);
    consumed = true;
}

/// Parse Slang reflection JSON. Free the returned layout with
/// `ReflectionLayout.deinit`.
fn parseReflection(allocator: std.mem.Allocator, json_bytes: []const u8) !ReflectionLayout {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{});
    defer parsed.deinit();

    const root_object = try expectObject(parsed.value);
    const parameter_values = try readRequiredArray(root_object, "parameters");

    var layouts: std.ArrayList(StructLayout) = .empty;
    errdefer {
        for (layouts.items) |*layout| freeStructContents(allocator, layout);
        layouts.deinit(allocator);
    }

    for (parameter_values.items) |parameter_value| {
        const parameter_object = try expectObject(parameter_value);
        const type_object = try readRequiredObject(parameter_object, "type");
        const kind = try readRequiredString(type_object, "kind");

        if (std.mem.eql(u8, kind, "resource")) {
            try parseResourceParameter(allocator, &layouts, type_object);
        } else if (std.mem.eql(u8, kind, "constantBuffer")) {
            try parseConstantBufferParameter(allocator, &layouts, type_object);
        }
    }

    return .{ .structs = try layouts.toOwnedSlice(allocator) };
}

fn requiredStruct(layout: ReflectionLayout, name: []const u8) !StructLayout {
    return layout.find(name) orelse error.MissingRequiredStruct;
}

fn validateRequestedStructNames(names: []const []const u8) !void {
    if (names.len == 0) return error.NoRequestedStructs;

    for (names, 0..) |name, i| {
        try validateIdentifier(name);
        for (names[0..i]) |previous| {
            if (std.mem.eql(u8, previous, name)) return error.DuplicateRequestedStruct;
        }
    }
}

fn writeZigType(writer: *std.Io.Writer, field_type: FieldType) !void {
    switch (field_type) {
        .scalar => |scalar| try writer.writeAll(scalar.zigName()),
        .vector => |vector| try writer.print("[{d}]{s}", .{
            vector.count,
            vector.element.zigName(),
        }),
        .matrix => |matrix| try writer.print("[{d}][{d}]{s}", .{
            matrix.cols,
            matrix.rows,
            matrix.element.zigName(),
        }),
    }
}

fn writeDefault(writer: *std.Io.Writer, field_type: FieldType) !void {
    switch (field_type) {
        .scalar => try writer.writeAll(" = 0"),
        .vector => |vector| try writer.print(" = .{{0}} ** {d}", .{vector.count}),
        .matrix => |matrix| try writer.print(" = .{{.{{0}} ** {d}}} ** {d}", .{
            matrix.rows,
            matrix.cols,
        }),
    }
}

fn writePaddingField(writer: *std.Io.Writer, index: *u32, byte_count: u32) !void {
    if (byte_count == 0) return;
    try writer.print("    {s}{d}: [{d}]u8 = .{{0}} ** {d},\n", .{
        generated_padding_prefix,
        index.*,
        byte_count,
        byte_count,
    });
    index.* += 1;
}

fn emitStruct(writer: *std.Io.Writer, layout: StructLayout) !void {
    try writer.print("\npub const {s} = extern struct {{\n", .{layout.name});

    var cursor: u32 = 0;
    var padding_index: u32 = 0;
    for (layout.fields) |field| {
        if (field.offset > cursor) {
            try writePaddingField(writer, &padding_index, field.offset - cursor);
        }

        try writer.print("    {s}: ", .{field.name});
        try writeZigType(writer, field.field_type);
        if (field.name[0] == '_') {
            try writeDefault(writer, field.field_type);
        }
        try writer.writeAll(",\n");

        cursor = try checkedAddU32(field.offset, field.type_size);
        if (field.storage_size > field.type_size) {
            try writePaddingField(writer, &padding_index, field.storage_size - field.type_size);
            cursor = try checkedAddU32(field.offset, field.storage_size);
        }
    }

    if (layout.size > cursor) {
        try writePaddingField(writer, &padding_index, layout.size - cursor);
    }

    try writer.writeAll("};\n");

    try writer.print("\ntest \"{s}: reflection layout matches Zig extern layout\" {{\n", .{
        layout.name,
    });
    try writer.print("    try std.testing.expectEqual(@as(usize, {d}), @sizeOf({s}));\n", .{
        layout.size,
        layout.name,
    });
    for (layout.fields) |field| {
        try writer.print(
            "    try std.testing.expectEqual(@as(usize, {d}), @offsetOf({s}, \"{s}\"));\n",
            .{ field.offset, layout.name, field.name },
        );
    }
    try writer.writeAll("}\n");
}

fn emitZig(
    writer: *std.Io.Writer,
    layout: ReflectionLayout,
    requested_struct_names: []const []const u8,
) !void {
    try validateRequestedStructNames(requested_struct_names);
    for (requested_struct_names) |name| {
        _ = try requiredStruct(layout, name);
    }

    try writer.writeAll(
        \\// AUTO-GENERATED by tools/layout_gen.zig - DO NOT EDIT.
        \\// Source: slangc -reflection-json output.
        \\// Struct order is supplied explicitly by build/shaders.zig.
        \\
        \\const std = @import("std");
        \\
    );

    try writer.print("\npub const reflected_struct_count: usize = {d};\n", .{
        requested_struct_names.len,
    });
    try writer.writeAll("pub const reflected_struct_names = [_][]const u8{\n");
    for (requested_struct_names) |name| {
        try writer.print("    \"{s}\",\n", .{name});
    }
    try writer.writeAll("};\n");

    for (requested_struct_names) |name| {
        try emitStruct(writer, try requiredStruct(layout, name));
    }
}

fn writeUsage(io: std.Io, message: []const u8) !void {
    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    try stderr_writer.interface.print(
        \\{s}
        \\Usage: layout_gen <reflection.json> <struct-name>...
        \\
    , .{message});
    try stderr_writer.interface.flush();
}

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const allocator = init.gpa;

    const args = try init.minimal.args.toSlice(init.arena.allocator());
    if (args.len < 3) {
        try writeUsage(io, "error: missing reflection JSON path or struct names");
        std.process.exit(1);
    }

    const requested_struct_names = args[2..];
    validateRequestedStructNames(requested_struct_names) catch |err| {
        var stderr_buffer: [512]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        try stderr_writer.interface.print("error: invalid requested struct names: {}\n", .{err});
        try stderr_writer.interface.flush();
        std.process.exit(1);
    };

    const json_path = args[1];
    const json_bytes = std.Io.Dir.cwd().readFileAlloc(
        io,
        json_path,
        allocator,
        .limited(max_reflection_json_bytes),
    ) catch |err| {
        var stderr_buffer: [512]u8 = undefined;
        var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
        try stderr_writer.interface.print("error: cannot read '{s}': {}\n", .{ json_path, err });
        try stderr_writer.interface.flush();
        std.process.exit(1);
    };
    defer allocator.free(json_bytes);

    const layout = try parseReflection(allocator, json_bytes);
    defer layout.deinit(allocator);

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &stdout_buffer);
    try emitZig(&stdout_writer.interface, layout, requested_struct_names);
    try stdout_writer.interface.flush();
}

const glyph_instance_resource_json =
    \\{
    \\  "name": "glyphs",
    \\  "binding": {"kind": "descriptorTableSlot", "index": 1},
    \\  "type": {
    \\    "kind": "resource",
    \\    "baseShape": "structuredBuffer",
    \\    "resultType": {
    \\      "kind": "struct",
    \\      "name": "GlyphInstance",
    \\      "fields": [
    \\        {
    \\          "name": "color",
    \\          "type": {"kind": "vector", "elementCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
    \\          "binding": {"kind": "uniform", "offset": 0, "size": 16, "elementStride": 4}
    \\        },
    \\        {
    \\          "name": "blob_ref",
    \\          "type": {"kind": "scalar", "scalarType": "uint32"},
    \\          "binding": {"kind": "uniform", "offset": 16, "size": 4, "elementStride": 0}
    \\        },
    \\        {
    \\          "name": "flags",
    \\          "type": {"kind": "scalar", "scalarType": "uint32"},
    \\          "binding": {"kind": "uniform", "offset": 20, "size": 4, "elementStride": 0}
    \\        },
    \\        {
    \\          "name": "precision_bits",
    \\          "type": {"kind": "scalar", "scalarType": "uint32"},
    \\          "binding": {"kind": "uniform", "offset": 24, "size": 4, "elementStride": 0}
    \\        },
    \\        {
    \\          "name": "glyph_anchor_q",
    \\          "type": {"kind": "vector", "elementCount": 2, "elementType": {"kind": "scalar", "scalarType": "int32"}},
    \\          "binding": {"kind": "uniform", "offset": 32, "size": 8, "elementStride": 4}
    \\        }
    \\      ]
    \\    }
    \\  }
    \\}
;

const glyph_meshlet_resource_json =
    \\{
    \\  "name": "meshlets",
    \\  "binding": {"kind": "descriptorTableSlot", "index": 2},
    \\  "type": {
    \\    "kind": "resource",
    \\    "baseShape": "structuredBuffer",
    \\    "resultType": {
    \\      "kind": "struct",
    \\      "name": "GlyphMeshlet",
    \\      "fields": [
    \\        {
    \\          "name": "glyph_index",
    \\          "type": {"kind": "scalar", "scalarType": "uint32"},
    \\          "binding": {"kind": "uniform", "offset": 0, "size": 4, "elementStride": 0}
    \\        },
    \\        {
    \\          "name": "_pad0",
    \\          "type": {"kind": "scalar", "scalarType": "uint32"},
    \\          "binding": {"kind": "uniform", "offset": 4, "size": 4, "elementStride": 0}
    \\        },
    \\        {
    \\          "name": "rect_min_q",
    \\          "type": {"kind": "vector", "elementCount": 2, "elementType": {"kind": "scalar", "scalarType": "int32"}},
    \\          "binding": {"kind": "uniform", "offset": 8, "size": 8, "elementStride": 4}
    \\        }
    \\      ]
    \\    }
    \\  }
    \\}
;

const frame_params_constant_json =
    \\{
    \\  "name": "pc",
    \\  "binding": {"kind": "pushConstantBuffer", "index": 0},
    \\  "type": {
    \\    "kind": "constantBuffer",
    \\    "elementType": {
    \\      "kind": "struct",
    \\      "name": "FrameParams",
    \\      "fields": []
    \\    },
    \\    "elementVarLayout": {
    \\      "type": {
    \\        "kind": "struct",
    \\        "name": "FrameParams",
    \\        "fields": [
    \\          {
    \\            "name": "viewport_size",
    \\            "type": {"kind": "vector", "elementCount": 2, "elementType": {"kind": "scalar", "scalarType": "float32"}},
    \\            "binding": {"kind": "uniform", "offset": 0, "size": 8, "elementStride": 4}
    \\          },
    \\          {
    \\            "name": "screen_from_framebuffer_2x2",
    \\            "type": {"kind": "vector", "elementCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
    \\            "binding": {"kind": "uniform", "offset": 16, "size": 16, "elementStride": 4}
    \\          },
    \\          {
    \\            "name": "meshlet_count",
    \\            "type": {"kind": "scalar", "scalarType": "uint32"},
    \\            "binding": {"kind": "uniform", "offset": 40, "size": 4, "elementStride": 0}
    \\          }
    \\        ]
    \\      },
    \\      "binding": {"kind": "uniform", "offset": 0, "size": 48, "elementStride": 0}
    \\    }
    \\  }
    \\}
;

fn reflectionJson(comptime parameter_json: []const u8) []const u8 {
    return
    \\{
    \\  "parameters": [
    ++ parameter_json ++
        \\  ],
        \\  "entryPoints": []
        \\}
    ;
}

fn reflectionJson2(
    comptime first_parameter_json: []const u8,
    comptime second_parameter_json: []const u8,
) []const u8 {
    return
    \\{
    \\  "parameters": [
    ++ first_parameter_json ++
        \\,
    ++ second_parameter_json ++
        \\  ],
        \\  "entryPoints": []
        \\}
    ;
}

fn reflectionJson3(
    comptime first_parameter_json: []const u8,
    comptime second_parameter_json: []const u8,
    comptime third_parameter_json: []const u8,
) []const u8 {
    return
    \\{
    \\  "parameters": [
    ++ first_parameter_json ++
        \\,
    ++ second_parameter_json ++
        \\,
    ++ third_parameter_json ++
        \\  ],
        \\  "entryPoints": []
        \\}
    ;
}

test "parseReflection: extracts explicit CPU-visible Slang buffer structs" {
    const layout = try parseReflection(
        std.testing.allocator,
        reflectionJson3(
            glyph_instance_resource_json,
            glyph_meshlet_resource_json,
            frame_params_constant_json,
        ),
    );
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), layout.structs.len);

    const glyph_instance = try requiredStruct(layout, "GlyphInstance");
    try std.testing.expectEqual(@as(u32, 40), glyph_instance.size);
    try std.testing.expectEqual(@as(usize, 5), glyph_instance.fields.len);
    try std.testing.expectEqualStrings("color", glyph_instance.fields[0].name);
    try std.testing.expectEqual(@as(u32, 0), glyph_instance.fields[0].offset);
    try std.testing.expectEqual(@as(u32, 16), glyph_instance.fields[0].storage_size);
    try std.testing.expectEqual(FieldType{ .vector = .{ .count = 4, .element = .float32 } }, glyph_instance.fields[0].field_type);

    const meshlet = try requiredStruct(layout, "GlyphMeshlet");
    try std.testing.expectEqual(@as(u32, 16), meshlet.size);
    try std.testing.expectEqualStrings("_pad0", meshlet.fields[1].name);

    const frame_params = try requiredStruct(layout, "FrameParams");
    try std.testing.expectEqual(@as(u32, 48), frame_params.size);
    try std.testing.expectEqual(@as(u32, 16), frame_params.fields[1].offset);
}

test "parseReflection: ignores non-structured resources" {
    const json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "glyphPool",
        \\      "binding": {"kind": "descriptorTableSlot", "index": 0},
        \\      "type": {"kind": "resource", "baseShape": "byteAddressBuffer"}
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    const layout = try parseReflection(std.testing.allocator, json);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 0), layout.structs.len);
}

test "parseReflection: deduplicates identical reflected structs" {
    const json = reflectionJson2(glyph_instance_resource_json, glyph_instance_resource_json);

    const layout = try parseReflection(std.testing.allocator, json);
    defer layout.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), layout.structs.len);
    try std.testing.expectEqualStrings("GlyphInstance", layout.structs[0].name);
}

test "parseReflection: rejects conflicting duplicate struct layouts" {
    const conflicting_glyph_instance =
        \\{
        \\  "name": "glyphs_conflict",
        \\  "type": {
        \\    "kind": "resource",
        \\    "baseShape": "structuredBuffer",
        \\    "resultType": {
        \\      "kind": "struct",
        \\      "name": "GlyphInstance",
        \\      "fields": [
        \\        {
        \\          "name": "blob_ref",
        \\          "type": {"kind": "scalar", "scalarType": "uint32"},
        \\          "binding": {"kind": "uniform", "offset": 4, "size": 4, "elementStride": 0}
        \\        }
        \\      ]
        \\    }
        \\  }
        \\}
    ;

    try std.testing.expectError(
        error.ConflictingStructLayout,
        parseReflection(
            std.testing.allocator,
            reflectionJson2(glyph_instance_resource_json, conflicting_glyph_instance),
        ),
    );
}

test "parseReflection: rejects overlapping fields" {
    const bad_json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "bad",
        \\      "type": {
        \\        "kind": "resource",
        \\        "baseShape": "structuredBuffer",
        \\        "resultType": {
        \\          "kind": "struct",
        \\          "name": "Bad",
        \\          "fields": [
        \\            {
        \\              "name": "a",
        \\              "type": {"kind": "scalar", "scalarType": "uint32"},
        \\              "binding": {"kind": "uniform", "offset": 0, "size": 4, "elementStride": 0}
        \\            },
        \\            {
        \\              "name": "b",
        \\              "type": {"kind": "scalar", "scalarType": "uint32"},
        \\              "binding": {"kind": "uniform", "offset": 2, "size": 4, "elementStride": 0}
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    try std.testing.expectError(
        error.OverlappingField,
        parseReflection(std.testing.allocator, bad_json),
    );
}

test "parseReflection: rejects identifiers that cannot be emitted as Zig" {
    const bad_json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "bad",
        \\      "type": {
        \\        "kind": "resource",
        \\        "baseShape": "structuredBuffer",
        \\        "resultType": {
        \\          "kind": "struct",
        \\          "name": "Bad",
        \\          "fields": [
        \\            {
        \\              "name": "pub",
        \\              "type": {"kind": "scalar", "scalarType": "uint32"},
        \\              "binding": {"kind": "uniform", "offset": 0, "size": 4, "elementStride": 0}
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    try std.testing.expectError(
        error.ReservedIdentifier,
        parseReflection(std.testing.allocator, bad_json),
    );
}

test "parseReflection: rejects structured buffers whose result type is not a struct" {
    const bad_json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "bad",
        \\      "type": {
        \\        "kind": "resource",
        \\        "baseShape": "structuredBuffer",
        \\        "resultType": {
        \\          "kind": "scalar",
        \\          "name": "Bad",
        \\          "fields": []
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    try std.testing.expectError(
        error.ExpectedStructType,
        parseReflection(std.testing.allocator, bad_json),
    );
}

test "parseReflection: rejects reflected field storage smaller than Zig type" {
    const bad_json =
        \\{
        \\  "parameters": [
        \\    {
        \\      "name": "bad",
        \\      "type": {
        \\        "kind": "resource",
        \\        "baseShape": "structuredBuffer",
        \\        "resultType": {
        \\          "kind": "struct",
        \\          "name": "Bad",
        \\          "fields": [
        \\            {
        \\              "name": "wide",
        \\              "type": {"kind": "vector", "elementCount": 4, "elementType": {"kind": "scalar", "scalarType": "float32"}},
        \\              "binding": {"kind": "uniform", "offset": 0, "size": 12, "elementStride": 4}
        \\            }
        \\          ]
        \\        }
        \\      }
        \\    }
        \\  ],
        \\  "entryPoints": []
        \\}
    ;

    try std.testing.expectError(
        error.ReflectedFieldSizeTooSmall,
        parseReflection(std.testing.allocator, bad_json),
    );
}

test "emitZig: emits requested structs in requested order" {
    const layout = try parseReflection(
        std.testing.allocator,
        reflectionJson3(
            glyph_instance_resource_json,
            glyph_meshlet_resource_json,
            frame_params_constant_json,
        ),
    );
    defer layout.deinit(std.testing.allocator);

    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();
    try emitZig(&output_writer.writer, layout, &.{ "FrameParams", "GlyphInstance" });
    const output = try output_writer.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "AUTO-GENERATED") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "Struct order is supplied explicitly") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const reflected_struct_count: usize = 2;") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "\"FrameParams\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const FrameParams = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "pub const GlyphInstance = extern struct {") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "reflection layout matches Zig extern layout") != null);

    const frame_index = std.mem.indexOf(u8, output, "pub const FrameParams").?;
    const glyph_index = std.mem.indexOf(u8, output, "pub const GlyphInstance").?;
    try std.testing.expect(frame_index < glyph_index);
}

test "emitZig: rejects missing requested structs" {
    const layout = try parseReflection(std.testing.allocator, reflectionJson(glyph_instance_resource_json));
    defer layout.deinit(std.testing.allocator);

    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();

    try std.testing.expectError(
        error.MissingRequiredStruct,
        emitZig(&output_writer.writer, layout, &.{"FrameParams"}),
    );
}

test "emitZig: rejects duplicate requested structs" {
    const layout = try parseReflection(std.testing.allocator, reflectionJson(glyph_instance_resource_json));
    defer layout.deinit(std.testing.allocator);

    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();

    try std.testing.expectError(
        error.DuplicateRequestedStruct,
        emitZig(&output_writer.writer, layout, &.{ "GlyphInstance", "GlyphInstance" }),
    );
}

test "emitZig: emits explicit padding for reflected storage larger than Zig type" {
    const fields = [_]FieldLayout{
        .{
            .name = "normal",
            .offset = 0,
            .storage_size = 16,
            .type_size = 12,
            .field_type = .{ .vector = .{ .count = 3, .element = .float32 } },
        },
        .{
            .name = "_internal",
            .offset = 16,
            .storage_size = 4,
            .type_size = 4,
            .field_type = .{ .scalar = .uint32 },
        },
    };
    const layouts = [_]StructLayout{
        .{ .name = "Padded", .size = 24, .fields = &fields },
    };
    const layout = ReflectionLayout{ .structs = @constCast(layouts[0..]) };

    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();
    try emitZig(&output_writer.writer, layout, &.{"Padded"});
    const output = try output_writer.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "normal: [3]f32,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__hs_pad0: [4]u8 = .{0} ** 4,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "_internal: u32 = 0,") != null);
    try std.testing.expect(std.mem.indexOf(u8, output, "__hs_pad1: [4]u8 = .{0} ** 4,") != null);
}

test "emitZig: non-square matrix emits column-major Zig storage" {
    const fields = [_]FieldLayout{
        .{
            .name = "m",
            .offset = 0,
            .storage_size = 48,
            .type_size = 48,
            .field_type = .{ .matrix = .{ .rows = 3, .cols = 4, .element = .float32 } },
        },
    };
    const layouts = [_]StructLayout{
        .{ .name = "MatrixHost", .size = 48, .fields = &fields },
    };
    const layout = ReflectionLayout{ .structs = @constCast(layouts[0..]) };

    var output_writer: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer output_writer.deinit();
    try emitZig(&output_writer.writer, layout, &.{"MatrixHost"});
    const output = try output_writer.toOwnedSlice();
    defer std.testing.allocator.free(output);

    try std.testing.expect(std.mem.indexOf(u8, output, "m: [4][3]f32,") != null);
}

test "validateRequestedStructNames rejects empty input" {
    try std.testing.expectError(error.NoRequestedStructs, validateRequestedStructNames(&.{}));
}
