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
const c = @import("c_data.zig");

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
};

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
