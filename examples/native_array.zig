const std = @import("std");
const arrowz = @import("arrowz");

pub fn main() !void {
    var builder = arrowz.PrimitiveBuilder(i64).init(std.heap.page_allocator);
    defer builder.deinit();
    try builder.append(42);
    try builder.append(null);
    try builder.append(100);
    var array = builder.finish();
    defer array.deinit();
    const slice = try array.view().slice(1, 2);
    std.debug.print("rows={d}, nulls={d}, slice[0]={?d}, slice[1]={?d}\n", .{
        array.len(), array.null_count, try slice.get(0), try slice.get(1),
    });
}
