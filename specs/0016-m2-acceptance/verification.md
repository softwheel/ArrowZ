# M2 acceptance verification and handoff

Spec commit: `e1be14ab44b668d947cc5272d6ecbd9cba9d3e69`.

Public API reconciliation commit:
`ee7db08cd911949df63bfaf3e53c20369f877368`.

## M2 coverage matrix

| Capability | Spec | Merged PR | Final CI |
| --- | --- | --- | --- |
| Borrowed leaf C Data import and M1 reconciliation | 0009 | #10 | 34422819998 |
| Ownership-taking leaf C Data import | 0010 | #11 | 34426504652 |
| Leaf C Stream consumer | 0011 | #12 | 34706045732 |
| Recursive struct C Data import | 0012 | #13 | 34769450177 |
| Native record-batch schema reconstruction/import | 0013 | #15 | 34965797404 |
| Recursive record-batch C Stream consumer | 0014 | #17 | 35016972128 |
| Native record-batch C Stream producer | 0015 | #19 | 35019892935 |

Every listed spec is Verified and records its ownership, allocator-failure,
malformed-input, bounds, zero-copy and independent interoperability evidence.

Local reconciliation on 2026-09-16 used repository-pinned Zig 0.16.0 and
test-only PyArrow 23.0.1. Debug and ReleaseSafe each passed 56 Zig tests, both
native examples, and 216 interoperability cases. `readelf -d` reported no
`NEEDED` runtime dependency for the fixture shared library. The new public-only
record-batch stream example printed `stream rows=1, value=42` in both modes.

M2's supported ABI scope is Linux x86_64, the thirteen native leaf types,
recursive structs and record batches. C Data buffer extents remain a trusted
producer contract because the ABI carries no byte sizes. Synchronous serialized
callbacks are required. Dictionaries, device memory, asynchronous/concurrent
streams and IPC are intentionally outside M2.

Published reconciliation head
`0bf9c84dc7773f53cb959ef8c5057f7a054e8e96` passed
[CI run 35053058694](https://github.com/softwheel/ArrowZ/actions/runs/35053058694)
on 2026-09-16. Both Native Zig Debug and Native Zig ReleaseSafe completed every
repository gate successfully on the exact proposed commit.

GitHub reported PR #21 clean and mergeable with no reviews or unresolved review
comments; repository rulesets were empty, and GitHub accepted the protected
expected-head merge without bypass or force. PR #21 was squash-merged as main
commit `7e392bc068e609bfea706c6d160ddd4e89c52dc1` on 2026-09-16.

M2 is complete for its explicitly scoped Linux x86_64 C Data/C Stream contracts.
The next semantic work must begin with an M3 numbered spec for a minimal native
Zig FlatBuffers/IPC foundation, including strict byte/resource bounds and
independently generated Arrow interoperability fixtures. M2 does not imply v1
readiness; IPC, extended coverage, package/release gates and upstream preparation
remain.

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

Record the M2 spec/PR/CI matrix, exact commit identity, actual counts, public API
example output, current limitations and next M3 handoff here.
