# Recursive struct C Data export verification and handoff

## Local evidence

Implementation commit: `a38ab3399e0f673fc35c0cca69c96360b508f0dc`.
Toolchain: repository-pinned Zig 0.16.0 on Linux x86_64. Independent oracle:
PyArrow 23.0.1 from the isolated test dependency directory.

| Gate | Debug | ReleaseSafe |
| --- | --- | --- |
| `zig fmt --check build.zig build.zig.zon src tests/fixture.zig examples` | Passed | Passed |
| `zig build test -Doptimize=$mode --summary all` | 33/33 passed | 33/33 passed |
| `zig build example -Doptimize=$mode --summary all` | Passed | Passed |
| `zig build interop -Doptimize=$mode --summary all` | Passed | Passed |
| `python tests/interop.py zig-out/lib/libarrowz_fixture.so` | 67/67 passed | 67/67 passed |
| `readelf -d` contains no `NEEDED` entry | Passed | Passed |

The recursive allocation-failure sweep constructs a two-level nullable struct and
proves that any failed array/schema-node allocation preserves the complete owning
batch without leaks. Successful export preserves outer/inner validity and numeric
leaf addresses. A moved nested leaf array and moved nested leaf schema remain valid
after all ancestors are released. Zero-child structs preserve their explicit row
count and canonical one-buffer/zero-child representation.

The PyArrow oracle independently imports a record batch containing outer and inner
nullable structs, validates recursive field metadata and nullability, checks parent
null semantics and values, runs full validation, and confirms original addresses
for both parent validity buffers plus numeric values and UTF-8 offsets/data.

## Published-commit gate

Not yet satisfied. Record the PR, proposed head, both CI jobs and merge SHA only
after remote checks complete. Spec 0008 is not Verified until then.

## Next handoff

M1 now covers the planned native array/schema/record-batch and nested export core.
Reconcile the M1 acceptance matrix, then specify the first M2 bounded slice: native
Zig C Data import with borrowed-versus-owned lifetime and malformed-input rules.
