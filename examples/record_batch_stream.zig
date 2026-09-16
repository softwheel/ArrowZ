const std = @import("std");
const arrowz = @import("arrowz");

fn makeSchema(allocator: std.mem.Allocator) !arrowz.Schema {
    return arrowz.Schema.init(
        allocator,
        &.{.{ .name = "value", .data_type = .int32, .nullable = false }},
        &.{.{ .key = "source", .value = "arrowz-example" }},
    );
}

fn makeBatch(allocator: std.mem.Allocator) !arrowz.OwnedRecordBatch {
    var schema = try makeSchema(allocator);
    errdefer schema.deinit();
    var builder = arrowz.PrimitiveBuilder(i32).init(allocator);
    defer builder.deinit();
    try builder.append(42);
    var array = builder.finish();
    defer array.deinit();
    var columns = [_]arrowz.OwnedArray{arrowz.OwnedArray.takePrimitive(i32, &array)};
    errdefer columns[0].deinit();
    return arrowz.OwnedRecordBatch.take(allocator, &schema, &columns, 1);
}

pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var stream_schema = try makeSchema(allocator);
    errdefer stream_schema.deinit();
    var batches = [_]arrowz.OwnedRecordBatch{try makeBatch(allocator)};
    errdefer batches[0].deinit();

    var c_stream = try arrowz.exportRecordBatchStream(allocator, &stream_schema, &batches);
    var stream = try arrowz.ImportedStream.take(&c_stream);
    defer stream.deinit();
    try stream.readSchema();

    var received = (try stream.nextRecordBatch(allocator)) orelse return error.MissingBatch;
    defer received.deinit();
    const batch = try received.borrow();
    const value = switch (try batch.columnByName("value")) {
        .int32 => |column| (try column.get(0)) orelse return error.UnexpectedNull,
        else => return error.UnexpectedType,
    };
    if (try stream.nextRecordBatch(allocator) != null) return error.UnexpectedBatch;
    std.debug.print("stream rows={d}, value={d}\n", .{ batch.row_count, value });
}
