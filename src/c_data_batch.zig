//! Native Zig record-batch export through the Arrow C Data Interface.
const std = @import("std");
const c = @import("c_data.zig");
const owned = @import("owned_batch.zig");
const schema_mod = @import("schema.zig");

const ChildArrayState = struct {
    allocator: std.mem.Allocator,
    column: owned.OwnedArray = undefined,
    armed: bool = false,
    empty_offset: i32 = 0,
    buffers: [3]?*const anyopaque = .{ null, null, null },
    base: c.ArrowArray = .{},

    fn create(allocator: std.mem.Allocator) !*ChildArrayState {
        const state = try allocator.create(ChildArrayState);
        state.* = .{ .allocator = allocator };
        state.base.release = release;
        state.base.private_data = state;
        return state;
    }

    fn arm(self: *ChildArrayState, source: *owned.OwnedArray) void {
        self.column = source.*;
        source.* = undefined;
        self.armed = true;
        switch (self.column) {
            inline .int8, .uint8, .int16, .uint16, .int32, .uint32, .int64, .uint64, .float32, .float64 => |*array| {
                self.buffers = .{
                    if (array.null_count == 0) null else @ptrCast(array.validity.items.ptr),
                    if (array.len() == 0) null else @ptrCast(array.values.items.ptr),
                    null,
                };
                self.base = childBase(self, array.len(), array.null_count, 2);
            },
            .boolean => |*array| {
                self.buffers = .{
                    if (array.null_count == 0) null else @ptrCast(array.validity.items.ptr),
                    if (array.len() == 0) null else @ptrCast(array.values.items.ptr),
                    null,
                };
                self.base = childBase(self, array.len(), array.null_count, 2);
            },
            .binary, .utf8 => |*array| {
                self.buffers = .{
                    if (array.null_count == 0) null else @ptrCast(array.validity.items.ptr),
                    if (array.offsets.items.len == 0) @ptrCast(&self.empty_offset) else @ptrCast(array.offsets.items.ptr),
                    if (array.data.items.len == 0) null else @ptrCast(array.data.items.ptr),
                };
                self.base = childBase(self, array.len(), array.null_count, 3);
            },
        }
    }

    fn childBase(self: *ChildArrayState, len: usize, null_count: usize, n_buffers: i64) c.ArrowArray {
        return .{
            .length = @intCast(len),
            .null_count = @intCast(null_count),
            .n_buffers = n_buffers,
            .buffers = &self.buffers,
            .release = release,
            .private_data = self,
        };
    }

    fn release(base: *c.ArrowArray) callconv(.c) void {
        const self: *ChildArrayState = @ptrCast(@alignCast(base.private_data.?));
        const allocator = self.allocator;
        if (self.armed) self.column.deinit();
        base.* = .{};
        allocator.destroy(self);
    }

    fn discard(self: *ChildArrayState) void {
        const allocator = self.allocator;
        if (self.armed) self.column.deinit();
        allocator.destroy(self);
    }
};

const ArrayRootState = struct {
    allocator: std.mem.Allocator,
    children: []?*c.ArrowArray,
    buffers: [1]?*const anyopaque = .{null},

    fn release(base: *c.ArrowArray) callconv(.c) void {
        const self: *ArrayRootState = @ptrCast(@alignCast(base.private_data.?));
        const allocator = self.allocator;
        for (self.children) |child| if (child) |value| c.releaseArray(value);
        allocator.free(self.children);
        base.* = .{};
        allocator.destroy(self);
    }

    fn discard(self: *ArrayRootState) void {
        for (self.children) |child| if (child) |value| {
            const state: *ChildArrayState = @ptrCast(@alignCast(value.private_data.?));
            state.discard();
        };
        self.allocator.free(self.children);
        self.allocator.destroy(self);
    }
};

const ChildSchemaState = struct {
    allocator: std.mem.Allocator,
    name: [:0]u8,
    metadata: ?[]u8,
    base: c.ArrowSchema,

    fn create(allocator: std.mem.Allocator, field: schema_mod.Field) !*ChildSchemaState {
        if (std.mem.indexOfScalar(u8, field.name, 0) != null) return error.NameContainsNul;
        const name = try allocator.dupeZ(u8, field.name);
        errdefer allocator.free(name);
        const metadata = try encodeMetadata(allocator, field.metadata);
        errdefer if (metadata) |bytes| allocator.free(bytes);
        const self = try allocator.create(ChildSchemaState);
        self.* = .{
            .allocator = allocator,
            .name = name,
            .metadata = metadata,
            .base = .{},
        };
        self.base = .{
            .format = format(field.data_type),
            .name = self.name.ptr,
            .metadata = if (self.metadata) |bytes| bytes.ptr else null,
            .flags = if (field.nullable) 2 else 0,
            .release = release,
            .private_data = self,
        };
        return self;
    }

    fn release(base: *c.ArrowSchema) callconv(.c) void {
        const self: *ChildSchemaState = @ptrCast(@alignCast(base.private_data.?));
        const allocator = self.allocator;
        allocator.free(self.name);
        if (self.metadata) |bytes| allocator.free(bytes);
        base.* = .{};
        allocator.destroy(self);
    }

    fn discard(self: *ChildSchemaState) void {
        self.allocator.free(self.name);
        if (self.metadata) |bytes| self.allocator.free(bytes);
        self.allocator.destroy(self);
    }
};

const SchemaRootState = struct {
    allocator: std.mem.Allocator,
    schema: schema_mod.Schema = undefined,
    armed: bool = false,
    metadata: ?[]u8,
    children: []?*c.ArrowSchema,

    fn release(base: *c.ArrowSchema) callconv(.c) void {
        const self: *SchemaRootState = @ptrCast(@alignCast(base.private_data.?));
        const allocator = self.allocator;
        for (self.children) |child| if (child) |value| c.releaseSchema(value);
        allocator.free(self.children);
        if (self.metadata) |bytes| allocator.free(bytes);
        if (self.armed) self.schema.deinit();
        base.* = .{};
        allocator.destroy(self);
    }

    fn discard(self: *SchemaRootState) void {
        for (self.children) |child| if (child) |value| {
            const state: *ChildSchemaState = @ptrCast(@alignCast(value.private_data.?));
            state.discard();
        };
        self.allocator.free(self.children);
        if (self.metadata) |bytes| self.allocator.free(bytes);
        if (self.armed) self.schema.deinit();
        self.allocator.destroy(self);
    }
};

/// Consumes a validated owning batch only after all fallible work succeeds.
/// On error, source remains fully owned and usable.
pub fn exportRecordBatch(source: *owned.OwnedRecordBatch) !c.Export {
    const row_count = std.math.cast(i64, source.row_count) orelse return error.LengthOverflow;
    const child_count = std.math.cast(i64, source.columns.len) orelse return error.LengthOverflow;
    const allocator = source.allocator;

    const array_state = try allocator.create(ArrayRootState);
    array_state.* = .{ .allocator = allocator, .children = &.{} };
    errdefer array_state.discard();
    array_state.children = try allocator.alloc(?*c.ArrowArray, source.columns.len);
    @memset(array_state.children, null);
    for (array_state.children) |*slot| {
        const child = try ChildArrayState.create(allocator);
        slot.* = &child.base;
    }

    const schema_state = try allocator.create(SchemaRootState);
    schema_state.* = .{
        .allocator = allocator,
        .metadata = null,
        .children = &.{},
    };
    errdefer schema_state.discard();
    schema_state.metadata = try encodeMetadata(allocator, source.schema.metadata);
    schema_state.children = try allocator.alloc(?*c.ArrowSchema, source.schema.fields.len);
    @memset(schema_state.children, null);
    for (source.schema.fields, schema_state.children) |field, *slot| {
        const child = try ChildSchemaState.create(allocator, field);
        slot.* = &child.base;
    }

    // No fallible operations after the first ownership move.
    for (source.columns, array_state.children) |*column, child_base| {
        const child: *ChildArrayState = @ptrCast(@alignCast(child_base.?.private_data.?));
        child.arm(column);
    }
    allocator.free(source.columns);
    schema_state.schema = source.schema;
    schema_state.armed = true;
    source.* = undefined;

    return .{
        .array = .{
            .length = row_count,
            .null_count = 0,
            .n_buffers = 1,
            .n_children = child_count,
            .buffers = &array_state.buffers,
            .children = if (array_state.children.len == 0) null else array_state.children.ptr,
            .release = ArrayRootState.release,
            .private_data = array_state,
        },
        .schema = .{
            .format = "+s",
            .metadata = if (schema_state.metadata) |bytes| bytes.ptr else null,
            .n_children = child_count,
            .children = if (schema_state.children.len == 0) null else schema_state.children.ptr,
            .release = SchemaRootState.release,
            .private_data = schema_state,
        },
    };
}

fn encodeMetadata(allocator: std.mem.Allocator, entries: []const schema_mod.Metadata) !?[]u8 {
    if (entries.len == 0) return null;
    if (entries.len > std.math.maxInt(i32)) return error.MetadataOverflow;
    var total: usize = 4;
    for (entries) |entry| {
        total = try metadataEntryEnd(total, entry.key.len, entry.value.len);
    }
    const bytes = try allocator.alloc(u8, total);
    var cursor: usize = 0;
    writeNativeI32(bytes, &cursor, @intCast(entries.len));
    for (entries) |entry| {
        writeNativeI32(bytes, &cursor, @intCast(entry.key.len));
        @memcpy(bytes[cursor .. cursor + entry.key.len], entry.key);
        cursor += entry.key.len;
        writeNativeI32(bytes, &cursor, @intCast(entry.value.len));
        @memcpy(bytes[cursor .. cursor + entry.value.len], entry.value);
        cursor += entry.value.len;
    }
    return bytes;
}

fn metadataEntryEnd(start: usize, key_len: usize, value_len: usize) !usize {
    if (key_len > std.math.maxInt(i32) or value_len > std.math.maxInt(i32)) return error.MetadataOverflow;
    var end = std.math.add(usize, start, 8) catch return error.MetadataOverflow;
    end = std.math.add(usize, end, key_len) catch return error.MetadataOverflow;
    return std.math.add(usize, end, value_len) catch return error.MetadataOverflow;
}

fn writeNativeI32(bytes: []u8, cursor: *usize, value: i32) void {
    @memcpy(bytes[cursor.* .. cursor.* + 4], std.mem.asBytes(&value));
    cursor.* += 4;
}

fn format(data_type: schema_mod.DataType) [:0]const u8 {
    return switch (data_type) {
        .int8 => "c",
        .uint8 => "C",
        .int16 => "s",
        .uint16 => "S",
        .int32 => "i",
        .uint32 => "I",
        .int64 => "l",
        .uint64 => "L",
        .float32 => "f",
        .float64 => "g",
        .boolean => "b",
        .binary => "z",
        .utf8 => "u",
    };
}

fn exportScenario(allocator: std.mem.Allocator) !void {
    const primitive = @import("primitive.zig");
    const variable = @import("variable_binary.zig");
    var schema = try schema_mod.Schema.init(allocator, &.{
        .{ .name = "id", .data_type = .int32, .nullable = false, .metadata = &.{.{ .key = "role", .value = "key" }} },
        .{ .name = "name", .data_type = .utf8 },
    }, &.{.{ .key = "source", .value = "arrowz" }});
    var schema_live = true;
    defer if (schema_live) schema.deinit();
    var ids_builder = primitive.PrimitiveBuilder(i32).init(allocator);
    defer ids_builder.deinit();
    var names_builder = variable.Utf8Builder.init(allocator);
    defer names_builder.deinit();
    try ids_builder.append(1);
    try ids_builder.append(2);
    try names_builder.append("one");
    try names_builder.append(null);
    var ids = ids_builder.finish();
    defer ids.deinit();
    var names = names_builder.finish();
    defer names.deinit();
    const id_pointer = ids.values.items.ptr;
    var columns = [_]owned.OwnedArray{ .takePrimitive(i32, &ids), .takeVariable(&names) };
    var columns_live = true;
    defer if (columns_live) for (&columns) |*column| column.deinit();
    var batch = try owned.OwnedRecordBatch.take(allocator, &schema, &columns, 2);
    schema_live = false;
    columns_live = false;
    var batch_live = true;
    defer if (batch_live) batch.deinit();

    var exported = exportRecordBatch(&batch) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), batch.row_count);
        try std.testing.expectEqual(@intFromPtr(id_pointer), @intFromPtr(batch.columns[0].int32.values.items.ptr));
        return err;
    };
    batch_live = false;
    defer exported.deinit();
    try std.testing.expectEqualStrings("+s", std.mem.span(exported.schema.format.?));
    try std.testing.expectEqualStrings("id", std.mem.span(exported.schema.children.?[0].?.name.?));
    try std.testing.expectEqual(@as(i64, 0), exported.schema.children.?[0].?.flags);
    try std.testing.expectEqual(@intFromPtr(id_pointer), @intFromPtr(exported.array.children.?[0].?.buffers.?[1].?));

    c.releaseSchema(&exported.schema);
    const values: [*]const i32 = @ptrCast(@alignCast(exported.array.children.?[0].?.buffers.?[1].?));
    try std.testing.expectEqual(@as(i32, 2), values[1]);
    c.releaseArray(&exported.array);
    c.releaseArray(&exported.array);
}

test "record-batch export is zero-copy and preserves source on every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exportScenario, .{});
}

test "moved child array and schema states survive immediate parent release" {
    const primitive = @import("primitive.zig");
    var schema = try schema_mod.Schema.init(std.testing.allocator, &.{.{ .name = "x", .data_type = .int32 }}, &.{});
    var builder = primitive.PrimitiveBuilder(i32).init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(9);
    var array = builder.finish();
    defer array.deinit();
    var columns = [_]owned.OwnedArray{owned.OwnedArray.takePrimitive(i32, &array)};
    var batch = try owned.OwnedRecordBatch.take(std.testing.allocator, &schema, &columns, 1);
    var exported = try exportRecordBatch(&batch);
    defer exported.deinit();

    var child_array = exported.array.children.?[0].?.*;
    exported.array.children.?[0].?.release = null;
    c.releaseArray(&exported.array);
    const values: [*]const i32 = @ptrCast(@alignCast(child_array.buffers.?[1].?));
    try std.testing.expectEqual(@as(i32, 9), values[0]);
    c.releaseArray(&child_array);

    var child_schema = exported.schema.children.?[0].?.*;
    exported.schema.children.?[0].?.release = null;
    c.releaseSchema(&exported.schema);
    try std.testing.expectEqualStrings("x", std.mem.span(child_schema.name.?));
    c.releaseSchema(&child_schema);
}

test "zero-column rows and embedded NUL field names" {
    var empty_schema = try schema_mod.Schema.init(std.testing.allocator, &.{}, &.{});
    var empty_batch = try owned.OwnedRecordBatch.take(std.testing.allocator, &empty_schema, &.{}, 7);
    var empty_export = try exportRecordBatch(&empty_batch);
    defer empty_export.deinit();
    try std.testing.expectEqual(@as(i64, 7), empty_export.array.length);
    try std.testing.expect(empty_export.array.children == null);
    try std.testing.expect(empty_export.schema.children == null);

    var bad_schema = try schema_mod.Schema.init(std.testing.allocator, &.{.{ .name = "a\x00b", .data_type = .int8 }}, &.{});
    var bad_schema_live = true;
    defer if (bad_schema_live) bad_schema.deinit();
    const primitive = @import("primitive.zig");
    var array: primitive.PrimitiveArray(i8) = .{ .allocator = std.testing.allocator };
    defer array.deinit();
    var columns = [_]owned.OwnedArray{owned.OwnedArray.takePrimitive(i8, &array)};
    var columns_live = true;
    defer if (columns_live) columns[0].deinit();
    var bad_batch = try owned.OwnedRecordBatch.take(std.testing.allocator, &bad_schema, &columns, 0);
    bad_schema_live = false;
    columns_live = false;
    defer bad_batch.deinit();
    try std.testing.expectError(error.NameContainsNul, exportRecordBatch(&bad_batch));
    try std.testing.expectEqual(@as(usize, 1), bad_batch.schema.fields.len);
    try std.testing.expectEqual(@as(usize, 1), bad_batch.columns.len);
}

test "all native child layouts and length and metadata bounds" {
    const primitive = @import("primitive.zig");
    const boolean = @import("boolean.zig");
    const variable = @import("variable_binary.zig");
    const fields = [_]schema_mod.FieldSpec{
        .{ .name = "i8", .data_type = .int8 },      .{ .name = "u8", .data_type = .uint8 },
        .{ .name = "i16", .data_type = .int16 },    .{ .name = "u16", .data_type = .uint16 },
        .{ .name = "i32", .data_type = .int32 },    .{ .name = "u32", .data_type = .uint32 },
        .{ .name = "i64", .data_type = .int64 },    .{ .name = "u64", .data_type = .uint64 },
        .{ .name = "f32", .data_type = .float32 },  .{ .name = "f64", .data_type = .float64 },
        .{ .name = "bool", .data_type = .boolean }, .{ .name = "binary", .data_type = .binary },
        .{ .name = "utf8", .data_type = .utf8 },
    };
    var schema = try schema_mod.Schema.init(std.testing.allocator, &fields, &.{});
    var columns = [_]owned.OwnedArray{
        .{ .int8 = .{ .allocator = std.testing.allocator } },                                           .{ .uint8 = .{ .allocator = std.testing.allocator } },
        .{ .int16 = .{ .allocator = std.testing.allocator } },                                          .{ .uint16 = .{ .allocator = std.testing.allocator } },
        .{ .int32 = .{ .allocator = std.testing.allocator } },                                          .{ .uint32 = .{ .allocator = std.testing.allocator } },
        .{ .int64 = .{ .allocator = std.testing.allocator } },                                          .{ .uint64 = .{ .allocator = std.testing.allocator } },
        .{ .float32 = .{ .allocator = std.testing.allocator } },                                        .{ .float64 = .{ .allocator = std.testing.allocator } },
        .{ .boolean = boolean.BooleanArray{ .allocator = std.testing.allocator } },                     .{ .binary = variable.VariableBinaryArray{ .allocator = std.testing.allocator, .kind = .binary } },
        .{ .utf8 = variable.VariableBinaryArray{ .allocator = std.testing.allocator, .kind = .utf8 } },
    };
    _ = primitive;
    var batch = try owned.OwnedRecordBatch.take(std.testing.allocator, &schema, &columns, 0);
    var exported = try exportRecordBatch(&batch);
    defer exported.deinit();
    const expected = [_][]const u8{ "c", "C", "s", "S", "i", "I", "l", "L", "f", "g", "b", "z", "u" };
    for (expected, 0..) |value, index| {
        try std.testing.expectEqualStrings(value, std.mem.span(exported.schema.children.?[index].?.format.?));
        try std.testing.expectEqual(@as(i64, if (index < 11) 2 else 3), exported.array.children.?[index].?.n_buffers);
    }

    try std.testing.expectError(error.MetadataOverflow, metadataEntryEnd(0, @as(usize, std.math.maxInt(i32)) + 1, 0));
    try std.testing.expectError(error.MetadataOverflow, metadataEntryEnd(std.math.maxInt(usize), 0, 0));

    if (@sizeOf(usize) > @sizeOf(i64)) {
        var overflow_schema = try schema_mod.Schema.init(std.testing.allocator, &.{}, &.{});
        var overflow_batch = try owned.OwnedRecordBatch.take(std.testing.allocator, &overflow_schema, &.{}, @as(usize, std.math.maxInt(i64)) + 1);
        defer overflow_batch.deinit();
        try std.testing.expectError(error.LengthOverflow, exportRecordBatch(&overflow_batch));
        try std.testing.expectEqual(@as(usize, 0), overflow_batch.columns.len);
    }
}
