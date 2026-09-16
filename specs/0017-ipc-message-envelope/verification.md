# IPC message envelope verification and handoff

Spec commit: `408041de6a3561a86745949bdb70c87666a4abab`.

Implementation commit: `e713e25430e12d6cfe19a8171acf1d9e9b8422ab`.

Local verification on 2026-09-16 used repository-pinned Zig 0.16.0 and
test-only PyArrow 23.0.1. Debug and ReleaseSafe each passed 58 Zig tests, both
native examples and 218 independent interoperability cases. `readelf -d`
reported no `NEEDED` runtime dependency for the fixture shared library.

Native tests parse current framing, V5 metadata, record-batch bodies and canonical
EOS without an allocator. They truncate a valid message at every byte boundary
and mutate the continuation marker, metadata alignment/limit, root uoffset,
signed vtable back-offset, vtable length, object size, metadata version, field
offset, union tag, union-table uoffset, negative/unaligned body length and body
limit. Every producer-controlled address calculation is checked before access.

PyArrow independently generated a V5 stream containing a schema and int32 record
batch. The Zig parser matched both header kinds, body lengths and complete
consumed frame boundaries. PyArrow remains a test-only reference.

The Apache Arrow 25.0.1 encapsulated IPC message specification, current
`format/Message.fbs`, and `MetadataVersion` definition in `format/Schema.fbs`
were rechecked on 2026-09-16. The parser deliberately stops at the verified
message envelope; header-table semantics are the next slice.

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

Record exact versions, commits, malformed-input/resource-bound coverage,
independent fixtures, CI URLs and the next schema-decoding handoff here.
