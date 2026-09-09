const std = @import("std");

pub const DataType = enum {
    int8,
    uint8,
    int16,
    uint16,
    int32,
    uint32,
    int64,
    uint64,
    float32,
    float64,
    boolean,
    binary,
    utf8,
};

pub const MetadataEntry = struct {
    key: []const u8,
    value: []const u8,
};

pub const FieldSpec = struct {
    name: []const u8,
    data_type: DataType,
    nullable: bool = true,
    metadata: []const MetadataEntry = &.{},
};

pub const Metadata = struct {
    key: []u8,
    value: []u8,

    fn deinit(self: *Metadata, allocator: std.mem.Allocator) void {
        allocator.free(self.key);
        allocator.free(self.value);
        self.* = undefined;
    }
};

pub const Field = struct {
    name: []u8,
    data_type: DataType,
    nullable: bool,
    metadata: []Metadata,

    fn deinit(self: *Field, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        deinitMetadata(allocator, self.metadata);
        self.* = undefined;
    }
};

/// Owning schema. Do not copy; all input names and metadata are deep-copied.
pub const Schema = struct {
    allocator: std.mem.Allocator,
    fields: []Field,
    metadata: []Metadata,

    pub fn init(
        allocator: std.mem.Allocator,
        field_specs: []const FieldSpec,
        metadata_specs: []const MetadataEntry,
    ) !Schema {
        const fields = try allocator.alloc(Field, field_specs.len);
        var fields_initialized: usize = 0;
        errdefer {
            for (fields[0..fields_initialized]) |*field| field.deinit(allocator);
            allocator.free(fields);
        }
        for (field_specs, 0..) |spec, i| {
            fields[i] = try cloneField(allocator, spec);
            fields_initialized += 1;
        }
        const metadata = try cloneMetadata(allocator, metadata_specs);
        return .{ .allocator = allocator, .fields = fields, .metadata = metadata };
    }

    pub fn deinit(self: *Schema) void {
        for (self.fields) |*field| field.deinit(self.allocator);
        self.allocator.free(self.fields);
        deinitMetadata(self.allocator, self.metadata);
        self.* = undefined;
    }

    pub fn fieldIndex(self: *const Schema, name: []const u8) ?usize {
        for (self.fields, 0..) |field, i| {
            if (std.mem.eql(u8, field.name, name)) return i;
        }
        return null;
    }
};

fn cloneField(allocator: std.mem.Allocator, spec: FieldSpec) !Field {
    if (!std.unicode.utf8ValidateSlice(spec.name)) return error.InvalidUtf8Name;
    const name = try allocator.dupe(u8, spec.name);
    errdefer allocator.free(name);
    const metadata = try cloneMetadata(allocator, spec.metadata);
    return .{ .name = name, .data_type = spec.data_type, .nullable = spec.nullable, .metadata = metadata };
}

fn cloneMetadata(allocator: std.mem.Allocator, specs: []const MetadataEntry) ![]Metadata {
    const result = try allocator.alloc(Metadata, specs.len);
    var initialized: usize = 0;
    errdefer {
        for (result[0..initialized]) |*entry| entry.deinit(allocator);
        allocator.free(result);
    }
    for (specs, 0..) |spec, i| {
        const key = try allocator.dupe(u8, spec.key);
        errdefer allocator.free(key);
        const value = try allocator.dupe(u8, spec.value);
        result[i] = .{ .key = key, .value = value };
        initialized += 1;
    }
    return result;
}

fn deinitMetadata(allocator: std.mem.Allocator, metadata: []Metadata) void {
    for (metadata) |*entry| entry.deinit(allocator);
    allocator.free(metadata);
}

fn allocationScenario(allocator: std.mem.Allocator) !void {
    const column_metadata = [_]MetadataEntry{
        .{ .key = "ARROW:extension:name", .value = "arrowz.test" },
        .{ .key = &.{ 0, 0xff }, .value = &.{ 0x80, 0 } },
    };
    const fields = [_]FieldSpec{
        .{ .name = "id", .data_type = .int64, .nullable = false },
        .{ .name = "数据", .data_type = .utf8, .metadata = &column_metadata },
    };
    const metadata = [_]MetadataEntry{.{ .key = "source", .value = "native-zig" }};
    var schema = try Schema.init(allocator, &fields, &metadata);
    defer schema.deinit();
    try std.testing.expectEqual(@as(usize, 1), schema.fieldIndex("数据").?);
    try std.testing.expectEqualSlices(u8, &.{ 0, 0xff }, schema.fields[1].metadata[1].key);
}

test "schema deep copy, UTF-8 names, metadata and every allocation failure" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationScenario, .{});
    var name = [_]u8{ 'i', 'd' };
    var key = [_]u8{'k'};
    var value = [_]u8{'v'};
    const metadata = [_]MetadataEntry{.{ .key = &key, .value = &value }};
    const fields = [_]FieldSpec{.{ .name = &name, .data_type = .int32, .metadata = &metadata }};
    var schema = try Schema.init(std.testing.allocator, &fields, &.{});
    defer schema.deinit();
    name[0] = 'x';
    key[0] = 'x';
    value[0] = 'x';
    try std.testing.expectEqualStrings("id", schema.fields[0].name);
    try std.testing.expectEqualStrings("k", schema.fields[0].metadata[0].key);
    try std.testing.expectEqualStrings("v", schema.fields[0].metadata[0].value);
    try std.testing.expectError(error.InvalidUtf8Name, Schema.init(std.testing.allocator, &.{.{ .name = &.{0xff}, .data_type = .binary }}, &.{}));
}

test "duplicate field names preserve order and first-match lookup" {
    var schema = try Schema.init(std.testing.allocator, &.{
        .{ .name = "x", .data_type = .int8 },
        .{ .name = "x", .data_type = .utf8 },
    }, &.{});
    defer schema.deinit();
    try std.testing.expectEqual(@as(?usize, 0), schema.fieldIndex("x"));
    try std.testing.expectEqual(@as(?usize, null), schema.fieldIndex("missing"));
}
