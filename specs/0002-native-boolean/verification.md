# Native boolean verification and handoff

Date: 2026-09-09. Status: Verified for scoped Linux x86_64 gates; merged.
Base main: `ce1075108d2ed9ef1f6ac6f0bc71e5694b5aa3ea` (M0 merged).
Requirements committed before semantic changes: `dc1eb24`.
Local implementation commit: `e85723d9ff8699b3fc6773425455fcc53bc268d6`.
Source tree: `ef3cf0f2df94028237d932fe0a6c5ee0ec33ad6a`.
Test tree: `f76752487973f8b33cebdc3bbfe2b1bcf3f19446`.

## Actual local results

Linux x86_64; pinned Zig 0.16.0; independent test-only PyArrow 23.0.1.
The pre-existing extracted compiler crashed even on `zig version`; `file`
reported missing section headers. Reinstalled with `python3 ci/install_zig.py
/tmp/arrowz-zig-verified`, which verified the repository-pinned SHA-256. The fresh
compiler reported 0.16.0 and all commands below completed successfully.

Environment: PATH prepended with `/tmp/arrowz-zig-verified/zig-x86_64-linux-0.16.0`;
PYTHONPATH set to `/workspace/scratch/c92aef11fa56/pydeps` for the test oracle.

| Command | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig build test -Doptimize=MODE --summary all` | 10/10 passed | 10/10 passed |
| `zig build example -Doptimize=MODE --summary all` | Passed | Passed |
| `zig build interop -Doptimize=MODE --summary all` | Passed | Passed |
| `python3 tests/interop.py zig-out/lib/libarrowz_fixture.so` | 55/55 passed | 55/55 passed |
| `readelf -d zig-out/lib/libarrowz_fixture.so` | No NEEDED entries | No NEEDED entries |

`zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` and
`git diff --check` passed. Example output in each mode:
`rows=3, nulls=1, slice[0]=null, slice[1]=100`.

New coverage: packed boolean value/validity bytes and trailing bits; true/false/null;
nested, empty and overflow-sized slices; builder reuse; synthetic length overflow;
all allocation failures during 600 appends and export, preserving logical state;
move-safe export, independent schema release and leak detection. PyArrow checks
five boolean scenarios (empty, all valid, all null, mixed, unaligned offset) plus
the unchanged 50 primitive cases, full validation and original buffer addresses.
No other-language implementation is linked into the SDK or fixture.

## Next run

CI [run 34384349287](https://github.com/softwheel/ArrowZ/actions/runs/34384349287)
completed successfully on head `57070144c35028d05d719d56966d76465a4e2210`.
Both Native Zig jobs passed every step. PR #3 was mergeable, had no requested or
required review recorded, and was squash-merged as
`436b87a482d83325ab5e54de6ec2f5fcdcac18e7`.

Specify native UTF-8/binary arrays: checked offsets, invalid UTF-8 rejection,
OOM atomicity, null/empty distinction, borrowed slices and independent interop.
M1 schemas/nested arrays/record batches and later native IPC remain unimplemented.
No upstream patch was submitted; human-owner review remains mandatory upstream.
