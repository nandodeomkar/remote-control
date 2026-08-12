---
phase: 02-end-to-end-cursor-spike
plan: 04
subsystem: testing
tags: [latency, wifi, hard-gate, enigo, tcp-nodelay, pointer-ballistics]

# Dependency graph
requires:
  - phase: 02-01
    provides: server-windows binary — enigo MouseKeys executor (input thread, sub-pixel accumulation, DPI awareness)
  - phase: 02-02
    provides: connectNoDelay (TCP_NODELAY WebSocket) + MoveSender (9-byte binary move frames)
  - phase: 02-03
    provides: runnable end-to-end vertical — handshake FSM, trackpad screen, interleaved-ping latency HUD
provides:
  - Recorded Phase-02 hard-gate verdict — PASS (p50 = 6ms, p95 = 10ms on real WiFi, ~3x under the 30ms budget)
  - Transport decision locked — ws:// + TCP_NODELAY proven; UDP-mouse-channel reconsideration NOT triggered
  - Known issue documented — Windows "Enhance pointer precision" (pointer ballistics) suppresses slow relative deltas; workaround = disable the setting; real fix = absolute injection
affects: [phase-03, phase-04]

# Tech tracking
tech-stack:
  added: []
  patterns: []

key-files:
  created:
    - .planning/phases/02-end-to-end-cursor-spike/02-04-GATE-RESULT.md
  modified: []

key-decisions:
  - "Gate judged PASS with the pointer-accel workaround (setting disabled): the accel loss is OS-injection fidelity, not transport/latency — it does not touch the risk Phase 02 exists to retire"
  - "Absolute-injection fix (enigo Coordinate::Abs / normalized SendInput) scoped OUT of Phase 02 — captured as a pending todo targeting Phase 4 (Trackpad & Keyboard cursor-feel work)"

patterns-established: []

requirements-completed: [PAD-05]

# Metrics
duration: manual (human-executed on-device gate)
completed: 2026-07-08
---

# Phase 2 Plan 4: Manual Hard-Gate Measurement Summary

**Phase-02 hard gate PASSED on real hardware: p50 = 6ms / p95 = 10ms round-trip-under-move-load over real WiFi (Xiaomi Android 16 phone → Windows 11 laptop), ~3x under the 30ms budget — the WebSocket-only transport is locked and Phase 3 is unblocked.**

## Performance

- **Duration:** manual — human-executed on-device measurement (not agent time)
- **Completed:** 2026-07-08
- **Tasks:** 1 of 1 (blocking human-verify checkpoint)
- **Files modified:** 1 (gate-result artifact)

## Accomplishments
- All four PAD-05 criteria judged on physical hardware over real WiFi: visually instant tracking (PASS), p95 < 30ms under continuous move load (PASS — 10ms), no 40–200ms hitches on slow precise movement (PASS), smooth slow diagonal with no drift or stair-stepping (PASS).
- The make-or-break transport risk Phase 02 exists to retire is retired: sub-6ms p50 under continuous load is consistent with TCP_NODELAY active on both ends; the roadmap's UDP-mouse-channel reconsideration is NOT triggered.
- Gate run surfaced one real-world defect outside the transport scope: Windows pointer ballistics ("Enhance pointer precision", the OS default) curves small relative deltas toward zero, so slow drags produced no movement until the setting was disabled. Root cause, workaround, and recommended absolute-injection fix are documented in the gate result and captured as a pending todo.

## Task Commits

Human-verify checkpoint — the measurement itself produced no code. The gate-result artifact is committed with this summary as the plan's docs commit.

## Files Created/Modified
- `.planning/phases/02-end-to-end-cursor-spike/02-04-GATE-RESULT.md` — full verdict: measurement setup, four criteria judgments, measured p50/p95, pointer-accel known issue, outcome

## Decisions Made
- Gate verdict is PASS with the pointer-accel workaround: the suppressed slow deltas are an OS-injection-fidelity issue downstream of the (correct) sub-pixel accumulator, not a transport or latency failure.
- Absolute-injection fix (GetCursorPos + accumulated delta → enigo `Coordinate::Abs`) deferred: captured as todo, natural home is Phase 4 cursor-feel work. Multi-monitor / virtual-desktop normalization flagged as its edge case.

## Deviations from Plan

None - plan executed exactly as written (owner ran the on-device procedure and recorded the verdict).

## Issues Encountered
- Criteria 3 and 4 initially failed with Windows "Enhance pointer precision" enabled: slow/small finger drags produced no cursor movement while fast drags worked. Disabling the setting made both criteria pass cleanly. Documented in 02-04-GATE-RESULT.md as a known issue with the recommended real fix.

## User Setup Required

None - no external service configuration required. (Note: until the absolute-injection fix lands, slow-drag fidelity requires Windows "Enhance pointer precision" OFF.)

## Next Phase Readiness
- Phase 02 hard gate CLEARED — transport locked (ws:// + TCP_NODELAY, p95 = 10ms). Phase 3 (Discovery, Pairing & Connection) may proceed.
- Carried forward: pointer-accel absolute-injection todo (Phase 4 candidate); spike-only removables (latency HUD, PIN shortcut, in-memory token, manual IP entry) are Phase-3 items per D-09.

---
*Phase: 02-end-to-end-cursor-spike*
*Completed: 2026-07-08*
