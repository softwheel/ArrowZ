# Ownership-taking C Data leaf import verification and handoff

## Local evidence

Published implementation commit: `00b22f39855fc624a8b8b825f031df65bfeb1f74`.
Toolchain: repository-pinned Zig 0.16.0 on Linux x86_64. Independent producer
oracle: PyArrow 23.0.1 from the isolated test dependency directory.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed | Passed |
| `zig build test -Doptimize=$mode --summary all` | 38/38 passed | 38/38 passed |
| `zig build example -Doptimize=$mode --summary all` | Passed | Passed |
| `zig build interop -Doptimize=$mode --summary all` | Passed | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 197/197 passed | 197/197 passed |
| `readelf -d` contains no `NEEDED` entry | Passed | Passed |

Native tests use independent array and schema callback counters. They prove that
failed validation leaves both input structures live, successful take clears both
sources, explicit move creates only one live owner, the original and moved owners
can both be deinitialized safely, producer callbacks each run exactly once, and
borrowing a released owner fails. Pointer identity confirms the native view uses
the producer values without copying. The implementation allocates no memory, so
there is no allocator-failure surface in this slice.

The independent matrix retains 67 Zig-to-PyArrow export cases and 65 borrowed
PyArrow-to-Zig cases, then adds 65 PyArrow-to-Zig ownership-transfer cases. Every
implemented leaf type covers empty, all-valid, all-null, mixed-null and non-zero-
offset arrays. Each ownership case checks that Zig invalidates both moved sources;
native callback counters provide the release-exactly-once evidence.

## Published-commit gate

Pending PR CI on the exact proposed commit. Do not mark this spec Verified until
both Debug and ReleaseSafe jobs pass and required review/protection gates permit
merge.

## Next handoff

Specify the first pure-Zig C Stream slice: ABI definitions plus an owning stream
consumer with schema-once, next-array, EOS, producer-error and release semantics.
Keep leaf arrays as its initial payload scope before recursive record batches.
