# ArrowZ development

Build a pure Zig native Apache Arrow implementation. Do not wrap/link Arrow C++,
nanoarrow, Rust Arrow, or any foreign Arrow implementation in the SDK. Test-only
reference implementations are permitted. Optional C ABI adapters must be Zig.

Use spec-driven development: requirements -> design -> tasks -> implementation ->
verification. Read the active numbered spec and docs/ROADMAP.md before changing
semantics. Keep interfaces small, allocator ownership explicit, and document
borrowing and move rules. Test allocation failures and lifetime-sensitive code.

Use pinned Zig 0.16.0, Debug and ReleaseSafe checks, and independent interoperability
tests. Never replace required tests with skips or weaken gates. Record actual
commands, versions, commit identity, results and remaining coverage in the spec's
verification document. Mark Verified only when required CI passes.

Each autopilot run resumes from current main, open PRs/issues and CI. Complete one
bounded useful slice, reconcile overlapping work, and persist the handoff in Git.
Use focused branches and PRs. Merge only with all required checks/reviews passing
and repository protections satisfied. Never force push or bypass controls.
Continue through milestones; report blockers accurately. Read docs/UPSTREAM.md
before preparing contributions. Do not claim Apache affiliation or adoption.
