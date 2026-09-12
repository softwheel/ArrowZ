# Path to Apache Arrow contribution

ArrowZ is an independent Apache-2.0-licensed implementation, not an official Apache
Arrow subproject. Existing repository license is retained.

1. Establish a useful, independently tested native Zig core and explicit coverage.
2. Survey existing Zig Arrow projects and open Arrow proposals to avoid duplicate
   work; compare APIs, ownership and compatibility evidence before proposing scope.
3. Prepare a concise `[DISCUSS][Zig] Native Arrow implementation` proposal for the
   Arrow development community with the repository, design, interoperability
   results, maintenance plan and a small candidate first contribution.
4. Seek agreement on integration tests, documentation, or an experimental language
   implementation before proposing broad upstream code integration.
5. Submit focused upstream changes following the target repository's current
   conventions; disclose AI assistance and keep an engaged human owner/reviewer.
   Never tag or ping maintainers automatically. Adoption is a community decision.

References checked 2026-09-09:
- https://arrow.apache.org/docs/developers/overview.html
- https://arrow.apache.org/community/
- https://arrow.apache.org/docs/format/CDataInterface.html
- https://arrow.apache.org/docs/format/CStreamInterface.html

The C Stream reference was rechecked on 2026-09-12 against the published Arrow
25.0.1 documentation before implementing the native consumer.

Before upstream submission, the owner should review and understand the generated
changes and be prepared to debug and maintain them, as Arrow's contribution guide
requests. Autopilot can develop and prepare concrete upstream patches and proposal
text; do not assert human review or community acceptance without evidence.
