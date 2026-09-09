const std = @import("std");
const primitive = @import("primitive.zig");
const boolean = @import("boolean.zig");
const variable = @import("variable_binary.zig");
const schema_mod = @import("schema.zig");
const record = @import("record_batch.zig");
const bitmap = @import("bitmap.zig");

/// Concrete ownership for every implemented native array type. Do not copy.
pub const OwnedArray = union(enum) {
    int8: primitive.PrimitiveArray(i8),
    uint8: primitive.PrimitiveArray(u8),
    int16: primitive.PrimitiveArray(i16),
    uint16: primitive.PrimitiveArray(u16),
    int32: primitive.PrimitiveArray(i32),
    uint32: primitive.PrimitiveArray(u32),
    int64: primitive.PrimitiveArray(i64),
    uint64: primitive.PrimitiveArray(u64),
    float32: primitive.PrimitiveArray(f32),
    float64: primitive.PrimitiveArray(f64),
    boolean: boolean.BooleanArray,
    binary: variable.VariableBinaryArray,
    utf8: variable.VariableBinaryArray,
    struct_: StructArray,

    /// Moves buffers from source and leaves it an empty, valid array.
    pub fn takePrimitive(comptime T: type, source: *primitive.PrimitiveArray(T)) OwnedArray {
        primitive.checkType(T);
        const moved = source.*;
        source.* = .{ .allocator = moved.allocator };
        if (T == i8) return .{ .int8 = moved };
        if (T == u8) return .{ .uint8 = moved };
        if (T == i16) return .{ .int16 = moved };
        if (T == u16) return .{ .uint16 = moved };
        if (T == i32) return .{ .int32 = moved };
        if (T == u32) return .{ .uint32 = moved };
        if (T == i64) return .{ .int64 = moved };
        if (T == u64) return .{ .uint64 = moved };
        if (T == f32) return .{ .float32 = moved };
        if (T == f64) return .{ .float64 = moved };
        unreachable;
    }

    pub fn takeBoolean(source: *boolean.BooleanArray) OwnedArray {
        const moved = source.*;
        source.* = .{ .allocator = moved.allocator };
        return .{ .boolean = moved };
    }

    pub fn takeVariable(source: *variable.VariableBinaryArray) OwnedArray {
        const moved = source.*;
        source.* = .{ .allocator = moved.allocator, .kind = moved.kind };
        return switch (moved.kind) {
            .binary => .{ .binary = moved },
            .utf8 => .{ .utf8 = moved },
        };
    }

    pub fn deinit(self: *OwnedArray) void {
        switch (self.*) {
            inline else => |*array| array.deinit(),
        }
        self.* = undefined;
    }

    pub fn dataType(self: *const OwnedArray) schema_mod.DataType {
        return switch (self.*) {
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
            .struct_ => .struct_,
        };
    }

    pub fn len(self: *const OwnedArray) usize {
        return switch (self.*) {
            inline else => |array| array.len(),
        };
    }

    pub fn view(self: *const OwnedArray) record.ArrayView {
        return switch (self.*) {
            .int8 => |*array| .fromPrimitive(i8, array),
            .uint8 => |*array| .fromPrimitive(u8, array),
            .int16 => |*array| .fromPrimitive(i16, array),
            .uint16 => |*array| .fromPrimitive(u16, array),
            .int32 => |*array| .fromPrimitive(i32, array),
            .uint32 => |*array| .fromPrimitive(u32, array),
            .int64 => |*array| .fromPrimitive(i64, array),
            .uint64 => |*array| .fromPrimitive(u64, array),
            .float32 => |*array| .fromPrimitive(f32, array),
            .float64 => |*array| .fromPrimitive(f64, array),
            .boolean => |*array| .fromBoolean(array),
            .binary, .utf8 => |*array| .fromVariable(array),
            .struct_ => |*array| .{ .struct_ = array.view() },
        };
    }

    pub fn matchesField(self: *const OwnedArray, field: schema_mod.Field) bool {
        return self.view().matchesField(field);
    }
};

/// Owns its packed parent validity, view descriptors and recursive child arrays.
pub const StructArray = struct {
    allocator: std.mem.Allocator,
    validity: []u8,
    children: []OwnedArray,
    child_views: []record.ArrayView,
    length: usize,
    null_count: usize,

    /// On failure every input child remains owned. Success moves all children.
    pub fn take(
        allocator: std.mem.Allocator,
        input_children: []OwnedArray,
        length: usize,
        row_validity: ?[]const bool,
    ) !StructArray {
        if (length > std.math.maxInt(i64)) return error.LengthOverflow;
        for (input_children) |*child| if (child.len() != length) return error.ChildLengthMismatch;
        if (row_validity) |validity| if (validity.len != length) return error.ValidityLengthMismatch;

        var null_count: usize = 0;
        if (row_validity) |validity| {
            for (validity) |valid| null_count += @intFromBool(!valid);
        }
        const byte_count = if (null_count == 0) 0 else bitmap.byteLength(length);
        const children = try allocator.alloc(OwnedArray, input_children.len);
        errdefer allocator.free(children);
        const child_views = try allocator.alloc(record.ArrayView, input_children.len);
        errdefer allocator.free(child_views);
        const validity = try allocator.alloc(u8, byte_count);
        errdefer allocator.free(validity);
        @memset(validity, 0);
        if (row_validity) |rows| for (rows, 0..) |valid, i| if (byte_count != 0) bitmap.set(validity, i, valid);

        // No fallible work after ownership starts moving.
        for (input_children, 0..) |*child, i| {
            children[i] = child.*;
            child.* = undefined;
            child_views[i] = children[i].view();
        }
        return .{
            .allocator = allocator,
            .validity = validity,
            .children = children,
            .child_views = child_views,
            .length = length,
            .null_count = null_count,
        };
    }

    pub fn deinit(self: *StructArray) void {
        for (self.children) |*child| child.deinit();
        self.allocator.free(self.children);
        self.allocator.free(self.child_views);
        self.allocator.free(self.validity);
        self.* = undefined;
    }

    pub fn len(self: *const StructArray) usize {
        return self.length;
    }

    pub fn view(self: *const StructArray) record.StructView {
        return .{
            .validity = self.validity,
            .children = self.child_views,
            .offset = 0,
            .len = self.length,
            .null_count = self.null_count,
        };
    }
};

/// Heap-backed borrowed view returned from an owning batch.
pub const BatchView = struct {
    allocator: std.mem.Allocator,
    columns: []record.ArrayView,
    batch: record.RecordBatch,

    pub fn deinit(self: *BatchView) void {
        self.allocator.free(self.columns);
        self.* = undefined;
    }
};

/// Owns a schema, heterogeneous column container, and every column's buffers.
pub const OwnedRecordBatch = struct {
    allocator: std.mem.Allocator,
    schema: schema_mod.Schema,
    columns: []OwnedArray,
    row_count: usize,

    /// On failure all inputs remain owned and valid. On success schema and each
    /// input column value are invalidated; the caller retains its outer container.
    pub fn take(
        allocator: std.mem.Allocator,
        schema: *schema_mod.Schema,
        input_columns: []OwnedArray,
        row_count: usize,
    ) !OwnedRecordBatch {
        if (input_columns.len != schema.fields.len) return error.ColumnCountMismatch;
        for (input_columns, schema.fields) |*owned_column, field| {
            if (!owned_column.matchesField(field)) return error.ColumnTypeMismatch;
            if (owned_column.len() != row_count) return error.ColumnLengthMismatch;
        }
        const columns = try allocator.alloc(OwnedArray, input_columns.len);
        for (input_columns, 0..) |*owned_column, i| {
            columns[i] = owned_column.*;
            owned_column.* = undefined;
        }
        const moved_schema = schema.*;
        schema.* = undefined;
        return .{
            .allocator = allocator,
            .schema = moved_schema,
            .columns = columns,
            .row_count = row_count,
        };
    }

    pub fn deinit(self: *OwnedRecordBatch) void {
        for (self.columns) |*owned_column| owned_column.deinit();
        self.allocator.free(self.columns);
        self.schema.deinit();
        self.* = undefined;
    }

    pub fn column(self: *const OwnedRecordBatch, index: usize) error{OutOfBounds}!*const OwnedArray {
        if (index >= self.columns.len) return error.OutOfBounds;
        return &self.columns[index];
    }

    pub fn columnByName(self: *const OwnedRecordBatch, name: []const u8) error{FieldNotFound}!*const OwnedArray {
        const index = self.schema.fieldIndex(name) orelse return error.FieldNotFound;
        return &self.columns[index];
    }

    /// Allocates only the view container; all array buffers remain zero-copy.
    pub fn borrow(self: *const OwnedRecordBatch, allocator: std.mem.Allocator) !BatchView {
        const views = try allocator.alloc(record.ArrayView, self.columns.len);
        errdefer allocator.free(views);
        for (self.columns, views) |*owned_column, *view_item| view_item.* = owned_column.view();
        return .{
            .allocator = allocator,
            .columns = views,
            .batch = try record.RecordBatch.init(&self.schema, views, self.row_count),
        };
    }
};

test "owned arrays move every native type without copying buffers" {
    inline for (.{ i8, u8, i16, u16, i32, u32, i64, u64, f32, f64 }) |T| {
        var builder = primitive.PrimitiveBuilder(T).init(std.testing.allocator);
        defer builder.deinit();
        try builder.append(@as(T, 7));
        var source = builder.finish();
        defer source.deinit();
        const pointer = source.values.items.ptr;
        var owned = OwnedArray.takePrimitive(T, &source);
        defer owned.deinit();
        const expected_type: schema_mod.DataType = if (T == i8) .int8 else if (T == u8) .uint8 else if (T == i16) .int16 else if (T == u16) .uint16 else if (T == i32) .int32 else if (T == u32) .uint32 else if (T == i64) .int64 else if (T == u64) .uint64 else if (T == f32) .float32 else .float64;
        try std.testing.expectEqual(expected_type, owned.dataType());
        try std.testing.expectEqual(@as(usize, 0), source.len());
        const moved_pointer = if (T == i8) owned.int8.values.items.ptr else if (T == u8) owned.uint8.values.items.ptr else if (T == i16) owned.int16.values.items.ptr else if (T == u16) owned.uint16.values.items.ptr else if (T == i32) owned.int32.values.items.ptr else if (T == u32) owned.uint32.values.items.ptr else if (T == i64) owned.int64.values.items.ptr else if (T == u64) owned.uint64.values.items.ptr else if (T == f32) owned.float32.values.items.ptr else owned.float64.values.items.ptr;
        try std.testing.expectEqual(@intFromPtr(pointer), @intFromPtr(moved_pointer));
        try std.testing.expectEqual(@as(usize, 1), owned.len());
    }
    var bool_builder = boolean.BooleanBuilder.init(std.testing.allocator);
    defer bool_builder.deinit();
    try bool_builder.append(true);
    var bool_source = bool_builder.finish();
    defer bool_source.deinit();
    const bool_pointer = bool_source.values.items.ptr;
    var bool_owned = OwnedArray.takeBoolean(&bool_source);
    defer bool_owned.deinit();
    try std.testing.expectEqual(@intFromPtr(bool_pointer), @intFromPtr(bool_owned.view().boolean.values.ptr));

    inline for (.{ variable.Kind.binary, variable.Kind.utf8 }) |kind| {
        var builder = variable.VariableBinaryBuilder.init(std.testing.allocator, kind);
        defer builder.deinit();
        try builder.append("value");
        var source = builder.finish();
        defer source.deinit();
        const pointer = source.data.items.ptr;
        var owned = OwnedArray.takeVariable(&source);
        defer owned.deinit();
        const view = owned.view();
        const moved_pointer = switch (view) {
            .binary => |v| v.data.ptr,
            .utf8 => |v| v.data.ptr,
            else => unreachable,
        };
        try std.testing.expectEqual(@intFromPtr(pointer), @intFromPtr(moved_pointer));
    }
}

fn ownershipScenario(allocator: std.mem.Allocator) !void {
    var schema = try schema_mod.Schema.init(allocator, &.{
        .{ .name = "id", .data_type = .int32, .nullable = false },
        .{ .name = "name", .data_type = .utf8 },
    }, &.{.{ .key = "owner", .value = "arrowz" }});
    var schema_live = true;
    defer if (schema_live) schema.deinit();

    var id_builder = primitive.PrimitiveBuilder(i32).init(allocator);
    defer id_builder.deinit();
    var name_builder = variable.Utf8Builder.init(allocator);
    defer name_builder.deinit();
    for (0..2) |i| {
        try id_builder.append(@intCast(i));
        try name_builder.append(if (i == 0) "zero" else "one");
    }
    var ids = id_builder.finish();
    defer ids.deinit();
    var names = name_builder.finish();
    defer names.deinit();
    const id_pointer = ids.values.items.ptr;
    var inputs = [_]OwnedArray{
        .takePrimitive(i32, &ids),
        .takeVariable(&names),
    };
    var inputs_live = true;
    defer if (inputs_live) for (&inputs) |*column| column.deinit();

    var batch = OwnedRecordBatch.take(allocator, &schema, &inputs, 2) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), schema.fields.len);
        try std.testing.expectEqual(schema_mod.DataType.int32, inputs[0].dataType());
        try std.testing.expectEqual(@as(usize, 2), inputs[1].len());
        return err;
    };
    schema_live = false;
    inputs_live = false;
    defer batch.deinit();
    try std.testing.expectEqual(schema_mod.DataType.utf8, (try batch.columnByName("name")).dataType());
    try std.testing.expectError(error.OutOfBounds, batch.column(2));
    var borrowed = try batch.borrow(allocator);
    defer borrowed.deinit();
    try std.testing.expectEqual(@intFromPtr(id_pointer), @intFromPtr(borrowed.columns[0].int32.values.ptr));
    try std.testing.expectEqual(@as(usize, 2), borrowed.batch.row_count);
}

test "owning batch transfer and borrow survive every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, ownershipScenario, .{});
}

test "owning batch validation errors preserve every input owner" {
    var builder = primitive.PrimitiveBuilder(i32).init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(1);
    var array = builder.finish();
    defer array.deinit();
    var column = OwnedArray.takePrimitive(i32, &array);
    defer column.deinit();
    var schema = try schema_mod.Schema.init(std.testing.allocator, &.{.{ .name = "x", .data_type = .int32 }}, &.{});
    defer schema.deinit();
    try std.testing.expectError(error.ColumnCountMismatch, OwnedRecordBatch.take(std.testing.allocator, &schema, &.{}, 1));
    try std.testing.expectEqual(@as(usize, 1), schema.fields.len);
    try std.testing.expectError(error.ColumnLengthMismatch, OwnedRecordBatch.take(std.testing.allocator, &schema, @as(*[1]OwnedArray, &column), 2));
    try std.testing.expectEqual(@as(usize, 1), schema.fields.len);
    try std.testing.expectEqual(@as(usize, 1), column.len());

    var wrong_builder = primitive.PrimitiveBuilder(i64).init(std.testing.allocator);
    defer wrong_builder.deinit();
    try wrong_builder.append(1);
    var wrong_array = wrong_builder.finish();
    defer wrong_array.deinit();
    var wrong_column = OwnedArray.takePrimitive(i64, &wrong_array);
    defer wrong_column.deinit();
    try std.testing.expectError(error.ColumnTypeMismatch, OwnedRecordBatch.take(std.testing.allocator, &schema, @as(*[1]OwnedArray, &wrong_column), 1));
    try std.testing.expectEqual(schema_mod.DataType.int64, wrong_column.dataType());
}

fn structAllocationScenario(allocator: std.mem.Allocator) !void {
    var id_builder = primitive.PrimitiveBuilder(i32).init(allocator);
    defer id_builder.deinit();
    var name_builder = variable.Utf8Builder.init(allocator);
    defer name_builder.deinit();
    for (0..3) |i| {
        try id_builder.append(@intCast(i + 10));
        try name_builder.append(if (i == 1) null else "zig");
    }
    var ids = id_builder.finish();
    defer ids.deinit();
    var names = name_builder.finish();
    defer names.deinit();
    const id_pointer = ids.values.items.ptr;
    var children = [_]OwnedArray{ .takePrimitive(i32, &ids), .takeVariable(&names) };
    var children_live = true;
    defer if (children_live) for (&children) |*child| child.deinit();

    var array = StructArray.take(allocator, &children, 3, &.{ true, false, true }) catch |err| {
        try std.testing.expectEqual(schema_mod.DataType.int32, children[0].dataType());
        try std.testing.expectEqual(@intFromPtr(id_pointer), @intFromPtr(children[0].int32.values.items.ptr));
        try std.testing.expectEqual(@as(usize, 3), children[1].len());
        return err;
    };
    children_live = false;
    defer array.deinit();
    try std.testing.expectEqual(@as(usize, 1), array.null_count);
    try std.testing.expectEqual(@intFromPtr(id_pointer), @intFromPtr(array.children[0].int32.values.items.ptr));
    const view = array.view();
    try std.testing.expect(try view.isValid(0));
    try std.testing.expect(!(try view.isValid(1)));
    try std.testing.expectError(error.OutOfBounds, view.isValid(3));
    const sliced = try view.slice(1, 2);
    try std.testing.expectEqual(@as(usize, 1), sliced.null_count);
    const id_child = try sliced.child(0);
    try std.testing.expectEqual(@as(usize, 2), id_child.len());
    try std.testing.expectEqual(@as(?i32, 11), try id_child.int32.get(0));
    try std.testing.expectError(error.OutOfBounds, sliced.child(2));
}

test "struct construction is failure atomic and views are bounds checked" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, structAllocationScenario, .{});
}

test "nested structs recursively match schema and move through owning batches" {
    var builder = primitive.PrimitiveBuilder(i32).init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(1);
    try builder.append(2);
    var values = builder.finish();
    defer values.deinit();
    var inner_children = [_]OwnedArray{OwnedArray.takePrimitive(i32, &values)};
    var inner = try StructArray.take(std.testing.allocator, &inner_children, 2, null);
    var inner_live = true;
    defer if (inner_live) inner.deinit();
    var outer_children = [_]OwnedArray{.{ .struct_ = inner }};
    inner_live = false;
    var outer = try StructArray.take(std.testing.allocator, &outer_children, 2, &.{ false, true });
    var outer_live = true;
    defer if (outer_live) outer.deinit();
    var columns = [_]OwnedArray{.{ .struct_ = outer }};
    outer_live = false;
    var columns_live = true;
    defer if (columns_live) columns[0].deinit();

    var schema = try schema_mod.Schema.init(std.testing.allocator, &.{.{
        .name = "outer",
        .data_type = .struct_,
        .children = &.{.{
            .name = "inner",
            .data_type = .struct_,
            .children = &.{.{ .name = "value", .data_type = .int32 }},
        }},
    }}, &.{});
    var schema_live = true;
    defer if (schema_live) schema.deinit();
    var batch = try OwnedRecordBatch.take(std.testing.allocator, &schema, &columns, 2);
    schema_live = false;
    columns_live = false;
    defer batch.deinit();
    const outer_view = batch.columns[0].view().struct_;
    const inner_view = (try outer_view.child(0)).struct_;
    const value_view = (try inner_view.child(0)).int32;
    try std.testing.expectEqual(@as(?i32, 2), try value_view.get(1));

    var wrong_schema = try schema_mod.Schema.init(std.testing.allocator, &.{.{
        .name = "outer",
        .data_type = .struct_,
        .children = &.{.{ .name = "wrong", .data_type = .uint32 }},
    }}, &.{});
    defer wrong_schema.deinit();
    var zero_child = try StructArray.take(std.testing.allocator, &.{}, 2, null);
    var wrong_columns = [_]OwnedArray{.{ .struct_ = zero_child }};
    zero_child = undefined;
    defer wrong_columns[0].deinit();
    try std.testing.expectError(error.ColumnTypeMismatch, OwnedRecordBatch.take(std.testing.allocator, &wrong_schema, &wrong_columns, 2));
    try std.testing.expectEqual(@as(usize, 0), wrong_columns[0].struct_.children.len);
}

test "struct validation errors preserve children and explicit empty length" {
    var child: primitive.PrimitiveArray(i8) = .{ .allocator = std.testing.allocator };
    defer child.deinit();
    var children = [_]OwnedArray{OwnedArray.takePrimitive(i8, &child)};
    defer children[0].deinit();
    try std.testing.expectError(error.ChildLengthMismatch, StructArray.take(std.testing.allocator, &children, 1, null));
    try std.testing.expectEqual(schema_mod.DataType.int8, children[0].dataType());
    try std.testing.expectError(error.ValidityLengthMismatch, StructArray.take(std.testing.allocator, &children, 0, &.{true}));
    var empty = try StructArray.take(std.testing.allocator, &.{}, 7, null);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 7), empty.len());
    try std.testing.expect(try empty.view().isValid(6));
    if (@sizeOf(usize) > @sizeOf(i64)) {
        try std.testing.expectError(error.LengthOverflow, StructArray.take(
            std.testing.allocator,
            &.{},
            @as(usize, std.math.maxInt(i64)) + 1,
            null,
        ));
    }
}

test "owning zero-column batch supports nonzero declared rows" {
    var schema = try schema_mod.Schema.init(std.testing.allocator, &.{}, &.{});
    var schema_live = true;
    defer if (schema_live) schema.deinit();
    var batch = try OwnedRecordBatch.take(std.testing.allocator, &schema, &.{}, 9);
    schema_live = false;
    defer batch.deinit();
    try std.testing.expectEqual(@as(usize, 9), batch.row_count);
}
