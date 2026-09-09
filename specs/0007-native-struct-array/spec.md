# Spec 0007: Native struct arrays

Status: Implemented; published-commit CI verification pending.

## Requirements

Implement Arrow struct arrays natively in Zig, without a foreign Arrow runtime.
A struct array owns an ordered heterogeneous child array per child field plus an
optional parent validity bitmap. Every child has the parent logical length;
zero-child structs retain an explicit length. Parent nulls do not alter child
storage, matching Arrow's nested-array model.

Extend native schemas with recursive child fields. Struct fields require matching
child count, order, types and nested layouts. Non-struct fields reject children.
Construction validates all invariants and completes all allocations before moving
any child owner. On validation error or OOM, every source remains usable; success
invalidates the input child values and transfers them without copying buffers.

## Design

`StructArray.take` receives owned child values, an explicit length and optional
row-validity booleans. It preallocates a child container, borrowed-view descriptors
and packed validity storage, then moves children only after validation/allocation.
`StructArray.deinit` recursively releases children exactly once. `StructView`
borrows the validity and child-view slices, supports checked slicing and validity
lookup, and cannot outlive its owner.

`FieldSpec.children` is recursively deep-copied into owning `Field.children`.
Schema cloning uses staged initialization so every allocation failure cleans all
completed descendants. Array/schema matching recursively validates struct layouts.

This slice does not export nested structs through C Data. Existing record-batch
export rejects struct columns before any ownership move; recursive C Data states,
child schemas and PyArrow nested interoperability require the next numbered spec.

## Tasks and acceptance gates

- [x] Recursive schema fields, deep-copy ownership and invalid child-layout checks.
- [x] Failure-atomic `StructArray.take`, packed parent validity, explicit empty
      struct length and recursive destruction.
- [x] Zero-copy child transfer and borrowed `StructView` validity, slicing, child
      access and bounds behavior, including nested structs.
- [x] Record-batch recursive type/layout validation for borrowed and owned columns.
- [x] Existing C Data batch export rejects struct columns without moving the batch.
- [ ] Exhaustive allocation-failure/leak tests and pinned Zig 0.16.0 Debug and
      ReleaseSafe formatting, tests, example, 66-case interop and no-runtime gates.
      Local gates pass; CI remains required on the published proposed commit.

Mark Verified only after CI passes on the published proposed commit.
