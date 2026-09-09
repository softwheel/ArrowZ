# Spec 0004: Native schemas and record batches

Status: Accepted for implementation; verification pending.

## Requirements

Implement Arrow schemas, fields, custom metadata and record batches natively in
Zig. Schema/field names must be valid UTF-8 and are deep-copied along with metadata
keys and values into an explicit allocator. A record batch binds one typed array
per field, validates column count, exact data type, and equal column length, and
supports a declared row count for zero-column batches. No foreign runtime.

## Design

`DataType` covers every currently implemented ArrowZ type. `Schema.init` consumes
borrowed `FieldSpec`/metadata input and produces an owning, non-copyable schema;
failure cleans every partially copied field. `ArrayView` is a tagged union of
borrowed native array views with uniform type/length access. `RecordBatch.init`
borrows a schema and caller-owned array-view slice, validates invariants without
allocating, and cannot outlive either. Column lookup by index and exact field name
is bounds-checked. Duplicate field names are legal and name lookup returns the
first, matching the schema's declared order.

This slice deliberately keeps column ownership with callers. Owning heterogeneous
arrays and nested C Data struct export require a later spec so move/failure
semantics are designed explicitly rather than hidden behind unsafe erasure.

## Tasks and acceptance gates

- [ ] Owning fields/schemas with deep-copied UTF-8 names and arbitrary metadata.
- [ ] Exhaustive allocator-failure tests for nested schema copies and cleanup.
- [ ] Borrowed views for all 13 implemented native types and uniform type/length.
- [ ] Record-batch validation: empty schemas, zero columns with nonzero rows,
      count/type/length errors, nullable metadata, name/index lookup and lifetimes.
- [ ] Pinned Zig 0.16.0 Debug and ReleaseSafe tests plus all existing example,
      65-case interoperability, formatting and no-shared-runtime gates.

Independent interoperability remains covered at the array boundary by the
unchanged PyArrow matrix. Native batch C Data export and batch-level PyArrow
interop are mandatory in the later owning/nested-export slice. Mark this spec
Verified only after required CI passes on the published proposed commit.
