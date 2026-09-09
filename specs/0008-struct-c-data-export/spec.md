# Spec 0008: Recursive struct C Data export

Status: Accepted for implementation; verification pending.

## Requirements

Extend native Zig record-batch C Data export to recursively nested struct arrays.
Every struct array uses one parent-validity buffer and ordered child arrays; every
struct schema uses format `+s` and ordered child schemas with exact names,
nullability and metadata. All native descendant buffers remain zero-copy. No
foreign Arrow runtime participates in SDK implementation.

Every fallible recursive allocation, C-name validation, metadata encoding and
signed-length conversion completes before any source ownership moves. Any error or
OOM leaves the complete owning batch usable. Success transfers the batch into
independently releasable array/schema trees. Parent release walks only still-live
children; moved descendants survive release of every ancestor.

## Design

Replace leaf-only export helpers with uniform heap-allocated recursive node states.
Array nodes preallocate pointer trees from the native `OwnedArray` shape. Arming a
leaf transfers its concrete array. Arming a struct transfers its validity and
container shell, recursively moves each child into the matching node, and retains
only the shell allocations at that node. Release walks child nodes before freeing
the shell, so ownership is singular at every depth.

Schema nodes recursively own NUL-terminated field-name copies, metadata blobs and
child pointer arrays. The root schema separately owns the native recursive schema;
therefore consuming or moving either ABI half cannot invalidate the other.

## Tasks and acceptance gates

- [ ] Recursive array/schema preallocation before move; exhaustive OOM preserves
      the source and proves cleanup of every partial tree.
- [ ] Correct struct buffers, lengths, null counts, child order, `+s` schemas,
      names, flags and metadata at two nesting levels and for zero-child structs.
- [ ] Zero-copy leaf and parent-validity addresses across the recursive tree.
- [ ] Independent root release, repeated cleanup, base relocation, ancestor-driven
      cleanup and moved nested descendant survival.
- [ ] Test-only Zig fixture exports nested nullable structs; PyArrow validates the
      recursive schema, values, metadata, parent nulls and original buffer addresses.
- [ ] Pinned Zig 0.16.0 Debug/ReleaseSafe tests, example, formatting, expanded
      interoperability and no-shared-runtime gates locally and in CI.

Mark Verified only after required CI passes on the published proposed commit.
