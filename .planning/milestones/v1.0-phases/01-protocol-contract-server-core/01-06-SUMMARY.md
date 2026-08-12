---
phase: 01-protocol-contract-server-core
plan: 06
subsystem: transport
tags: [rust, tokio, tokio-tungstenite, websocket, integration-tests, conn-07]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core (plan 03)
    provides: JSON envelope codec (decode_text/encode_msg) and strict 9-byte binary codec
  - phase: 01-protocol-contract-server-core (plan 04)
    provides: AuthManager (begin_pairing/verify_pin/complete_pairing/issue_challenge/verify_auth)
  - phase: 01-protocol-contract-server-core (plan 05)
    provides: dispatch::route/route_binary gates, SessionCtx, drain-based HeldInput, recording MockExecutors
provides:
  - Implemented server_core::run — WebSocket accept loop on an injected TcpListener
  - listener.rs — set_nodelay(true) per stream + accept_async_with_config with 64 KB message/frame caps
  - session.rs — per-connection read loop + mpsc write task, handshake FSM (AwaitingHello → AwaitingAuth → Authed) owned by the session layer
  - CONN-07 — unconditional held.release_all after the read loop + immediate release on pause activation
  - 8 socket-level integration tests — walking skeleton, reconnect challenge-response, disconnect-mid-drag headline, pre-auth/pause gating, D-06 version reject, D-07 unknown-type survival, 64 KB oversize handling
affects: [02-windows-server, phase-2-latency-gate, all-later-feature-phases]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Session-owned handshake FSM: hello/pin/auth never reach dispatch::route (its debug_assert enforces the split)"
    - "mpsc-backed write task: read loop never touches the sink; reply ordering guaranteed by channel FIFO (err-then-close for D-06)"
    - "Unskippable cleanup: release_all in straight-line code after the read loop, reached on every exit path"
    - "watch::Receiver pause branch with pause_alive guard (sender drop disables the select branch instead of busy-looping)"

key-files:
  created: []
  modified:
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/src/transport/session.rs
    - server/server-core/tests/integration.rs

key-decisions:
  - "Post-auth JSON decode errors reply err{code:internal} and keep the connection: SPEC err table defines no decode-failure code, and inventing one (badMessage) would be off-spec; pre-auth decode errors stay silent per SPEC §6"
  - "Unparseable protoVersion major (e.g. 'abc') is treated as a version mismatch → err{versionMismatch} + close, matching D-06's reject-by-default posture"
  - "Post-auth hello/pin/auth replays are ignored silently: the FSM owns handshake types and route()'s debug_assert forbids forwarding them"
  - "Zero-Windows-deps criterion verified against the Linux target: windows-sys appears in the host-platform tree only via tokio/mio/socket2 runtime plumbing; cargo tree --target x86_64-unknown-linux-gnu has zero windows/winapi matches"

patterns-established:
  - "Integration Harness struct (addr + log + auth + pause_tx + server handle) with pair_client/authed_client helpers — reuse for all future socket-level suites"
  - "Prove-before-kill: tests wait_for the executor call before dropping the socket (no sleep-and-hope sequencing)"

requirements-completed: [CONN-07]

# Metrics
duration: 13min
completed: 2026-07-07
---

# Phase 01 Plan 06: Transport Layer and Integration Suite Summary

**WebSocket transport with session-owned handshake FSM and unconditional CONN-07 cleanup — walking skeleton plus 7 new socket-level tests, cargo test --workspace fully green (98 tests)**

## Performance

- **Duration:** 13 min
- **Started:** 2026-07-07T15:50:09Z
- **Completed:** 2026-07-07T16:03:07Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- Walking-skeleton E2E test green with zero test modification: connect → hello → challenge → pin → pairOk → click → mock recording, over a real TCP socket
- CONN-07 headline proven at socket level: abrupt mid-drag disconnect releases the held button via the unskippable post-loop `release_all`; a fresh session shows no phantom releases (5 consecutive runs, no flake)
- Reconnect path proven on the wire: HMAC challenge-response (key = SHA-256(token)) authenticates without the raw token ever re-crossing, then drives the 9-byte binary hot path
- All four gate behaviors proven at socket level: pre-auth drops (JSON + binary), pause drops with ping liveness and held-input release, D-06 version reject with both versions, D-07 unknown-type survival
- 64 KB transport caps enforced at accept: >64 KB pre-auth frame rejected without panic or executor call, server keeps accepting new connections

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement transport to turn the walking-skeleton test green** - `7e85c0c` (feat)
2. **Task 2: Complete the socket-level integration suite (CONN-07 headline)** - `65e3751` (test)

## Files Created/Modified

- `server/server-core/src/transport/mod.rs` - `run()` implemented: delegates to the accept loop with injected ServerDeps
- `server/server-core/src/transport/listener.rs` - Accept loop: `set_nodelay(true)` before the WS handshake, `accept_async_with_config` with 65536-byte message/frame caps, per-connection session task spawn
- `server/server-core/src/transport/session.rs` - Handshake FSM, mpsc write task, `tokio::select!` read loop over stream + pause watch, pre-auth silent drops, post-loop unconditional `release_all` (CONN-07), no logging of any payload content (T-01-31)
- `server/server-core/tests/integration.rs` - Harness + helpers (`start_server`, `pair_client`, `authed_client`, `hello_challenge`, `move_frame`) and 7 new tests alongside the untouched walking skeleton

## Decisions Made

- **Post-auth decode errors → `err{code:"internal"}`, connection kept:** the SPEC §7 err table has no decode-failure code; using the closest existing code avoids inventing an off-spec `badMessage`. Pre-auth decode errors are silently dropped (SPEC §6 — no probing oracle). Documented in a comment at the decode site.
- **Unparseable protoVersion treated as major mismatch:** a hello with a garbage version string gets `err{versionMismatch}` + close rather than a silent drop — reject-by-default per D-06.
- **`pause_alive` guard on the watch branch:** `watch::Receiver::changed()` returns Err forever once the sender drops; the guard disables that select branch instead of busy-looping the session task.
- **Right button used for the pause-release drag assertion** so the released `ButtonUp(Right)` is unambiguous against the test's earlier left-clicks.

## Deviations from Plan

None - plan executed exactly as written. Both tasks' verification passed on the first run with no transport bugs surfaced by the test suite.

## Verification Notes

- `cargo test --workspace`: 98 tests green (86 lib + 4 fixture + 8 integration), 0 failed
- `disconnect_mid_drag_releases_held_input`: 5 consecutive passes, no flake
- **Zero-Windows-deps criterion:** `cargo tree -p server-core --target x86_64-unknown-linux-gnu` has zero windows/winapi matches. On the Windows host tree, `windows-sys` appears only as transitive platform plumbing of tokio/mio/socket2 (the async runtime's syscall bindings for whatever host it compiles on) — not a project Windows dependency. The phase gate (D-01/D-02 CI on ubuntu-latest) compiles clean by construction.
- `grep -n release_all src/transport/session.rs`: exactly two call sites — the pause-transition release and the post-loop unconditional release
- Every recv in integration.rs goes through timeout-wrapped `recv_json`/`ws.next()`; connects timeout-wrapped too

## Issues Encountered

None. The rand/hmac API-drift pitfalls flagged in STATE were already absorbed by Plan 04; tungstenite 0.29's `Utf8Bytes`/`Bytes` payload types and the builder-style `WebSocketConfig` were confirmed against the local registry source before writing code.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Phase success criteria 2 (pair/reconnect over the wire), 4 (CONN-07), and 5's test half (workspace green, zero Windows deps on the CI target) are proven at socket level
- `server_core::run(listener, deps)` is the single composition-root entry point the Phase-2 Windows binary will call with real executors
- Remaining phase plans: 01-07 (Dart codec) and 01-08 — the Rust side of the contract is complete
- Phase-2 latency prerequisite baked in: every accepted stream has TCP_NODELAY set before the WebSocket handshake

## Self-Check: PASSED

All created/modified files verified on disk; both task commits (7e85c0c, 65e3751) verified in git log.

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*
