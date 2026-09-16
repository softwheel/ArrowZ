# Spec 0017: Native IPC message envelope reader

Status: Implemented; exact proposed-head CI and publication gates pending.

## Requirements

Implement the first M3 slice as a pure-Zig, zero-allocation borrowed reader for
one Arrow encapsulated IPC message. Accept the current continuation marker
`0xFFFFFFFF`, a little-endian 32-bit metadata length including padding, an Arrow
FlatBuffers `Message` root, and its declared body. Recognize canonical stream EOS
as the marker followed by zero metadata length.

Expose the borrowed metadata and body slices, consumed frame byte count, metadata
version, message-header kind and declared body length. Require caller-supplied
limits for metadata and body bytes before following any FlatBuffers offsets.
Reject truncated prefixes/metadata/body, incorrect markers, unaligned metadata or
body lengths, negative or oversized body lengths, unsupported header tags, and
every out-of-range root/table/vtable/field/indirect offset using checked integer
arithmetic. Never read padding or producer-controlled offsets out of bounds.

The SDK implementation must use only Zig and must not link a FlatBuffers or Arrow
runtime. PyArrow may generate independent test messages only.

## Design

Add `src/ipc.zig` with `Limits`, `MessageHeader`, `Message`, `Frame` and
`parseFrame(input, limits)`. Implement only the FlatBuffers wire primitives
required to verify and read the root `Message` table: little-endian scalar loads,
root uoffset, signed vtable back-offset, vtable entry lookup, union tag, union
table uoffset and 64-bit body length. Missing scalar slots use FlatBuffers schema
defaults; the header union must be present and point inside metadata.

Return `.eos` or a borrowed `.message`; no ownership is transferred. This slice
does not decode the header table, schema fields, record-batch nodes/buffers,
dictionaries, compression, file footers, legacy pre-0.15 framing, or async I/O.

## Tasks and acceptance gates

- [x] Parse current encapsulated framing and canonical EOS without allocation.
- [x] Verify bounded FlatBuffers root/table/vtable/scalar/union offsets.
- [x] Enforce configurable metadata/body limits, nonnegative lengths and 8-byte
      framing alignment with overflow-safe arithmetic.
- [x] Cover truncation and mutation of every framing and FlatBuffers offset class.
- [x] Independently parse PyArrow 23.0.1 schema and record-batch messages and
      match their header kinds, body lengths and consumed boundaries.
- [x] Pass pinned Zig 0.16.0 Debug and ReleaseSafe format, tests, examples,
      interoperability and no-runtime-dependency gates locally and in CI.
- [ ] Exact proposed-head CI, mergeability, review and unresolved-thread checks.

Recheck the published Arrow IPC encapsulated-message specification and current
`format/Message.fbs` before final verification.
