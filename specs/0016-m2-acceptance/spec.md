# Spec 0016: M2 acceptance and public API reconciliation

Status: Verified.

## Requirements

Reconcile Specs 0009 through 0015 as one M2 bidirectional C Data/C Stream
acceptance matrix. Confirm the published API covers borrowed leaf import,
ownership-taking leaf and recursive record-batch import, leaf and record-batch
stream consumption, and record-batch stream production without a foreign runtime
dependency. Preserve every verified ownership, allocation-failure, bounds, error,
EOS and zero-copy gate; do not change runtime semantics in this slice.

Replace stale public documentation with the exact implemented scope and ownership
contracts. Add a repository-built pure-Zig example that moves a native record
batch into a native C Stream producer, consumes it through `ImportedStream`, and
reads the value through the native record-batch view. The example must exercise
only public `arrowz` declarations so missing or renamed API exports fail CI.

## Design

Create `examples/record_batch_stream.zig` and make the existing `example` build
step compile and run both examples. Construct independent but equal schemas for
the stream and batch, move a primitive array into `OwnedRecordBatch`, move the
batch into `exportRecordBatchStream`, then take/read/consume the resulting ABI
stream in Zig. Every live owner has one cleanup path and moved values are never
accessed again.

Update README scope, import/stream usage, verification counts and spec links.
Record an explicit M2 coverage table and the final repository gates in the
verification document. Mark M2 complete only after exact proposed-head Debug and
ReleaseSafe CI, mergeability, review and unresolved-thread checks pass.

## Tasks and acceptance gates

- [x] Reconcile every M2 feature to a verified numbered spec and final CI run.
- [x] Compile and run a public-API-only native record-batch stream round trip.
- [x] Document record-batch stream consumer and producer ownership/error/EOS rules.
- [x] Correct supported scope, test counts, limitations and spec links.
- [x] Pass pinned Zig 0.16.0 Debug and ReleaseSafe format, tests, both examples,
      interoperability and no-runtime-dependency gates locally and in CI.
- [x] Exact proposed-head CI, mergeability, review and unresolved-thread checks.

M2 acceptance does not add IPC, FlatBuffers, asynchronous streams, concurrent
callbacks, device memory, dictionaries or new Arrow types. Those remain later
milestones.
