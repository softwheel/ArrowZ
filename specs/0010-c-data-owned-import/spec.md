# Spec 0010: Ownership-taking C Data leaf import

Status: Implementing.

## Requirements

Provide a pure-Zig owner for the 13 leaf layouts accepted by Spec 0009. Taking an
array validates both live C base structures before ownership changes. Failure must
leave the caller's `ArrowArray` and `ArrowSchema` live and unchanged. Success must
move both structures, mark both caller structures released without invoking their
callbacks, and expose checked zero-copy native views while the owner is live.

Deinitialization calls each moved producer callback exactly once and invalidates
the owner. Repeated deinitialization is harmless. An explicit move operation must
relocate ownership without callbacks or duplicate live release pointers. Borrowing
after deinitialization must fail as released. The owner must not allocate and must
not depend on a foreign Arrow runtime.

## Design

Add `c_data_import.ImportedArray`, containing the moved `ArrowArray` and
`ArrowSchema`. `take` first calls the complete borrowed validator; after that
success there are no fallible operations, so the two shallow copies and source
invalidations form the ownership commit point. `borrow` reuses the same validator.
`move` copies the relocatable ABI structures and clears the source owner. `deinit`
releases array then schema and clears all local state.

The type is a singular owner and must not be copied. This matches the existing
ArrowZ owner convention and the C Data Interface's move semantics. Producer
callbacks must themselves satisfy the interface requirement that base structures
are relocatable.

## Tasks and acceptance gates

- [ ] Take every supported leaf type without copying its buffers.
- [ ] Prove validation failure preserves both caller-owned structures.
- [ ] Prove source invalidation, explicit relocation, independent callback counts,
      release-exactly-once, repeated cleanup and borrow-after-release behavior.
- [ ] Add PyArrow-produced ownership-transfer cases for every type, including
      empty, all-valid, all-null, mixed-null and non-zero-offset arrays.
- [ ] Pass pinned Zig 0.16.0 Debug and ReleaseSafe native tests, examples,
      formatting, expanded interoperability and no-runtime-dependency gates.

Mark Verified only after the exact final proposed commit passes required CI.

