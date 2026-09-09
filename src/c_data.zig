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
    const State = struct {
        array: primitive.PrimitiveArray(T),
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
        .schema = .{ .format = format(T), .flags = 2, .release = schemaRelease },
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
