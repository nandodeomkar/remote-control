---
phase: 04-trackpad-keyboard
plan: 10
subsystem: transport
tags: [rust, tokio, websocket, liveness, half-open-tcp, conn-07, tdd]

# Dependency graph
requires:
  - phase: 01-protocol-server-core
    provides: "run_session read loop + straight-line CONN-07 release_all cleanup, HeldInput, CallLog::wait_for mock harness"
  - phase: 04-trackpad-keyboard (04-02)
    provides: "key hold wire vocabulary (t=key, code=ShiftLeft, action=down) and server-side held-key model"
provides:
  - "LIVENESS_TIMEOUT (10s) deadline branch in run_session's select! — half-open TCP (abrupt WiFi kill, no FIN/RST) now breaks the read loop onto the existing CONN-07 cleanup"
  - "half_open_silence_releases_held_input paused-clock socket-level regression test (04-UAT Test 5)"
  - "Side-effect hardening: silent pre-hello socket squatters die in 10s instead of holding a session task forever"
affects: [phase-04-uat-retest, phase-05-control-center, phase-07-settings]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Liveness deadline via sleep_until(last_inbound + LIVENESS_TIMEOUT) select! branch — deadline expiry reuses the existing straight-line cleanup, never new cleanup code"
    - "tokio::time::pause() mid-test + resume() before real-IO assertions (plan-checker flake mitigation for paused-clock vs kernel FIN races)"

key-files:
  created: []
  modified:
    - server/server-core/src/transport/session.rs
    - server/server-core/tests/integration.rs

key-decisions:
  - "last_inbound refreshes on EVERY inbound frame (Text, Binary, WS control) before the frame-type match — any bytes prove the peer alive; the pause-watch branch deliberately does not refresh"
  - "Session-end assertion runs under REAL time (tokio::time::resume() + 2s RECV_TIMEOUT) per plan-checker note 1 — auto-advance does not block-wait on IO, so a virtual timeout races the kernel-delivered loopback FIN"
  - "LIVENESS_TIMEOUT stays private to session.rs — the integration test hard-codes a longer 60s wait and names the coupling in a comment"

patterns-established:
  - "Half-open simulation in socket tests: keep the client alive and silent (never drop/close) — dropping emits FIN/RST on loopback, which is the graceful path"

requirements-completed: [KEY-04]

# Metrics
duration: 11min
completed: 2026-07-10
---

# Phase 04 Plan 10: Half-Open Liveness Deadline Summary

**10s liveness deadline in run_session's select! breaks the read loop onto the existing CONN-07 release_all when a half-open TCP connection goes silent — closing the 04-UAT Test 5 phantom-held-Shift gap**

## Performance

- **Duration:** ~11 min
- **Started:** 2026-07-10T09:30:57Z
- **Completed:** 2026-07-10T09:42:00Z
- **Tasks:** 2 (RED → GREEN)
- **Files modified:** 2

## Accomplishments

- Closed the single MAJOR gap from 04-UAT (Test 5): an abrupt WiFi kill while a locked modifier is held no longer leaves the key stuck on the PC — held input releases within 10 seconds instead of OS-TCP-timeout minutes
- `half_open_silence_releases_held_input`: deterministic, ~instant (0.22s wall-clock) paused-clock regression test that simulates a half-open connection byte-for-byte (socket alive and bound, zero frames) and asserts KeyUp + session termination
- Zero wire-protocol, client, or executor changes — the entire fix is one const + one select! branch + one `last_inbound` refresh in session.rs
- Bonus hardening (T-04-10-02): unauthenticated silent socket squatters now die in 10s

## Task Commits

Each task was committed atomically:

1. **Task 1: RED — half-open silence regression test** - `baff15a` (test) — verified failing on exactly the KeyUp assertion in 0.01s, all 8 sibling tests green
2. **Task 2: GREEN — liveness deadline in run_session's select!** - `d269c05` (fix) — full workspace suite green (91 + 4 + 9 + 10 tests)

**TDD gate compliance:** RED commit precedes GREEN commit in history; RED failure landed on the intended assertion (not compile/handshake).

## Files Created/Modified

- `server/server-core/src/transport/session.rs` - `LIVENESS_TIMEOUT` const (10s, doc-commented with the 250ms/2s client ping cadence rationale), `last_inbound: tokio::time::Instant` tracking, `sleep_until` liveness branch breaking `'read` onto the existing CONN-07 cleanup; module doc extended to name the half-open leg
- `server/server-core/tests/integration.rs` - `half_open_silence_releases_held_input` regression test (paused clock, 60s virtual wait > 10s deadline, real-time session-end check); `KeyCode` added to executor imports

## Decisions Made

- Followed plan-checker note 1: `tokio::time::resume()` before the session-end assertion with a short real 2s timeout, instead of the plan's original virtual 60s `timeout(ws.next())` — avoids the auto-advance-vs-kernel-FIN flake
- `last_inbound` refresh placed before the frame-type match so WS control frames (Ping/Pong in the `_` arm) count as liveness, exactly as planned

## Deviations from Plan

None - plan executed exactly as written (the resume()-based session-end check is the plan-checker's own documented mitigation, incorporated into the plan's notes).

## Issues Encountered

None. RED failed instantly on the intended assertion; GREEN passed on first run.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- All 10 plans of Phase 04 now have summaries; the last open UAT gap (Test 5, MAJOR) has a named closing mechanism (`LIVENESS_TIMEOUT` → CONN-07)
- Human re-check pending at UAT re-run (not a blocking checkpoint): kill WiFi while Shift is locked — the PC should release Shift within ~10s
- Phase 04 is ready to close after the on-device re-test

## Review Follow-Up: CR-01 (Critical, fixed)

**Finding (code review, post-execution):** the unconditional 10s `LIVENESS_TIMEOUT` was armed from connection start in every auth state — but the client's ping cadence only exists post-auth. During pairing the user reads the PIN off the PC toast and types 6 digits (routinely >10s of silence; the server's own PIN window budgets 60s), so the deadline slammed the socket mid-PIN-entry: a deterministic pairing regression against the Phase 3 pairing criterion.

**Fix shape (same minimal style):** the deadline now scales by auth state inside the same `select!` branch — `Authed` keeps the 10s UAT Test 5 contract (held input only exists post-auth); any pre-auth state uses `PRE_AUTH_LIVENESS_TIMEOUT` (90s = 60s `PIN_TTL_SECS` window + margin, so the deadline can never race a still-valid PIN). Pre-hello squatter hygiene (T-04-10-02) relaxes 10s → 90s, still bounded.

**Regression test:** `pre_auth_silence_survives_pin_entry` — 30s of paused-clock pre-auth silence, then PIN pairing must complete on the same connection. RED failed with `ConnectionAborted` (the CR-01 failure mode exactly); GREEN passes with the full workspace suite green (91 + 4 + 10 + 10).

**Commits:**
- `e1c01d1`: test(04-10): add failing pre-auth PIN-entry liveness regression (review CR-01)
- `213b8fd`: fix(04-10): scale liveness deadline by auth state — pre-auth survives PIN entry (review CR-01)

**Out of scope (per review routing):** WR-02 — `tx.send(frame).await` inside the read loop can starve the liveness branch if the peer stops draining the socket; pre-existing structure, tracked as a warning.

## Self-Check: PASSED

- SUMMARY file exists on disk
- Task commits `baff15a` (test) and `d269c05` (fix) verified in git log; CR-01 follow-up commits `e1c01d1` (test) and `213b8fd` (fix) verified in git log
- Plan diff scope: exactly the two declared files (session.rs, integration.rs); no diff under app/, protocol/, or server-windows/

---
*Phase: 04-trackpad-keyboard*
*Completed: 2026-07-10*
