# C Stream record-batch producer verification and handoff

Spec commit: `4de8c3a5bed2b3cd892f4972e1a4f005abf0b694`.

Implementation commit: `4dff035e7f7c66628fd38689fadd96a5de26c44a`.

Local verification on 2026-09-15 used the repository-pinned Zig 0.16.0 and
PyArrow 23.0.1. Debug and ReleaseSafe each passed 56 Zig tests, the native
example, and 216 independent interoperability cases. `readelf -d` reported no
`NEEDED` runtime dependency for the fixture shared library. The Zig tests include
exhaustive allocation-failure cleanup for borrowed schema export and stream
construction, validation-before-move, callback allocation failure and retry,
repeated schema results, early stream release, returned-array independence,
ordered chunks, canonical EOS, empty streams, and zero-column batches.

PyArrow imported the Zig-produced stream through its standard
`RecordBatchReader` C Stream entry point, reconstructed recursive fields and
metadata, validated both batches, and observed the original Zig value-buffer
addresses. Foreign Arrow code remains test-only.

The Apache Arrow v25.0.1 C Stream and C Data documentation was rechecked on
2026-09-15. The implementation follows its errno-like callback results,
null-release EOS marker, independent result lifetimes, serialized-callback
assumption, schema metadata encoding, and release-callback ownership rules.

Exact proposed-head CI, mergeability, review and unresolved-thread evidence are
pending publication.

Required verification:

```sh
zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples
zig build test -Doptimize=Debug --summary all
zig build example -Doptimize=Debug --summary all
zig build interop -Doptimize=Debug --summary all
PYTHONPATH=../pydeps python3 tests/interop.py zig-out/lib/libarrowz_fixture.so
zig build test -Doptimize=ReleaseSafe --summary all
zig build example -Doptimize=ReleaseSafe --summary all
zig build interop -Doptimize=ReleaseSafe --summary all
PYTHONPATH=../pydeps python3 tests/interop.py zig-out/lib/libarrowz_fixture.so
readelf -d zig-out/lib/libarrowz_fixture.so
```

Record actual versions, commit identities, test counts, ownership/failure evidence,
independent interoperability, CI URLs and remaining limitations here.
