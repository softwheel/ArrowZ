//! Optional C Data Interface boundary implemented entirely in Zig.
//! Layout reference: https://arrow.apache.org/docs/format/CDataInterface.html
const std = @import("std");
const primitive = @import("primitive.zig");

pub const ArrowSchema = extern struct {
    format: ?[*:0]const u8 = null,
    name: ?[*:0]const u8 = null,
    metadata: ?[*]const u8 = null,
    flags: i64 = 0,
    n_children: i64 = 0,
    children: ?[*]?*ArrowSchema = null,
    dictionary: ?*ArrowSchema = null,
    release: ?*const fn (*ArrowSchema) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};

pub const ArrowArray = extern struct {
    length: i64 = 0,
    null_count: i64 = 0,
    offset: i64 = 0,
    n_buffers: i64 = 0,
    n_children: i64 = 0,
    buffers: ?[*]const ?*const anyopaque = null,
    children: ?[*]?*ArrowArray = null,
    dictionary: ?*ArrowArray = null,
    release: ?*const fn (*ArrowArray) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};

pub const Export = struct {
    array: ArrowArray,
    schema: ArrowSchema,

    pub fn deinit(self: *Export) void {
        releaseArray(&self.array);
        releaseSchema(&self.schema);
    }
};

pub fn releaseArray(array: *ArrowArray) void {
    if (array.release) |release| release(array);
}

pub fn releaseSchema(schema: *ArrowSchema) void {
    if (schema.release) |release| release(schema);
}

/// Consumes the source without copying buffers. Failure leaves ownership intact.
/// The source becomes an empty, reusable array. Do not copy the returned owner.
pub fn exportPrimitive(comptime T: type, source: *primitive.PrimitiveArray(T)) !Export {
    primitive.checkType(T);
    return exportFixedWidth(primitive.PrimitiveArray(T), format(T), source);
}

/// Transfers native packed boolean buffers; failure preserves source ownership.
pub fn exportBoolean(source: *@import("boolean.zig").BooleanArray) !Export {
    return exportFixedWidth(@import("boolean.zig").BooleanArray, "b", source);
}

/// Transfers native offsets, data and validity without copying.
pub fn exportVariableBinary(source: *@import("variable_binary.zig").VariableBinaryArray) !Export {
    const variable = @import("variable_binary.zig");
    const State = struct {
        array: variable.VariableBinaryArray,
        empty_offset: i32 = 0,
        buffers: [3]?*const anyopaque,

        fn release(base: *ArrowArray) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(base.private_data.?));
            const allocator = state.array.allocator;
            state.array.deinit();
            allocator.destroy(state);
            base.* = .{};
        }
    };
    const length = std.math.cast(i64, source.len()) orelse return error.LengthOverflow;
    const state = try source.allocator.create(State);
    state.* = .{
        .array = source.*,
        .buffers = .{ null, null, null },
    };
    state.buffers = .{
        if (state.array.null_count == 0) null else @ptrCast(state.array.validity.items.ptr),
        if (state.array.offsets.items.len == 0) @ptrCast(&state.empty_offset) else @ptrCast(state.array.offsets.items.ptr),
        if (state.array.data.items.len == 0) null else @ptrCast(state.array.data.items.ptr),
    };
    source.* = .{ .allocator = source.allocator, .kind = source.kind };
    return .{
        .array = .{
            .length = length,
            .null_count = @intCast(state.array.null_count),
            .n_buffers = 3,
            .buffers = &state.buffers,
            .release = State.release,
            .private_data = state,
        },
        .schema = .{
            .format = if (state.array.kind == .binary) "z" else "u",
            .flags = 2,
            .release = schemaRelease,
        },
    };
}

fn exportFixedWidth(comptime Array: type, comptime arrow_format: [:0]const u8, source: *Array) !Export {
    const State = struct {
        array: Array,
        buffers: [2]?*const anyopaque,

        fn release(base: *ArrowArray) callconv(.c) void {
            const state: *@This() = @ptrCast(@alignCast(base.private_data.?));
            const allocator = state.array.allocator;
            state.array.deinit();
            allocator.destroy(state);
            base.* = .{};
        }
    };
    const length = std.math.cast(i64, source.len()) orelse return error.LengthOverflow;
    const state = try source.allocator.create(State);
    state.* = .{
        .array = source.*,
        .buffers = .{
            if (source.null_count == 0) null else @ptrCast(source.validity.items.ptr),
            if (source.len() == 0) null else @ptrCast(source.values.items.ptr),
        },
    };
    source.* = .{ .allocator = source.allocator };
    return .{
        .array = .{
            .length = length,
            .null_count = @intCast(state.array.null_count),
            .n_buffers = 2,
            .buffers = &state.buffers,
            .release = State.release,
            .private_data = state,
        },
        .schema = .{ .format = arrow_format, .flags = 2, .release = schemaRelease },
    };
}

fn schemaRelease(schema: *ArrowSchema) callconv(.c) void {
    schema.* = .{};
}

fn format(comptime T: type) [:0]const u8 {
    return switch (T) {
        i8 => "c",
        u8 => "C",
        i16 => "s",
        u16 => "S",
        i32 => "i",
        u32 => "I",
        i64 => "l",
        u64 => "L",
        f32 => "f",
        f64 => "g",
        else => unreachable,
    };
}

fn exportScenario(allocator: std.mem.Allocator) !void {
    var builder = primitive.PrimitiveBuilder(i64).init(allocator);
    defer builder.deinit();
    try builder.append(42);
    try builder.append(null);
    var array = builder.finish();
    defer array.deinit();
    const values = array.values.items.ptr;
    var exported = exportPrimitive(i64, &array) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), array.len());
        try std.testing.expectEqual(@as(?i64, 42), try array.get(0));
        try std.testing.expectEqual(@as(?i64, null), try array.get(1));
        return err;
    };
    defer exported.deinit();
    try std.testing.expectEqual(@as(usize, 0), array.len());
    try std.testing.expectEqual(@intFromPtr(values), @intFromPtr(exported.array.buffers.?[1].?));
    // C Data move semantics: shallow-copy then invalidate the source release.
    var moved = exported.array;
    exported.array.release = null;
    releaseSchema(&exported.schema);
    const data: [*]const i64 = @ptrCast(@alignCast(moved.buffers.?[1].?));
    try std.testing.expectEqual(@as(i64, 42), data[0]);
    releaseArray(&moved);
    try std.testing.expect(moved.release == null);
    releaseArray(&moved);
}

test "zero-copy export, relocation, independent schema lifetime and all OOM paths" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, exportScenario, .{});
}

test "empty export and every primitive format" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 }) |T| {
        var array: primitive.PrimitiveArray(T) = .{ .allocator = std.testing.allocator };
        defer array.deinit();
        var exported = try exportPrimitive(T, &array);
        defer exported.deinit();
        try std.testing.expectEqual(@as(i64, 0), exported.array.length);
        try std.testing.expect(exported.array.buffers.?[1] == null);
        try std.testing.expectEqualStrings(format(T), std.mem.span(exported.schema.format.?));
    }
}

fn booleanExportScenario(allocator: std.mem.Allocator) !void {
    var builder = @import("boolean.zig").BooleanBuilder.init(allocator);
    defer builder.deinit();
    try builder.append(true);
    try builder.append(null);
    var array = builder.finish();
    defer array.deinit();
    const values = array.values.items.ptr;
    var exported = exportBoolean(&array) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), array.len());
        try std.testing.expectEqual(@as(?bool, true), try array.get(0));
        try std.testing.expectEqual(@as(?bool, null), try array.get(1));
        return err;
    };
    defer exported.deinit();
    try std.testing.expectEqual(@as(usize, 0), array.len());
    try std.testing.expectEqual(@intFromPtr(values), @intFromPtr(exported.array.buffers.?[1].?));
    var moved = exported.array;
    exported.array.release = null;
    releaseSchema(&exported.schema);
    const data: [*]const u8 = @ptrCast(moved.buffers.?[1].?);
    try std.testing.expectEqual(@as(u8, 1), data[0]);
    releaseArray(&moved);
    try std.testing.expect(moved.release == null);
    releaseArray(&moved);
}

test "boolean export allocation failures, zero-copy, relocation and release" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, booleanExportScenario, .{});
}

fn variableExportScenario(allocator: std.mem.Allocator) !void {
    const variable = @import("variable_binary.zig");
    var builder = variable.Utf8Builder.init(allocator);
    defer builder.deinit();
    try builder.append("数据");
    try builder.append(null);
    var array = builder.finish();
    defer array.deinit();
    const offsets = array.offsets.items.ptr;
    const data = array.data.items.ptr;
    var exported = exportVariableBinary(&array) catch |err| {
        try std.testing.expectEqual(@as(usize, 2), array.len());
        try std.testing.expectEqualStrings("数据", (try array.get(0)).?);
        return err;
    };
    defer exported.deinit();
    try std.testing.expectEqual(@intFromPtr(offsets), @intFromPtr(exported.array.buffers.?[1].?));
    try std.testing.expectEqual(@intFromPtr(data), @intFromPtr(exported.array.buffers.?[2].?));
    try std.testing.expectEqualStrings("u", std.mem.span(exported.schema.format.?));
    var moved = exported.array;
    exported.array.release = null;
    releaseSchema(&exported.schema);
    const moved_offsets: [*]const i32 = @ptrCast(@alignCast(moved.buffers.?[1].?));
    try std.testing.expectEqual(@as(i32, 6), moved_offsets[1]);
    releaseArray(&moved);
    releaseArray(&moved);
}

test "variable binary export allocation failures and zero-copy ownership" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, variableExportScenario, .{});
    const variable = @import("variable_binary.zig");
    var empty: variable.VariableBinaryArray = .{ .allocator = std.testing.allocator, .kind = .binary };
    defer empty.deinit();
    var exported = try exportVariableBinary(&empty);
    defer exported.deinit();
    try std.testing.expect(exported.array.buffers.?[1] != null);
    const offsets: [*]const i32 = @ptrCast(@alignCast(exported.array.buffers.?[1].?));
    try std.testing.expectEqual(@as(i32, 0), offsets[0]);
    try std.testing.expectEqualStrings("z", std.mem.span(exported.schema.format.?));
}
