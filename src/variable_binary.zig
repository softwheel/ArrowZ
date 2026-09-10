const std = @import("std");
const bitmap = @import("bitmap.zig");

pub const Kind = enum { binary, utf8 };

fn checkedNextOffset(current: usize, additional: usize) error{OffsetOverflow}!i32 {
    if (current > std.math.maxInt(i32) or additional > std.math.maxInt(i32) - current) return error.OffsetOverflow;
    return @intCast(current + additional);
}

pub const VariableBinaryView = struct {
    offsets: []const i32,
    data: []const u8,
    validity: []const u8,
    offset: usize,
    len: usize,
    kind: Kind,

    pub fn get(self: VariableBinaryView, index: usize) error{OutOfBounds}!?[]const u8 {
        if (index >= self.len) return error.OutOfBounds;
        const physical = self.offset + index;
        if (self.validity.len != 0 and !bitmap.isSet(self.validity, physical)) return null;
        const start: usize = @intCast(self.offsets[physical]);
        const end: usize = @intCast(self.offsets[physical + 1]);
        return self.data[start..end];
    }

    pub fn slice(self: VariableBinaryView, offset: usize, len: usize) error{OutOfBounds}!VariableBinaryView {
        if (offset > self.len or len > self.len - offset) return error.OutOfBounds;
        return .{
            .offsets = self.offsets,
            .data = self.data,
            .validity = self.validity,
            .offset = self.offset + offset,
            .len = len,
            .kind = self.kind,
        };
    }
};

/// Owning canonical Arrow variable-size binary layout. Do not copy.
pub const VariableBinaryArray = struct {
    allocator: std.mem.Allocator,
    offsets: std.ArrayList(i32) = .empty,
    data: std.ArrayList(u8) = .empty,
    validity: std.ArrayList(u8) = .empty,
    length: usize = 0,
    null_count: usize = 0,
    kind: Kind,

    pub fn deinit(self: *VariableBinaryArray) void {
        self.offsets.deinit(self.allocator);
        self.data.deinit(self.allocator);
        self.validity.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator, .kind = self.kind };
    }

    pub fn len(self: *const VariableBinaryArray) usize {
        return self.length;
    }

    pub fn view(self: *const VariableBinaryArray) VariableBinaryView {
        return .{
            .offsets = self.offsets.items,
            .data = self.data.items,
            .validity = self.validity.items,
            .offset = 0,
            .len = self.length,
            .kind = self.kind,
        };
    }

    pub fn get(self: *const VariableBinaryArray, index: usize) error{OutOfBounds}!?[]const u8 {
        return self.view().get(index);
    }

    /// Canonical logical offset, including offset zero for an empty array.
    pub fn offsetAt(self: *const VariableBinaryArray, index: usize) error{OutOfBounds}!i32 {
        if (index > self.length) return error.OutOfBounds;
        if (self.offsets.items.len == 0) return 0;
        return self.offsets.items[index];
    }
};

pub const VariableBinaryBuilder = struct {
    array: VariableBinaryArray,

    pub fn init(allocator: std.mem.Allocator, kind: Kind) VariableBinaryBuilder {
        return .{ .array = .{ .allocator = allocator, .kind = kind } };
    }

    pub fn deinit(self: *VariableBinaryBuilder) void {
        self.array.deinit();
    }

    /// Reserves all buffers before mutation. Invalid UTF-8 and OOM are atomic.
    pub fn append(self: *VariableBinaryBuilder, value: ?[]const u8) !void {
        if (self.array.length >= std.math.maxInt(i32)) return error.LengthOverflow;
        if (self.array.kind == .utf8 and value != null and !std.unicode.utf8ValidateSlice(value.?)) return error.InvalidUtf8;
        const bytes = value orelse &.{};
        const next_offset = try checkedNextOffset(self.array.data.items.len, bytes.len);
        const bitmap_bytes = bitmap.byteLength(self.array.length + 1);
        const required_offsets = self.array.length + 2;
        try self.array.offsets.ensureTotalCapacity(self.array.allocator, required_offsets);
        try self.array.data.ensureTotalCapacity(self.array.allocator, @intCast(next_offset));
        try self.array.validity.ensureTotalCapacity(self.array.allocator, bitmap_bytes);

        if (self.array.offsets.items.len == 0) self.array.offsets.appendAssumeCapacity(0);
        if (bitmap_bytes > self.array.validity.items.len) self.array.validity.appendAssumeCapacity(0);
        self.array.data.appendSliceAssumeCapacity(bytes);
        self.array.offsets.appendAssumeCapacity(next_offset);
        bitmap.set(self.array.validity.items, self.array.length, value != null);
        self.array.length += 1;
        self.array.null_count += @intFromBool(value == null);
    }

    pub fn finish(self: *VariableBinaryBuilder) VariableBinaryArray {
        const result = self.array;
        self.array = .{ .allocator = result.allocator, .kind = result.kind };
        return result;
    }
};

pub const BinaryBuilder = struct {
    inner: VariableBinaryBuilder,

    pub fn init(allocator: std.mem.Allocator) BinaryBuilder {
        return .{ .inner = .init(allocator, .binary) };
    }
    pub fn deinit(self: *BinaryBuilder) void {
        self.inner.deinit();
    }
    pub fn append(self: *BinaryBuilder, value: ?[]const u8) !void {
        try self.inner.append(value);
    }
    pub fn finish(self: *BinaryBuilder) VariableBinaryArray {
        return self.inner.finish();
    }
};

pub const Utf8Builder = struct {
    inner: VariableBinaryBuilder,

    pub fn init(allocator: std.mem.Allocator) Utf8Builder {
        return .{ .inner = .init(allocator, .utf8) };
    }
    pub fn deinit(self: *Utf8Builder) void {
        self.inner.deinit();
    }
    pub fn append(self: *Utf8Builder, value: ?[]const u8) !void {
        try self.inner.append(value);
    }
    pub fn finish(self: *Utf8Builder) VariableBinaryArray {
        return self.inner.finish();
    }
};

test "binary layout preserves null, empty, arbitrary bytes, slices and reuse" {
    var builder = BinaryBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append(&.{ 0, 0xff });
    try builder.append(null);
    try builder.append("");
    try builder.append("abc");
    var array = builder.finish();
    defer array.deinit();
    try std.testing.expectEqualSlices(i32, &.{ 0, 2, 2, 2, 5 }, array.offsets.items);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff, 'a', 'b', 'c' }, array.data.items);
    try std.testing.expectEqual(@as(?[]const u8, null), try array.get(1));
    try std.testing.expectEqualStrings("", (try array.get(2)).?);
    const nested = try (try array.view().slice(1, 3)).slice(1, 2);
    try std.testing.expectEqualStrings("", (try nested.get(0)).?);
    try std.testing.expectEqualStrings("abc", (try nested.get(1)).?);
    try std.testing.expectError(error.OutOfBounds, nested.get(2));
    try std.testing.expectError(error.OutOfBounds, nested.slice(1, std.math.maxInt(usize)));
    try builder.append("reused");
    try std.testing.expectEqual(@as(usize, 4), array.len());
}

test "UTF-8 accepts Unicode and rejects invalid bytes without mutation" {
    var builder = Utf8Builder.init(std.testing.allocator);
    defer builder.deinit();
    try builder.append("Arrow 🏹 数据");
    try std.testing.expectError(error.InvalidUtf8, builder.append(&.{ 0xc0, 0x80 }));
    try std.testing.expectEqual(@as(usize, 1), builder.inner.array.len());
    var array = builder.finish();
    defer array.deinit();
    try std.testing.expectEqualStrings("Arrow 🏹 数据", (try array.get(0)).?);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var builder = BinaryBuilder.init(allocator);
    defer builder.deinit();
    for (0..300) |i| {
        const before_data = builder.inner.array.data.items.len;
        const before_nulls = builder.inner.array.null_count;
        builder.append(if (i % 4 == 0) null else "xyz") catch |err| {
            try std.testing.expectEqual(i, builder.inner.array.len());
            try std.testing.expectEqual(before_data, builder.inner.array.data.items.len);
            try std.testing.expectEqual(before_nulls, builder.inner.array.null_count);
            try std.testing.expectEqual(if (i == 0) @as(usize, 0) else i + 1, builder.inner.array.offsets.items.len);
            return err;
        };
    }
    var array = builder.finish();
    defer array.deinit();
    try std.testing.expectEqualStrings("xyz", (try array.get(299)).?);
}

test "variable binary every allocation failure is atomic and leak free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "length and terminal offset overflow are rejected before mutation" {
    var builder = BinaryBuilder.init(std.testing.allocator);
    defer builder.deinit();
    builder.inner.array.length = std.math.maxInt(i32);
    try std.testing.expectError(error.LengthOverflow, builder.append("x"));
    builder.inner.array.length = 0;
    try std.testing.expectEqual(@as(i32, std.math.maxInt(i32)), try checkedNextOffset(std.math.maxInt(i32) - 1, 1));
    try std.testing.expectError(error.OffsetOverflow, checkedNextOffset(std.math.maxInt(i32), 1));
    var empty = builder.finish();
    defer empty.deinit();
    try std.testing.expectEqual(@as(i32, 0), try empty.offsetAt(0));
    try std.testing.expectError(error.OutOfBounds, empty.offsetAt(1));
}
