---
phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
plan: 04
subsystem: ui
tags: [flutter, riverpod, trackpad, floating-window, gesture, drag-clamp]

# Dependency graph
requires:
  - phase: 08-01
    provides: windowPositionProvider / WindowPosition (unset sentinel), clamped [0,1] persistence
  - phase: 08-02
    provides: TrackpadCore shared hot-path engine + ValueListenable<bool> dragLocked, MouseButtonsBar
provides:
  - "FloatingTrackpadWindow — the D8-03 expanded-state card (header + shared TrackpadCore + reused MouseButtonsBar) with header-only drag that clamps fully on-screen and commits (x,y) fractions to windowPositionProvider"
  - "kWindowWidthFraction (0.78) / kWindowHeightFraction (0.38) card-size constants"
  - "Test seams: injectable dragLock notifier + keepAwake spy; kWindowCardKey / kWindowDragLockPillKey for widget assertions"
affects:
  - "08-05 (BubbleScaffold mounts FloatingTrackpadWindow in the expanded branch, wiring onExpandFull/onCollapse/onMouseButton + initialTopLeft)"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Header-only window drag: a GestureDetector on the ⠿ handle that is a spatially-disjoint SIBLING of the TrackpadCore Listener (surface touches never move the window — Pitfall 2)"
    - "On-screen clamp: offset bounded to [0, screen − card] on both axes; committed fractions clamped [0,1] so a tampered store can never place the card off-screen (T-08-06)"
    - "Self-positioning widget: returns a single Positioned (left/top) for direct placement inside the scaffold Stack"

key-files:
  created:
    - app/remote_control/lib/trackpad/floating_trackpad_window.dart
    - app/remote_control/test/floating_trackpad_window_test.dart
  modified: []

key-decisions:
  - "FloatingTrackpadWindow returns a single Positioned (left/top/width/height) so the 08-05 scaffold drops it straight into its Stack; the card size is derived from MediaQuery.sizeOf via kWindowWidthFraction/kWindowHeightFraction"
  - "The window OWNS its drag-lock ValueNotifier (passed into TrackpadCore, read by the header pill) unless a test injects one — mirroring the TrackpadScreen 'parent owns and disposes' idiom; keepAwake stays a forwarded-only seam (TrackpadCore is the sole hold owner, Pitfall 4)"
  - "First-open anchor: unset store → initialTopLeft (bubble spot, clamped) if given, else screen-center; after any move it commits real fractions"
  - "Compact header pill ('Drag locked' + lock glyph) wrapped in FittedBox(scaleDown) so the inline pill can never overflow the narrow header row"

requirements-completed: [PAD-01, PAD-02, PAD-03, PAD-04, PAD-05]

# Metrics
duration: ~10min
completed: 2026-07-15
---

# Phase 8 Plan 04: FloatingTrackpadWindow Summary

**The D8-03 expanded-state floating trackpad card: a fixed ~78%w × ~38%h `kSurface` card with a header-only drag that clamps fully on-screen, the shared `TrackpadCore` gesture surface (cursor parity by construction), and a reused `MouseButtonsBar`.**

## What Was Built

- **`lib/trackpad/floating_trackpad_window.dart`** — `FloatingTrackpadWindow` (a `ConsumerStatefulWidget`) rendering a single `Positioned` card with three stacked rows:
  1. **Header bar** — a `⠿` `Icons.drag_indicator` handle wrapped in its OWN `GestureDetector` (a spatially-disjoint SIBLING of the core `Listener`, never an ancestor — RESEARCH Pitfall 2), an inline drag-lock pill (`ValueListenableBuilder` over the drag-lock notifier, visible only while locked), a `⤢` `Icons.open_in_full` button firing `onExpandFull`, and a `✕` `Icons.close` button firing `onCollapse`.
  2. **Gesture surface** — `Expanded(child: TrackpadCore(authed, dragLock, keepAwake))` — the SAME engine the full screen mounts, so cursor input is behavior-identical by construction (SC2, D8-04).
  3. **`MouseButtonsBar`** reused as-is, `enabled: authed` (muted-not-red).
  Card chrome: `kSurface` fill, 1px `kHairline` border, 16px radius, drop shadow, `ClipRRect` content. Constants `kWindowWidthFraction = 0.78` / `kWindowHeightFraction = 0.38` size the card from `MediaQuery.sizeOf`.
- **`test/floating_trackpad_window_test.dart`** — 6 widget cases: header-drag moves the card offset; header-drag far past an edge commits fractions within `[0,1]`; a surface pan does NOT move the window; `⤢`/`✕` fire their callbacks; the inline pill is hidden by default and shown when the injected drag-lock listenable is true; and the 360×640 no-overflow A2 guard.

## How It Works

The window is draggable by its header only. The `⠿` handle's `GestureDetector.onPanUpdate` moves a live `_offset`, clamped to `[0, screen − card]` on both axes so the FULL card always stays visible; `onPanEnd` converts that offset to `(x, y)` fractions (guarded against a zero range) and commits `WindowPosition.at(fx, fy)` to `windowPositionProvider`. Because the offset is clamped and the fractions are clamped `[0,1]`, a tampered/out-of-range stored value can never render the window off-screen (T-08-06 / SC3). Touches on the `TrackpadCore` surface are pure mouse input — the header detector and the core's opaque `Listener` are disjoint siblings in the `Column`, so a surface pan never reaches the header and never moves the window. At rest the card resolves its top-left from the stored fractions when set, else the `initialTopLeft` anchor (the bubble spot, clamped) or the screen center on first-ever open.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added the `window_position.dart` import to the test**
- **Found during:** Task 2 (first GREEN run).
- **Issue:** The Task-1 test referenced `windowPositionProvider` (to assert the committed clamp) without importing its library, failing compilation.
- **Fix:** Added `import 'package:remote_control/settings/window_position.dart';` to the test.
- **Files modified:** app/remote_control/test/floating_trackpad_window_test.dart
- **Verification:** `flutter test test/floating_trackpad_window_test.dart` → 6/6 green.
- **Committed in:** `8e86313` (Task 2 commit).

Two analyzer lint nits (unnecessary `foundation` import in the widget, unused `shared_preferences` import in the test) were removed in the same commit — `flutter analyze` on both files then reported **No issues found**.

**Total deviations:** 1 blocking auto-fix (a missing test import) + 2 trivial lint cleanups. No scope creep.

## Verification

- `flutter test test/floating_trackpad_window_test.dart` → **6/6 green**, including the 360×640 no-overflow A2 guard.
- `flutter analyze lib/trackpad/floating_trackpad_window.dart test/floating_trackpad_window_test.dart` → **No issues found**.
- All six `must_haves.truths` proven: fixed-fraction card chrome, three-row order, header-only drag (surface-is-mouse), TrackpadCore cursor parity, header-button callbacks + drag-lock pill, and clamped fraction commit with no 360×640 overflow.
- Manual device UAT (header/surface/bar fit + edge clamp) is the end-of-phase A2 gate, unchanged.

## Threat Surface

- **T-08-06 (mitigate):** drag clamps the full card on-screen and commits clamped `[0,1]` fractions; the 08-01 store degrades corrupt reads to the unset sentinel — the window can never render off-screen. Covered by the "far past an edge → fractions within [0,1]" test.
- **T-08-03 (mitigate, inherited):** the CR-01 dispose flush lives in the shared `TrackpadCore` (08-02) and fires on collapse; this plan adds no new input path.
- No package installs (T-08-SC accept) — first-party gestures + reused `TrackpadCore`/`MouseButtonsBar` only.

No new security-relevant surface beyond the plan's threat model.

## Known Stubs

None — the widget is fully wired to `TrackpadCore`, `MouseButtonsBar`, and `windowPositionProvider`. It has no mounted caller yet (that is 08-05's `BubbleScaffold` expanded branch), which is the intended leaf-first Wave-2 sequencing, not a stub.

## Commits

- `a607ee5` test(08-04): add failing FloatingTrackpadWindow safety net
- `8e86313` feat(08-04): implement FloatingTrackpadWindow card

## Self-Check: PASSED

- FOUND: app/remote_control/lib/trackpad/floating_trackpad_window.dart
- FOUND: app/remote_control/test/floating_trackpad_window_test.dart
- FOUND commits: a607ee5, 8e86313
