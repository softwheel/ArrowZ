//! Test-only ABI fixture; not part of the public ArrowZ SDK.
const std = @import("std");
const z = @import("arrowz");
const c = z.c_data;

export fn arrowz_batch_fixture(out: *c.ArrowArray, out_schema: *c.ArrowSchema) c_int {
    if (out.release != null or out_schema.release != null) return 1;
    produceBatch(out, out_schema) catch return 3;
    return 0;
}

export fn arrowz_nested_batch_fixture(out: *c.ArrowArray, out_schema: *c.ArrowSchema) c_int {
    if (out.release != null or out_schema.release != null) return 1;
    produceNestedBatch(out, out_schema) catch return 3;
    return 0;
}

fn produceNestedBatch(out: *c.ArrowArray, out_schema: *c.ArrowSchema) !void {
    const allocator = std.heap.page_allocator;
    var native_schema = try z.Schema.init(allocator, &.{.{
        .name = "outer",
        .data_type = .struct_,
        .metadata = &.{.{ .key = "level", .value = "outer" }},
        .children = &.{
            .{
                .name = "inner",
                .data_type = .struct_,
                .metadata = &.{.{ .key = "level", .value = "inner" }},
                .children = &.{.{ .name = "id", .data_type = .int32, .nullable = false }},
            },
            .{ .name = "label", .data_type = .utf8 },
        },
    }}, &.{.{ .key = "source", .value = "arrowz-nested" }});
    var schema_live = true;
    defer if (schema_live) native_schema.deinit();
    var id_builder = z.PrimitiveBuilder(i32).init(allocator);
    defer id_builder.deinit();
    var label_builder = z.Utf8Builder.init(allocator);
    defer label_builder.deinit();
    for ([_]?i32{ 40, 41, 42 }) |value| try id_builder.append(value);
    for ([_]?[]const u8{ "zero", null, "two" }) |value| try label_builder.append(value);
    var ids = id_builder.finish();
    defer ids.deinit();
    var labels = label_builder.finish();
    defer labels.deinit();
    var inner_children = [_]z.OwnedArray{z.OwnedArray.takePrimitive(i32, &ids)};
    var inner_children_live = true;
    defer if (inner_children_live) inner_children[0].deinit();
    var inner = try z.StructArray.take(allocator, &inner_children, 3, &.{ true, false, true });
    inner_children_live = false;
    var inner_live = true;
    defer if (inner_live) inner.deinit();
    var outer_children = [_]z.OwnedArray{ .{ .struct_ = inner }, z.OwnedArray.takeVariable(&labels) };
    inner_live = false;
    var outer_children_live = true;
    defer if (outer_children_live) for (&outer_children) |*child| child.deinit();
    var outer = try z.StructArray.take(allocator, &outer_children, 3, &.{ false, true, true });
    outer_children_live = false;
    var outer_live = true;
    defer if (outer_live) outer.deinit();
    var columns = [_]z.OwnedArray{.{ .struct_ = outer }};
    outer_live = false;
    var columns_live = true;
    defer if (columns_live) columns[0].deinit();
    var batch = try z.OwnedRecordBatch.take(allocator, &native_schema, &columns, 3);
    schema_live = false;
    columns_live = false;
    var batch_live = true;
    defer if (batch_live) batch.deinit();
    var exported = try z.c_data_batch.exportRecordBatch(&batch);
    batch_live = false;
    out.* = exported.array;
    out_schema.* = exported.schema;
    exported.array.release = null;
    exported.schema.release = null;
}

fn produceBatch(out: *c.ArrowArray, out_schema: *c.ArrowSchema) !void {
    const allocator = std.heap.page_allocator;
    var native_schema = try z.Schema.init(allocator, &.{
        .{ .name = "id", .data_type = .int32, .nullable = false, .metadata = &.{.{ .key = "role", .value = "key" }} },
        .{ .name = "name", .data_type = .utf8 },
        .{ .name = "active", .data_type = .boolean },
    }, &.{.{ .key = "source", .value = "arrowz" }});
    var schema_live = true;
    defer if (schema_live) native_schema.deinit();
    var ids_builder = z.PrimitiveBuilder(i32).init(allocator);
    defer ids_builder.deinit();
    var names_builder = z.Utf8Builder.init(allocator);
    defer names_builder.deinit();
    var active_builder = z.BooleanBuilder.init(allocator);
    defer active_builder.deinit();
    for ([_]?i32{ 10, 11, 12, 13 }) |value| try ids_builder.append(value);
    for ([_]?[]const u8{ "zero", null, "数据", "" }) |value| try names_builder.append(value);
    for ([_]?bool{ true, false, null, true }) |value| try active_builder.append(value);
    var ids = ids_builder.finish();
    defer ids.deinit();
    var names = names_builder.finish();
    defer names.deinit();
    var active = active_builder.finish();
    defer active.deinit();
    var columns = [_]z.OwnedArray{
        .takePrimitive(i32, &ids), .takeVariable(&names), .takeBoolean(&active),
    };
    var columns_live = true;
    defer if (columns_live) for (&columns) |*column| column.deinit();
    var batch = try z.OwnedRecordBatch.take(allocator, &native_schema, &columns, 4);
    schema_live = false;
    columns_live = false;
    var batch_live = true;
    defer if (batch_live) batch.deinit();
    var exported = try z.c_data_batch.exportRecordBatch(&batch);
    batch_live = false;
    out.* = exported.array;
    out_schema.* = exported.schema;
    exported.array.release = null;
    exported.schema.release = null;
}

export fn arrowz_fixture(kind: u32, scenario: u32, out: *c.ArrowArray, schema: *c.ArrowSchema) c_int {
    if (out.release != null or schema.release != null) return 1;
    (switch (kind) {
        0 => produce(i8, scenario, out, schema),
        1 => produce(u8, scenario, out, schema),
        2 => produce(i16, scenario, out, schema),
        3 => produce(u16, scenario, out, schema),
        4 => produce(i32, scenario, out, schema),
        5 => produce(u32, scenario, out, schema),
        6 => produce(i64, scenario, out, schema),
        7 => produce(u64, scenario, out, schema),
        8 => produce(f32, scenario, out, schema),
        9 => produce(f64, scenario, out, schema),
        10 => produce(bool, scenario, out, schema),
        11 => produceVariable(.binary, scenario, out, schema),
        12 => produceVariable(.utf8, scenario, out, schema),
        else => return 2,
    }) catch return 3;
    return 0;
}

fn produceVariable(kind: z.variable_binary.Kind, scenario: u32, out: *c.ArrowArray, schema: *c.ArrowSchema) !void {
    if (scenario > 4) return error.BadScenario;
    var builder = z.variable_binary.VariableBinaryBuilder.init(std.heap.page_allocator, kind);
    defer builder.deinit();
    const count: usize = if (scenario == 0) 0 else 20;
    const binary = [_][]const u8{ "", &.{ 0, 0xff }, "abc" };
    const utf8 = [_][]const u8{ "", "数据", "🏹" };
    for (0..count) |i| {
        const value = if (kind == .binary) binary[i % binary.len] else utf8[i % utf8.len];
        try builder.append(if (scenario == 2 or (scenario >= 3 and i % 3 == 0)) null else value);
    }
    var array = builder.finish();
    defer array.deinit();
    var exported = try c.exportVariableBinary(&array);
    if (scenario == 4) {
        exported.array.offset = 7;
        exported.array.length = 9;
        exported.array.null_count = 3;
    }
    out.* = exported.array;
    schema.* = exported.schema;
    exported.array.release = null;
    exported.schema.release = null;
}

fn produce(comptime T: type, scenario: u32, out: *c.ArrowArray, schema: *c.ArrowSchema) !void {
    if (scenario > 4) return error.BadScenario;
    var builder = (if (T == bool) z.BooleanBuilder else z.PrimitiveBuilder(T)).init(std.heap.page_allocator);
    defer builder.deinit();
    const count: usize = if (scenario == 0) 0 else 20;
    for (0..count) |i| {
        const value: T = switch (@typeInfo(T)) {
            .bool => i % 2 == 0,
            .float => @floatFromInt(i),
            else => @intCast(i),
        };
        try builder.append(if (scenario == 2 or (scenario >= 3 and i % 3 == 0)) null else value);
    }
    var array = builder.finish();
    defer array.deinit();
    var exported = if (T == bool) try c.exportBoolean(&array) else try c.exportPrimitive(T, &array);
    // Exercise non-byte-aligned offset through the standard ABI consumer rules.
    if (scenario == 4) {
        exported.array.offset = 7;
        exported.array.length = 9;
        exported.array.null_count = 3;
    }
    out.* = exported.array;
    schema.* = exported.schema;
    exported.array.release = null;
    exported.schema.release = null;
}

export fn arrowz_abi_size(which: u32) usize {
    return switch (which) {
        0 => @sizeOf(c.ArrowArray),
        1 => @sizeOf(c.ArrowSchema),
        else => 0,
    };
}

export fn arrowz_abi_offset(which: u32, field: u32) usize {
    if (which == 0) {
        inline for (std.meta.fields(c.ArrowArray), 0..) |f, i| {
            if (field == i) return @offsetOf(c.ArrowArray, f.name);
        }
    } else if (which == 1) {
        inline for (std.meta.fields(c.ArrowSchema), 0..) |f, i| {
            if (field == i) return @offsetOf(c.ArrowSchema, f.name);
        }
    }
    return std.math.maxInt(usize);
}
