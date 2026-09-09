# Owning record-batch verification and handoff

Date: 2026-09-09. Status: local gates passed; required CI pending.
Base main: `24e2a766aca9e2938fac73bc7b79db139c27314c`.
Requirements committed before implementation: `466896f` (local identity).
Implementation commit: `8c25463f09985bea6d81a4c1f9ea1aae02a3fb0a`.
Implementation tree: `aff87fb3f3b4bee63eea44806386d1f7568c8dee`.
Source tree: `c707ca2c7cf76b2b9afa37acd8bbabe292cc1909`.
Test tree: `76980a485f08185d15ce22748775fdb6b087e30f` (fixture unchanged).

## Local evidence

Linux x86_64; SHA-256-verified repository-pinned Zig 0.16.0; independent
test-only PyArrow 23.0.1.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig build test -Doptimize=MODE --summary all` | 24/24 passed | 24/24 passed |
| `zig build example -Doptimize=MODE --summary all` | Passed | Passed |
| `zig build interop -Doptimize=MODE --summary all` | Passed | Passed |
| `python3 tests/interop.py zig-out/lib/libarrowz_fixture.so` | 65/65 passed | 65/65 passed |
| `readelf -d zig-out/lib/libarrowz_fixture.so` | No NEEDED entries | No NEEDED entries |

Formatting and `git diff --check` passed. Example output remained
`rows=3, nulls=1, slice[0]=null, slice[1]=100` in both modes.

New coverage moves all ten primitive types, boolean, binary and UTF-8 into concrete
tagged owners and proves original buffer addresses remain unchanged. Sources become
empty and safely deinitializable. Owning batch tests cover count/type/length error
rollback, explicit zero-column row counts, name/index access and pointer-preserving
borrowed views. Exhaustive allocation failure injection spans schema and metadata
copies, primitive/UTF-8 builders, destination column-container allocation, view
allocation and full destruction with no leaks. The valid scenario verifies that
failure before batch transfer preserves the source schema and every owning column.

No foreign vtable, pointer erasure, or runtime is used. Outer caller containers
remain caller-owned after successful transfer; their moved element values are
invalid and must not be deinitialized. The owned batch destroys its copied schema,
column container and every native buffer exactly once.

## Remaining gate and next slice

Publish a focused PR preserving spec-before-code order and verify its full/source
trees. Record the actual CI head/run/job results; mark Verified and merge only after
required reviews and protections pass. No human review is claimed.

Next write Spec 0006 for native nested C Data record-batch export. Preallocate
uniform child state so allocation failure leaves the source batch intact; test
root/child/schema release order, field names and batch-level zero-copy PyArrow
interop. Metadata ABI encoding may be a separately bounded subtask if required for
auditable bounds. Struct/list arrays, C Data import, C Stream and IPC remain later.
