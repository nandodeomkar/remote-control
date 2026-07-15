---
phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
plan: 02
subsystem: ui
tags: [flutter, riverpod, trackpad, gesture, widget-extraction, keep-awake]

# Dependency graph
requires:
  - phase: 04-trackpad
    provides: GestureClassifier (pure FSM) + TrackpadDriver (intent executor) + the D-04 hot-path split
  - phase: 07
    provides: KeepAwake ref-counted singleton (D-14), scroll_direction hot-path cache (D-11)
provides:
  - "TrackpadCore — a reusable, zero-setState hot-path engine widget (pointer route + sensitivity/scroll caches + disconnect hygiene + keepAwake hold + CR-01 dispose flush) that both the full screen and the 08-04 floating window mount"
  - "A slimmed TrackpadScreen that is a thin composition of TrackpadCore + retained chrome (pill, tune, keyboard panel, MouseButtonsBar, header chip)"
  - "Safety-net tests: trackpad_core_test.dart (pointer route, CR-01 4-quadrant, keepAwake count) + trackpad_screen_test.dart (composition smoke)"
affects: [08-04-floating-trackpad-window, 08-05-bubble-scaffold]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Hot-path engine extraction: a ConsumerStatefulWidget owning the pointer route + all its seams, mounted identically by multiple surfaces (cursor parity by construction)"
    - "Parent-owned ValueNotifier handle: the core drives drag-lock via an injected notifier and exposes it as ValueListenable<bool> dragLocked — both surfaces' pills read one source"

key-files:
  created:
    - app/remote_control/lib/trackpad/trackpad_core.dart
    - app/remote_control/test/trackpad/trackpad_core_test.dart
    - app/remote_control/test/trackpad/trackpad_screen_test.dart
  modified:
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/test/keep_awake_test.dart

key-decisions:
  - "Drag-lock is surfaced via a parent-owned ValueNotifier passed into TrackpadCore (the D8-04 'injected ValueNotifier' discretion option) and re-exposed as ValueListenable<bool> dragLocked — no GlobalKey needed for the full screen; the window can read the getter via key"
  - "TrackpadScreen keeps its _service read for CHROME only (mouse-button clicks, IME diffs, keyboard panel, header chip, banner retry); the hot-path service read now lives solely inside TrackpadCore"
  - "TrackpadCore returns a bare Listener surface (not a Positioned) so it composes in a Stack (screen) or a Column child (window); the parent handles positioning"

patterns-established:
  - "TrackpadCore is the single owner of the pointer route, sensitivity/scroll caches, disconnect hygiene, keepAwake hold, and the CR-01 dispose flush"

requirements-completed: [PAD-01, PAD-02, PAD-03, PAD-04, PAD-05, CONN-07]

# Metrics
duration: 22min
completed: 2026-07-15
---

# Phase 8 Plan 02: Extract TrackpadCore Summary

**Behavior-neutral extraction of the trackpad hot-path engine into a reusable `TrackpadCore` widget (zero-setState pointer route + keepAwake + CR-01 dispose flush), leaving `TrackpadScreen` a thin composition of core + chrome.**

## Performance

- **Duration:** ~22 min
- **Started:** 2026-07-15T13:48Z
- **Completed:** 2026-07-15T14:10Z
- **Tasks:** 3
- **Files modified:** 5 (3 created, 2 modified)

## Accomplishments
- Authored the Wave-0 safety net FIRST (composition smoke + core RED net + keep-awake window-excursion case) so the relocation is provably behavior-neutral.
- Created `TrackpadCore`: the D8-04 hot-path engine owning the classifier/driver, the D-05 sensitivity cache, the D-11 scroll cache binding, the disconnect-hygiene subscription, the sole D-14 keepAwake hold, and the CR-01 dispose flush — with the ZERO-setState pointer route preserved verbatim.
- Slimmed `_TrackpadScreenState` to a thin composition mounting `TrackpadCore` under its retained chrome; the drag-lock pill now reads the shared handle the core drives.
- Full suite green (385 tests) and `flutter analyze` clean — the four primitive gesture tests passed UNMODIFIED (behavior-neutrality proven).

## Task Commits

1. **Task 1: Author the extraction safety net (tests first)** — `bae70c9` (test)
2. **Task 2: Create TrackpadCore by relocating the hot path verbatim** — `6205475` (feat)
3. **Task 3: Slim TrackpadScreen to TrackpadCore + chrome** — `9321fb3` (refactor)

## Files Created/Modified
- `app/remote_control/lib/trackpad/trackpad_core.dart` — the extracted hot-path engine widget; exposes `ValueListenable<bool> dragLocked`.
- `app/remote_control/lib/trackpad/trackpad_screen.dart` — slimmed to a thin composition of `TrackpadCore` + chrome.
- `app/remote_control/test/trackpad/trackpad_core_test.dart` — pointer-route, CR-01 4-quadrant, keepAwake-count net.
- `app/remote_control/test/trackpad/trackpad_screen_test.dart` — composition smoke (new; none existed — RESEARCH Pitfall 7).
- `app/remote_control/test/keep_awake_test.dart` — extended with the window-excursion / Presenter-survival case.

## Decisions Made
- **Injected ValueNotifier for drag-lock** (D8-04 discretion): the parent owns and disposes the notifier; the core drives it and re-exposes it via `dragLocked`. Clean for the full screen (no GlobalKey), and the window can read the getter via a key.
- **Screen keeps `_service` for chrome only**: the hot-path service read is now solely in the core; the screen still needs the service for clicks/IME/panel/header/banner.
- **Core returns a bare `Listener`** (parent positions it), so it drops into a `Positioned.fill` (screen) or a Column child (window).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added explicit `package:flutter/foundation.dart` import**
- **Found during:** Task 2 (TrackpadCore creation)
- **Issue:** `ValueListenable` was not in scope via the `material.dart` re-export, failing compilation of the `dragLocked` getter.
- **Fix:** Added `import 'package:flutter/foundation.dart';` (necessary — `unnecessary_import` does not fire since the symbol is not otherwise available).
- **Files modified:** app/remote_control/lib/trackpad/trackpad_core.dart
- **Verification:** `flutter test test/trackpad/trackpad_core_test.dart` green; `flutter analyze` clean.
- **Committed in:** `6205475` (Task 2 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Trivial missing-import fix required to compile. No scope creep.

## Issues Encountered
- The full `TrackpadScreen` smoke test mounts the global `keepAwake` singleton (→ `WakelockPlus`) and the header chip's `Timer.periodic`. Resolved by stubbing the wakelock platform via `wakelockPlusPlatformInstance` in `setUpAll` and disposing the tree (`pumpWidget(SizedBox())`) at the end of the test. The core tests inject a spy `KeepAwake`, avoiding the platform entirely.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `TrackpadCore` is ready to be mounted by 08-04's `FloatingTrackpadWindow` (same engine → cursor parity by construction) and its `dragLocked` listenable feeds the window's inline pill.
- The screen's keyboard/tune/IME concerns remain screen-only (the window does NOT get keyboard/tune — Deferred per plan).

---
*Phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu*
*Completed: 2026-07-15*

## Self-Check: PASSED
- FOUND: app/remote_control/lib/trackpad/trackpad_core.dart
- FOUND: app/remote_control/test/trackpad/trackpad_core_test.dart
- FOUND: app/remote_control/test/trackpad/trackpad_screen_test.dart
- FOUND commits: bae70c9 (test), 6205475 (feat), 9321fb3 (refactor)
