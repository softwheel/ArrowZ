# Spec 0013: Native record-batch schema reconstruction from C Data

Status: Verified on published implementation head; final evidence-head CI pending.

## Requirements

For a live C Data `+s` root representing a record batch, reconstruct an
allocator-owned native `Schema` of ordered child fields (including recursive
struct children), field names, nullability and binary metadata; top-level
metadata becomes schema metadata. Map only ArrowZ's currently supported 13
leaf formats and `+s`; explicitly reject unsupported formats, dictionaries
and malformed child schema trees. A missing name maps to an empty field name.
Preserve duplicate field names and metadata order; validate UTF-8 field names
but preserve arbitrary binary metadata keys/values.

Expose a read-only native `RecordBatch` that borrows the imported `+s`
array's zero-copy columns and owns a deep-copied Zig schema for its lifetime.
Reject a root struct with null rows because native `RecordBatch` has no row-level
validity representation; child and nested-struct nullability remain supported.
Construction validates the entire recursive C Data array/schema pair before
moving either producer base; any invalid layout or allocator failure preserves
both caller bases and cleans every Zig allocation. The borrowed batch and
schema must remain usable after producer-provided schema memory is released
only when their copied data and retained array buffers still have valid
independent ownership. Never release child structures directly.

C Data metadata is a native-endian binary sequence of signed 32-bit pair
counts and length-prefixed key/value bytes; it has no total byte-length field.
As with buffer extents, the caller must supply trusted producer memory. Set
explicit limits on recursion depth, child counts and metadata entries/bytes to
avoid unbounded allocation from attacker-influenced counts. Reject negative
counts/lengths, arithmetic overflow, invalid flags and unsupported formats
without claiming safe arbitrary-pointer decoding.

## Design

Add a scoped import entry point building a native owning schema and a batch
view from `ImportedStruct`. Decode the C `ArrowSchema` tree recursively,
mapping flags to `Field.nullable`, names to validated copies and metadata
to separate owned byte slices. Roll back partially constructed fields and
metadata on each allocation failure. Preserve one singular root owner; expose
an explicit `move` and idempotent `deinit` with a documented borrow lifetime.
Only construct `RecordBatch` after type/length validation against the newly
built schema, and apply root struct offset to child views.

Before coding, check whether `Schema.init`/existing owned-field helpers can
be reused without intermediate copies; otherwise add a narrow private clone
helper. Keep the public native schema independent of C ABI structures. Root
`+s` is interpreted as a batch; a generic standalone struct array retains
the existing `ImportedStruct` API. Direct C Stream record-batch consumption
is deliberately the next spec, not part of this slice.

## Tasks and acceptance gates

- [x] Recursive names, nullable flags, ordered child fields and schema/field
      metadata (binary including embedded NUL), deep-copy ownership.
- [x] Limits, malformed counts/lengths/flags/formats and unsupported dictionary
      rejection; failure-atomic validation, exact root release and moves.
- [x] Sliced, nested, nullable, zero-column and duplicate-name batch cases.
- [x] Exhaustive allocator-failure tests and producer-owned-pointer lifetime tests.
- [x] PyArrow-produced record-batch C Data including names/metadata/nullability;
      assert values, schema equality and zero-copy buffer addresses.
- [x] Pinned Zig 0.16.0 Debug and ReleaseSafe test, example, format, interop and
      runtime-dependency checks locally.
- [x] Published implementation-head CI gates (run 34965588452).
- [ ] Final evidence-head CI and repository review/protection checks.

Do not mark Verified or broaden `ImportedStream` until these gates pass.
The Arrow C Data schema/metadata contract was reviewed on 2026-09-14:
https://arrow.apache.org/docs/format/CDataInterface.html
