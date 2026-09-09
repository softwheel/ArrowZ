//! Arrow validity bitmaps use least-significant-bit-first ordering.
const std = @import("std");

pub fn byteLength(bits: usize) usize {
    return bits / 8 + @intFromBool(bits % 8 != 0);
}

pub fn isSet(bytes: []const u8, index: usize) bool {
    return bytes[index / 8] & (@as(u8, 1) << @as(u3, @intCast(index % 8))) != 0;
}

pub fn set(bytes: []u8, index: usize, value: bool) void {
    const mask = @as(u8, 1) << @as(u3, @intCast(index % 8));
    if (value) bytes[index / 8] |= mask else bytes[index / 8] &= ~mask;
}

test "bitmap byte boundaries, bit order and overflow-free length" {
    var bytes = [_]u8{0} ** 2;
    set(&bytes, 0, true);
    set(&bytes, 7, true);
    set(&bytes, 8, true);
    try std.testing.expectEqualSlices(u8, &.{ 0x81, 0x01 }, &bytes);
    set(&bytes, 7, false);
    try std.testing.expect(!isSet(&bytes, 7));
    try std.testing.expectEqual(@as(usize, 0), byteLength(0));
    try std.testing.expectEqual(@as(usize, 2), byteLength(9));
    try std.testing.expectEqual(std.math.maxInt(usize) / 8 + 1, byteLength(std.math.maxInt(usize)));
}
