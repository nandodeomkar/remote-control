---
phase: 01-protocol-contract-server-core
type: code-review
depth: standard
status: clean
reviewer: inline (orchestrator; gsd-code-reviewer agent terminated on spend limit mid-run)
files_reviewed: 41
critical: 0
warning: 0
info: 2
reviewed: 2026-07-07
---

# Phase 01 Code Review

**Verdict: CLEAN.** No Critical or Warning findings. Security-critical surface (auth, dispatch gates, transport cleanup, cross-language crypto) reviewed against the phase's locked invariants — all hold. Two Info-level notes below are documented design choices, not defects.

## Scope

41 files: Rust `server-core` (auth, codec, dispatch, transport, executors, error, lib), pure Dart `remote_protocol` (binary/JSON codecs, auth_proof, diff_ops, hex, version + tests), the frozen `protocol/` contract (SPEC, schema, sampled fixtures), and `.github/workflows/ci.yml` + root README.

**Process note:** the `gsd-code-reviewer` subagent was terminated by a provider spend limit after 46 tool calls without writing output. The orchestrator (on Opus 4.8) completed a focused inline review of the security-critical files. Coverage prioritized the auth/gate/crypto surface — the phase's stated purpose — plus the newest code (the Dart package). The lower-risk fixture JSON and schema docs were spot-checked, not line-audited.

## Security invariant verification (all PASS)

| Invariant | Where | Status |
|-----------|-------|--------|
| Tokens stored only as SHA-256 hashes; raw token transient | `auth/mod.rs` `complete_pairing`, `auth/token.rs` | PASS — `paired_hashes: Vec<[u8;32]>`, no raw-token field |
| HMAC key = SHA-256(raw token), message = nonce | `auth/challenge.rs`, Dart `auth_proof.dart` | PASS — byte-identical across .NET/Rust/Dart (`auth_proof_fixture` + Dart `auth_proof_test`) |
| Constant-time compares (PIN, MAC) | `auth/pin.rs` `ConstantTimeEq`, `challenge.rs` `Mac::verify_slice` | PASS — no manual byte compares |
| PIN 60s / 5 attempts / 300s per-IP / global cap 20 | `auth/pin.rs` (paused-time tests) | PASS |
| Lockout survives reconnect (on AuthManager, not session) | `auth/mod.rs`, `pin.rs` | PASS — `HashMap<IpAddr, Instant>` owned by manager |
| Pre-auth messages silently dropped (no oracle) | `transport/session.rs`, `dispatch/router.rs` GATE 1 | PASS — text, binary, and malformed frames all silent pre-auth |
| Disconnect releases all held input (CONN-07) | `transport/session.rs` post-loop `release_all`, `dispatch/held.rs` | PASS — straight-line unconditional cleanup, drain-based + idempotent |
| Power actions double-confirmed, 10s window | `dispatch/router.rs` `Power`/`Confirm` | PASS — `power` never executes alone; `take()` single-shot; window + mismatch → `noPendingAction` |
| Pause immediately releases held input, drops executor traffic | `session.rs` pause branch, `router.rs` GATE 2 | PASS — ping/read-only queries exempt, executor families dropped |
| No secrets logged (T-01-31) | `transport/session.rs` | PASS — no log sink in the module; decode errors counted, not printed |

## Info-level notes (no action required)

### Info 1 — `auth` MAC failures are not rate-limited (only PIN is)
`server/server-core/src/transport/session.rs` (`Msg::Auth` branch) returns `authFail{badMac}` on a bad proof but does not increment any lockout counter — only the PIN pairing path feeds the lockout table.

This is not exploitable: the proof is HMAC-SHA256 over a fresh per-connection 32-byte nonce keyed by a 256-bit secret, so guessing is a 2^256 search with no reuse across reconnects. The SPEC scopes lockout to PIN pairing (§4). Recorded only so a future reviewer does not re-flag it as a gap.

### Info 2 — post-auth decode error replies `err{code:"internal"}`
`session.rs` `handle_text` maps a post-auth malformed frame to `err{internal}` and keeps the connection (pre-auth stays silent). The SPEC §7 err table defines no decode-failure code, so the closest existing code was chosen by documented decision (already logged in STATE.md and the 01-06 SUMMARY). Acceptable; noted for traceability.

## Quality observations

- Every module carries a doc-comment stating its SPEC section and threat IDs; held-input, gates, and CONN-07 cleanup each explain the *why*, not just the *what*.
- The Dart codec mirrors every locked Rust codec decision (always-emit-`p`, lenient unknown `t` → `UnknownMsg`, string-typed enum fields, binary decode order length→f32→finite→opcode). No wire divergence.
- Tests are behavior-first and comprehensive: gate ordering proven by the pre-auth-ping-while-paused case; confirm window proven with paused-clock advance at 9s (pass) and 11s (expire); `release_all` idempotency asserted directly.

## Follow-ups

None blocking. Both Info notes are intentional, documented choices.
