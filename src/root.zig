//! Pure Zig native Arrow arrays. Optional ABI adapters are exposed as c_data.
pub const bitmap = @import("bitmap.zig");
pub const PrimitiveArray = @import("primitive.zig").PrimitiveArray;
pub const PrimitiveBuilder = @import("primitive.zig").PrimitiveBuilder;
pub const PrimitiveView = @import("primitive.zig").PrimitiveView;
pub const c_data = @import("c_data.zig");
pub const BooleanArray = @import("boolean.zig").BooleanArray;
pub const BooleanBuilder = @import("boolean.zig").BooleanBuilder;
pub const BooleanView = @import("boolean.zig").BooleanView;

test {
    _ = bitmap;
    _ = @import("primitive.zig");
    _ = c_data;
    _ = @import("boolean.zig");
}
