# ArrowZ roadmap

Goal: a pure Zig native Apache Arrow implementation with an idiomatic Zig SDK.
The implementation and public core API are Zig; C interoperability is optional.

| Milestone | Deliverable | Verification gate |
| --- | --- | --- |
| M0 | Native primitive arrays, builders, bitmap, slices; C export adapter | Zig allocator/lifetime tests and independent PyArrow export tests |
| M1 | Boolean, UTF-8/binary, schema/metadata, nested arrays and record batches | Type/layout/null/offset interoperability matrix |
| M2 | C Data import and C Stream adapters in Zig | Bidirectional exchange, lifetime/error/EOS tests |
| M3 | Native Zig IPC file/stream reader and writer, native FlatBuffers handling | Arrow integration fixtures, malformed/truncated input and resource limits |
| M4 | Extended types, documented coverage, benchmarks and package release | Compatibility matrix, reproducible benchmarks, supported-target CI |
| M5 | Upstream collaboration and contribution | Maintainer-agreed scope and upstream review |

M0 is governed by specs/0001-native-foundation/spec.md. Before each later milestone,
write requirements, design, tasks and acceptance evidence in a numbered spec.
M0 passed its scoped gates in PR #1. The first M1 slice, native bit-packed boolean
arrays, passed in PR #3. Native UTF-8/binary is governed by
specs/0003-native-variable-binary/spec.md and passed in PR #4. Native schemas and
borrowed validated record batches are governed by
specs/0004-native-schema-record-batch/spec.md and passed in PR #5. Owning
heterogeneous batches are governed by specs/0005-owning-record-batch/spec.md.
Native record-batch C Data export is governed by
specs/0006-c-data-record-batch/spec.md.
Native struct arrays are governed by specs/0007-native-struct-array/spec.md.
Performance follows correctness; preserve zero-copy interoperability where valid.
Do not add C/C++ implementations or another-language Arrow runtime to save time.
