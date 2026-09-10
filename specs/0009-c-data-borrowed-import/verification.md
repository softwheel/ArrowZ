# Borrowed C Data leaf-array import verification and handoff

## Local evidence

Published implementation commit: `3c5b970aecb1213117ed68801e29437eec8ea802`.
Toolchain:
repository-pinned Zig 0.16.0 on Linux x86_64. Independent producer/consumer oracle:
PyArrow 23.0.1 from the isolated test dependency directory.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed | Passed |
| `zig build test -Doptimize=$mode --summary all` | 36/36 passed | 36/36 passed |
| `zig build example -Doptimize=$mode --summary all` | Passed | Passed |
| `zig build interop -Doptimize=$mode --summary all` | Passed | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 132/132 passed | 132/132 passed |
| `readelf -d` contains no `NEEDED` entry | Passed | Passed |

The native tests cover omitted validity, unknown and inconsistent null counts,
non-zero logical offsets, zero-copy pointer identity, missing buffers, signed and
address-space overflow, alignment, dictionary/nested rejection, decreasing binary
offsets, invalid UTF-8, released inputs, and the rule that failure never releases
producer ownership. The path allocates no memory, so there is no allocator-failure
surface in this slice.

The independent matrix contains the prior 67 Zig-to-PyArrow cases and 65 new
PyArrow-to-Zig cases: every supported leaf type across empty, all-valid, all-null,
mixed-null and non-zero-offset scenarios. The inverse cases assert that Zig does
not consume either producer-owned base structure.

## Published-commit gate

Pending PR CI on the exact proposed commit. Do not mark this spec Verified until
both Debug and ReleaseSafe jobs pass and required review/protection gates permit
merge.

## Next handoff

After this borrowed leaf slice, specify ownership-taking C Data import. It must
move both base structures safely, release each producer exactly once, and define
failure behavior without exposing a view whose owner has already been released.
