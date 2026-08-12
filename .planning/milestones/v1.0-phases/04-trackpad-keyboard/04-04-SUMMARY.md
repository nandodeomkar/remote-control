---
phase: 04-trackpad-keyboard
plan: 04
subsystem: ui
tags: [flutter, riverpod, shared-preferences, gestures, trackpad, haptics]

# Dependency graph
requires:
  - phase: 04-01
    provides: absolute pointer injection + real move/scroll executors the intents land on
  - phase: 04-02
    provides: real click/drag/key Windows executors (enigo SendInput) behind the dispatch gates
  - phase: 04-03
    provides: GestureClassifier pure FSM + GestureIntent family + accelGain curve + tuning.dart constants
  - phase: 03-05/03-07
    provides: ConnectionService sendMove/sendScroll/sendReliable, chipStatus/changes, header chip + banner chrome
provides:
  - TrackpadDriver intent executor (momentum loop, long-press timer, drag-lock state — all seam-injected, generation-guarded)
  - Live trackpad surface routing Listener pointer events through classifier -> driver -> service (PAD-01..04 end-to-end)
  - MouseButtonsBar L/M/R 64px bar (PAD-02) with gated muted state
  - Drag-lock pill on a localized ValueNotifier (PAD-04)
  - SensitivityStore + Riverpod 3 sensitivityProvider persisting `pointer.sensitivity` (D-05) + tune bottom sheet
affects: [04-05, 04-06, 07-settings, trackpad, keyboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Intent-executor driver with injected seams (callbacks + schedule + sensitivity getter) — widget-free, fully unit-testable"
    - "Generation-counter timer invalidation (no-cancel schedule seam), copied from ConnectionService._backoffGen"
    - "Cached-double provider bridge: ref.listenManual(fireImmediately) updates a plain field; hot path reads the field, never the provider"
    - "Chrome on localized listenables: ValueNotifier + ValueListenableBuilder for the drag-lock pill (zero Listener-subtree rebuilds)"

key-files:
  created:
    - app/remote_control/lib/trackpad/trackpad_driver.dart
    - app/remote_control/lib/trackpad/mouse_buttons.dart
    - app/remote_control/lib/settings/sensitivity.dart
    - app/remote_control/test/trackpad/trackpad_driver_test.dart
    - app/remote_control/test/trackpad/mouse_buttons_test.dart
  modified:
    - app/remote_control/lib/trackpad/trackpad_screen.dart

key-decisions:
  - "Long-press timer round-trips through the classifier: onLongPressElapsed calls classifier.onLongPressFire() and feeds the verdict back through driver.handle — stale fires are classifier no-ops, the driver never guesses"
  - "Sensitivity cache uses ref.listenManual(fireImmediately: true) in initState — no widget rebuild on slider change, subscription closes with the element"
  - "SensitivityStore degrades to kSensitivityDefault on any platform read failure and clamps every read/write to the tuning.dart slider bounds — a corrupt pref can never produce a wild gain"
  - "Tune sheet is a modal route with a Consumer-scoped Slider — provider watch lives inside the sheet, outside the Listener subtree, so tuning never rebuilds the hot path"

patterns-established:
  - "Settings live in lib/settings/ as small typed stores over injectable SharedPreferencesAsync + a thin Riverpod 3 Notifier (device_store house pattern, double-typed)"
  - "UI-SPEC panel-toggle pattern reified: circular 48px #16181D/#2A2D34 Material+InkWell affordance, neutral at rest"

requirements-completed: [PAD-01, PAD-02, PAD-03, PAD-04]

# Metrics
duration: ~25min (2 sessions)
completed: 2026-07-09
---

# Phase 4 Plan 04: Live Trackpad Gesture Surface Summary

**Full PAD-01..04 trackpad wired end-to-end: TrackpadDriver executes classifier intents (accel-scaled moves, tap/two-finger-tap clicks, momentum scroll with instant touch-stop, drag-lock with pill), L/M/R button bar, and a persisted D-05 sensitivity slider — hot path still setState-free.**

## Performance

- **Duration:** ~25 min across 2 executor sessions (session cut after Task 2; resumed for Task 3)
- **Started:** 2026-07-09T19:30Z (approx, first session)
- **Completed:** 2026-07-09T19:57Z
- **Tasks:** 3 (Task 1 TDD: RED + GREEN commits)
- **Files modified:** 6

## Accomplishments

- `TrackpadDriver` (Task 1, TDD): a widget-free intent executor with every seam injected — send callbacks, haptics, drag-lock notifier, sensitivity getter, and a `schedule` timer seam. Momentum loop decays by `kMomentumDecay` per `kMomentumTickMs` tick and stops below `kMomentumStopVelocity`; `StopFlingIntent` cancels instantly via generation counters (same idiom as `ConnectionService._backoffGen`); long-press is a generation-guarded one-shot that fires back INTO the classifier; `reset()`/`dispose()` guarantee no callback fires after teardown.
- Trackpad screen grown into the live gesture surface (Task 2): `Listener` routes `onPointerDown/Move/Up/Cancel` through `GestureClassifier` into the driver with zero `setState`; drag-lock pill rides its own `ValueNotifier` (localized rebuild); `MouseButtonsBar` docked beneath (L flex2 / M flex1 / R flex2, gated muted when unauthed); disconnect transition calls `driver.reset()` so no stale drag pill or momentum survives a drop (client half of the no-phantom-input rule; server half is CONN-07).
- D-05 sensitivity (Task 3): `SensitivityStore` persists the `pointer.sensitivity` double via `SharedPreferencesAsync` (clamped, degrade-to-default reads); `sensitivityProvider` is a Riverpod 3 unified `Notifier` loading on build and persisting on `set()`; the screen caches the double via `ref.listenManual(fireImmediately: true)` so the driver's gain reads a plain field — never a provider lookup per pointer event; a 48px circular tune affordance (UI-SPEC panel-toggle pattern, `Icons.tune`, tooltip "Pointer speed") opens a modal bottom sheet with a Slider bound `kSensitivityMin..kSensitivityMax`, applying live and persisting immediately.

## Task Commits

Each task was committed atomically:

1. **Task 1: TrackpadDriver (RED)** - `ba1aaa3` (test)
2. **Task 1: TrackpadDriver (GREEN)** - `2d50d9c` (feat)
3. **Task 2: Gesture surface — classifier routing, L/M/R bar, drag-lock pill** - `c69eabc` (feat)
4. **Task 3: Sensitivity — store, provider, tune sheet (D-05)** - `7c00e10` (feat)

_Note: Task 1 was tdd="true" — no refactor commit was needed (GREEN implementation was already clean)._

## Files Created/Modified

- `app/remote_control/lib/trackpad/trackpad_driver.dart` - Intent executor: sends, momentum loop, long-press one-shot, drag-lock state (all seam-injected)
- `app/remote_control/lib/trackpad/mouse_buttons.dart` - `MouseButtonsBar` 64px L/M/R bar per UI-SPEC, callback-injected + gated
- `app/remote_control/lib/settings/sensitivity.dart` - `SensitivityStore` + `SensitivityNotifier`/`sensitivityProvider`, prefs key `pointer.sensitivity`
- `app/remote_control/lib/trackpad/trackpad_screen.dart` - Classifier-fed Listener surface, drag-lock pill, tune affordance + sheet, disconnect hygiene
- `app/remote_control/test/trackpad/trackpad_driver_test.dart` - Deterministic driver suite (fake schedule seam, zero real Timers)
- `app/remote_control/test/trackpad/mouse_buttons_test.dart` - Widget test: L/M/R taps record 'left'/'middle'/'right'; disabled bar records nothing

## Decisions Made

- Long-press verdicts round-trip through the classifier (`onLongPressElapsed -> classifier.onLongPressFire() -> driver.handle`) so drag-start vs stale-fire logic stays in the pure FSM.
- Sensitivity cache bridged with `ref.listenManual(fireImmediately: true)` in `initState` — updates the plain `_sensitivity` field without any widget rebuild; the driver getter closes over the field.
- `SensitivityStore` clamps on BOTH read and write and swallows platform read failures to `kSensitivityDefault` — trackpad feel is never hostage to a broken prefs read.
- Tune sheet Slider watch is scoped to a `Consumer` inside the modal route — opening/dragging the slider rebuilds only the sheet, never the trackpad surface or header chip.

## Deviations from Plan

None - plan executed exactly as written. (Task 3 required `.toDouble()` on `num.clamp` results for Dart typing — an implementation detail, not a plan deviation.)

## Issues Encountered

- Executor session was cut off after Task 2; a continuation session verified commits `ba1aaa3`/`2d50d9c`/`c69eabc`, executed Task 3 only, and closed out the plan. No rework required.

## Verification Gates (all green)

- `flutter test` — 197 tests pass (driver, mouse-buttons, and all prior suites).
- `flutter analyze` — no issues.
- Hot-path grep gate — `setState` count in non-comment `trackpad_screen.dart` lines: **0**.
- Persisted key literal `pointer.sensitivity` present; `sensitivityProvider` is a Riverpod 3 `NotifierProvider` (no legacy StateNotifier); Slider bounds are `kSensitivityMin`/`kSensitivityMax` from tuning.dart; gain reads the cached double updated by a provider listener.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Trackpad vertical slice COMPLETE: the phone is a full daily mouse (PAD-01..04 user-operable against the 04-01/04-02 real executors). Keyboard slices (04-05 hidden-IME text + panel, 04-06 special keys/modifiers) are next; the tune affordance placement leaves the bottom-right slot shared with 04-05's keyboard panel toggle (stack/offset when it lands).
- End-of-phase on-device feel gate (04-VALIDATION Manual-Only) still pending: full gesture set vs the Remote Mouse benchmark; tuning.dart constants are on-device starting points (D-06).

## Self-Check: PASSED

All 6 claimed files exist on disk; all 4 task commits (`ba1aaa3`, `2d50d9c`, `c69eabc`, `7c00e10`) verified in git log.
