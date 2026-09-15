//! Pure-Zig Arrow C Stream ABI and synchronous array/record-batch consumer.
const std = @import("std");
const c = @import("c_data.zig");
const data_import = @import("c_data_import.zig");
const record_batch = @import("record_batch.zig");

pub const ArrowArrayStream = extern struct {
    get_schema: ?*const fn (*ArrowArrayStream, *c.ArrowSchema) callconv(.c) c_int = null,
    get_next: ?*const fn (*ArrowArrayStream, *c.ArrowArray) callconv(.c) c_int = null,
    get_last_error: ?*const fn (*ArrowArrayStream) callconv(.c) ?[*:0]const u8 = null,
    release: ?*const fn (*ArrowArrayStream) callconv(.c) void = null,
    private_data: ?*anyopaque = null,
};

pub const StreamError = data_import.ImportError || error{
    MissingCallback,
    SchemaAlreadyRead,
    SchemaNotReady,
    InvalidSchemaResult,
    ProducerError,
    NoProducerError,
};

/// Independently owned chunk returned by a C stream. Do not copy.
pub const StreamChunk = struct {
    array: c.ArrowArray = .{},
    view: ?record_batch.ArrayView = null,

    pub fn borrow(self: *const StreamChunk) error{Released}!record_batch.ArrayView {
        if (self.array.release == null or self.view == null) return error.Released;
        return self.view.?;
    }

    pub fn move(self: *StreamChunk) StreamChunk {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn deinit(self: *StreamChunk) void {
        c.releaseArray(&self.array);
        self.* = .{};
    }
};

/// Singular owner and serialized consumer of an ArrowArrayStream. Do not copy.
pub const ImportedStream = struct {
    stream: ArrowArrayStream = .{},
    schema: c.ArrowSchema = .{},
    schema_requested: bool = false,
    ended: bool = false,
    last_error_code: ?c_int = null,
    error_text_read: bool = false,

    /// Validates mandatory callbacks, then moves and clears the caller structure.
    pub fn take(stream: *ArrowArrayStream) StreamError!ImportedStream {
        if (stream.release == null) return error.Released;
        if (stream.get_schema == null or stream.get_next == null or stream.get_last_error == null) return error.MissingCallback;
        const result: ImportedStream = .{ .stream = stream.* };
        stream.* = .{};
        return result;
    }

    /// Calls the producer exactly once and owns the independently returned schema.
    pub fn readSchema(self: *ImportedStream) StreamError!void {
        try self.requireLive();
        if (self.schema_requested) return error.SchemaAlreadyRead;
        self.schema_requested = true;
        var output: c.ArrowSchema = .{};
        const code = self.stream.get_schema.?(&self.stream, &output);
        if (code != 0) {
            c.releaseSchema(&output);
            self.recordProducerError(code);
            return error.ProducerError;
        }
        self.clearProducerError();
        if (output.release == null) return error.InvalidSchemaResult;
        self.schema = output;
    }

    /// Pulls one independently owned chunk, or null after canonical EOS.
    pub fn next(self: *ImportedStream) StreamError!?StreamChunk {
        try self.requireLive();
        if (self.schema.release == null) return error.SchemaNotReady;
        if (isStructSchema(&self.schema)) return error.UnsupportedType;
        if (self.ended) return null;
        var output: c.ArrowArray = .{};
        const code = self.stream.get_next.?(&self.stream, &output);
        if (code != 0) {
            c.releaseArray(&output);
            self.recordProducerError(code);
            return error.ProducerError;
        }
        self.clearProducerError();
        if (output.release == null) {
            self.ended = true;
            return null;
        }
        const view = data_import.borrowArray(&output, &self.schema) catch |err| {
            c.releaseArray(&output);
            return err;
        };
        return .{ .array = output, .view = view };
    }

    /// Pulls one independently owned record batch from a `+s` stream.
    /// The allocator owns recursive descriptors and a native schema deep copy.
    pub fn nextRecordBatch(self: *ImportedStream, allocator: std.mem.Allocator) !?data_import.ImportedRecordBatch {
        try self.requireLive();
        if (self.schema.release == null) return error.SchemaNotReady;
        if (!isStructSchema(&self.schema)) return error.UnsupportedType;
        if (self.ended) return null;
        var output: c.ArrowArray = .{};
        const code = self.stream.get_next.?(&self.stream, &output);
        if (code != 0) {
            c.releaseArray(&output);
            self.recordProducerError(code);
            return error.ProducerError;
        }
        self.clearProducerError();
        if (output.release == null) {
            self.ended = true;
            return null;
        }
        return data_import.ImportedRecordBatch.takeArray(allocator, &output, &self.schema) catch |err| {
            c.releaseArray(&output);
            return err;
        };
    }

    pub fn lastErrorCode(self: *const ImportedStream) ?c_int {
        return self.last_error_code;
    }

    /// Producer-borrowed text, valid only until the next stream callback.
    pub fn lastError(self: *ImportedStream) StreamError!?[:0]const u8 {
        try self.requireLive();
        if (self.last_error_code == null or self.error_text_read) return error.NoProducerError;
        self.error_text_read = true;
        const pointer = self.stream.get_last_error.?(&self.stream) orelse return null;
        return std.mem.span(pointer);
    }

    pub fn move(self: *ImportedStream) ImportedStream {
        const result = self.*;
        self.* = .{};
        return result;
    }

    pub fn deinit(self: *ImportedStream) void {
        c.releaseSchema(&self.schema);
        if (self.stream.release) |release| release(&self.stream);
        self.* = .{};
    }

    fn requireLive(self: *const ImportedStream) error{Released}!void {
        if (self.stream.release == null) return error.Released;
    }

    fn recordProducerError(self: *ImportedStream, code: c_int) void {
        self.last_error_code = code;
        self.error_text_read = false;
    }

    fn clearProducerError(self: *ImportedStream) void {
        self.last_error_code = null;
        self.error_text_read = false;
    }
};

fn isStructSchema(schema: *const c.ArrowSchema) bool {
    const format = schema.format orelse return false;
    return format[0] == '+' and format[1] == 's' and format[2] == 0;
}

const TestState = struct {
    buffers: *[2]?*const anyopaque,
    schema_calls: usize = 0,
    next_calls: usize = 0,
    error_calls: usize = 0,
    array_releases: usize = 0,
    schema_releases: usize = 0,
    stream_releases: usize = 0,
    fail_schema: bool = false,
    fail_next: bool = false,
};

const BatchTestState = struct {
    values: [1]i32 = .{42},
    leaf_buffers: [2]?*const anyopaque = .{ null, null },
    root_buffers: [1]?*const anyopaque = .{null},
    child: c.ArrowArray = .{},
    array_children: [1]?*c.ArrowArray = .{null},
    child_schema: c.ArrowSchema = .{},
    schema_children: [1]?*c.ArrowSchema = .{null},
    next_calls: usize = 0,
    array_releases: usize = 0,
    schema_releases: usize = 0,
    stream_releases: usize = 0,
    invalid_first: bool = false,

    fn prepare(self: *BatchTestState) void {
        self.leaf_buffers[1] = @ptrCast(&self.values);
        self.child = .{ .length = 1, .n_buffers = 2, .buffers = &self.leaf_buffers, .release = batchChildArrayRelease };
        self.array_children[0] = &self.child;
        self.child_schema = .{ .format = "i", .name = "answer", .flags = 0, .release = batchChildSchemaRelease };
        self.schema_children[0] = &self.child_schema;
    }
};

fn batchState(stream: *ArrowArrayStream) *BatchTestState {
    return @ptrCast(@alignCast(stream.private_data.?));
}

fn batchGetSchema(stream: *ArrowArrayStream, output: *c.ArrowSchema) callconv(.c) c_int {
    const state = batchState(stream);
    output.* = .{ .format = "+s", .n_children = 1, .children = &state.schema_children, .release = batchSchemaRelease, .private_data = state };
    return 0;
}

fn batchGetNext(stream: *ArrowArrayStream, output: *c.ArrowArray) callconv(.c) c_int {
    const state = batchState(stream);
    state.next_calls += 1;
    const chunk_index = state.next_calls - 1;
    const chunk_count: usize = if (state.invalid_first) 2 else 1;
    if (chunk_index >= chunk_count) return 0;
    output.* = .{ .length = 1, .n_buffers = if (state.invalid_first and chunk_index == 0) 2 else 1, .n_children = 1, .buffers = &state.root_buffers, .children = &state.array_children, .release = batchArrayRelease, .private_data = state };
    return 0;
}

fn batchLastError(_: *ArrowArrayStream) callconv(.c) ?[*:0]const u8 {
    return null;
}

fn batchArrayRelease(array: *c.ArrowArray) callconv(.c) void {
    const state: *BatchTestState = @ptrCast(@alignCast(array.private_data.?));
    state.array_releases += 1;
    array.* = .{};
}

fn batchSchemaRelease(schema: *c.ArrowSchema) callconv(.c) void {
    const state: *BatchTestState = @ptrCast(@alignCast(schema.private_data.?));
    state.schema_releases += 1;
    schema.* = .{};
}

fn batchChildArrayRelease(array: *c.ArrowArray) callconv(.c) void {
    array.* = .{};
}

fn batchChildSchemaRelease(schema: *c.ArrowSchema) callconv(.c) void {
    schema.* = .{};
}

fn batchStreamRelease(stream: *ArrowArrayStream) callconv(.c) void {
    const state = batchState(stream);
    state.stream_releases += 1;
    stream.* = .{};
}

fn makeBatchTestStream(state: *BatchTestState) ArrowArrayStream {
    state.prepare();
    return .{ .get_schema = batchGetSchema, .get_next = batchGetNext, .get_last_error = batchLastError, .release = batchStreamRelease, .private_data = state };
}

fn testState(stream: *ArrowArrayStream) *TestState {
    return @ptrCast(@alignCast(stream.private_data.?));
}

fn testGetSchema(stream: *ArrowArrayStream, output: *c.ArrowSchema) callconv(.c) c_int {
    const state = testState(stream);
    state.schema_calls += 1;
    output.* = .{ .format = "i", .release = testSchemaRelease, .private_data = state };
    return if (state.fail_schema) 22 else 0;
}

fn testGetNext(stream: *ArrowArrayStream, output: *c.ArrowArray) callconv(.c) c_int {
    const state = testState(stream);
    state.next_calls += 1;
    if (state.fail_next) {
        output.* = .{ .length = 2, .n_buffers = 2, .buffers = state.buffers, .release = testArrayRelease, .private_data = state };
        return 5;
    }
    if (state.next_calls > 1) {
        output.* = .{};
        return 0;
    }
    output.* = .{ .length = 2, .n_buffers = 2, .buffers = state.buffers, .release = testArrayRelease, .private_data = state };
    return 0;
}

fn testLastError(stream: *ArrowArrayStream) callconv(.c) ?[*:0]const u8 {
    const state = testState(stream);
    state.error_calls += 1;
    return if (state.fail_schema) "schema failed" else "next failed";
}

fn testArrayRelease(array: *c.ArrowArray) callconv(.c) void {
    const state: *TestState = @ptrCast(@alignCast(array.private_data.?));
    state.array_releases += 1;
    array.* = .{};
}

fn testSchemaRelease(schema: *c.ArrowSchema) callconv(.c) void {
    const state: *TestState = @ptrCast(@alignCast(schema.private_data.?));
    state.schema_releases += 1;
    schema.* = .{};
}

fn testStreamRelease(stream: *ArrowArrayStream) callconv(.c) void {
    const state = testState(stream);
    state.stream_releases += 1;
    stream.* = .{};
}

fn makeTestStream(state: *TestState) ArrowArrayStream {
    return .{
        .get_schema = testGetSchema,
        .get_next = testGetNext,
        .get_last_error = testLastError,
        .release = testStreamRelease,
        .private_data = state,
    };
}

test "stream ABI layout contains five pointer-sized fields" {
    try std.testing.expectEqual(@as(usize, 5) * @sizeOf(usize), @sizeOf(ArrowArrayStream));
    inline for (std.meta.fields(ArrowArrayStream), 0..) |field, index| {
        try std.testing.expectEqual(index * @sizeOf(usize), @offsetOf(ArrowArrayStream, field.name));
    }
}

test "stream schema, chunk, relocation, independent lifetime and cached EOS" {
    const values = [_]i32{ 30, 31 };
    var buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };
    var state: TestState = .{ .buffers = &buffers };
    var source = makeTestStream(&state);
    var consumer = try ImportedStream.take(&source);
    try std.testing.expect(source.release == null);
    try std.testing.expectError(error.SchemaNotReady, consumer.next());
    try consumer.readSchema();
    try std.testing.expectError(error.SchemaAlreadyRead, consumer.readSchema());
    try std.testing.expectError(error.UnsupportedType, consumer.nextRecordBatch(std.testing.allocator));
    try std.testing.expectEqual(@as(usize, 0), state.next_calls);
    var chunk = (try consumer.next()).?;
    try std.testing.expectEqual(@as(?i32, 31), try (try chunk.borrow()).int32.get(1));
    try std.testing.expect((try consumer.next()) == null);
    try std.testing.expect((try consumer.next()) == null);
    try std.testing.expectEqual(@as(usize, 2), state.next_calls);

    var moved_consumer = consumer.move();
    try std.testing.expectError(error.Released, consumer.next());
    consumer.deinit();
    moved_consumer.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.schema_releases);
    try std.testing.expectEqual(@as(usize, 1), state.stream_releases);
    try std.testing.expectEqual(@as(?i32, 30), try (try chunk.borrow()).int32.get(0));

    var moved_chunk = chunk.move();
    try std.testing.expectError(error.Released, chunk.borrow());
    chunk.deinit();
    moved_chunk.deinit();
    moved_chunk.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.array_releases);
}

fn batchStreamAllocationScenario(allocator: std.mem.Allocator) !void {
    var state: BatchTestState = .{};
    var source = makeBatchTestStream(&state);
    var consumer = try ImportedStream.take(&source);
    try consumer.readSchema();
    try std.testing.expectError(error.UnsupportedType, consumer.next());
    try std.testing.expectEqual(@as(usize, 0), state.next_calls);
    var owner = (consumer.nextRecordBatch(allocator) catch |err| {
        consumer.deinit();
        try std.testing.expectEqual(@as(usize, 1), state.array_releases);
        try std.testing.expectEqual(@as(usize, 1), state.schema_releases);
        try std.testing.expectEqual(@as(usize, 1), state.stream_releases);
        return err;
    }).?;
    try std.testing.expect((try consumer.nextRecordBatch(allocator)) == null);
    try std.testing.expect((try consumer.nextRecordBatch(allocator)) == null);
    consumer.deinit();
    const batch = try owner.borrow();
    try std.testing.expectEqual(@as(?i32, 42), try (try batch.column(0)).int32.get(0));
    owner.deinit();
    try std.testing.expectEqual(@as(usize, 1), state.array_releases);
    try std.testing.expectEqual(@as(usize, 1), state.schema_releases);
    try std.testing.expectEqual(@as(usize, 1), state.stream_releases);
    try std.testing.expectEqual(@as(usize, 2), state.next_calls);
}

test "record-batch stream survives every allocation failure and owns chunks independently" {
    try std.testing.checkAllAllocationFailures(std.testing.allocator, batchStreamAllocationScenario, .{});
}

test "record-batch stream releases malformed chunks and remains usable" {
    var state: BatchTestState = .{ .invalid_first = true };
    var source = makeBatchTestStream(&state);
    var consumer = try ImportedStream.take(&source);
    defer consumer.deinit();
    try consumer.readSchema();
    try std.testing.expectError(error.InvalidBufferCount, consumer.nextRecordBatch(std.testing.allocator));
    try std.testing.expectEqual(@as(?c_int, null), consumer.lastErrorCode());
    try std.testing.expectEqual(@as(usize, 1), state.array_releases);
    var owner = (try consumer.nextRecordBatch(std.testing.allocator)).?;
    defer owner.deinit();
    try std.testing.expectEqual(@as(?i32, 42), try (try (try owner.borrow()).column(0)).int32.get(0));
    try std.testing.expect((try consumer.nextRecordBatch(std.testing.allocator)) == null);
    try std.testing.expectEqual(@as(usize, 3), state.next_calls);
}

test "stream producer errors retain errno and release live partial outputs" {
    const values = [_]i32{ 1, 2 };
    var buffers = [_]?*const anyopaque{ null, @ptrCast(&values) };

    var schema_state: TestState = .{ .buffers = &buffers, .fail_schema = true };
    var schema_source = makeTestStream(&schema_state);
    var schema_consumer = try ImportedStream.take(&schema_source);
    try std.testing.expectError(error.ProducerError, schema_consumer.readSchema());
    try std.testing.expectError(error.SchemaAlreadyRead, schema_consumer.readSchema());
    try std.testing.expectEqual(@as(?c_int, 22), schema_consumer.lastErrorCode());
    try std.testing.expectEqualStrings("schema failed", (try schema_consumer.lastError()).?);
    try std.testing.expectError(error.NoProducerError, schema_consumer.lastError());
    try std.testing.expectEqual(@as(usize, 1), schema_state.schema_releases);
    schema_consumer.deinit();
    try std.testing.expectEqual(@as(usize, 1), schema_state.stream_releases);

    var next_state: TestState = .{ .buffers = &buffers, .fail_next = true };
    var next_source = makeTestStream(&next_state);
    var next_consumer = try ImportedStream.take(&next_source);
    try next_consumer.readSchema();
    try std.testing.expectError(error.ProducerError, next_consumer.next());
    try std.testing.expectEqual(@as(?c_int, 5), next_consumer.lastErrorCode());
    try std.testing.expectEqualStrings("next failed", (try next_consumer.lastError()).?);
    try std.testing.expectEqual(@as(usize, 1), next_state.array_releases);
    next_consumer.deinit();
    try std.testing.expectEqual(@as(usize, 1), next_state.schema_releases);
    try std.testing.expectEqual(@as(usize, 1), next_state.stream_releases);
}

test "stream take rejects released and incomplete callback tables without move" {
    var released: ArrowArrayStream = .{};
    try std.testing.expectError(error.Released, ImportedStream.take(&released));
    var incomplete: ArrowArrayStream = .{ .release = testStreamRelease };
    try std.testing.expectError(error.MissingCallback, ImportedStream.take(&incomplete));
    try std.testing.expect(incomplete.release != null);
}
