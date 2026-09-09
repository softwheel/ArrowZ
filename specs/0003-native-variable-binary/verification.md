# Native UTF-8/binary verification and handoff

Date: 2026-09-09. Status: Verified for scoped Linux x86_64 gates; merged.
Base main: `436b87a482d83325ab5e54de6ec2f5fcdcac18e7`.
Requirements committed before implementation: `cb39c2b` (local identity).
Implementation commit: `ce02eaf96772e2237f5d4ae19d3d4527454982a8`.
Implementation tree: `d1cf4ae09d57d02cf90965a530e0010d5b588a0b`.
Source tree: `11a274ae653db73d4385b343ce2f1004f566e95e`.
Test tree: `76980a485f08185d15ce22748775fdb6b087e30f`.

## Local evidence

Linux x86_64; repository-pinned, SHA-256-verified Zig 0.16.0; independent
test-only PyArrow 23.0.1. PATH used the clean compiler installed during Spec 0002
verification; PYTHONPATH used the isolated test dependency directory.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig build test -Doptimize=MODE --summary all` | 15/15 passed | 15/15 passed |
| `zig build example -Doptimize=MODE --summary all` | Passed | Passed |
| `zig build interop -Doptimize=MODE --summary all` | Passed | Passed |
| `python3 tests/interop.py zig-out/lib/libarrowz_fixture.so` | 65/65 passed | 65/65 passed |
| `readelf -d zig-out/lib/libarrowz_fixture.so` | No NEEDED entries | No NEEDED entries |

`zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` and
`git diff --check` passed. Example output in both modes remained:
`rows=3, nulls=1, slice[0]=null, slice[1]=100`.

New native tests cover canonical offsets, arbitrary binary bytes, embedded NUL,
multi-byte Unicode, invalid UTF-8 atomic rejection, null versus empty, nested and
overflow-sized slicing, builder reuse, checked length/terminal offset limits,
and exhaustive failure injection across allocation points. Export tests cover
source preservation on OOM, three original buffer addresses, empty-array offset
zero, move-safe release and independent schema lifetime.

PyArrow independently validates five binary and five UTF-8 cases: empty, all
valid, all null, mixed nulls, and a non-byte-aligned/nonzero array offset. It
checks values, full validation, type formats, and zero-copy offsets/data/validity,
while retaining all 55 earlier cases. PyArrow is not linked into the SDK/fixture.

## Remaining gate and next slice

CI [run 34390666241](https://github.com/softwheel/ArrowZ/actions/runs/34390666241)
completed successfully on published head
`0b78673bd0ef47b39592abc65c76ed840977d823`; both Native Zig jobs passed every
step. The published full/source/test trees matched the locally tested identities.
PR #4 was mergeable with no requested or required review recorded and was
squash-merged as `7eee632ae308e9ba462b6a50529a81e01c6a8e85`.

Next specify native schema/field metadata and record batches with equal-length
column validation and ownership/lifetime tests. Nested arrays follow. C Data import,
C Stream and native IPC/FlatBuffers remain later milestones. No upstream patch was
submitted; owner understanding and maintenance commitment remain prerequisites.
