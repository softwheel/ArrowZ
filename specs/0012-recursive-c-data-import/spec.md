# Spec 0012: Recursive C Data struct import

Status: Verified for scoped Linux x86_64 gates in PR #13.

## Requirements

Accept a C Data `+s` root with recursively nested `+s` children and all thirteen
existing leaf formats as immutable native `StructView`/`ArrayView` values. Keep
input buffers zero-copy; allocate only Zig view-tree descriptors with an explicit
allocator. Expose an owning `ImportedStruct.take` that validates the complete tree
before either ABI base structure moves. On validation or allocation failure leave
both producer bases live and unchanged and free every temporary Zig allocation.

Verify exact array/schema child counts, non-null child pointers, live child bases,
dictionary rejection, canonical struct buffer count, nonnegative/checked length,
offset, null count and parent validity; child lengths must cover the parent logical
slice. Preserve unknown null count (-1) by counting parent validity. Support
zero-child structs, nested nulls, and nonzero (including non-byte-aligned) parent
offsets; reject unsupported formats and malformed descendants without release.

The C Data ABI has no buffer-length fields: the producer guarantees accessible
physical buffers. This API requires trusted producers under that interface rule.
It must not release child bases directly; the root producer owns recursive release.

## Design

`c_data_import.ImportedStruct` owns two moved C Data bases, an allocator and a
recursive tree of allocated Zig `ArrayView` child slices. Recursive validation
visits children before constructing the parent view. Each node receives a borrowed
view spanning its own physical extent; `StructView.child` applies the parent slice
offset. On any error, recursive descriptor cleanup occurs before returning. The
move point occurs only after validation is complete; `deinit` releases root array,
root schema, then descriptors; `move` transfers the singular owner explicitly.

## Tasks and acceptance gates

- [x] Nested and zero-child struct views, offset/null semantics, zero-copy buffers.
- [x] Failure-atomic recursive descriptor allocations and exact root-only release.
- [x] Malformed child/count/type/buffer/length and unsupported dictionary tests.
- [x] Independent PyArrow-produced nested struct and record-batch C Data inputs.
- [x] Pinned Zig 0.16.0 Debug/ReleaseSafe native, example, formatting,
      interoperability and no-runtime-dependency gates locally.
- [x] Published implementation-head CI gates (run 34769337801).
- [x] Final evidence-head CI (run 34769450177), mergeability and review-thread checks.

Record-batch schema metadata reconstruction and direct C Stream record-batch
integration remain later slices; this slice returns recursive native struct views.
Mark Verified only on the final published commit after CI and repository gates.
