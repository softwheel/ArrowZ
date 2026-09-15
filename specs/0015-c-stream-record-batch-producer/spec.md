# Spec 0015: Native record-batch C Stream producer

Status: Verified.

## Requirements

Export an allocator-owned native `Schema` and an ordered slice of native
`OwnedRecordBatch` values through the Arrow C Stream ABI using only Zig. Support
empty streams, zero-column batches, all currently implemented leaf types and
recursive structs. Before moving anything, require every batch schema to equal the
stream schema recursively, including names, types, nullability and ordered binary
metadata. Failure preserves all caller ownership; success invalidates the schema
and each input batch while leaving the caller's outer batch slice allocated.

`get_schema` returns a fresh independently releasable C Data schema on every call.
`get_next` returns each batch exactly once as an independently releasable zero-copy
C Data array, then canonical null-release end-of-stream. Releasing the stream
releases its schema and every batch not yet returned, but never invalidates arrays
already returned. Repeated stream release is harmless through the cleared ABI base.

Callback allocation/export failures return errno-compatible nonzero codes, retain
the current unconsumed batch for retry, and expose stable NUL-terminated diagnostic
text through `get_last_error` until the next callback. Successful callbacks clear
the previous error. The implementation is synchronous and serialized; concurrent
callback invocation is outside this slice.

## Design

Add recursive native schema equality and a borrowed native-schema C Data exporter
that allocates ABI descriptors without consuming the source schema. Refactor the
existing record-batch exporter to share that descriptor construction without
changing its move semantics.

Add `exportRecordBatchStream(allocator, schema, batches)` in `c_stream.zig`. A
heap state owns the moved stream schema, an allocated batch-owner slice, the next
index and last-error text. Construct and validate all state before a no-fail move
phase. `get_next` calls the existing failure-atomic record-batch exporter; it
releases the unused per-batch exported schema and transfers only the array base.
The stream release callback destroys remaining owners and the state exactly once.

## Tasks and acceptance gates

- [x] Recursive schema equality including binary metadata, duplicate names and
      mismatched field order/type/nullability rejection before ownership moves.
- [x] Borrowed native-schema C Data export with independent repeated releases and
      exhaustive allocation-failure cleanup.
- [x] Native stream ownership, schema callbacks, ordered next/EOS, early release,
      zero batches, zero columns, explicit relocation and exact cleanup.
- [x] Callback failure/retry and stable/cleared error-text behavior under injected
      allocation failures.
- [x] PyArrow imports a Zig-produced `RecordBatchReader`, validates recursive
      schema/metadata/values and observes zero-copy value-buffer addresses.
- [x] Pinned Zig 0.16.0 Debug and ReleaseSafe format, tests, examples,
      interoperability and no-runtime-dependency gates locally and in CI.
- [x] Exact proposed-head CI, mergeability, review and unresolved-thread checks.

Do not mark Verified or begin IPC/FlatBuffers until every scoped gate passes.
Recheck the current official Arrow C Stream and C Data contracts before final
verification.
