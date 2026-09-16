//! Bounded, zero-allocation Arrow IPC message-envelope parsing.
const std = @import("std");

pub const Limits = struct {
    max_metadata_bytes: usize,
    max_body_bytes: usize,
};

pub const MetadataVersion = enum(u16) { v1, v2, v3, v4, v5 };

pub const MessageHeader = enum(u8) {
    schema = 1,
    dictionary_batch = 2,
    record_batch = 3,
    tensor = 4,
    sparse_tensor = 5,
};

pub const Message = struct {
    metadata_version: MetadataVersion,
    header: MessageHeader,
    metadata: []const u8,
    body: []const u8,
    consumed: usize,
};

pub const Frame = union(enum) {
    eos: usize,
    message: Message,
};

pub const ParseError = error{
    Truncated,
    InvalidContinuation,
    MetadataTooLarge,
    BodyTooLarge,
    InvalidAlignment,
    InvalidFlatbuffer,
    UnsupportedMetadataVersion,
    UnsupportedMessageHeader,
    NegativeBodyLength,
    LengthOverflow,
};

const continuation: u32 = 0xffff_ffff;

/// Parses one current-format encapsulated IPC message or canonical EOS.
/// All returned slices borrow `input` and remain valid only while it is live.
pub fn parseFrame(input: []const u8, limits: Limits) ParseError!Frame {
    if (input.len < 8) return error.Truncated;
    if (readU32(input, 0) != continuation) return error.InvalidContinuation;
    const metadata_len: usize = readU32(input, 4);
    if (metadata_len == 0) return .{ .eos = 8 };
    if (metadata_len > limits.max_metadata_bytes) return error.MetadataTooLarge;
    if (metadata_len % 8 != 0) return error.InvalidAlignment;
    const metadata_end = std.math.add(usize, 8, metadata_len) catch return error.LengthOverflow;
    if (metadata_end > input.len) return error.Truncated;
    const metadata = input[8..metadata_end];

    const root = readU32Checked(metadata, 0) catch return error.InvalidFlatbuffer;
    const table = try Table.init(metadata, root);
    const version_raw = try table.readU16(0, 0);
    if (version_raw > @intFromEnum(MetadataVersion.v5)) return error.UnsupportedMetadataVersion;
    const version: MetadataVersion = @enumFromInt(version_raw);
    const header_raw = try table.readU8(1, 0);
    const header: MessageHeader = switch (header_raw) {
        1 => .schema,
        2 => .dictionary_batch,
        3 => .record_batch,
        4 => .tensor,
        5 => .sparse_tensor,
        else => return error.UnsupportedMessageHeader,
    };
    _ = try table.readTable(2);
    const body_signed = try table.readI64(3, 0);
    if (body_signed < 0) return error.NegativeBodyLength;
    const body_len: usize = std.math.cast(usize, body_signed) orelse return error.BodyTooLarge;
    if (body_len > limits.max_body_bytes) return error.BodyTooLarge;
    if (body_len % 8 != 0) return error.InvalidAlignment;
    const frame_end = std.math.add(usize, metadata_end, body_len) catch return error.LengthOverflow;
    if (frame_end > input.len) return error.Truncated;
    return .{ .message = .{
        .metadata_version = version,
        .header = header,
        .metadata = metadata,
        .body = input[metadata_end..frame_end],
        .consumed = frame_end,
    } };
}

const Table = struct {
    bytes: []const u8,
    table: usize,
    vtable: usize,
    vtable_len: usize,
    object_len: usize,

    fn init(bytes: []const u8, table_offset: usize) ParseError!Table {
        if (table_offset > bytes.len or bytes.len - table_offset < 4) return error.InvalidFlatbuffer;
        const relative = readI32(bytes, table_offset);
        const vtable = if (relative >= 0)
            std.math.sub(usize, table_offset, @intCast(relative)) catch return error.InvalidFlatbuffer
        else
            std.math.add(usize, table_offset, @as(usize, @intCast(-@as(i64, relative)))) catch return error.InvalidFlatbuffer;
        if (vtable > bytes.len or bytes.len - vtable < 4) return error.InvalidFlatbuffer;
        const vtable_len: usize = loadU16(bytes, vtable);
        const object_len: usize = loadU16(bytes, vtable + 2);
        if (vtable_len < 4 or vtable_len % 2 != 0 or vtable_len > bytes.len - vtable) return error.InvalidFlatbuffer;
        if (object_len < 4 or object_len > bytes.len - table_offset) return error.InvalidFlatbuffer;
        return .{ .bytes = bytes, .table = table_offset, .vtable = vtable, .vtable_len = vtable_len, .object_len = object_len };
    }

    fn field(self: Table, index: usize, width: usize) ParseError!?usize {
        const entry_delta = std.math.mul(usize, index, 2) catch return error.InvalidFlatbuffer;
        const entry = std.math.add(usize, self.vtable, 4 + entry_delta) catch return error.InvalidFlatbuffer;
        if (entry + 2 > self.vtable + self.vtable_len) return null;
        const offset: usize = loadU16(self.bytes, entry);
        if (offset == 0) return null;
        if (offset > self.object_len or width > self.object_len - offset) return error.InvalidFlatbuffer;
        const position = std.math.add(usize, self.table, offset) catch return error.InvalidFlatbuffer;
        if (position > self.bytes.len or width > self.bytes.len - position) return error.InvalidFlatbuffer;
        return position;
    }

    fn readU8(self: Table, index: usize, default: u8) ParseError!u8 {
        return if (try self.field(index, 1)) |position| self.bytes[position] else default;
    }

    fn readU16(self: Table, index: usize, default: u16) ParseError!u16 {
        return if (try self.field(index, 2)) |position| loadU16(self.bytes, position) else default;
    }

    fn readI64(self: Table, index: usize, default: i64) ParseError!i64 {
        return if (try self.field(index, 8)) |position| loadI64(self.bytes, position) else default;
    }

    fn readTable(self: Table, index: usize) ParseError!Table {
        const position = (try self.field(index, 4)) orelse return error.InvalidFlatbuffer;
        const relative: usize = readU32(self.bytes, position);
        const target = std.math.add(usize, position, relative) catch return error.InvalidFlatbuffer;
        return Table.init(self.bytes, target);
    }
};

fn loadU16(bytes: []const u8, offset: usize) u16 {
    return @as(u16, bytes[offset]) | (@as(u16, bytes[offset + 1]) << 8);
}

fn readU32(bytes: []const u8, offset: usize) u32 {
    return @as(u32, bytes[offset]) |
        (@as(u32, bytes[offset + 1]) << 8) |
        (@as(u32, bytes[offset + 2]) << 16) |
        (@as(u32, bytes[offset + 3]) << 24);
}

fn readU32Checked(bytes: []const u8, offset: usize) error{Truncated}!u32 {
    if (offset > bytes.len or bytes.len - offset < 4) return error.Truncated;
    return readU32(bytes, offset);
}

fn readI32(bytes: []const u8, offset: usize) i32 {
    return @bitCast(readU32(bytes, offset));
}

fn loadI64(bytes: []const u8, offset: usize) i64 {
    var value: u64 = 0;
    for (0..8) |i| value |= @as(u64, bytes[offset + i]) << @intCast(i * 8);
    return @bitCast(value);
}

fn writeU16(bytes: []u8, offset: usize, value: u16) void {
    bytes[offset] = @truncate(value);
    bytes[offset + 1] = @truncate(value >> 8);
}

fn writeU32(bytes: []u8, offset: usize, value: u32) void {
    for (0..4) |i| bytes[offset + i] = @truncate(value >> @intCast(i * 8));
}

fn writeI64(bytes: []u8, offset: usize, value: i64) void {
    const raw: u64 = @bitCast(value);
    for (0..8) |i| bytes[offset + i] = @truncate(raw >> @intCast(i * 8));
}

fn testFrame(header: MessageHeader, body_len: usize) [80]u8 {
    var frame: [80]u8 = @splat(0);
    writeU32(&frame, 0, continuation);
    writeU32(&frame, 4, 64);
    const metadata = frame[8..72];
    writeU32(metadata, 0, 24);
    writeU16(metadata, 8, 14);
    writeU16(metadata, 10, 24);
    writeU16(metadata, 12, 4);
    writeU16(metadata, 14, 6);
    writeU16(metadata, 16, 8);
    writeU16(metadata, 18, 16);
    writeU32(metadata, 24, 16);
    writeU16(metadata, 28, @intFromEnum(MetadataVersion.v5));
    metadata[30] = @intFromEnum(header);
    writeU32(metadata, 32, 24);
    writeI64(metadata, 40, @intCast(body_len));
    writeU16(metadata, 48, 4);
    writeU16(metadata, 50, 4);
    writeU32(metadata, 56, 8);
    return frame;
}

const test_limits: Limits = .{ .max_metadata_bytes = 1024, .max_body_bytes = 1024 };

test "IPC message envelope parses bounded messages and EOS" {
    var frame = testFrame(.record_batch, 8);
    const parsed = (try parseFrame(&frame, test_limits)).message;
    try std.testing.expectEqual(MetadataVersion.v5, parsed.metadata_version);
    try std.testing.expectEqual(MessageHeader.record_batch, parsed.header);
    try std.testing.expectEqual(@as(usize, 64), parsed.metadata.len);
    try std.testing.expectEqual(@as(usize, 8), parsed.body.len);
    try std.testing.expectEqual(@as(usize, 80), parsed.consumed);

    const eos = [_]u8{ 0xff, 0xff, 0xff, 0xff, 0, 0, 0, 0 };
    try std.testing.expectEqual(@as(usize, 8), (try parseFrame(&eos, test_limits)).eos);
}

test "IPC message envelope rejects truncation, malformed offsets and limits" {
    var valid = testFrame(.record_batch, 8);
    for (0..valid.len) |length| try std.testing.expectError(error.Truncated, parseFrame(valid[0..length], test_limits));

    var changed = valid;
    changed[0] = 0;
    try std.testing.expectError(error.InvalidContinuation, parseFrame(&changed, test_limits));
    changed = valid;
    writeU32(&changed, 4, 63);
    try std.testing.expectError(error.InvalidAlignment, parseFrame(&changed, test_limits));
    try std.testing.expectError(error.MetadataTooLarge, parseFrame(&valid, .{ .max_metadata_bytes = 63, .max_body_bytes = 1024 }));
    try std.testing.expectError(error.BodyTooLarge, parseFrame(&valid, .{ .max_metadata_bytes = 1024, .max_body_bytes = 7 }));

    changed = valid;
    writeU32(changed[8..], 0, 64);
    try std.testing.expectError(error.InvalidFlatbuffer, parseFrame(&changed, test_limits));
    changed = valid;
    writeU32(changed[8..], 24, 25);
    try std.testing.expectError(error.InvalidFlatbuffer, parseFrame(&changed, test_limits));
    changed = valid;
    writeU16(changed[8..], 8, 3);
    try std.testing.expectError(error.InvalidFlatbuffer, parseFrame(&changed, test_limits));
    changed = valid;
    writeU16(changed[8..], 10, 8);
    try std.testing.expectError(error.InvalidFlatbuffer, parseFrame(&changed, test_limits));
    changed = valid;
    writeU16(changed[8..], 28, 5);
    try std.testing.expectError(error.UnsupportedMetadataVersion, parseFrame(&changed, test_limits));
    changed = valid;
    writeU16(changed[8..], 16, 23);
    try std.testing.expectError(error.InvalidFlatbuffer, parseFrame(&changed, test_limits));
    changed = valid;
    changed[38] = 0;
    try std.testing.expectError(error.UnsupportedMessageHeader, parseFrame(&changed, test_limits));
    changed = valid;
    writeU32(changed[8..], 32, 64);
    try std.testing.expectError(error.InvalidFlatbuffer, parseFrame(&changed, test_limits));
    changed = valid;
    writeI64(changed[8..], 40, -1);
    try std.testing.expectError(error.NegativeBodyLength, parseFrame(&changed, test_limits));
    changed = valid;
    writeI64(changed[8..], 40, 7);
    try std.testing.expectError(error.InvalidAlignment, parseFrame(&changed, test_limits));
}
