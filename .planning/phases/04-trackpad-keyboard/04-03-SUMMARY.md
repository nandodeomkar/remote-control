---
phase: 04-trackpad-keyboard
plan: 03
subsystem: trackpad
tags: [flutter, dart, gesture-fsm, acceleration-curve, websocket, binary-frames]

# Dependency graph
requires:
  - phase: 02-end-to-end-cursor-spike
    provides: MoveSender (encodeScroll 0x02 fixture-proven), volatile sendMove hot path, SendPolicy gating
  - phase: 03-connect-pair-reconnect
    provides: ConnectionService reconnect driver, injected nowMillis/schedule seams, pure-FSM house style (reconnect_fsm/handshake_fsm)
provides:
  - GestureClassifier pure IO-free FSM emitting GestureIntent lists (D-04 full vocabulary)
  - Sealed GestureIntent family (Move/ClickLeft/ClickRight/Scroll/Fling/StopFling/ArmLongPress/DisarmLongPress/DragStart/DragEnd)
  - tuning.dart — the ONE D-06 constants file (17 tunable feel constants)
  - accelGain velocity acceleration curve with linear sensitivity multiplier (PAD-01, D-05)
  - ConnectionService.sendScroll volatile 0x02 method (RESEARCH Open Q4 closed)
affects: [04-04 trackpad screen wiring, 04-05, on-device feel tuning gate]

# Tech tracking
tech-stack:
  added: []
  patterns: [pure gesture FSM with injected clock seam, driver-owned timers via arm/disarm intents, ONE tunable-constants file for feel]

key-files:
  created:
    - app/remote_control/lib/trackpad/tuning.dart
    - app/remote_control/lib/trackpad/gesture_classifier.dart
    - app/remote_control/lib/trackpad/accel.dart
    - app/remote_control/test/trackpad/gesture_classifier_test.dart
    - app/remote_control/test/trackpad/accel_test.dart
  modified:
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/test/connection_service_test.dart

key-decisions:
  - "ScrollIntent carries delta/2 per move event — the average of the two pointers' deltas (the non-moving finger contributes zero), so summed over both fingers the total equals average finger motion"
  - "Fling velocity = sum(sample deltas in kVelocityWindowMs) / (liftTime − oldestSampleTs): a pause before lifting naturally decays the seed below kFlingMinVelocityPxMs — no explicit pause detection needed"
  - "onLongPressFire while already drag-locked is a no-op (no second DragStart); moves still stream MoveIntent so the held drag keeps tracking"
  - "onPointerCancel keeps drag-lock (cancel is per-pointer); only reset() or tap-to-drop clears the lock"
  - "A second finger landing during a drag is ignored (routed to the extras set) — the drag keeps the surface"

patterns-established:
  - "Driver-owned timers via intents: classifier emits ArmLongPressIntent(delayMs)/DisarmLongPressIntent and the driver calls onLongPressFire() — reconnect_fsm effect/driver split applied to gestures"
  - "StopFlingIntent is unconditionally FIRST in every pointer-down's intent list (instant touch-stop invariant, T-04-06)"
  - "All feel thresholds are k* constants imported from tuning.dart — no inline numeric thresholds in classifier or curve (D-06)"

requirements-completed: [PAD-01, PAD-02, PAD-03, PAD-04]

# Metrics
duration: 15min
completed: 2026-07-09
---

# Phase 4 Plan 03: Trackpad Pure Client Logic Summary

**Pure IO-free GestureClassifier FSM (tap/two-finger-tap/scroll/fling/drag-lock), velocity accelGain curve with linear sensitivity, the ONE tuning.dart constants file, and ConnectionService.sendScroll volatile 0x02 — 23 new unit tests, zero Flutter imports in the logic files**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-09T19:01:57Z
- **Completed:** 2026-07-09T19:17:00Z
- **Tasks:** 3 (2 TDD, 1 standard)
- **Files modified:** 7

## Accomplishments

- Full D-04 gesture vocabulary classified deterministically by a pure FSM: single-finger move (slop-gated), tap = left click, two-finger tap = right click (Pitfall-4 window+slop disambiguation), averaged two-finger scroll with velocity-window fling seed, and long-press drag with drag-lock that survives lifts + tap-to-drop (18 unit tests, no device)
- Velocity acceleration curve `accelGain` per D-05: slow deltas stay ~1:1 (preserving D-02 server sub-pixel fidelity), monotonic lerp saturating at kAccelMaxGain, sensitivity a pure linear multiplier, scalar return so the move hot path allocates nothing (5 unit tests)
- All 17 feel constants (tap slop/timing, two-finger window, long-press, momentum decay/tick/stop, fling threshold/window, scroll unit/direction, accel min/max/ref, sensitivity default/bounds) live in tuning.dart with D-06 on-device-tuning header — the feel gate is a constants edit, not a refactor
- `ConnectionService.sendScroll` mirrors `sendMove` byte-for-byte (shouldSendVolatile gate + `_sender?.sendScroll` + `_probe?.onMove`): RESEARCH Open Q4 closed, pre-auth scroll frames dropped never queued, opcode 0x02 asserted in tests

## Task Commits

Each task was committed atomically (TDD tasks have RED + GREEN commits):

1. **Task 1: GestureClassifier pure FSM + tuning.dart** — `834cc58` (test, RED), `bd7f049` (feat, GREEN)
2. **Task 2: Velocity acceleration curve + sensitivity** — `a9674e0` (test, RED), `e69e7f6` (feat, GREEN)
3. **Task 3: ConnectionService.sendScroll volatile method** — `e6f368b` (feat + tests)

## Files Created/Modified

- `app/remote_control/lib/trackpad/tuning.dart` — the ONE D-06 constants file (17 tunable feel constants, on-device-tuning header)
- `app/remote_control/lib/trackpad/gesture_classifier.dart` — pure FSM + sealed GestureIntent family; injected nowMillis clock; driver owns all timers/sends
- `app/remote_control/lib/trackpad/accel.dart` — `accelGain(dx, dy, sensitivity)` pure top-level fn, imports only dart:math + tuning.dart
- `app/remote_control/test/trackpad/gesture_classifier_test.dart` — 18 tests covering the full behavior contract (Wave 0 gap closed)
- `app/remote_control/test/trackpad/accel_test.dart` — 5 tests: 1:1 floor, monotonic saturation, linear sensitivity, euclidean speed, determinism (Wave 0 gap closed)
- `app/remote_control/lib/net/connection_service.dart` — added `sendScroll` directly below `sendMove`, identical policy shape
- `app/remote_control/test/connection_service_test.dart` — 2 new send-policy tests (pre-auth drop; post-auth 9-byte 0x02 frame)

## Decisions Made

- **Scroll averaging:** `ScrollIntent(dx/2, dy/2)` per move event — per-event average of the two pointers' deltas (the stationary finger contributes 0); summed across both fingers' events this equals average finger motion
- **Fling seed math:** velocity = sum of scroll-sample deltas within kVelocityWindowMs divided by (lift time − oldest in-window sample ts); a lift after a pause has an empty/stale window → no fling, giving pause-to-cancel for free
- **Drag-lock edge semantics:** onLongPressFire while already locked → no-op; onPointerCancel never clears the lock (only reset() or the tap-to-drop); a second finger during a drag is ignored
- **Pre-slop suppression:** moves under kTapSlopPx emit nothing (tap candidate preserved) — the ≤10px pre-slop travel is intentionally dropped, standard trackpad behavior

## Deviations from Plan

None - plan executed exactly as written. (One `// ignore: prefer_initializing_formals` added to the classifier ctor to satisfy `flutter analyze` — same idiom connection_service.dart already uses for injected seams.)

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 04-04 (trackpad screen wiring) has everything it needs: GestureIntent family to switch on, arm/disarm long-press contract, fling/stop-fling seeds for its momentum loop, accelGain for the move path, and sendScroll on the service
- Momentum-loop constants (kMomentumDecay/kMomentumTickMs/kMomentumStopVelocity) and scroll-unit conversion (kScrollUnitPerPx/kScrollDirection) are pre-landed in tuning.dart for the 04-04 driver
- All tuning constants are D-06 starting points — the end-of-phase on-device feel gate adjusts tuning.dart only

## Self-Check: PASSED

- All 5 created files exist on disk
- All 5 task commits verified in git log (834cc58, bd7f049, a9674e0, e69e7f6, e6f368b)
- Full suite green: 175 tests; `flutter analyze`: no issues
- Grep gates: 0 flutter imports in classifier/tuning; shouldSendVolatile ×2; `_sender?.sendScroll` present

---
*Phase: 04-trackpad-keyboard*
*Completed: 2026-07-09*
