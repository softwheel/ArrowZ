# Native schema and record-batch verification and handoff

Date: 2026-09-09. Status: Verified for scoped Linux x86_64 gates; merged.
Base main: `7eee632ae308e9ba462b6a50529a81e01c6a8e85`.
Requirements committed before implementation: `90b8753` (local identity).
Implementation commit: `19f0e70f2bec25c0a66b6d9ac67988ebbe8827cd`.
Implementation tree: `a716f3f0a2409112760fabcbd2d753ff85b1d696`.
Source tree: `98c8709117ee4e96f761f0a2492e5dd5d77b6df0`.
Test tree: `76980a485f08185d15ce22748775fdb6b087e30f` (unchanged fixture/oracle).

## Local evidence

Linux x86_64; repository-pinned, SHA-256-verified Zig 0.16.0; independent
test-only PyArrow 23.0.1.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig build test -Doptimize=MODE --summary all` | 20/20 passed | 20/20 passed |
| `zig build example -Doptimize=MODE --summary all` | Passed | Passed |
| `zig build interop -Doptimize=MODE --summary all` | Passed | Passed |
| `python3 tests/interop.py zig-out/lib/libarrowz_fixture.so` | 65/65 passed | 65/65 passed |
| `readelf -d zig-out/lib/libarrowz_fixture.so` | No NEEDED entries | No NEEDED entries |

`zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` and
`git diff --check` passed. The example output remained
`rows=3, nulls=1, slice[0]=null, slice[1]=100` in both modes.

New tests exercise UTF-8 field names, arbitrary metadata bytes, deep-copy
independence, duplicate ordered fields and first-name lookup, and exhaustive
allocation failure cleanup across fields and nested metadata. All thirteen native
array types map to exact `DataType` values. Record batches cover valid mixed-type
columns, pointer-preserving borrowed views, count/type/length failures, lookup
errors, nullability metadata, and explicit nonzero rows for a zero-column batch.

The record batch owns no arrays: callers retain owners and must keep the schema,
column-view slice, and arrays alive. No type erasure, foreign runtime, or hidden
allocation is used by batch validation. Independent PyArrow coverage remains at
the unchanged array export boundary; batch-level C export was explicitly deferred.

## Remaining gate and next slice

CI [run 34396481112](https://github.com/softwheel/ArrowZ/actions/runs/34396481112)
completed successfully on published head
`782320f6dc1a10fe38d026c0565cdb9bdad8e168`; both jobs passed every step and
the published trees matched local evidence. PR #5 was mergeable with no requested
or required review recorded and was squash-merged as
`24e2a766aca9e2938fac73bc7b79db139c27314c`.

Next design ownership-bearing heterogeneous columns and nested C Data struct
export, including all-or-nothing OOM behavior, child/schema release ordering and
batch-level PyArrow interoperability. Then add native struct/list arrays. C Data
import, C Stream and native IPC/FlatBuffers remain later milestones. No upstream
submission has occurred; human owner review is still required before one.
