# Spec 0001: Native Zig foundation

Status: Accepted (implementation direction authorized by repository owner).

## Requirements

ArrowZ implements Apache Arrow natively in pure Zig. The implementation must not
wrap or link Arrow C++, nanoarrow, Rust, or another Arrow implementation. Zig's
standard library and explicit allocators are permitted. C ABI compatibility is an
optional boundary implemented in Zig, not the core abstraction. PyArrow is a
test-only independent oracle. No libc dependency in the SDK.

M0 provides native nullable fixed-width arrays (i8/i16/i32/i64, unsigned equivalents,
f32/f64), builders, validity bitmaps, bounded borrowed slicing, and optional C Data
export. Export transfers ownership without copying value or bitmap buffers.
Buffers and release callbacks remain valid after moving the exported structure.
Empty arrays, nulls, offsets, allocation failure, bounds and release behavior must
be tested. Ownership-bearing Zig values must not be copied; explicit transfer
invalidates the source. Slices borrow and cannot outlive their array.

## Design

`PrimitiveArray(T)` owns typed values and an LSB-first validity bitmap. A builder
appends optional values and finishes into an owning array. Native access uses
slices and Zig error unions. C export consumes an owning array only after all
fallible allocations succeed; heap state owns the values, validity, and buffer
pointer table. Exported base structures contain no pointers into themselves.
Schema release is independent from array release. No foreign buffer import or
unsafe untrusted-pointer validation is promised in M0.

Pin Zig 0.16.0. Test Debug and ReleaseSafe. The integration fixture exports Zig
arrays to PyArrow using C ABI structs; assert values, nulls, sliced offsets,
empty arrays, and shared buffer addresses. PyArrow is not a runtime dependency.

## Tasks / acceptance

- [ ] M0-T1 native bitmap, primitive arrays, builders and borrowed slices.
- [ ] M0-T2 optional C Data exports with move-safe ownership.
- [ ] M0-T3 allocator failure, lifetime and bounds tests.
- [ ] M0-T4 independent PyArrow export interoperability and ABI checks.
- [ ] M0-T5 CI, runnable example, exact evidence and handoff.

Mark Verified only after required CI passes on the proposed commit/merge checkout.
Local verification alone does not establish cross-platform or full Arrow coverage.

## Deferred

Boolean bit-packed arrays, binary/UTF-8, nested/dictionary/temporal types, imported
arrays, C Stream, IPC/FlatBuffers, compression, Flight and compute kernels require
later specs. No complete SDK or performance superiority claim at M0.
