const std = @import("std");
const primitive = @import("primitive.zig");
const boolean = @import("boolean.zig");
const variable = @import("variable_binary.zig");
const schema_mod = @import("schema.zig");

pub const ArrayView = union(enum) {
    int8: primitive.PrimitiveView(i8),
    uint8: primitive.PrimitiveView(u8),
    int16: primitive.PrimitiveView(i16),
    uint16: primitive.PrimitiveView(u16),
    int32: primitive.PrimitiveView(i32),
    uint32: primitive.PrimitiveView(u32),
    int64: primitive.PrimitiveView(i64),
    uint64: primitive.PrimitiveView(u64),
    float32: primitive.PrimitiveView(f32),
    float64: primitive.PrimitiveView(f64),
    boolean: boolean.BooleanView,
    binary: variable.VariableBinaryView,
    utf8: variable.VariableBinaryView,

    pub fn fromPrimitive(comptime T: type, array: *const primitive.PrimitiveArray(T)) ArrayView {
        primitive.checkType(T);
        if (T == i8) return .{ .int8 = array.view() };
        if (T == u8) return .{ .uint8 = array.view() };
        if (T == i16) return .{ .int16 = array.view() };
        if (T == u16) return .{ .uint16 = array.view() };
        if (T == i32) return .{ .int32 = array.view() };
        if (T == u32) return .{ .uint32 = array.view() };
        if (T == i64) return .{ .int64 = array.view() };
        if (T == u64) return .{ .uint64 = array.view() };
        if (T == f32) return .{ .float32 = array.view() };
        if (T == f64) return .{ .float64 = array.view() };
        unreachable;
    }

    pub fn fromBoolean(array: *const boolean.BooleanArray) ArrayView {
        return .{ .boolean = array.view() };
    }

    pub fn fromVariable(array: *const variable.VariableBinaryArray) ArrayView {
        return switch (array.kind) {
            .binary => .{ .binary = array.view() },
            .utf8 => .{ .utf8 = array.view() },
        };
    }

    pub fn dataType(self: ArrayView) schema_mod.DataType {
        return switch (self) {
            .int8 => .int8,
            .uint8 => .uint8,
            .int16 => .int16,
            .uint16 => .uint16,
            .int32 => .int32,
            .uint32 => .uint32,
            .int64 => .int64,
            .uint64 => .uint64,
            .float32 => .float32,
            .float64 => .float64,
            .boolean => .boolean,
            .binary => .binary,
            .utf8 => .utf8,
        };
    }

    pub fn len(self: ArrayView) usize {
        return switch (self) {
            inline else => |view| view.len,
        };
    }
};

/// Validated borrowed batch. Schema, columns and their arrays must outlive it.
pub const RecordBatch = struct {
    schema: *const schema_mod.Schema,
    columns: []const ArrayView,
    row_count: usize,

    pub fn init(schema: *const schema_mod.Schema, columns: []const ArrayView, row_count: usize) !RecordBatch {
        if (columns.len != schema.fields.len) return error.ColumnCountMismatch;
        for (columns, schema.fields) |array_view, field| {
            if (array_view.dataType() != field.data_type) return error.ColumnTypeMismatch;
            if (array_view.len() != row_count) return error.ColumnLengthMismatch;
        }
        return .{ .schema = schema, .columns = columns, .row_count = row_count };
    }

    pub fn column(self: RecordBatch, index: usize) error{OutOfBounds}!ArrayView {
        if (index >= self.columns.len) return error.OutOfBounds;
        return self.columns[index];
    }

    pub fn columnByName(self: RecordBatch, name: []const u8) error{FieldNotFound}!ArrayView {
        const index = self.schema.fieldIndex(name) orelse return error.FieldNotFound;
        return self.columns[index];
    }
};

test "all implemented native types map to exact schema types" {
    inline for (.{ i8, u8, i16, u16, i32, u32, i64, u64, f32, f64 }) |T| {
        var array: primitive.PrimitiveArray(T) = .{ .allocator = std.testing.allocator };
        defer array.deinit();
        const view = ArrayView.fromPrimitive(T, &array);
        try std.testing.expectEqual(@as(usize, 0), view.len());
    }
    var bool_array: boolean.BooleanArray = .{ .allocator = std.testing.allocator };
    defer bool_array.deinit();
    try std.testing.expectEqual(schema_mod.DataType.boolean, ArrayView.fromBoolean(&bool_array).dataType());
    var binary_array: variable.VariableBinaryArray = .{ .allocator = std.testing.allocator, .kind = .binary };
    defer binary_array.deinit();
    var utf8_array: variable.VariableBinaryArray = .{ .allocator = std.testing.allocator, .kind = .utf8 };
    defer utf8_array.deinit();
    try std.testing.expectEqual(schema_mod.DataType.binary, ArrayView.fromVariable(&binary_array).dataType());
    try std.testing.expectEqual(schema_mod.DataType.utf8, ArrayView.fromVariable(&utf8_array).dataType());
}

test "record batch validates count, type, length and lookup" {
    var id_builder = primitive.PrimitiveBuilder(i32).init(std.testing.allocator);
    defer id_builder.deinit();
    var name_builder = variable.Utf8Builder.init(std.testing.allocator);
    defer name_builder.deinit();
    var active_builder = boolean.BooleanBuilder.init(std.testing.allocator);
    defer active_builder.deinit();
    for (0..3) |i| {
        try id_builder.append(@intCast(i));
        try name_builder.append(if (i == 1) null else "zig");
        try active_builder.append(i % 2 == 0);
    }
    var ids = id_builder.finish();
    defer ids.deinit();
    var names = name_builder.finish();
    defer names.deinit();
    var active = active_builder.finish();
    defer active.deinit();
    var schema = try schema_mod.Schema.init(std.testing.allocator, &.{
        .{ .name = "id", .data_type = .int32, .nullable = false },
        .{ .name = "name", .data_type = .utf8 },
        .{ .name = "active", .data_type = .boolean },
    }, &.{});
    defer schema.deinit();
    const columns = [_]ArrayView{
        .fromPrimitive(i32, &ids),
        .fromVariable(&names),
        .fromBoolean(&active),
    };
    const batch = try RecordBatch.init(&schema, &columns, 3);
    try std.testing.expectEqual(@as(usize, 3), batch.row_count);
    try std.testing.expectEqual(schema_mod.DataType.utf8, (try batch.columnByName("name")).dataType());
    try std.testing.expectError(error.OutOfBounds, batch.column(3));
    try std.testing.expectError(error.FieldNotFound, batch.columnByName("missing"));
    try std.testing.expectError(error.ColumnCountMismatch, RecordBatch.init(&schema, columns[0..2], 3));
    const wrong_type = [_]ArrayView{ columns[1], columns[1], columns[2] };
    try std.testing.expectError(error.ColumnTypeMismatch, RecordBatch.init(&schema, &wrong_type, 3));
    try std.testing.expectError(error.ColumnLengthMismatch, RecordBatch.init(&schema, &columns, 2));
    try std.testing.expectEqual(@intFromPtr(ids.values.items.ptr), @intFromPtr(columns[0].int32.values.ptr));
}

test "zero-column record batches preserve an explicit row count" {
    var schema = try schema_mod.Schema.init(std.testing.allocator, &.{}, &.{});
    defer schema.deinit();
    const batch = try RecordBatch.init(&schema, &.{}, 42);
    try std.testing.expectEqual(@as(usize, 42), batch.row_count);
    try std.testing.expectEqual(@as(usize, 0), batch.columns.len);
}
