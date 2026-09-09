# Spec 0003: Native UTF-8 and binary arrays

Status: Verified for scoped Linux x86_64 gates; merged in PR #4.

## Requirements

Implement nullable Arrow UTF-8 and binary arrays natively in Zig with explicit
allocators and no foreign runtime. Use the canonical variable-size binary layout:
validity bitmap, signed 32-bit offsets, and contiguous bytes. UTF-8 builders reject
invalid input before mutation; binary arrays preserve arbitrary bytes. Preserve
the distinction between null and empty values. Null slots append no data and
repeat the preceding offset. Offset 0 exists even for an empty array.

## Design

`VariableBinaryArray` owns offsets, data and validity plus type kind, length and
null count. `BinaryBuilder` and `Utf8Builder` share an internal native builder;
only UTF-8 validates input. Builders reserve every required allocation before
mutating logical state, enforce the Arrow `i32` terminal-offset limit, and transfer
ownership on finish. Borrowed views retain base slot offsets and return slices
from the shared data buffer without copying. Successful Zig C Data export transfers
all three buffers and uses format `z` for binary or `u` for UTF-8.

## Tasks and acceptance gates

- [x] Native UTF-8/binary builders, arrays and nested borrowed slices.
- [x] Null versus empty, embedded NUL/arbitrary binary, multi-byte Unicode,
      offsets, nonzero slices, bounds and invalid UTF-8 tests.
- [x] Offset/length overflow tests and exhaustive allocation-failure injection;
      append/export failures preserve logical state and leak no memory.
- [x] Zig-owned move-safe C Data export with independent schema lifetime and
      shared validity/offset/data addresses.
- [x] Independent PyArrow empty/all-valid/all-null/mixed/nonzero-offset tests for
      both types, full validation, retaining all prior 55 cases.
- [x] Pinned Zig 0.16.0 Debug and ReleaseSafe tests, example, interoperability,
      formatting and no-shared-runtime gates locally and in CI.

Mark Verified only after required CI passes on the published proposed commit.
This slice does not complete schemas/metadata, nested arrays or record batches.
