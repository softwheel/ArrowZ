//! Zero-copy borrowed C Data import implemented entirely in Zig.
//!
//! The returned view never owns or releases the input. The producer-owned base
//! structures and buffers must remain live and immutable for the view lifetime.
//! C Data has no byte lengths, so callers must uphold the ABI buffer-extent rule.
const std = @import("std");
const bitmap = @import("bitmap.zig");
const primitive = @import("primitive.zig");
const boolean = @import("boolean.zig");
const variable = @import("variable_binary.zig");
const record_batch = @import("record_batch.zig");
const schema_mod = @import("schema.zig");
const c = @import("c_data.zig");

const max_schema_depth: usize = 64;
const max_children: usize = 65_536;
const max_metadata_entries: usize = 1_024;
const max_metadata_bytes: usize = 16 * 1024 * 1024;
const max_name_bytes: usize = 1024 * 1024;

pub const ImportError = error{
    Released,
    MissingFormat,
    UnsupportedType,
    DictionaryUnsupported,
    NestedTypeUnsupported,
    InvalidLength,
    InvalidOffset,
    LengthOverflow,
    InvalidNullCount,
    InvalidBufferCount,
    MissingBuffers,
    MissingValidity,
    MissingValues,
    MisalignedBuffer,
    InvalidBinaryOffset,
    InvalidUtf8,
    InvalidChildCount,
    MissingChildren,
    MissingChild,
    ChildTooShort,
    InvalidFlags,
    InvalidMetadata,
    MetadataLimitExceeded,
    NameLimitExceeded,
    SchemaDepthExceeded,
    ChildLimitExceeded,
    InvalidBatchValidity,
};

/// Singular owner of a deep-copied native schema and zero-copy batch columns.
/// Do not copy. Moving invalidates every outstanding borrowed RecordBatch.
pub const ImportedRecordBatch = struct {
    allocator: std.mem.Allocator,
    array: c.ArrowArray = .{},
    c_schema: c.ArrowSchema = .{},
    view: ?record_batch.ArrayView = null,
    native_schema: ?schema_mod.Schema = null,
    columns: []record_batch.ArrayView = &.{},

    /// Completes recursive validation and every allocation before moving roots.
    pub fn take(allocator: std.mem.Allocator, array: *c.ArrowArray, schema: *c.ArrowSchema) !ImportedRecordBatch {
        const view = try buildStruct(allocator, array, schema);
        errdefer freeView(allocator, view);
        const root = view.struct_;
        if (root.null_count != 0) return error.InvalidBatchValidity;
        if (schema.flags != 0) return error.InvalidFlags;

        const specs = try buildFieldSpecs(allocator, schema, 0);
        defer freeFieldSpecs(allocator, specs);
        const metadata = try parseMetadata(allocator, schema.metadata);
        defer freeMetadataSpecs(allocator, metadata);
        var native_schema = try schema_mod.Schema.init(allocator, specs, metadata);
        errdefer native_schema.deinit();

        const columns = if (root.children.len == 0)
            @as([]record_batch.ArrayView, &.{})
        else
            try allocator.alloc(record_batch.ArrayView, root.children.len);
        errdefer if (columns.len != 0) allocator.free(columns);
        for (columns, 0..) |*column, index| column.* = try root.child(index);
        _ = try record_batch.RecordBatch.init(&native_schema, columns, root.len);

        const result: ImportedRecordBatch = .{
            .allocator = allocator,
            .array = array.*,
            .c_schema = schema.*,
            .view = view,
            .native_schema = native_schema,
            .columns = columns,
        };
        array.* = .{};
        schema.* = .{};
        return result;
    }

    pub fn borrow(self: *const ImportedRecordBatch) !record_batch.RecordBatch {
        if (self.array.release == null or self.c_schema.release == null or self.native_schema == null or self.view == null) return error.Released;
        return record_batch.RecordBatch.init(&self.native_schema.?, self.columns, self.view.?.struct_.len);
    }

    pub fn move(self: *ImportedRecordBatch) ImportedRecordBatch {
        const result = self.*;
        self.* = .{ .allocator = self.allocator };
        return result;
    }

    pub fn deinit(self: *ImportedRecordBatch) void {
        c.releaseArray(&self.array);
        c.releaseSchema(&self.c_schema);
        if (self.view) |view| freeView(self.allocator, view);
        if (self.native_schema) |*schema| schema.deinit();
        if (self.columns.len != 0) self.allocator.free(self.columns);
        self.* = .{ .allocator = self.allocator };
    }
};

fn buildFieldSpecs(allocator: std.mem.Allocator, parent: *const c.ArrowSchema, depth: usize) anyerror![]schema_mod.FieldSpec {
    if (depth >= max_schema_depth) return error.SchemaDepthExceeded;
    if (parent.n_children < 0) return error.InvalidChildCount;
    const count = std.math.cast(usize, parent.n_children) orelse return error.LengthOverflow;
    if (count > max_children) return error.ChildLimitExceeded;
    if (count == 0) return &.{};
    const children = parent.children orelse return error.MissingChildren;
    const specs = try allocator.alloc(schema_mod.FieldSpec, count);
    var initialized: usize = 0;
    errdefer {
        for (specs[0..initialized]) |spec| freeFieldSpec(allocator, spec);
        allocator.free(specs);
    }
    for (specs, 0..) |*spec, index| {
        const child = children[index] orelse return error.MissingChild;
        spec.* = try buildFieldSpec(allocator, child, depth + 1);
        initialized += 1;
    }
    return specs;
}

fn buildFieldSpec(allocator: std.mem.Allocator, schema: *const c.ArrowSchema, depth: usize) anyerror!schema_mod.FieldSpec {
    if (schema.release == null) return error.Released;
    if (schema.dictionary != null) return error.DictionaryUnsupported;
    if (schema.flags & ~@as(i64, 2) != 0) return error.InvalidFlags;
    const format = try boundedZ(schema.format orelse return error.MissingFormat, 16, error.UnsupportedType);
    const data_type: schema_mod.DataType = if (std.mem.eql(u8, format, "+s")) .struct_ else if (format.len == 1) switch (format[0]) {
        'c' => .int8,
        'C' => .uint8,
        's' => .int16,
        'S' => .uint16,
        'i' => .int32,
        'I' => .uint32,
        'l' => .int64,
        'L' => .uint64,
        'f' => .float32,
        'g' => .float64,
        'b' => .boolean,
        'z' => .binary,
        'u' => .utf8,
        else => return error.UnsupportedType,
    } else return error.UnsupportedType;
    if (data_type != .struct_ and schema.n_children != 0) return error.InvalidChildCount;
    const name = try boundedOptionalName(schema.name);
    const metadata = try parseMetadata(allocator, schema.metadata);
    errdefer freeMetadataSpecs(allocator, metadata);
    const children = if (data_type == .struct_) try buildFieldSpecs(allocator, schema, depth) else @as([]schema_mod.FieldSpec, &.{});
    return .{
        .name = name,
        .data_type = data_type,
        .nullable = schema.flags & 2 != 0,
        .metadata = metadata,
        .children = children,
    };
}

fn freeFieldSpecs(allocator: std.mem.Allocator, specs: []const schema_mod.FieldSpec) void {
    for (specs) |spec| freeFieldSpec(allocator, spec);
    if (specs.len != 0) allocator.free(@constCast(specs));
}

fn freeFieldSpec(allocator: std.mem.Allocator, spec: schema_mod.FieldSpec) void {
    freeMetadataSpecs(allocator, spec.metadata);
    freeFieldSpecs(allocator, spec.children);
}

fn parseMetadata(allocator: std.mem.Allocator, pointer: ?[*]const u8) ![]schema_mod.MetadataEntry {
    const source = pointer orelse return &.{};
    const bytes = source[0..max_metadata_bytes];
    var cursor: usize = 0;
    const signed_count = try readMetadataI32(bytes, &cursor);
    if (signed_count < 0) return error.InvalidMetadata;
    const count: usize = @intCast(signed_count);
    if (count > max_metadata_entries) return error.MetadataLimitExceeded;
    if (count == 0) return &.{};
    const entries = try allocator.alloc(schema_mod.MetadataEntry, count);
    errdefer allocator.free(entries);
    for (entries) |*entry| {
        const key_len = try readMetadataLength(bytes, &cursor);
        const key_end = std.math.add(usize, cursor, key_len) catch return error.InvalidMetadata;
        if (key_end > bytes.len) return error.MetadataLimitExceeded;
        const key = bytes[cursor..key_end];
        cursor = key_end;
        const value_len = try readMetadataLength(bytes, &cursor);
        const value_end = std.math.add(usize, cursor, value_len) catch return error.InvalidMetadata;
        if (value_end > bytes.len) return error.MetadataLimitExceeded;
        entry.* = .{ .key = key, .value = bytes[cursor..value_end] };
        cursor = value_end;
    }
    return entries;
}

fn readMetadataLength(bytes: []const u8, cursor: *usize) !usize {
    const value = try readMetadataI32(bytes, cursor);
    if (value < 0) return error.InvalidMetadata;
    return @intCast(value);
}

fn readMetadataI32(bytes: []const u8, cursor: *usize) !i32 {
    const end = std.math.add(usize, cursor.*, @sizeOf(i32)) catch return error.InvalidMetadata;
    if (end > bytes.len) return error.MetadataLimitExceeded;
    var value: i32 = undefined;
    @memcpy(std.mem.asBytes(&value), bytes[cursor.*..end]);
    cursor.* = end;
    return value;
}

fn freeMetadataSpecs(allocator: std.mem.Allocator, entries: []const schema_mod.MetadataEntry) void {
    if (entries.len != 0) allocator.free(@constCast(entries));
}

fn boundedOptionalName(pointer: ?[*:0]const u8) ![]const u8 {
    return if (pointer) |name| boundedZ(name, max_name_bytes, error.NameLimitExceeded) else "";
}

fn boundedZ(pointer: [*:0]const u8, limit: usize, comptime too_long: anyerror) ![]const u8 {
    for (0..limit) |index| if (pointer[index] == 0) return pointer[0..index];
    return too_long;
}

/// Singular owner of recursive C Data struct bases and Zig view descriptors.
/// Buffer bytes remain producer-owned; do not copy this value. Use `move`.
pub const ImportedStruct = struct {
    allocator: std.mem.Allocator,
    array: c.ArrowArray = .{},
    schema: c.ArrowSchema = .{},
    view: ?record_batch.ArrayView = null,

    /// All validation and descriptor allocations finish before either base moves.
    pub fn take(allocator: std.mem.Allocator, array: *c.ArrowArray, schema: *c.ArrowSchema) !ImportedStruct {
        const view = try buildStruct(allocator, array, schema);
        const result: ImportedStruct = .{
            .allocator = allocator,
            .array = array.*,
            .schema = schema.*,
            .view = view,
        };
        array.* = .{};
        schema.* = .{};
        return result;
    }

    pub fn borrow(self: *const ImportedStruct) error{Released}!record_batch.ArrayView {
        if (self.array.release == null or self.schema.release == null or self.view == null) return error.Released;
        return self.view.?;
    }

    pub fn move(self: *ImportedStruct) ImportedStruct {
        const result = self.*;
        self.* = .{ .allocator = self.allocator };
        return result;
    }

    pub fn deinit(self: *ImportedStruct) void {
        c.releaseArray(&self.array);
        c.releaseSchema(&self.schema);
        if (self.view) |view| freeView(self.allocator, view);
        self.* = .{ .allocator = self.allocator };
    }
};

fn freeView(allocator: std.mem.Allocator, view: record_batch.ArrayView) void {
    switch (view) {
        .struct_ => |parent| {
            for (parent.children) |child| freeView(allocator, child);
            if (parent.children.len != 0) allocator.free(@constCast(parent.children));
        },
        else => {},
    }
}

fn buildStruct(allocator: std.mem.Allocator, array: *const c.ArrowArray, schema: *const c.ArrowSchema) !record_batch.ArrayView {
    return buildStructDepth(allocator, array, schema, 0);
}

fn buildStructDepth(allocator: std.mem.Allocator, array: *const c.ArrowArray, schema: *const c.ArrowSchema, depth: usize) !record_batch.ArrayView {
    if (depth >= max_schema_depth) return error.SchemaDepthExceeded;
    if (array.release == null or schema.release == null) return error.Released;
    if (array.dictionary != null or schema.dictionary != null) return error.DictionaryUnsupported;
    const format = schema.format orelse return error.MissingFormat;
    if (format[0] != '+' or format[1] != 's' or format[2] != 0) return error.UnsupportedType;
    if (array.length < 0) return error.InvalidLength;
    if (array.offset < 0) return error.InvalidOffset;
    if (array.null_count < -1 or array.null_count > array.length) return error.InvalidNullCount;
    if (array.n_buffers != 1) return error.InvalidBufferCount;
    const buffers = array.buffers orelse return error.MissingBuffers;
    if (array.n_children < 0 or array.n_children != schema.n_children) return error.InvalidChildCount;
    const len = std.math.cast(usize, array.length) orelse return error.LengthOverflow;
    const offset = std.math.cast(usize, array.offset) orelse return error.LengthOverflow;
    const end = std.math.add(usize, len, offset) catch return error.LengthOverflow;
    const validity = if (buffers[0]) |pointer|
        try byteBuffer(pointer, bitmap.byteLength(end))
    else blk: {
        if (array.null_count != 0) return error.MissingValidity;
        break :blk &.{};
    };
    var null_count: usize = 0;
    if (validity.len != 0) {
        for (offset..end) |i| null_count += @intFromBool(!bitmap.isSet(validity, i));
    }
    if (array.null_count >= 0 and null_count != @as(usize, @intCast(array.null_count))) return error.InvalidNullCount;
    const count = std.math.cast(usize, array.n_children) orelse return error.LengthOverflow;
    if (count > max_children) return error.ChildLimitExceeded;
    if (count == 0) return .{ .struct_ = .{ .validity = validity, .children = &.{}, .offset = offset, .len = len, .null_count = null_count } };
    const array_children = array.children orelse return error.MissingChildren;
    const schema_children = schema.children orelse return error.MissingChildren;
    const children = try allocator.alloc(record_batch.ArrayView, count);
    var initialized: usize = 0;
    errdefer {
        for (children[0..initialized]) |child| freeView(allocator, child);
        allocator.free(children);
    }
    for (children, 0..) |*child, i| {
        const child_array = array_children[i] orelse return error.MissingChild;
        const child_schema = schema_children[i] orelse return error.MissingChild;
        const child_format = child_schema.format orelse return error.MissingFormat;
        child.* = if (child_format[0] == '+')
            try buildStructDepth(allocator, child_array, child_schema, depth + 1)
        else
            try borrowArray(child_array, child_schema);
        initialized += 1;
        if (child.len() < end) return error.ChildTooShort;
    }
    return .{ .struct_ = .{ .validity = validity, .children = children, .offset = offset, .len = len, .null_count = null_count } };
}

/// Singular owner of producer-created C Data base structures. Do not copy.
/// Use `move` for explicit relocation and `deinit` exactly once per live owner.
pub const ImportedArray = struct {
    array: c.ArrowArray = .{},
    schema: c.ArrowSchema = .{},

    /// Validates before moving. Failure leaves both caller structures untouched.
    pub fn take(array: *c.ArrowArray, schema: *c.ArrowSchema) ImportError!ImportedArray {
        _ = try borrowArray(array, schema);
        const result: ImportedArray = .{ .array = array.*, .schema = schema.* };
        array.* = .{};
        schema.* = .{};
        return result;
    }

    pub fn borrow(self: *const ImportedArray) ImportError!record_batch.ArrayView {
        return borrowArray(&self.array, &self.schema);
    }

    /// Relocates ownership and invalidates the source owner without releasing.
    pub fn move(self: *ImportedArray) ImportedArray {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn deinit(self: *ImportedArray) void {
        c.releaseArray(&self.array);
        c.releaseSchema(&self.schema);
        self.* = .{};
    }
};

const Common = struct {
    buffers: [*]const ?*const anyopaque,
    validity: []const u8,
    offset: usize,
    len: usize,
    end: usize,
};

/// Borrows a supported leaf array. This function does not call either release
/// callback, including on error.
pub fn borrowArray(array: *const c.ArrowArray, schema: *const c.ArrowSchema) ImportError!record_batch.ArrayView {
    if (array.release == null or schema.release == null) return error.Released;
    if (array.dictionary != null or schema.dictionary != null) return error.DictionaryUnsupported;
    if (array.n_children != 0 or schema.n_children != 0) return error.NestedTypeUnsupported;
    const format = schema.format orelse return error.MissingFormat;
    if (format[1] != 0) return error.UnsupportedType;
    return switch (format[0]) {
        'c' => borrowFixed(i8, .int8, array),
        'C' => borrowFixed(u8, .uint8, array),
        's' => borrowFixed(i16, .int16, array),
        'S' => borrowFixed(u16, .uint16, array),
        'i' => borrowFixed(i32, .int32, array),
        'I' => borrowFixed(u32, .uint32, array),
        'l' => borrowFixed(i64, .int64, array),
        'L' => borrowFixed(u64, .uint64, array),
        'f' => borrowFixed(f32, .float32, array),
        'g' => borrowFixed(f64, .float64, array),
        'b' => borrowBoolean(array),
        'z' => borrowVariable(.binary, array),
        'u' => borrowVariable(.utf8, array),
        else => error.UnsupportedType,
    };
}

fn borrowFixed(comptime T: type, comptime tag: std.meta.Tag(record_batch.ArrayView), array: *const c.ArrowArray) ImportError!record_batch.ArrayView {
    primitive.checkType(T);
    const common = try validateCommon(array, 2);
    const values = try typedBuffer(T, common.buffers[1], common.end);
    const view: primitive.PrimitiveView(T) = .{
        .values = values,
        .validity = common.validity,
        .offset = common.offset,
        .len = common.len,
    };
    return @unionInit(record_batch.ArrayView, @tagName(tag), view);
}

fn borrowBoolean(array: *const c.ArrowArray) ImportError!record_batch.ArrayView {
    const common = try validateCommon(array, 2);
    const value_bytes = bitmap.byteLength(common.end);
    const values = try byteBuffer(common.buffers[1], value_bytes);
    return .{ .boolean = .{
        .values = values,
        .validity = common.validity,
        .offset = common.offset,
        .len = common.len,
    } };
}

fn borrowVariable(kind: variable.Kind, array: *const c.ArrowArray) ImportError!record_batch.ArrayView {
    const common = try validateCommon(array, 3);
    const offsets_len = std.math.add(usize, common.end, 1) catch return error.LengthOverflow;
    const offsets = try typedBuffer(i32, common.buffers[1], offsets_len);
    var previous = offsets[common.offset];
    if (previous < 0) return error.InvalidBinaryOffset;
    for (common.offset..common.end) |index| {
        const next = offsets[index + 1];
        if (next < previous) return error.InvalidBinaryOffset;
        previous = next;
    }
    const data_len: usize = @intCast(previous);
    const data = try byteBuffer(common.buffers[2], data_len);
    const view: variable.VariableBinaryView = .{
        .offsets = offsets,
        .data = data,
        .validity = common.validity,
        .offset = common.offset,
        .len = common.len,
        .kind = kind,
    };
    if (kind == .utf8) {
        for (0..common.len) |index| {
            if (common.validity.len != 0 and !bitmap.isSet(common.validity, common.offset + index)) continue;
            const value = view.get(index) catch unreachable;
            if (!std.unicode.utf8ValidateSlice(value.?)) return error.InvalidUtf8;
        }
    }
    return if (kind == .binary) .{ .binary = view } else .{ .utf8 = view };
}

fn validateCommon(array: *const c.ArrowArray, expected_buffers: i64) ImportError!Common {
    if (array.length < 0) return error.InvalidLength;
    if (array.offset < 0) return error.InvalidOffset;
    if (array.null_count < -1 or array.null_count > array.length) return error.InvalidNullCount;
    if (array.n_buffers != expected_buffers) return error.InvalidBufferCount;
    const buffers = array.buffers orelse return error.MissingBuffers;
    const len = std.math.cast(usize, array.length) orelse return error.LengthOverflow;
    const offset = std.math.cast(usize, array.offset) orelse return error.LengthOverflow;
    const end = std.math.add(usize, offset, len) catch return error.LengthOverflow;
    const validity_len = bitmap.byteLength(end);
    const validity = if (buffers[0]) |pointer|
        try byteBuffer(pointer, validity_len)
    else blk: {
        if (array.null_count != 0) return error.MissingValidity;
        break :blk &.{};
    };
    if (array.null_count >= 0 and validity.len != 0) {
        var actual: i64 = 0;
        for (0..len) |index| actual += @intFromBool(!bitmap.isSet(validity, offset + index));
        if (actual != array.null_count) return error.InvalidNullCount;
    }
    return .{ .buffers = buffers, .validity = validity, .offset = offset, .len = len, .end = end };
}

fn byteBuffer(pointer: ?*const anyopaque, len: usize) ImportError![]const u8 {
    if (len == 0) return &.{};
    const present = pointer orelse return error.MissingValues;
    const bytes: [*]const u8 = @ptrCast(present);
    return bytes[0..len];
}

fn typedBuffer(comptime T: type, pointer: ?*const anyopaque, len: usize) ImportError![]const T {
    if (len == 0) return &.{};
    if (len > std.math.maxInt(usize) / @sizeOf(T)) return error.LengthOverflow;
    const present = pointer orelse return error.MissingValues;
    if (@intFromPtr(present) % @alignOf(T) != 0) return error.MisalignedBuffer;
    const values: [*]const T = @ptrCast(@alignCast(present));
    return values[0..len];
}

fn noOpArrayRelease(array: *c.ArrowArray) callconv(.c) void {
    array.release = null;
}

fn noOpSchemaRelease(schema: *c.ArrowSchema) callconv(.c) void {
    schema.release = null;
}

const ReleaseCounts = struct {
    arrays: usize = 0,
    schemas: usize = 0,
};

fn countArrayRelease(array: *c.ArrowArray) callconv(.c) void {
    const counts: *ReleaseCounts = @ptrCast(@alignCast(array.private_data.?));
    counts.arrays += 1;
    array.* = .{};
}

fn countSchemaRelease(schema: *c.ArrowSchema) callconv(.c) void {
    const counts: *ReleaseCounts = @ptrCast(@alignCast(schema.private_data.?));
    counts.schemas += 1;
    schema.* = .{};
}

test "take validates before move, relocates explicitly and releases exactly once" {
    const values = [_]i32{ 20, 21 };
    var buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var counts: ReleaseCounts = .{};
    var array: c.ArrowArray = .{
        .length = 2,
        .n_buffers = 2,
        .buffers = &buffers,
        .release = countArrayRelease,
        .private_data = &counts,
    };
    var schema: c.ArrowSchema = .{
        .format = "i",
        .release = countSchemaRelease,
        .private_data = &counts,
    };
    var imported = try ImportedArray.take(&array, &schema);
    try std.testing.expect(array.release == null and schema.release == null);
    try std.testing.expectEqual(@as(?i32, 21), try (try imported.borrow()).int32.get(1));
    try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr((try imported.borrow()).int32.values.ptr));

    var moved = imported.move();
    try std.testing.expectError(error.Released, imported.borrow());
    imported.deinit();
    try std.testing.expectEqual(@as(usize, 0), counts.arrays);
    try std.testing.expectEqual(@as(usize, 0), counts.schemas);
    moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), counts.arrays);
    try std.testing.expectEqual(@as(usize, 1), counts.schemas);
    moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), counts.arrays);
    try std.testing.expectEqual(@as(usize, 1), counts.schemas);
    try std.testing.expectError(error.Released, moved.borrow());
}

test "take failure preserves both producer owners" {
    const values = [_]i32{1};
    var buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var counts: ReleaseCounts = .{};
    var array: c.ArrowArray = .{
        .length = 1,
        .n_buffers = 1,
        .buffers = &buffers,
        .release = countArrayRelease,
        .private_data = &counts,
    };
    var schema: c.ArrowSchema = .{
        .format = "i",
        .release = countSchemaRelease,
        .private_data = &counts,
    };
    try std.testing.expectError(error.InvalidBufferCount, ImportedArray.take(&array, &schema));
    try std.testing.expect(array.release != null and schema.release != null);
    c.releaseArray(&array);
    c.releaseSchema(&schema);
    try std.testing.expectEqual(@as(usize, 1), counts.arrays);
    try std.testing.expectEqual(@as(usize, 1), counts.schemas);
}

test "borrow all leaf layouts, omitted validity, offsets and zero-copy addresses" {
    const values = [_]i32{ 10, 11, 12, 13 };
    var fixed_buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var array: c.ArrowArray = .{
        .length = 2,
        .offset = 1,
        .n_buffers = 2,
        .buffers = &fixed_buffers,
        .release = noOpArrayRelease,
    };
    var schema: c.ArrowSchema = .{ .format = "i", .release = noOpSchemaRelease };
    const fixed = (try borrowArray(&array, &schema)).int32;
    try std.testing.expectEqual(@as(?i32, 11), try fixed.get(0));
    try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr(fixed.values.ptr));
    try std.testing.expect(array.release != null and schema.release != null);

    const bool_values = [_]u8{0b00000101};
    var bool_buffers = [_]?*const anyopaque{ null, @ptrCast(&bool_values) };
    array = .{ .length = 3, .n_buffers = 2, .buffers = &bool_buffers, .release = noOpArrayRelease };
    schema.format = "b";
    const booleans = (try borrowArray(&array, &schema)).boolean;
    try std.testing.expectEqual(@as(?bool, true), try booleans.get(0));
    try std.testing.expectEqual(@as(?bool, false), try booleans.get(1));

    const offsets = [_]i32{ 0, 0, 3, 9 };
    const data = "abc数据";
    var variable_buffers = [_]?*const anyopaque{ null, @ptrCast(&offsets), @ptrCast(data.ptr) };
    array = .{ .length = 2, .offset = 1, .n_buffers = 3, .buffers = &variable_buffers, .release = noOpArrayRelease };
    schema.format = "u";
    const strings = (try borrowArray(&array, &schema)).utf8;
    try std.testing.expectEqualStrings("abc", (try strings.get(0)).?);
    try std.testing.expectEqualStrings("数据", (try strings.get(1)).?);
    try std.testing.expectEqual(@intFromPtr(&offsets), @intFromPtr(strings.offsets.ptr));
    try std.testing.expectEqual(@intFromPtr(data.ptr), @intFromPtr(strings.data.ptr));
}

test "borrow validates null bitmap and malformed metadata without release" {
    const values = [_]i16{ 3, 4, 5 };
    const validity = [_]u8{0b00000101};
    var buffers = [_]?*const anyopaque{ @ptrCast(&validity), @ptrCast(&values) };
    var array: c.ArrowArray = .{
        .length = 3,
        .null_count = -1,
        .n_buffers = 2,
        .buffers = &buffers,
        .release = noOpArrayRelease,
    };
    var schema: c.ArrowSchema = .{ .format = "s", .release = noOpSchemaRelease };
    const view = (try borrowArray(&array, &schema)).int16;
    try std.testing.expectEqual(@as(?i16, null), try view.get(1));
    array.null_count = 1;
    _ = try borrowArray(&array, &schema);
    array.null_count = 2;
    try std.testing.expectError(error.InvalidNullCount, borrowArray(&array, &schema));
    try std.testing.expect(array.release != null and schema.release != null);

    array.null_count = 0;
    array.length = -1;
    try std.testing.expectError(error.InvalidLength, borrowArray(&array, &schema));
    array.length = 3;
    array.offset = -1;
    try std.testing.expectError(error.InvalidOffset, borrowArray(&array, &schema));
    array.offset = 0;
    array.n_buffers = 3;
    try std.testing.expectError(error.InvalidBufferCount, borrowArray(&array, &schema));
    array.n_buffers = 2;
    schema.format = "+s";
    try std.testing.expectError(error.UnsupportedType, borrowArray(&array, &schema));
    schema.format = "s";
    buffers[0] = null;
    array.null_count = -1;
    try std.testing.expectError(error.MissingValidity, borrowArray(&array, &schema));
    array.null_count = 0;
    buffers[1] = null;
    try std.testing.expectError(error.MissingValues, borrowArray(&array, &schema));
    buffers[1] = @ptrCast(&values);
    schema.format = "l";
    array.length = std.math.maxInt(i64);
    try std.testing.expectError(error.LengthOverflow, borrowArray(&array, &schema));
    array.length = 3;
    schema.release = null;
    try std.testing.expectError(error.Released, borrowArray(&array, &schema));
}

test "borrow rejects malformed variable offsets, UTF-8, pointers and nesting" {
    var offsets = [_]i32{ 0, 2, 1 };
    const data = [_]u8{ 0xc0, 0x80 };
    var buffers = [_]?*const anyopaque{ null, @ptrCast(&offsets), @ptrCast(&data) };
    var array: c.ArrowArray = .{ .length = 2, .n_buffers = 3, .buffers = &buffers, .release = noOpArrayRelease };
    var schema: c.ArrowSchema = .{ .format = "z", .release = noOpSchemaRelease };
    try std.testing.expectError(error.InvalidBinaryOffset, borrowArray(&array, &schema));
    offsets = .{ 0, 2, 2 };
    schema.format = "u";
    try std.testing.expectError(error.InvalidUtf8, borrowArray(&array, &schema));
    buffers[1] = @ptrFromInt(@intFromPtr(&offsets) + 1);
    try std.testing.expectError(error.MisalignedBuffer, borrowArray(&array, &schema));
    buffers[1] = @ptrCast(&offsets);
    array.n_children = 1;
    try std.testing.expectError(error.NestedTypeUnsupported, borrowArray(&array, &schema));
    array.n_children = 0;
    array.dictionary = &array;
    try std.testing.expectError(error.DictionaryUnsupported, borrowArray(&array, &schema));
}

fn recursiveScenario(allocator: std.mem.Allocator) !void {
    const values = [_]i32{ 40, 41, 42, 43 };
    const outer_validity = [_]u8{0b00001101};
    const inner_validity = [_]u8{0b00001011};
    var leaf_buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var inner_buffers = [_]?*const anyopaque{@ptrCast(&inner_validity)};
    var outer_buffers = [_]?*const anyopaque{@ptrCast(&outer_validity)};
    var leaf_array: c.ArrowArray = .{ .length = 4, .n_buffers = 2, .buffers = &leaf_buffers, .release = noOpArrayRelease };
    var inner_array_children = [_]?*c.ArrowArray{&leaf_array};
    var inner_array: c.ArrowArray = .{ .length = 4, .null_count = 1, .n_buffers = 1, .n_children = 1, .buffers = &inner_buffers, .children = &inner_array_children, .release = noOpArrayRelease };
    var outer_array_children = [_]?*c.ArrowArray{&inner_array};
    var counts: ReleaseCounts = .{};
    var array: c.ArrowArray = .{ .length = 2, .offset = 1, .null_count = 1, .n_buffers = 1, .n_children = 1, .buffers = &outer_buffers, .children = &outer_array_children, .release = countArrayRelease, .private_data = &counts };

    var leaf_schema: c.ArrowSchema = .{ .format = "i", .release = noOpSchemaRelease };
    var inner_schema_children = [_]?*c.ArrowSchema{&leaf_schema};
    var inner_schema: c.ArrowSchema = .{ .format = "+s", .n_children = 1, .children = &inner_schema_children, .release = noOpSchemaRelease };
    var outer_schema_children = [_]?*c.ArrowSchema{&inner_schema};
    var schema: c.ArrowSchema = .{ .format = "+s", .n_children = 1, .children = &outer_schema_children, .release = countSchemaRelease, .private_data = &counts };

    var owner = ImportedStruct.take(allocator, &array, &schema) catch |err| {
        try std.testing.expect(array.release != null and schema.release != null);
        try std.testing.expectEqual(@as(usize, 0), counts.arrays);
        try std.testing.expectEqual(@as(usize, 0), counts.schemas);
        c.releaseArray(&array);
        c.releaseSchema(&schema);
        try std.testing.expectEqual(@as(usize, 1), counts.arrays);
        try std.testing.expectEqual(@as(usize, 1), counts.schemas);
        return err;
    };
    try std.testing.expect(array.release == null and schema.release == null);
    const outer = (try owner.borrow()).struct_;
    try std.testing.expectEqual(@as(usize, 1), outer.null_count);
    try std.testing.expect(!(try outer.isValid(0)));
    try std.testing.expect(try outer.isValid(1));
    const inner = (try outer.child(0)).struct_;
    try std.testing.expectEqual(@as(usize, 1), inner.null_count);
    const ints = (try inner.child(0)).int32;
    try std.testing.expectEqual(@as(?i32, 41), try ints.get(0));
    try std.testing.expectEqual(@as(?i32, 42), try ints.get(1));
    try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr(ints.values.ptr));
    var moved = owner.move();
    try std.testing.expectError(error.Released, owner.borrow());
    owner.deinit();
    moved.deinit();
    moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), counts.arrays);
    try std.testing.expectEqual(@as(usize, 1), counts.schemas);
}

test "recursive struct import is zero-copy and all allocation failures preserve both bases" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, recursiveScenario, .{});
}

test "recursive struct validates descendant layouts without moving either base" {
    const values = [_]i32{1};
    var leaf_buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var root_buffers = [_]?*const anyopaque{null};
    var child: c.ArrowArray = .{ .length = 1, .n_buffers = 2, .buffers = &leaf_buffers, .release = noOpArrayRelease };
    var children = [_]?*c.ArrowArray{&child};
    var array: c.ArrowArray = .{ .length = 1, .n_buffers = 1, .n_children = 1, .buffers = &root_buffers, .children = &children, .release = noOpArrayRelease };
    var child_schema: c.ArrowSchema = .{ .format = "i", .release = noOpSchemaRelease };
    var schemas = [_]?*c.ArrowSchema{&child_schema};
    var schema: c.ArrowSchema = .{ .format = "+s", .n_children = 1, .children = &schemas, .release = noOpSchemaRelease };
    child.length = 0;
    try std.testing.expectError(error.ChildTooShort, ImportedStruct.take(std.testing.allocator, &array, &schema));
    child.length = 1;
    children[0] = null;
    try std.testing.expectError(error.MissingChild, ImportedStruct.take(std.testing.allocator, &array, &schema));
    children[0] = &child;
    schema.n_children = 2;
    try std.testing.expectError(error.InvalidChildCount, ImportedStruct.take(std.testing.allocator, &array, &schema));
    schema.n_children = 1;
    array.children = null;
    try std.testing.expectError(error.MissingChildren, ImportedStruct.take(std.testing.allocator, &array, &schema));
    array.children = &children;
    array.n_buffers = 2;
    try std.testing.expectError(error.InvalidBufferCount, ImportedStruct.take(std.testing.allocator, &array, &schema));
    array.n_buffers = 1;
    array.null_count = 1;
    try std.testing.expectError(error.MissingValidity, ImportedStruct.take(std.testing.allocator, &array, &schema));
    array.null_count = 0;
    child.n_buffers = 1;
    try std.testing.expectError(error.InvalidBufferCount, ImportedStruct.take(std.testing.allocator, &array, &schema));
    child.n_buffers = 2;
    child.dictionary = &child;
    try std.testing.expectError(error.DictionaryUnsupported, ImportedStruct.take(std.testing.allocator, &array, &schema));
    try std.testing.expect(array.release != null and schema.release != null);

    var empty_array: c.ArrowArray = .{ .length = 3, .n_buffers = 1, .buffers = &root_buffers, .release = noOpArrayRelease };
    var empty_schema: c.ArrowSchema = .{ .format = "+s", .release = noOpSchemaRelease };
    var empty = try ImportedStruct.take(std.testing.allocator, &empty_array, &empty_schema);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 3), (try empty.borrow()).struct_.len);
    try std.testing.expectEqual(@as(usize, 0), (try empty.borrow()).struct_.children.len);
}

fn writeTestMetadata(bytes: []u8, key: []const u8, value: []const u8) void {
    var cursor: usize = 0;
    const one: i32 = 1;
    const key_len: i32 = @intCast(key.len);
    const value_len: i32 = @intCast(value.len);
    inline for (.{ std.mem.asBytes(&one), std.mem.asBytes(&key_len), key, std.mem.asBytes(&value_len), value }) |part| {
        @memcpy(bytes[cursor .. cursor + part.len], part);
        cursor += part.len;
    }
}

fn batchImportScenario(allocator: std.mem.Allocator) !void {
    const values = [_]i32{ 10, 11, 12 };
    var leaf_buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var root_buffers = [_]?*const anyopaque{null};
    var child: c.ArrowArray = .{ .length = 3, .n_buffers = 2, .buffers = &leaf_buffers, .release = noOpArrayRelease };
    var array_children = [_]?*c.ArrowArray{&child};
    var counts: ReleaseCounts = .{};
    var array: c.ArrowArray = .{ .length = 2, .offset = 1, .n_buffers = 1, .n_children = 1, .buffers = &root_buffers, .children = &array_children, .release = countArrayRelease, .private_data = &counts };

    var field_metadata: [4 + 4 + 4 + 4 + 3]u8 = undefined;
    writeTestMetadata(&field_metadata, &.{ 0, 'k', 0, 'y' }, &.{ 'v', 0, 0xff });
    var schema_metadata: [4 + 4 + 6 + 4 + 6]u8 = undefined;
    writeTestMetadata(&schema_metadata, "source", "native");
    var name: [6:0]u8 = "数据".*;
    var child_schema: c.ArrowSchema = .{ .format = "i", .name = &name, .metadata = &field_metadata, .flags = 0, .release = noOpSchemaRelease };
    var schema_children = [_]?*c.ArrowSchema{&child_schema};
    var schema: c.ArrowSchema = .{ .format = "+s", .metadata = &schema_metadata, .n_children = 1, .children = &schema_children, .release = countSchemaRelease, .private_data = &counts };

    var owner = ImportedRecordBatch.take(allocator, &array, &schema) catch |err| {
        try std.testing.expect(array.release != null and schema.release != null);
        try std.testing.expectEqual(@as(usize, 0), counts.arrays);
        try std.testing.expectEqual(@as(usize, 0), counts.schemas);
        c.releaseArray(&array);
        c.releaseSchema(&schema);
        return err;
    };
    name[0] = 'x';
    field_metadata[12] = 'x';
    schema_metadata[14] = 'x';
    const batch = try owner.borrow();
    try std.testing.expectEqual(@as(usize, 2), batch.row_count);
    try std.testing.expectEqualStrings("数据", batch.schema.fields[0].name);
    try std.testing.expectEqualSlices(u8, &.{ 0, 'k', 0, 'y' }, batch.schema.fields[0].metadata[0].key);
    try std.testing.expectEqualSlices(u8, &.{ 'v', 0, 0xff }, batch.schema.fields[0].metadata[0].value);
    try std.testing.expectEqualStrings("source", batch.schema.metadata[0].key);
    try std.testing.expectEqualStrings("native", batch.schema.metadata[0].value);
    const ints = (try batch.column(0)).int32;
    try std.testing.expectEqual(@as(?i32, 11), try ints.get(0));
    try std.testing.expectEqual(@intFromPtr(&values), @intFromPtr(ints.values.ptr));

    var moved = owner.move();
    try std.testing.expectError(error.Released, owner.borrow());
    owner.deinit();
    moved.deinit();
    moved.deinit();
    try std.testing.expectEqual(@as(usize, 1), counts.arrays);
    try std.testing.expectEqual(@as(usize, 1), counts.schemas);
}

test "record batch schema import deep copies metadata and rolls back every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, batchImportScenario, .{});
}

test "record batch schema import rejects lost row validity, flags and malformed metadata before move" {
    var root_buffers = [_]?*const anyopaque{null};
    var array: c.ArrowArray = .{ .length = 1, .null_count = 1, .n_buffers = 1, .buffers = &root_buffers, .release = noOpArrayRelease };
    var schema: c.ArrowSchema = .{ .format = "+s", .release = noOpSchemaRelease };
    try std.testing.expectError(error.MissingValidity, ImportedRecordBatch.take(std.testing.allocator, &array, &schema));
    const invalid = [_]u8{0};
    root_buffers[0] = @ptrCast(&invalid);
    try std.testing.expectError(error.InvalidBatchValidity, ImportedRecordBatch.take(std.testing.allocator, &array, &schema));
    array.null_count = 0;
    root_buffers[0] = null;
    schema.flags = 2;
    try std.testing.expectError(error.InvalidFlags, ImportedRecordBatch.take(std.testing.allocator, &array, &schema));
    schema.flags = 0;
    var negative_count: i32 = -1;
    schema.metadata = std.mem.asBytes(&negative_count).ptr;
    try std.testing.expectError(error.InvalidMetadata, ImportedRecordBatch.take(std.testing.allocator, &array, &schema));
    try std.testing.expect(array.release != null and schema.release != null);
}

test "record batch schema import preserves zero columns and duplicate field order" {
    var root_buffers = [_]?*const anyopaque{null};
    var empty_array: c.ArrowArray = .{ .length = 5, .n_buffers = 1, .buffers = &root_buffers, .release = noOpArrayRelease };
    var empty_schema: c.ArrowSchema = .{ .format = "+s", .release = noOpSchemaRelease };
    var empty = try ImportedRecordBatch.take(std.testing.allocator, &empty_array, &empty_schema);
    defer empty.deinit();
    const empty_batch = try empty.borrow();
    try std.testing.expectEqual(@as(usize, 5), empty_batch.row_count);
    try std.testing.expectEqual(@as(usize, 0), empty_batch.schema.fields.len);

    const values = [_]i8{ 1, 2 };
    var child_buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var child: c.ArrowArray = .{ .length = 2, .n_buffers = 2, .buffers = &child_buffers, .release = noOpArrayRelease };
    var array_children = [_]?*c.ArrowArray{ &child, &child };
    var array: c.ArrowArray = .{ .length = 2, .n_buffers = 1, .n_children = 2, .buffers = &root_buffers, .children = &array_children, .release = noOpArrayRelease };
    var first: c.ArrowSchema = .{ .format = "c", .name = "x", .release = noOpSchemaRelease };
    var second: c.ArrowSchema = .{ .format = "c", .name = "x", .release = noOpSchemaRelease };
    var schema_children = [_]?*c.ArrowSchema{ &first, &second };
    var schema: c.ArrowSchema = .{ .format = "+s", .n_children = 2, .children = &schema_children, .release = noOpSchemaRelease };
    var duplicate = try ImportedRecordBatch.take(std.testing.allocator, &array, &schema);
    defer duplicate.deinit();
    const batch = try duplicate.borrow();
    try std.testing.expectEqual(@as(usize, 2), batch.schema.fields.len);
    try std.testing.expectEqual(@as(?usize, 0), batch.schema.fieldIndex("x"));
    try std.testing.expectEqual(@as(?i8, 2), try (try batch.column(1)).int8.get(1));
}
