# Spec 0014: Native C Stream record-batch consumer

Status: Verified for scoped Linux x86_64 gates in PR #17.

## Requirements

Extend the pure-Zig synchronous C Stream consumer to accept a stream schema whose
root format is `+s` and return recursively validated native `RecordBatch` values.
Each returned batch owns its producer-provided C Data array tree and an independent
deep copy of the native schema, so it remains usable after later stream callbacks,
end-of-stream, stream release, and destruction of sibling batches. Array buffers
remain zero-copy and are released through the producer callback exactly once.

The stream schema is requested once and remains owned by `ImportedStream`. A batch
import must therefore borrow that C schema while allocating its own native schema
and move only the successful `get_next` array result. Validation or allocation
failure releases that live result exactly once, leaves the stream schema and stream
usable, and does not fabricate a producer errno. Producer callback failures retain
the existing transient error-text contract; canonical end-of-stream is cached.

Keep the existing leaf `next` API source-compatible. Add a distinct allocator-
explicit record-batch pull method, reject using either pull API with the wrong
schema root before consuming a producer chunk, and serialize both methods through
the same stream owner and EOS state. Reuse Spec 0013's format, nullability,
metadata, depth, child-count and malformed-input limits without widening support.

## Design

Refactor `ImportedRecordBatch` construction around a shared preparation path.
The existing `take` continues to validate and move both an array and schema.
A new narrowly scoped constructor borrows `*const ArrowSchema`, completes recursive
descriptor/native-schema allocation, then moves only `ArrowArray`. Ownership is
represented explicitly so deinitialization releases a C schema only when one was
actually moved. Both constructors preserve validation-before-move and idempotent
cleanup.

Add `ImportedStream.nextRecordBatch(allocator)`. It checks that `readSchema` has
completed and that the cached schema root is `+s` before `get_next`. A non-null
result is handed to the array-only batch constructor; errors release the result.
The returned `ImportedRecordBatch` already provides explicit move, borrow and
deinit behavior and therefore needs no second stream-specific batch abstraction.

## Tasks and acceptance gates

- [x] Array-only record-batch ownership with borrowed C schema; exact cleanup,
      explicit moves and batch lifetime independent of stream/schema release.
- [x] Record-batch stream pull, shared cached EOS, wrong-method rejection before
      `get_next`, producer error behavior and recoverable validation failures.
- [x] Recursive/sliced/nullable fields, metadata, multiple chunks and zero-column
      batches under Spec 0013 limits.
- [x] Exhaustive allocator-failure tests with exact producer release counts.
- [x] PyArrow `RecordBatchReader` C Stream interoperability with recursive values,
      schema fidelity and zero-copy buffer-address assertions.
- [x] Pinned Zig 0.16.0 Debug and ReleaseSafe format, tests, examples,
      interoperability and no-runtime-dependency gates locally and in CI.
- [x] Exact proposed-head CI, mergeability, review and unresolved-thread checks.

Do not mark Verified or begin C Stream production until every scoped gate passes.
The Arrow C Stream and C Data contracts must be rechecked against current official
documentation before final verification.
