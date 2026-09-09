# Native C Data record-batch export verification and handoff

## Local evidence

Implementation commit: `e65a5e4bd947b803768eeb5e3ab87d04fe7ea92c`.
Toolchain: repository-pinned Zig 0.16.0 on Linux x86_64. Independent oracle:
PyArrow 23.0.1 from the isolated test dependency directory.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed | Passed |
| `zig build test -Doptimize=$mode --summary all` | 28/28 passed | 28/28 passed |
| `zig build example -Doptimize=$mode --summary all` | Passed | Passed |
| `zig build interop -Doptimize=$mode --summary all` | Passed | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 66/66 passed | 66/66 passed |
| `readelf -d` contains no `NEEDED` entry | Passed | Passed |

The allocation-failure sweep exposed and drove correction of a double-free in an
intermediate implementation when schema child allocation failed after root
metadata allocation. The corrected ownership transition passed the exhaustive
allocation-failure gate. Tests cover all 13 child formats, zero-copy buffers,
empty-schema rows, NUL and numeric bounds, independent root release, relocation
and moved-child survival. PyArrow independently validates a nullable mixed batch,
schema/field metadata, nullability, values and original buffer addresses.

## Published-commit gate

Not yet satisfied. Record the PR, proposed commit, both CI job results and merge
commit here only after the remote checks complete. Until then Spec 0006 is not
Verified.

## Next handoff

After CI verification, proceed with a separately specified M1 nested-array slice;
struct is the natural first target because its validation and C Data shape build
directly on this work. C Data import and C Stream remain M2 work.
