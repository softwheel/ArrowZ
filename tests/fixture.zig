//! Test-only ABI fixture; not part of the public ArrowZ SDK.
const std = @import("std");
const z = @import("arrowz");
const c = z.c_data;

export fn arrowz_fixture(kind: u32, scenario: u32, out: *c.ArrowArray, schema: *c.ArrowSchema) c_int {
    if (out.release != null or schema.release != null) return 1;
    (switch (kind) {
        0 => produce(i8, scenario, out, schema),
        1 => produce(u8, scenario, out, schema),
        2 => produce(i16, scenario, out, schema),
        3 => produce(u16, scenario, out, schema),
        4 => produce(i32, scenario, out, schema),
        5 => produce(u32, scenario, out, schema),
        6 => produce(i64, scenario, out, schema),
        7 => produce(u64, scenario, out, schema),
        8 => produce(f32, scenario, out, schema),
        9 => produce(f64, scenario, out, schema),
        10 => produce(bool, scenario, out, schema),
        else => return 2,
    }) catch return 3;
    return 0;
}

fn produce(comptime T: type, scenario: u32, out: *c.ArrowArray, schema: *c.ArrowSchema) !void {
    if (scenario > 4) return error.BadScenario;
    var builder = (if (T == bool) z.BooleanBuilder else z.PrimitiveBuilder(T)).init(std.heap.page_allocator);
    defer builder.deinit();
    const count: usize = if (scenario == 0) 0 else 20;
    for (0..count) |i| {
        const value: T = switch (@typeInfo(T)) {
            .bool => i % 2 == 0,
            .float => @floatFromInt(i),
            else => @intCast(i),
        };
        try builder.append(if (scenario == 2 or (scenario >= 3 and i % 3 == 0)) null else value);
    }
    var array = builder.finish();
    defer array.deinit();
    var exported = if (T == bool) try c.exportBoolean(&array) else try c.exportPrimitive(T, &array);
    // Exercise non-byte-aligned offset through the standard ABI consumer rules.
    if (scenario == 4) {
        exported.array.offset = 7;
        exported.array.length = 9;
        exported.array.null_count = 3;
    }
    out.* = exported.array;
    schema.* = exported.schema;
    exported.array.release = null;
    exported.schema.release = null;
}

export fn arrowz_abi_size(which: u32) usize {
    return switch (which) {
        0 => @sizeOf(c.ArrowArray),
        1 => @sizeOf(c.ArrowSchema),
        else => 0,
    };
}

export fn arrowz_abi_offset(which: u32, field: u32) usize {
    if (which == 0) {
        inline for (std.meta.fields(c.ArrowArray), 0..) |f, i| {
            if (field == i) return @offsetOf(c.ArrowArray, f.name);
        }
    } else if (which == 1) {
        inline for (std.meta.fields(c.ArrowSchema), 0..) |f, i| {
            if (field == i) return @offsetOf(c.ArrowSchema, f.name);
        }
    }
    return std.math.maxInt(usize);
}
