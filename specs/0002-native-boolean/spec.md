# Spec 0002: Native boolean arrays

Status: Accepted for implementation; verification pending.

## Requirements

Implement nullable boolean arrays entirely in Zig using explicit allocators.
Values and validity are separate LSB-first packed bitmaps, not byte-per-bool
storage. Null value bits and unused trailing bits are zero. No foreign runtime.
Reference: https://arrow.apache.org/docs/format/Columnar.html (2026-09-09).

## Design

BooleanArray owns two byte ArrayLists and a logical length/null count.
BooleanBuilder reserves both bitmaps before logical mutation; allocation failure
preserves existing values and counts. Finish transfers ownership, leaving a
reusable empty builder. Views borrow the owner and support bounded nested slices
without copying, including unaligned bit offsets. Owners must not be copied or
mutated while borrowed. Optional Zig C Data export uses format `b`, two buffers,
and the same move-safe state ownership as primitive export. Export failure must
leave the source intact; schema release is independent from array lifetime.

## Tasks and acceptance gates

- [ ] Native builder, array and borrowed views, empty/true/false/null cases.
- [ ] Exact bit order, byte boundaries, zero trailing bits, nested/empty slices,
      overflow-sized bounds, builder reuse and synthetic length overflow test.
- [ ] Exhaustive allocator failure injection for append and export; preserve
      source state on failure and verify relocation and release without leaks.
- [ ] Independent PyArrow empty/all-valid/all-null/mixed/offset boolean exports,
      full validation and shared buffer addresses; retain all primitive cases.
- [ ] Zig 0.16.0 Debug and ReleaseSafe tests, examples, interoperability, format
      checks and no shared runtime dependency gate, locally and in CI.

Mark Verified only after CI passes on the proposed commit/merge checkout.
This is one M1 slice, not completion of M1. UTF-8/binary (including offset overflow
and invalid UTF-8), schemas, nested arrays and record batches need later specs.
