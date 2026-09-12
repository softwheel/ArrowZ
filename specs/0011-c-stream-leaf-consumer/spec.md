# Spec 0011: C Stream leaf-array consumer

Status: Awaiting published-commit CI (local gates passed; see verification.md).

## Requirements

Define the Arrow C Stream ABI natively in Zig and consume streams whose schema and
chunks use one of the 13 leaf layouts supported by Specs 0009-0010. The consumer
owns a moved stream, retrieves its schema exactly once, pulls owning zero-copy
chunks, recognizes successful released-array output as end-of-stream, records
producer errno-style error codes, and exposes the producer's transient error text
only immediately after a failed callback.

Reject released streams and missing mandatory callbacks before moving. A failed
schema or next callback must release any live partial output supplied by the
producer. Schema and chunk owners must release independently of the stream. Once
EOS is observed, later `next` calls return EOS without calling the producer again.
Explicit stream/chunk relocation and repeated cleanup must retain singular
ownership and invoke each producer callback exactly once.

This slice is synchronous and not thread-safe, matching the interface baseline.
It allocates no SDK memory and does not copy Arrow buffers. Recursive record-batch
streams, stream production and persisted error-message copies remain later work.

## Design

Add `c_stream.ArrowArrayStream`, `ImportedStream` and `StreamChunk`. `take` checks
the four mandatory callbacks before shallow-moving and clearing the caller's base
structure. `readSchema` calls `get_schema` once and owns the returned schema.
`next` calls `get_next`, distinguishes error/EOS/live output, validates a live
chunk against the stored schema, then moves it into an independently releasable
`StreamChunk` holding its already-validated native view.

The consumer stores the last non-zero producer code. `lastError` is permitted only
while that code is present and returns a producer-borrowed NUL-terminated slice;
the caller must copy it before any further stream callback. Non-producer validation
errors do not authorize `get_last_error`.

## Tasks and acceptance gates

- [x] Match the canonical five-field C ABI layout and callback signatures.
- [x] Cover schema-once, live chunks, independent lifetimes, EOS caching, explicit
      relocation, missing callbacks, released state and idempotent cleanup.
- [x] Cover schema/next producer errors, errno retention, transient error text and
      cleanup of live partial outputs.
- [x] Consume PyArrow-produced leaf chunks through independent Python C callbacks
      for every supported type without transferring any foreign runtime into SDK.
- [ ] Pass pinned Zig 0.16.0 Debug and ReleaseSafe native tests, examples,
      formatting, expanded interoperability and no-runtime-dependency gates.

Mark Verified only after the exact final proposed commit passes required CI.
