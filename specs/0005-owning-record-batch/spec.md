# Spec 0005: Owning heterogeneous record batches

Status: Accepted for implementation; verification pending.

## Requirements

Add a pure Zig ownership layer for heterogeneous native arrays and record batches.
An owning tagged array must cover all thirteen implemented types without pointers,
foreign vtables or type erasure. Taking an array transfers its existing buffers
without copying and leaves the source empty and reusable. Owning batch construction
must validate schema count/type/length before any move and be all-or-nothing on
validation or allocation failure.

## Design

`OwnedArray` is a tagged union containing concrete native owning array values. Its
take constructors reset source arrays only after copying their ownership fields.
It provides uniform `dataType`, `len`, borrowed `view`, and single-use `deinit`.

`OwnedRecordBatch.take` first validates borrowed views, allocates its own column
container, and only then moves the schema and every column. Failure leaves the
schema and all input `OwnedArray` values valid and owned by the caller. Success
invalidates the input schema and column values; callers still own any outer input
container. The batch owns its schema, column container and native array buffers.
No fallible operation occurs after the first move. Borrowed views cannot outlive
the owning batch.

Nested C Data record-batch export is explicitly deferred to Spec 0006. It will use
this concrete union to preallocate all child state before ownership transfer and
provide batch-level PyArrow interoperability.

## Tasks and acceptance gates

- [ ] Zero-copy take constructors, view/type/length access and cleanup for all
      thirteen types; source arrays become empty and reusable.
- [ ] Owning batch validation and transfer with schema/columns unchanged on every
      error or allocation failure.
- [ ] Batch column/index/name access, zero-column nonzero-row batches, and borrowed
      view pointer/lifetime evidence.
- [ ] Exhaustive allocator-failure and leak tests over schema, builders, column
      container transfer and batch destruction.
- [ ] Pinned Zig 0.16.0 Debug and ReleaseSafe tests plus unchanged example,
      65-case PyArrow array interop, formatting and no-shared-runtime gates.

Mark Verified only after required CI passes on the published proposed commit.
