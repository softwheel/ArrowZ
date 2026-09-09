//! Pure Zig native Arrow arrays. Optional ABI adapters are exposed as c_data.
pub const bitmap = @import("bitmap.zig");
pub const PrimitiveArray = @import("primitive.zig").PrimitiveArray;
pub const PrimitiveBuilder = @import("primitive.zig").PrimitiveBuilder;
pub const PrimitiveView = @import("primitive.zig").PrimitiveView;
pub const c_data = @import("c_data.zig");
pub const BooleanArray = @import("boolean.zig").BooleanArray;
pub const BooleanBuilder = @import("boolean.zig").BooleanBuilder;
pub const BooleanView = @import("boolean.zig").BooleanView;
pub const BinaryBuilder = @import("variable_binary.zig").BinaryBuilder;
pub const Utf8Builder = @import("variable_binary.zig").Utf8Builder;
pub const VariableBinaryArray = @import("variable_binary.zig").VariableBinaryArray;
pub const VariableBinaryView = @import("variable_binary.zig").VariableBinaryView;
pub const variable_binary = @import("variable_binary.zig");
pub const schema = @import("schema.zig");
pub const DataType = schema.DataType;
pub const FieldSpec = schema.FieldSpec;
pub const MetadataEntry = schema.MetadataEntry;
pub const Schema = schema.Schema;
pub const record_batch = @import("record_batch.zig");
pub const ArrayView = record_batch.ArrayView;
pub const RecordBatch = record_batch.RecordBatch;

test {
    _ = bitmap;
    _ = @import("primitive.zig");
    _ = c_data;
    _ = @import("boolean.zig");
    _ = @import("variable_binary.zig");
    _ = schema;
    _ = record_batch;
}
