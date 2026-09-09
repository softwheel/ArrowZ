# M0 verification and handoff

Status: Implemented; local gates passed; required GitHub CI pending.
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

## Remaining gate

Run the GitHub Zig workflow on the proposed PR checkout. Both Debug and ReleaseSafe
must pass. Retain verification artifacts and record tested commit and run links.
Do not mark the spec Verified or merge while a required CI job is absent/failing.

## Next iteration

1. Inspect the M0 PR and CI; fix any failures without relaxing assertions.
2. Reconcile main/head identity and record CI evidence; mark Spec 0001 Verified
   only when gates pass, then merge subject to repository protections/review rules.
3. Write Spec 0002 for native boolean and UTF-8/binary arrays, with bitmap/offset
   overflow, invalid UTF-8, OOM and independent interoperability acceptance tests.
4. Continue the roadmap toward native record batches and IPC; preserve pure Zig.

Not proved: full Arrow format coverage, imports/C Stream/IPC, untrusted-pointer
validation, other operating systems/architectures, performance superiority, or
upstream acceptance. No upstream submission has been made.
