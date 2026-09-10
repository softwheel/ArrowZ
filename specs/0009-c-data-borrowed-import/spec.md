# Spec 0009: Borrowed C Data leaf-array import

Status: Implementing.

## M1 reconciliation

M1's scoped deliverables are complete. PRs #3 through #9 added bit-packed
booleans, UTF-8/binary, recursive allocator-owned schemas, heterogeneous owning
record batches, native struct arrays, and recursive zero-copy C Data export.
Their verification documents record Debug and ReleaseSafe native, allocator,
ownership, bounds, format, example, no-runtime-dependency and independent
PyArrow gates. PR #9's final proposed head passed 33 Zig tests and 67 PyArrow
cases per mode in GitHub Actions run `34418809057` before merge commit
`34ff84964968d48ad275168f7907679c1a240159`.

This is milestone reconciliation, not a v1 claim. Dictionary encoding, temporal
and decimal types, C Data import ownership, C Stream, IPC and broader target
coverage remain later work.

## Requirements

Import the 13 implemented primitive, Boolean, binary and UTF-8 C Data layouts as
native immutable Zig views without allocation, copying, mutation, release, or a
foreign runtime dependency. The producer-owned `ArrowArray` and `ArrowSchema`
and all reachable buffers must remain live and immutable for the view lifetime.

Reject released structures; unsupported/dictionary/nested types; negative or
overflowing lengths and offsets; invalid null counts; wrong buffer/child counts;
missing required buffers; misaligned fixed-width and offset buffers; decreasing
or negative binary offsets; and invalid UTF-8 in valid logical values. Accept a
missing validity bitmap only when `null_count == 0`, and accept Arrow's unknown
null count (`-1`) only when a validity bitmap is present.

The C Data ABI does not carry buffer byte lengths. As required by the interface,
the producer guarantees that non-null buffers cover `offset + length` values.
The importer validates all representable metadata and safely computed extents,
but callers must only pass ABI structures from a trusted memory-safe boundary.

## Design

Add `c_data_import.borrowArray`, returning the existing native `ArrayView` union.
The function performs validation before constructing slices and never retains a
release callback. Existing leaf views treat an empty validity slice as all-valid,
which maps the ABI's canonical omitted-validity representation without allocating.

Fixed-width imports expose a typed slice spanning the physical extent. Boolean
imports expose packed value and validity byte slices. Variable-width imports
validate the logical offset interval, derive the data extent from its terminal
offset, and validate UTF-8 only for valid logical values. Slicing remains handled
by the existing checked native views.

## Tasks and acceptance gates

- [ ] Implement zero-allocation borrowed imports for all 13 M1 leaf types.
- [ ] Cover omitted validity, unknown null count, non-zero/non-byte-aligned
      offsets, empty arrays, nulls, binary bytes, Unicode and zero-copy addresses.
- [ ] Reject malformed scalar metadata, layouts, pointers, alignment, offsets and
      UTF-8 without calling producer release callbacks.
- [ ] Add PyArrow-to-Zig interoperability cases; PyArrow remains test-only.
- [ ] Pass pinned Zig 0.16.0 Debug and ReleaseSafe native tests, examples,
      formatting, bidirectional interoperability and no-runtime-dependency gates.

Mark Verified only after the exact final proposed commit passes required CI.

