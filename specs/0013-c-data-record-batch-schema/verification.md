# Record-batch schema import verification and handoff

Spec amendment commit: `8a1e76e4472b1220accf30af7d03569dcf4c1881`.
Implementation commit: `5a5e818389bf441ce83e357c59c678ac343e68df`.
Deep-copy mutation assertion correction: `f53ccad56351d898690a409a835630cd2f029776`.

Local verification on 2026-09-15, Linux x86_64, repository-pinned Zig 0.16.0
and test-only PyArrow 23.0.1:

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
readelf -d zig-out/lib/libarrowz_fixture.so # no NEEDED entry in either mode
```

All local gates passed in both modes: 47/47 Zig tests, native example, and 214
independent interoperability cases. Native tests cover exhaustive allocator
failure rollback, validation-before-move, root release exactly once, explicit
move, deep-copy independence, root-null rejection, malformed metadata/flags,
zero columns and duplicate field order. The new PyArrow-produced sliced nested
batch covers recursive names, nullability, schema/field metadata with embedded
NUL bytes, values and zero-copy primitive buffers. PyArrow is test-only.

Limits: nesting depth 64, children per node 65,536, metadata pairs 1,024,
metadata bytes 16 MiB and names 1 MiB. C Data carries no physical byte lengths,
so arbitrary invalid pointers cannot be made safe; producer memory must be
trusted as the interface requires. Root row validity is rejected because the
native RecordBatch model has no row bitmap.

Published implementation head `a5a723b74b0967a7972dc4eb603644ed3b441e70`
passed [CI run 34965588452](https://github.com/softwheel/ArrowZ/actions/runs/34965588452)
on 2026-09-15. Both Native Zig Debug and Native Zig ReleaseSafe completed
successfully with the same format, 47-test, example, 214-case interoperability
and no-runtime-dependency gates.

Final evidence head `ea4ab5ffecca0cd481ec35f2d984f440fde02e90`
passed [CI run 34965797404](https://github.com/softwheel/ArrowZ/actions/runs/34965797404):
both Native Zig Debug and ReleaseSafe succeeded on the exact proposed commit.
GitHub reported PR #15 mergeable with no reviews or unresolved review threads;
the target branch had no required review protection. PR #15 was squash-merged as
main commit `1a6459534ccf664bb277584b25f292e33177fb60` on 2026-09-15.

Spec 0013 is complete. Remaining M2 work starts with a new spec for recursive
C Stream record-batch consumption; native C Stream production remains later.
