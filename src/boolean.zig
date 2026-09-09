const std = @import("std");
const bitmap = @import("bitmap.zig");

/// Immutable borrowed view; the owner must remain alive and unmodified.
pub const BooleanView = struct {
    values: []const u8,
    validity: []const u8,
    offset: usize,
    len: usize,

    pub fn get(self: BooleanView, index: usize) error{OutOfBounds}!?bool {
        if (index >= self.len) return error.OutOfBounds;
        const physical = self.offset + index;
        return if (bitmap.isSet(self.validity, physical)) bitmap.isSet(self.values, physical) else null;
    }

    pub fn slice(self: BooleanView, offset: usize, len: usize) error{OutOfBounds}!BooleanView {
        if (offset > self.len or len > self.len - offset) return error.OutOfBounds;
        return .{ .values = self.values, .validity = self.validity, .offset = self.offset + offset, .len = len };
    }
};

/// Owning bit-packed array. Do not copy; deinit once or transfer to C export.
pub const BooleanArray = struct {
    allocator: std.mem.Allocator,
    values: std.ArrayList(u8) = .empty,
    validity: std.ArrayList(u8) = .empty,
    length: usize = 0,
    null_count: usize = 0,

    pub fn deinit(self: *BooleanArray) void {
        self.values.deinit(self.allocator);
        self.validity.deinit(self.allocator);
        self.* = .{ .allocator = self.allocator };
    }

    pub fn len(self: *const BooleanArray) usize {
        return self.length;
    }

    pub fn view(self: *const BooleanArray) BooleanView {
        return .{ .values = self.values.items, .validity = self.validity.items, .offset = 0, .len = self.length };
    }

    pub fn get(self: *const BooleanArray, index: usize) error{OutOfBounds}!?bool {
        return self.view().get(index);
    }
};

pub const BooleanBuilder = struct {
    array: BooleanArray,

    pub fn init(allocator: std.mem.Allocator) BooleanBuilder {
        return .{ .array = .{ .allocator = allocator } };
    }

    pub fn deinit(self: *BooleanBuilder) void {
        self.array.deinit();
    }

    /// Logical state is unchanged on OOM; reserved capacity may increase.
    pub fn append(self: *BooleanBuilder, value: ?bool) !void {
        const index = self.array.length;
        if (index >= std.math.maxInt(i64) or index == std.math.maxInt(usize)) return error.LengthOverflow;
        const bytes = bitmap.byteLength(index + 1);
        try self.array.values.ensureTotalCapacity(self.array.allocator, bytes);
        try self.array.validity.ensureTotalCapacity(self.array.allocator, bytes);
        if (bytes > self.array.values.items.len) {
            self.array.values.appendAssumeCapacity(0);
            self.array.validity.appendAssumeCapacity(0);
        }
        bitmap.set(self.array.values.items, index, value orelse false);
        bitmap.set(self.array.validity.items, index, value != null);
        self.array.length += 1;
        self.array.null_count += @intFromBool(value == null);
    }

    /// Transfers buffers without copying; builder becomes empty and reusable.
    pub fn finish(self: *BooleanBuilder) BooleanArray {
        const result = self.array;
        self.array = .{ .allocator = result.allocator };
        return result;
    }
};

test "boolean packed layout, trailing bits, borrowed bounds and reuse" {
    var builder = BooleanBuilder.init(std.testing.allocator);
    defer builder.deinit();
    try std.testing.expectError(error.OutOfBounds, builder.array.get(0));
    for ([_]?bool{ true, false, null, true, false, true, null, true, true, null }) |value| try builder.append(value);
    var array = builder.finish();
    defer array.deinit();
    try std.testing.expectEqualSlices(u8, &.{ 0xa9, 0x01 }, array.values.items);
    try std.testing.expectEqualSlices(u8, &.{ 0xbb, 0x01 }, array.validity.items);
    try std.testing.expectEqual(@as(usize, 3), array.null_count);
    const slice = try (try array.view().slice(7, 3)).slice(1, 2);
    try std.testing.expectEqual(@as(?bool, true), try slice.get(0));
    try std.testing.expectEqual(@as(?bool, null), try slice.get(1));
    try std.testing.expectEqual(@as(?bool, false), try array.get(1));
    try std.testing.expectError(error.OutOfBounds, slice.get(2));
    try std.testing.expectError(error.OutOfBounds, slice.slice(1, std.math.maxInt(usize)));
    try std.testing.expectError(error.OutOfBounds, slice.slice(std.math.maxInt(usize), 0));
    try std.testing.expectEqual(@as(usize, 0), (try array.view().slice(10, 0)).len);
    try builder.append(false);
    try std.testing.expectEqual(@as(usize, 10), array.len());
    try std.testing.expectEqual(@as(?bool, false), try builder.array.get(0));
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var builder = BooleanBuilder.init(allocator);
    defer builder.deinit();
    for (0..600) |i| {
        const nulls = builder.array.null_count;
        builder.append(if (i % 3 == 0) null else i % 2 == 0) catch |err| {
            try std.testing.expectEqual(i, builder.array.len());
            try std.testing.expectEqual(nulls, builder.array.null_count);
            try std.testing.expectEqual(bitmap.byteLength(i), builder.array.values.items.len);
            try std.testing.expectEqual(bitmap.byteLength(i), builder.array.validity.items.len);
            for (0..i) |j| try std.testing.expectEqual(if (j % 3 == 0) @as(?bool, null) else j % 2 == 0, try builder.array.get(j));
            return err;
        };
    }
    var array = builder.finish();
    defer array.deinit();
    try std.testing.expectEqual(@as(?bool, false), try array.get(599));
}

test "boolean every allocation failure is atomic and leak free" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}

test "boolean length overflow rejected before allocation or mutation" {
    var builder = BooleanBuilder.init(std.testing.allocator);
    defer builder.deinit();
    builder.array.length = std.math.maxInt(usize);
    try std.testing.expectError(error.LengthOverflow, builder.append(true));
    try std.testing.expectEqual(std.math.maxInt(usize), builder.array.length);
    try std.testing.expectEqual(@as(usize, 0), builder.array.values.items.len);
    builder.array.length = 0;
}
