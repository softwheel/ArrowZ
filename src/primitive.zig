const std = @import("std");
const bitmap = @import("bitmap.zig");

pub fn checkType(comptime T: type) void {
    switch (T) {
        i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 => {},
        else => @compileError("ArrowZ primitives support i/u8/16/32/64 and f32/f64"),
    }
}

/// Borrowed immutable view. The owning array must remain alive and unmodified.
pub fn PrimitiveView(comptime T: type) type {
    checkType(T);
    return struct {
        values: []const T,
        validity: []const u8,
        offset: usize,
        len: usize,
        const Self = @This();

        pub fn get(self: Self, index: usize) error{OutOfBounds}!?T {
            if (index >= self.len) return error.OutOfBounds;
            const physical = self.offset + index;
            return if (self.validity.len == 0 or bitmap.isSet(self.validity, physical)) self.values[physical] else null;
        }

        pub fn slice(self: Self, offset: usize, len: usize) error{OutOfBounds}!Self {
            if (offset > self.len or len > self.len - offset) return error.OutOfBounds;
            return .{ .values = self.values, .validity = self.validity, .offset = self.offset + offset, .len = len };
        }
    };
}

/// Owning array: do not copy. Deinit once, or transfer through the C export adapter.
pub fn PrimitiveArray(comptime T: type) type {
    checkType(T);
    return struct {
        allocator: std.mem.Allocator,
        values: std.ArrayList(T) = .empty,
        validity: std.ArrayList(u8) = .empty,
        null_count: usize = 0,
        const Self = @This();

        pub fn deinit(self: *Self) void {
            self.values.deinit(self.allocator);
            self.validity.deinit(self.allocator);
            self.* = .{ .allocator = self.allocator };
        }

        pub fn len(self: *const Self) usize {
            return self.values.items.len;
        }

        pub fn view(self: *const Self) PrimitiveView(T) {
            return .{ .values = self.values.items, .validity = self.validity.items, .offset = 0, .len = self.len() };
        }

        pub fn get(self: *const Self, index: usize) error{OutOfBounds}!?T {
            return self.view().get(index);
        }
    };
}

/// Append is logically atomic on allocation failure; capacity may still increase.
pub fn PrimitiveBuilder(comptime T: type) type {
    checkType(T);
    return struct {
        array: PrimitiveArray(T),
        const Self = @This();

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{ .array = .{ .allocator = allocator } };
        }

        pub fn deinit(self: *Self) void {
            self.array.deinit();
        }

        pub fn append(self: *Self, value: ?T) !void {
            const index = self.array.len();
            if (index >= std.math.maxInt(i64)) return error.LengthOverflow;
            try self.array.values.ensureUnusedCapacity(self.array.allocator, 1);
            const bytes = bitmap.byteLength(index + 1);
            try self.array.validity.ensureTotalCapacity(self.array.allocator, bytes);
            if (bytes > self.array.validity.items.len) self.array.validity.appendAssumeCapacity(0);
            self.array.values.appendAssumeCapacity(value orelse 0);
            bitmap.set(self.array.validity.items, index, value != null);
            self.array.null_count += @intFromBool(value == null);
        }

        /// Transfers buffers without copying. Builder becomes empty and reusable.
        pub fn finish(self: *Self) PrimitiveArray(T) {
            const result = self.array;
            self.array = .{ .allocator = result.allocator };
            return result;
        }
    };
}

test "native primitives, nullable values, nested slices and overflow bounds" {
    inline for (.{ i8, i16, i32, i64, u8, u16, u32, u64, f32, f64 }) |T| {
        var builder = PrimitiveBuilder(T).init(std.testing.allocator);
        defer builder.deinit();
        for (0..20) |i| try builder.append(if (i % 3 == 0) null else @as(T, 7));
        var array = builder.finish();
        defer array.deinit();
        try std.testing.expectEqual(@as(usize, 20), array.len());
        try std.testing.expectEqual(@as(usize, 7), array.null_count);
        try std.testing.expectEqual(@as(?T, null), try array.get(0));
        const slice = try (try array.view().slice(7, 8)).slice(1, 3);
        try std.testing.expectEqual(@as(?T, 7), try slice.get(0));
        try std.testing.expectEqual(@as(?T, null), try slice.get(1));
        try std.testing.expectError(error.OutOfBounds, slice.get(3));
        try std.testing.expectError(error.OutOfBounds, slice.slice(1, std.math.maxInt(usize)));
        try std.testing.expectError(error.OutOfBounds, slice.slice(std.math.maxInt(usize), 0));
        try std.testing.expectEqual(@as(usize, 0), (try array.view().slice(20, 0)).len);
        try builder.append(2);
        try std.testing.expectEqual(@as(usize, 20), array.len());
    }
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    var builder = PrimitiveBuilder(i64).init(allocator);
    defer builder.deinit();
    for (0..80) |i| {
        const before_len = builder.array.len();
        const before_nulls = builder.array.null_count;
        builder.append(if (i % 2 == 0) null else @intCast(i)) catch |err| {
            try std.testing.expectEqual(before_len, builder.array.len());
            try std.testing.expectEqual(before_nulls, builder.array.null_count);
            for (0..before_len) |j| {
                try std.testing.expectEqual(if (j % 2 == 0) @as(?i64, null) else @as(?i64, @intCast(j)), try builder.array.get(j));
            }
            return err;
        };
    }
    var array = builder.finish();
    defer array.deinit();
    try std.testing.expectEqual(@as(?i64, 79), try array.get(79));
}

test "every builder allocation failure releases all memory" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
}
