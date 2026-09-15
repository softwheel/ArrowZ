# C Stream record-batch consumer verification and handoff

Spec commit: `70954fb4abb7a6a21a1e0242fc5b012b8dd79f63`.
Implementation commit: `6c967e534175dee8738286b5e7bb3eb52c3e822c`.

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

Record actual tool versions, commit identities, counts, ownership/failure coverage,
independent interoperability evidence, CI URLs and remaining limitations here.

Local verification passed on 2026-09-15, Linux x86_64, with repository-pinned
Zig 0.16.0 and test-only PyArrow 23.0.1. Both Debug and ReleaseSafe passed:
50/50 Zig tests, native example, 215 independent interoperability cases,
format checks, and `readelf` showing no `NEEDED` runtime dependency entry.

Native tests exhaust every consumer allocation failure and verify validation
before move, exact root releases, borrowed-schema independence, explicit move,
idempotent cleanup, wrong pull-method rejection before `get_next`, cached EOS,
malformed-chunk recovery and producer error state. The PyArrow-produced standard
`RecordBatchReader` case supplies two independently owned recursive batches with
native schema/field metadata, nullability and zero-copy primitive addresses; both
remain readable after Zig releases the stream schema and stream.

The official Arrow C Stream and C Data interface documents were rechecked on
2026-09-15. C Data provides no physical buffer extents, so trusted producer
pointers remain required. Supported types and resource limits remain those of
Spec 0013.

Published implementation/evidence head
`bcb754ff1a8ac470f6293c7bf1681719a0e4b7fe` passed
[CI run 35016680480](https://github.com/softwheel/ArrowZ/actions/runs/35016680480)
on 2026-09-15. Both Native Zig Debug and Native Zig ReleaseSafe completed every
repository gate successfully on that implementation/evidence head.

Final evidence head `da3c543fbbd5bf5d36bef3929aba91a7b643c901`
passed [CI run 35016972128](https://github.com/softwheel/ArrowZ/actions/runs/35016972128):
both Native Zig Debug and ReleaseSafe succeeded on the exact proposed commit.
GitHub reported PR #17 clean and mergeable with no reviews or unresolved review
comments; repository rulesets were empty, and GitHub accepted the protected
expected-head merge without bypass or force. PR #17 was squash-merged as main
commit `13f00edc59364529f2da28a9ec3ec39bba628bcd` on 2026-09-15.

Spec 0014 is complete. Remaining M2 work starts with a new spec for a native
record-batch C Stream producer, including callback lifetime, error and ownership
behavior; IPC/FlatBuffers remains M3.
