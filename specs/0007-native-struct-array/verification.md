# Native struct-array verification and handoff

## Local evidence

Implementation commit: `a376de30fbc4e41a10070b4d338327ba8f97bf65`.
Toolchain: repository-pinned Zig 0.16.0 on Linux x86_64. Test-only oracle:
PyArrow 23.0.1 from the isolated dependency directory.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed | Passed |
| `zig build test -Doptimize=$mode --summary all` | 32/32 passed | 32/32 passed |
| `zig build example -Doptimize=$mode --summary all` | Passed | Passed |
| `zig build interop -Doptimize=$mode --summary all` | Passed | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 66/66 passed | 66/66 passed |
| `readelf -d` contains no `NEEDED` entry | Passed | Passed |

The native tests exhaust every allocation failure while recursively cloning struct
schemas and while constructing a nullable struct from numeric and UTF-8 children.
They prove failure preserves input owners, child data pointers are unchanged,
recursive destruction is leak-free, nested schemas match recursively, parent-null
slices retain child values, and empty structs preserve an explicit length. Invalid
child/validity lengths, recursive schema mismatches, bounds and `i64` overflow are
rejected. Existing C Data export returns `UnsupportedNestedType` before moving a
struct-containing batch.

## Published-commit gate

Not yet satisfied. Record the PR, proposed head, both CI matrix jobs and merge SHA
only after remote checks complete. Spec 0007 is not Verified until then.

## Next handoff

Specify recursive C Data struct export separately. It must recursively preallocate
array/schema states, preserve parent and descendant buffers without copying, prove
all release and moved-child orders, and add an independent nested PyArrow oracle.
