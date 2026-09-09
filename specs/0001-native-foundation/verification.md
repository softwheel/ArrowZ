# M0 verification and handoff

Status: Verified for M0's Linux x86_64 gates; PR #1 merged.
Date: 2026-09-09. Platform: Linux x86_64. Zig: 0.16.0.
Independent reference: PyArrow 23.0.1 (test-only).

Implementation identities (Git trees, stable across publication):
- `src`: `da9153bbc50820c6a5b97de7c377f6d9998a2f7e`
- `tests`: `f150fe3fc76143188f0966b5a303050d3fd2e811`

| Gate | Local result |
| --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed |
| `zig build test` | 6/6 tests passed (including root module discovery test) |
| `zig build test -Doptimize=ReleaseSafe` | 6/6 tests passed |
| `zig build example` in Debug and ReleaseSafe | rows=3, nulls=1, slice[0]=null, slice[1]=100 |
| `zig build interop` in Debug and ReleaseSafe | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 50/50 cases passed in each build mode |
| `readelf -d zig-out/lib/libarrowz_fixture.so` (Debug) | No NEEDED shared-library dependencies |
| `git diff --check` | Passed |

Tests cover ten primitive types, native slicing including overflow-sized bounds,
bitmap byte boundaries, empty/all-valid/all-null/mixed-null data, nonzero unaligned
bit offsets, every ABI field offset, shared value/validity buffer addresses,
independent schema release, export relocation and repeated cleanup helper calls.
Allocation failure injection checks each allocation in builder and export paths,
leak freedom, append logical atomicity and preservation of source ownership on
failed export. The local integration commands used an isolated Python dependency
path; no foreign Arrow implementation is linked into the SDK or fixture.

## Completed CI gate

[Run 34377921707](https://github.com/softwheel/ArrowZ/actions/runs/34377921707)
completed successfully on 2026-09-09; rechecked during the next iteration.
Debug and ReleaseSafe each passed 6 Zig tests, the native example, 50 PyArrow
cases and the no-shared-runtime dependency check.

- Proposed head: `9276915dd56e52c5eb96bff005614d32433cd977`.
- Base: `4db5b3fd2e5e8c9a4e3d1e1baf034261dd1ac593`.
- Tested merge checkout: `72fec81342fce8314e810dc296bf7da1591694e7`.
- Merged [PR #1](https://github.com/softwheel/ArrowZ/pull/1):
  `ce1075108d2ed9ef1f6ac6f0bc71e5694b5aa3ea`.
- Retained artifacts: Debug `10114652129`, ReleaseSafe `10114684229`.

These results apply to M0, not subsequent semantic changes.

## Next iteration

1. Finish Spec 0002 native boolean gates and reconcile its PR/CI before merge.
2. Specify UTF-8/binary arrays with offset overflow, invalid UTF-8, OOM and
   independent interoperability acceptance tests.
3. Continue the roadmap toward native record batches and IPC; preserve pure Zig.

Not proved: full Arrow format coverage, imports/C Stream/IPC, untrusted-pointer
validation, other operating systems/architectures, performance superiority, or
upstream acceptance. No upstream submission has been made.
