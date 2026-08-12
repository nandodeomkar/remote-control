---
status: passed
phase: 01-protocol-contract-server-core
verifier: inline (orchestrator, Opus 4.8; gsd-verifier subagent skipped after repeated provider-limit terminations)
score: 5/5 success criteria + 1/1 requirement
must_haves_verified: true
requirements_verified: [CONN-07]
verified: 2026-07-07
---

# Phase 01 Verification — Protocol Contract & Server Core

**Verdict: PASSED.** All 5 ROADMAP success criteria and requirement CONN-07 verified against the live codebase and fresh test runs (not just SUMMARY claims).

## Phase Goal

> The wire protocol is locked as a versioned contract (challenge-response auth, diff-ops text, 9-byte binary mouse frames) and an OS-agnostic Rust server core enforces it — pairing, auth gating, routing, pause, and session cleanup all proven in CI with mock executors and zero Windows dependencies.

Achieved.

## Success Criteria (goal-backward)

### SC1 — Shared fixtures decode identically in Rust and Dart — PASS
Both suites run against the SAME `protocol/fixtures/` files (Dart loads them via `../../../protocol/fixtures`, guarded by `existsSync`; per-language copies forbidden, D-09).
- Rust: `cargo test -p server-core --test fixtures` → 4 passed (`codec_fixtures_mouse_binary`, `codec_fixtures_handshake`, `codec_fixtures_text`, `auth_proof_fixture`)
- Dart: `dart test` → 8 passed, including `fixture_test.dart` mouse-binary / handshake / text families

### SC2 — Full pair → challenge-response → input flow; gates drop pre-auth and paused traffic — PASS
- `cargo test --test integration` → 8 passed, including `walking_skeleton_pair_auth_input` (fake WS client completes hello → challenge → pin/pairOk → auth → input)
- `dispatch/router.rs` GATE 1 (auth) and GATE 2 (pause) proven: `pre_auth_drops_every_non_handshake_message_silently`, `pre_auth_ping_dropped_even_though_pause_would_pong_it` (gate ordering), `paused_drops_every_executor_bound_family_silently`, `paused_ping_still_ponged`

### SC3 — PIN rules enforced; tokens SHA-256-only; raw token never crosses wire after pairing (HMAC of server nonce) — PASS
- `cargo test -p server-core --lib auth::` → 21 passed under paused tokio time (60s TTL, 5 attempts, 300s per-IP lockout, global cap 20) in <1s wall clock
- `AuthManager` stores `paired_hashes: Vec<[u8;32]>` only; `complete_pairing` returns the raw hex transiently with no raw-token field retained
- Construction `mac = HMAC-SHA256(key = SHA-256(raw token), msg = nonce)` reproduces the independently .NET-computed `05-auth-proof.json` macHex byte-identically in both Rust and Dart; `verify_mac` keys from the stored hash via constant-time `Mac::verify_slice`

### SC4 — Kill socket mid-drag releases all held input via cleanup hook; no phantom held input — PASS (CONN-07)
- `transport/session.rs` runs `ctx.held.release_all(...)` as straight-line code after the read loop — reached on clean close, socket error, oversize-frame error, and version-reject alike; `release_all` is drain-based and idempotent
- Integration test `disconnect_mid_drag_releases_held_input` confirms an abrupt mid-drag socket kill emits `ButtonUp` to the mock and a fresh session shows no phantom release

### SC5 — server-core builds and passes all tests with zero Windows dependencies — PASS
- `cargo test --workspace` → 98 passed (86 lib + 4 fixture + 8 integration), 0 failed
- `cargo tree -p server-core --target x86_64-unknown-linux-gnu` → 106-node tree, **0** `windows`/`winapi` matches (host-target tree pulls `windows-sys` transitively via tokio/mio only; the CI-compiled Linux target — the criterion's contract — is clean)

## Requirement Traceability

| Req ID | Requirement | Phase | Status | Evidence |
|--------|-------------|-------|--------|----------|
| CONN-07 | Server releases all held keys/buttons when a session ends | 01 | Complete | SC4 above; marked `[x]` Complete in REQUIREMENTS.md |

Every requirement ID declared in the phase's PLAN frontmatter (CONN-07) is accounted for.

## Cross-check: claimed vs actual

All 8 plan SUMMARYs claim green suites; re-ran independently at verification time — claims hold. The 01-06 SUMMARY's "walking skeleton green without test modification" and the CONN-07 5-run stability claim are consistent with the current 8/8 integration pass. No self-check discrepancies found.

## Notes

- Verification performed inline by the orchestrator because the `gsd-verifier` subagent could not complete — the provider terminated three consecutive background agents (executor 01-07 closeout, executor 01-08 Task 3, and the code-reviewer) on session/spend limits. To avoid a fourth dropped run, the goal-backward check was done directly with fresh test execution as primary evidence.
- Plan 01-07 (Flutter SDK install) was a human-in-loop environment task; its checkpoint was approved by the user (`dart --version` → 3.12.2 confirmed in a fresh terminal).

## Verdict

**PASSED — phase may be marked complete.**
