---
phase: 03-discovery-pairing-connection
plan: 02
subsystem: net
tags: [flutter, dart, fsm, reconnect, backoff, send-policy, tdd]

# Dependency graph
requires:
  - phase: 02-transport-input-spike
    provides: HandshakeFsm pure-FSM + thin-driver pattern (the shape this plan copies), gate-proven connectNoDelay dial path
provides:
  - ReconnectFsm — pure IO-free connection-lifecycle FSM implementing the D-04/D-05/D-06 policy table (transport-retry with 1/2/4/8s backoff capped 10s and ±20% jitter; auth-stop with token clear; resume/retry-now/beacon short-circuits)
  - SendPolicy — per-message-class send seam (volatile drop-if-not-authed, reliable FIFO queue ≤10 with overflow drop)
  - kRevokedExplanation — the exact D-05 needPairing copy string
affects: [03-05 connection-service-driver, 03-06 device-list-ui, 03-07 pairing-flow]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Reconnect FSM composes AROUND HandshakeFsm — connection lifecycle here, hello/pin/auth there, zero state duplication"
    - "Timers/sockets/storage are driver effects (StartBackoffEffect/DialEffect/ClearTokenEffect/CloseEffect); FSM holds only data"
    - "Injectable random closure (0.8 + 0.4*random()) makes jitter deterministic in tests"

key-files:
  created:
    - app/remote_control/lib/net/reconnect_fsm.dart
    - app/remote_control/lib/net/send_policy.dart
    - app/remote_control/test/reconnect_fsm_test.dart
    - app/remote_control/test/send_policy_test.dart
  modified: []

key-decisions:
  - "Backoff cap is 10s (design spec §8) — D-06's discretionary ~30s not taken, per RESEARCH Pattern 6"
  - "Backoff delay = base(1/2/4/8/10s) × (0.8 + 0.4×random()), rounded to whole milliseconds — deterministic under an injected random closure"
  - "beaconSighted short-circuit also resets the attempt counter (consistent D-06 fresh-start semantics with appResumed/retryNowPressed)"
  - "authRejected for ANY reason lands in needPairing with AuthStopEffect + CloseEffect; ClearTokenEffect only for noPairing/badMac (revoked token); explanation copy only for those two"
  - "socketConnected/authedOk return ReconnectStep.none (state-only transitions) — the driver already owns the socket, no effect needed"

patterns-established:
  - "Per-input FSM methods each with an exhaustive switch on the private state; stray inputs return the const ReconnectStep.none, never throw"
  - "SendPolicy message classes: volatile=binary move/scroll, reliable=click/drag/key/text/media/power/confirm/clip.*/browser/present, internal=handshake+ping (driver/probe-owned)"

requirements-completed: [CONN-03, CONN-04]

# Metrics
duration: 8min
completed: 2026-07-08
---

# Phase 3 Plan 02: Reconnect FSM + Send Policy Summary

**Pure IO-free reconnect FSM encoding the locked D-04/D-05/D-06 policy table (capped jittered backoff, auth-stop with token clear, resume/beacon short-circuits) plus the volatile-drop/reliable-queue send seam — 32 new unit tests, zero sockets or timers.**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-08T13:37:17Z
- **Completed:** 2026-07-08T13:45:36Z
- **Tasks:** 2 (TDD RED + GREEN)
- **Files modified:** 4

## Accomplishments

- CONN-04 recovery policy is fully unit-proven without IO: transport failures from connecting/handshaking/authed enter backoff with delays 1s, 2s, 4s, 8s then cap 10s (±20% jitter, deterministic via injected `random`); `backoffElapsed` redials the last-known ip:port.
- CONN-03 auth-stop contract implemented: `authRejected(noPairing|badMac)` emits `ClearTokenEffect` + `AuthStopEffect` + `CloseEffect` and lands in `needPairing` carrying the exact D-05 copy (`kRevokedExplanation`); NO `StartBackoffEffect` exists for any auth reason (T-03-05 — retrying badMac would hammer the server lockout counter).
- D-06 short-circuits: `appResumed`/`retryNowPressed`/`beaconSighted(target guid)` reset the attempt counter and dial immediately; a beacon updates the target's host/port (PC IP change recovery); foreign-guid beacons are ignored (T-03-06).
- SendPolicy seam shipped: volatile frames are a boolean gate (never queued — spec §8 cursor-teleport rule); reliable frames queue FIFO up to 10 during blips, overflow drops with an `onOverflow` signal, `flushOnAuthed` drains in order.
- Composition rule held: reconnect_fsm.dart has zero references to handshake_fsm.dart, Flutter, dart:io, or Timer (grep-asserted) — hello/pin/auth stay solely in HandshakeFsm.

## Task Commits

Each TDD gate was committed atomically:

1. **Task 1 (RED): failing policy-table suites + declaration stubs** - `71bf096` (test)
2. **Task 2 (GREEN): ReconnectFsm + SendPolicy implementation** - `61a7d2a` (feat)

_No REFACTOR commit: the GREEN implementation copied the proven HandshakeFsm shape directly and the analyzer reports no issues — no cleanup was warranted._

## Files Created/Modified

- `app/remote_control/lib/net/reconnect_fsm.dart` - Pure connection-lifecycle FSM (states idle/connecting/handshaking/authed/backoff/needPairing; sealed effects DialEffect/StartBackoffEffect/ClearTokenEffect/AuthStopEffect/CloseEffect; ReconnectStep with effects list; delayFor jitter math; kRevokedExplanation)
- `app/remote_control/lib/net/send_policy.dart` - Per-message-class send policy (volatile gate, bounded reliable queue, FIFO flush, clear)
- `app/remote_control/test/reconnect_fsm_test.dart` - 24 tests across 6 groups (connect, backoff, short-circuits, auth-stop, stray inputs, disconnect), every test citing its decision ID in `reason:`
- `app/remote_control/test/send_policy_test.dart` - 8 tests (volatile gating, queue bound + overflow, FIFO flush, clear)

## Decisions Made

- **10s backoff cap** (design spec §8) taken over D-06's discretionary "around 30s" — per the plan and RESEARCH Pattern 6 table.
- **Jitter formula** `0.8 + 0.4 × random()` with millisecond rounding: random 0.5 → exactly 1.0× base, 0.0 → 800ms, 1.0 → 1200ms for attempt 1 — provable bounds in tests, real `math.Random().nextDouble` as the production default.
- **beaconSighted resets the attempt counter** (plan left this unspecified): a sighting proves the server is alive, so retry starts fresh — consistent with the other two D-06 short-circuits.
- **All authRejected reasons land in needPairing** with `AuthStopEffect` + `CloseEffect`; only noPairing/badMac add `ClearTokenEffect` and set the explanation — pinInvalid/pinExpired/lockedOut/versionMismatch keep the token (not a revocation).
- **disconnectRequested from any non-idle state** returns to idle with `CloseEffect` and clears target/attempt/explanation — a user disconnect never leaves retry armed.

## Deviations from Plan

None - plan executed exactly as written.

(One within-task acceptance fix: the FSM doc header originally used the literal words `Timer` and `dart:io` in its purity comment, tripping the plan's literal grep criteria — reworded to "timer objects" / "the IO libraries" before the GREEN commit. Comment-only change, no behavior impact.)

## Issues Encountered

None.

## Known Stubs

None — all RED-phase `UnimplementedError` stubs were replaced in GREEN; no placeholder values or unwired seams remain in the two lib files. (SendPolicy and ReconnectFsm are consumed by ConnectionService in plan 03-05, by design.)

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The recovery-policy brain of "connects and recovers silently" is done and provable offline; plan 03-05 (ConnectionService driver) can now execute effects (dial via `connectNoDelay`, run backoff timers, clear tokens in DeviceStore, route SendPolicy).
- `AuthStopEffect` carries attemptsRemaining/retryAfterSecs for the pairing UI (plan 03-07) verbatim from SPEC §5.
- All 64 app tests green (32 new + 32 existing: handshake_fsm, latency_probe, move_sender, nodelay_factory, widget suites untouched).

## Self-Check: PASSED

- All 4 created files exist on disk
- Commits 71bf096 (RED) and 61a7d2a (GREEN) present in git log
- `flutter test`: 64/64 green; purity greps (flutter/dart:io/Timer/handshake_fsm in reconnect_fsm.dart) all 0

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-08*
