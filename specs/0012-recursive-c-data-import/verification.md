# Recursive C Data struct import verification and handoff

Implementation commit: `0cf0cfb444ee1176d5456001dea163c50e075547`.
Spec-first commit: `a3a479c` (parent of the implementation commit).

Local checks, 2026-09-13, Linux x86_64; pinned Zig `0.16.0`,
PyArrow `23.0.1` as test-only producer:

```sh
zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples
zig build test -Doptimize=Debug --summary all
zig build example -Doptimize=Debug --summary all
zig build interop -Doptimize=Debug --summary all
PYTHONPATH=/workspace/scratch/c92aef11fa56/pydeps python3 tests/interop.py zig-out/lib/libarrowz_fixture.so
zig build test -Doptimize=ReleaseSafe --summary all
zig build example -Doptimize=ReleaseSafe --summary all
zig build interop -Doptimize=ReleaseSafe --summary all
PYTHONPATH=/workspace/scratch/c92aef11fa56/pydeps python3 tests/interop.py zig-out/lib/libarrowz_fixture.so
readelf -d zig-out/lib/libarrowz_fixture.so # no NEEDED entries in either mode
```

All succeeded: 44/44 Zig tests and 213 PyArrow interoperability cases in each
mode, examples and formatting passed; exhaustive recursive descriptor allocator
failure cleanup, root release-once and validation-before-move are native tests.
The 213 count includes 3 new PyArrow-produced nested, zero-child and record-batch
struct import cases. PyArrow is not a runtime SDK dependency.

Published implementation head `2205a02b2e0688c5a82c0c517deaf354f2aa00a2`
passed [CI run 34769337801](https://github.com/softwheel/ArrowZ/actions/runs/34769337801),
both `Native Zig (Debug)` and `Native Zig (ReleaseSafe)` successful. The workflow
executes the same gates and retains verification artifacts. No reviews or review
threads were recorded at this point; PR #13 was mergeable, but not yet merged.

Pending: final evidence-only published-head CI and repository gates. Next slice: reconstruct native
record-batch schema metadata and integrate recursive import into C Stream chunks.
ABI input buffers have no lengths; trusted producer extent is still required.
