# Spec 0006: Native C Data record-batch export

Status: Accepted for implementation; verification pending.

## Requirements

Export an `OwnedRecordBatch` as an Arrow C Data struct array entirely in Zig. The
root schema uses format `+s`; child schemas preserve exact names, nullability and
custom metadata; root metadata preserves schema metadata. Child arrays expose the
existing native buffers without copying. No Arrow/nanoarrow/foreign runtime.

All fallible allocation, UTF-8/NUL validation, metadata sizing and `i64` length
checks occur before ownership moves. Any error or allocation failure leaves the
source batch valid and unchanged. Successful export invalidates the source and
transfers schema, columns and helper allocations to independently releasable root
array/schema owners. Base structs remain relocatable.

## Design

The array and schema halves use separate private states so either may be released
first. Uniform heap-allocated child states survive permitted child moves. A root
release walks all still-live children, then frees its pointer array and state.
Child releases own exactly one concrete `OwnedArray`. The schema half owns the
native schema plus NUL-terminated field-name copies and native-endian C metadata
blobs. No pointer inside a returned base struct points back into that base struct.

Metadata encoding is bounds-checked: signed 32-bit pair count and key/value byte
lengths, checked total `usize`, native-endian `i32` prefixes, and NULL for no pairs.
Field names containing NUL are rejected because the ABI name is C-terminated.

## Tasks and acceptance gates

- [ ] Preallocate all root/child array and schema state before moving the batch;
      exhaustive OOM proves source preservation and leak freedom.
- [ ] Struct root and all 13 child layouts, field names, flags and metadata encode
      according to the current C Data specification.
- [ ] Root/schema independent release, repeated cleanup helpers, base relocation,
      root-driven child release and moved-child survival.
- [ ] Test-only Zig fixture exports a mixed numeric/UTF-8/boolean record batch;
      PyArrow validates values, schema/field metadata, nullability and original
      child buffer addresses without copying.
- [ ] Empty-schema/nonzero-row batch and metadata/NUL/length overflow behavior.
- [ ] Pinned Zig 0.16.0 Debug/ReleaseSafe tests, examples, expanded interop,
      formatting and no-shared-runtime gates locally and in CI.

Mark Verified only after required CI passes on the published proposed commit.
