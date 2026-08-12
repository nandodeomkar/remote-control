# Phase 1: Protocol Contract & Server Core - Context

**Gathered:** 2026-07-07
**Status:** Ready for planning

<domain>
## Phase Boundary

The wire protocol is locked as a versioned contract (challenge-response auth, diff-ops text, 9-byte binary mouse frames) and an OS-agnostic Rust `server-core` enforces it — pairing, auth gating, routing, pause, and session cleanup all proven by tests with mock executors and zero Windows dependencies. Includes the Dart codec passing the same golden fixtures. No Windows executors, no Flutter UI, no real input injection — those are later phases.

</domain>

<decisions>
## Implementation Decisions

User was offered all four gray areas (CI target, Dart codec home, protocol strictness, fixture format) and answered "no preference" — all four delegated to Claude's discretion. Defaults locked below so downstream agents don't re-litigate.

### CI target
- **D-01:** Repo is local-only (no git remote). Phase 1's "proven in CI" criterion is satisfied by local test suites: `cargo test` (workspace) and `dart test` (codec package) both green.
- **D-02:** Write a GitHub Actions workflow file (`.github/workflows/ci.yml` — Rust + Dart jobs) as part of Phase 1 anyway; it is cheap, documents the test entrypoints, and activates automatically whenever the repo is pushed to GitHub. Do not block any success criterion on remote CI running.

### Dart codec home
- **D-03:** Phase 1 creates a **pure Dart package** (no Flutter dependency) for the protocol codec, e.g. `app/packages/remote_protocol/`. The Flutter app scaffold itself is deferred to Phase 2 (the cursor spike needs it; Phase 1 doesn't).
- **D-04:** The package owns: binary mouse-frame encoder/decoder, JSON message codecs for every family, protoVersion constants, and fixture-driven tests. Phase 2's Flutter app imports it via path dependency.

### Protocol strictness
- **D-05:** Unknown JSON fields are **ignored** on decode (forward-compatible — new minor versions can add fields without breaking old peers). Missing required fields are hard decode errors.
- **D-06:** `protoVersion` is `major.minor` (string "1.0" in `hello`). Major mismatch → server rejects, rejection message carries both versions (per spec §5). Minor mismatch → accepted; peers simply don't use features they don't know.
- **D-07:** Unknown message type `t` after auth → server replies `err` (human-readable, per spec §5) and keeps the connection; it never kills the session over an unknown type.

### Fixture format
- **D-08:** `protocol/fixtures/` organized per family: `handshake/`, `text/`, `mouse-binary/`, etc. Each scenario is one JSON file: `{ "name", "description", "wire" (JSON object for text frames | hex string for binary frames), "expect" (canonical decoded form) }`. Naming: `NN-scenario-slug.json`.
- **D-09:** Required scenario coverage comes from the roadmap success criteria: auth handshake (challenge/auth/authOk/authFail), IME-revision diff-ops, emoji (multi-byte UTF-8), rapid-backspace, binary mouse move/scroll frames including negative deltas. Both codecs load the same files — no per-language fixture copies.

### Claude's Discretion
- All of the above are Claude-discretion defaults (user explicitly had no preference). Planner may refine details (exact directory names, test harness choices) as long as the observable contract holds: shared fixtures, both codecs green, zero Windows deps in `server-core`, local tests as the gate.

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design spec (authoritative for this phase)
- `docs/superpowers/specs/2026-07-07-remote-control-design.md` — §3 architecture/monorepo layout, §4 discovery+pairing (PIN rules, challenge-response), §5 wire protocol (frame formats, message families, versioning, auth gating), §6 server-core crate boundaries + executor traits, §9 testing strategy. Approved and locked — planning must follow it.

### Research
- `.planning/research/SUMMARY.md` — synthesized findings; build-order rationale
- `.planning/research/STACK.md` — tokio/tungstenite/enigo versions and rationale
- `.planning/research/PITFALLS.md` — domain pitfalls with phase mapping
- `.planning/research/ARCHITECTURE.md` — component boundaries, data flow

</canonical_refs>

<code_context>
## Existing Code Insights

Greenfield — no code exists yet. Repo contains only `docs/`, `CLAUDE.md`, and `.planning/`.

### Reusable Assets
- None (first code phase).

### Established Patterns
- Monorepo layout is pre-decided by spec §3: `protocol/` (spec + fixtures), `server/` (Rust workspace: `server-core` + `server-windows`), `app/` (Flutter). Phase 1 creates `protocol/`, `server/server-core/`, and the pure Dart codec package; `server-windows` is stubbed or deferred to Phase 2.

### Integration Points
- Phase 2 consumes: `server-core` + a minimal `server-windows` binary (enigo mouse executor) + the Dart codec package.
- STATE.md blocker for Phase 2 (Dart TCP_NODELAY via web_socket_channel) is out of Phase 1 scope but the codec package API should not preclude a raw-socket construction path.

</code_context>

<specifics>
## Specific Ideas

No specific requirements — user delegated implementation choices; standard approaches apply within the locked spec.

</specifics>

<deferred>
## Deferred Ideas

None — discussion stayed within phase scope.

</deferred>

---

*Phase: 1-Protocol Contract & Server Core*
*Context gathered: 2026-07-07*
