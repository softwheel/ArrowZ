# ArrowZ

A **pure Zig native implementation of Apache Arrow** with a small, idiomatic Zig
SDK. Independent project, licensed under Apache-2.0; not an official Apache Arrow
subproject.

ArrowZ implements its own buffers, validity bitmaps, arrays, builders and slicing
in Zig. It does not wrap or link Arrow C++, nanoarrow, Rust Arrow, or another Arrow
runtime. An optional C Data Interface adapter, also written in Zig, enables
zero-copy interchange with other Arrow implementations. PyArrow is used only in
tests as an independent compatibility reference.

## Current scope

Experimental native core: nullable signed/unsigned 8/16/32/64-bit integers,
float32/float64, bit-packed booleans, UTF-8 and binary arrays, owning schemas and
metadata, borrowed and owning heterogeneous record batches, builders, slices and
ownership-transferring C Data array and record-batch exports. This is a foundation,
not a complete Arrow SDK. Nested arrays, import/stream adapters and native IPC are
planned in the [roadmap](docs/ROADMAP.md).

## Use

Requires Zig **0.16.0**. The package exposes the `arrowz` module through `build.zig`.
Add it as a Zig package dependency and import `dependency.module("arrowz")` into
your application's root module.

```zig
const arrowz = @import("arrowz");

var builder = arrowz.PrimitiveBuilder(i64).init(allocator);
defer builder.deinit();
try builder.append(42);
try builder.append(null);
var array = builder.finish();
defer array.deinit();
const value = try array.get(0); // ?i64: 42
const view = try array.view().slice(1, 1);
const missing = try view.get(0); // null
```

Owning arrays/builders/exports must not be copied. `finish` transfers buffers and
leaves the builder empty and reusable. Views borrow the array and must not outlive
it. Out-of-range access returns `error.OutOfBounds`. Allocator lifetime must exceed
all arrays and exported buffers created with it. Internal storage fields are not
an API for mutation; use builders and views to preserve invariants.

For nullable booleans use `arrowz.BooleanBuilder.init(allocator)`, append `true`,
`false` or `null`, and call `finish()`. `BooleanArray` and `BooleanView` expose the
same `get`/`view`/`slice` pattern; both values and validity use packed bitmaps.
Use `arrowz.c_data.exportBoolean(&array)` for zero-copy boolean export.

`arrowz.BinaryBuilder` preserves arbitrary bytes; `arrowz.Utf8Builder` validates
UTF-8 before mutation. Both produce canonical 32-bit-offset variable-binary arrays
and distinguish null from empty values. `exportVariableBinary` transfers validity,
offset and data buffers without copying.

`arrowz.Schema.init` deep-copies field names and custom metadata. Construct typed
borrowed columns with `arrowz.ArrayView`, then call `arrowz.RecordBatch.init` with
an explicit row count. It rejects mismatched column counts, Arrow types and lengths.
The schema, view slice and underlying arrays must outlive the borrowed batch.

Use `OwnedArray.takePrimitive`, `takeBoolean`, or `takeVariable` to transfer native
buffers into a concrete tagged owner. `OwnedRecordBatch.take` validates before
moving anything: errors and allocation failures preserve every input, while
success owns the schema, column container and all buffers. `borrow` creates a
temporary zero-copy `RecordBatch` view.

`arrowz.c_data_batch.exportRecordBatch` transfers an owning batch into a `+s`
C Data struct array. It preserves field names, nullability and metadata, exposes
the original child buffers without copying, and lets consumers release or move
the array and schema halves independently. Any export error leaves the input batch
unchanged.

For optional zero-copy export:

```zig
var exported = try arrowz.c_data.exportPrimitive(i64, &array);
defer exported.deinit();
// Pass &exported.array and &exported.schema to an Arrow C Data consumer.
// Successful export leaves array empty; exported owns the original buffers.
// A consuming C Data client clears the release callbacks when it moves ownership.
```

## Verify

```sh
zig build test
zig build test -Doptimize=ReleaseSafe
zig build example
zig build interop
python -m venv .venv
.venv/bin/pip install pyarrow==23.0.1
.venv/bin/python tests/interop.py zig-out/lib/libarrowz_fixture.so
```

The integration command above targets Linux. CI checks Linux x86_64 in Debug and
ReleaseSafe, including 66 independent PyArrow cases, allocation failure paths and
ABI layout/zero-copy checks. Other targets remain unverified.

See [Spec 0001](specs/0001-native-foundation/spec.md), its verification record, and
the [boolean spec](specs/0002-native-boolean/spec.md) and
[UTF-8/binary spec](specs/0003-native-variable-binary/spec.md), alongside
the [schema/record-batch spec](specs/0004-native-schema-record-batch/spec.md) and
the [owning-batch spec](specs/0005-owning-record-batch/spec.md) and
the [record-batch export spec](specs/0006-c-data-record-batch/spec.md), plus
the [upstream contribution path](docs/UPSTREAM.md). Development is assisted by AI;
upstream submission requires engaged human review and maintainership.
