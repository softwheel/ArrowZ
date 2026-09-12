# C Stream leaf-array consumer verification and handoff

## Local evidence

Published implementation commit: `27fe5b4f5575f2e789a903053ae72bdac82a5bd9`.
Toolchain: repository-pinned and SHA-256-verified Zig 0.16.0 on Linux x86_64.
Independent chunk/schema producer: PyArrow 23.0.1 from the isolated test
dependency directory. The Arrow 25.0.1 C Stream reference was checked 2026-09-12.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed | Passed |
| `zig build test -Doptimize=$mode --summary all` | 42/42 passed | 42/42 passed |
| `zig build example -Doptimize=$mode --summary all` | Passed | Passed |
| `zig build interop -Doptimize=$mode --summary all` | Passed | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 210/210 passed | 210/210 passed |
| `readelf -d` contains no `NEEDED` entry | Passed | Passed |

Native tests verify the five-pointer ABI layout, validation-before-move, schema
retrieval exactly once, refusal to pull before schema, a live zero-copy chunk,
explicit owner/chunk relocation, chunk survival after schema/stream release,
canonical released-output EOS and cached later EOS. Independent counters prove
one schema, chunk and stream release despite repeated cleanup.

Separate producer-error paths return errno-style 22 and 5, expose transient schema
and next error text exactly once, and release producer-supplied live partial schema
and array outputs. Released or incomplete callback tables remain caller-owned.
This slice allocates no memory, so it has no allocator-failure surface.

The independent Python producer implements the canonical callback table and uses
PyArrow only to export each of the 13 leaf schemas and mixed-null chunks. Zig
retrieves one schema and chunk, caches EOS without an extra producer call, releases
the stream before reading the still-live chunk, and owns every result callback.

## Published-commit gate

Pending PR CI on the exact proposed commit. Do not mark this spec Verified until
both Debug and ReleaseSafe jobs pass and required review/protection gates permit
merge.

## Next handoff

Specify recursive C Data import for struct arrays and record batches. That unlocks
standard record-batch C Streams (including direct PyArrow `RecordBatchReader`
producers) before implementing ArrowZ's native C Stream producer adapter.
