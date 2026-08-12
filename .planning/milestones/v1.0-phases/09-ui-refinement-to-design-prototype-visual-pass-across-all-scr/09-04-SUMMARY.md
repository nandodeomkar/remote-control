---
phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
plan: 04
subsystem: ui
tags: [flutter, widget-test, media, browser, riverpod]

# Dependency graph
requires:
  - phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
    provides: 09-UI-SPEC per-screen delta table + locked palette tokens
provides:
  - Media transport/volume-block visual contract pinned by widget tests
  - Browser macro-grid layout + press-flash contract pinned by widget tests
affects: [09-05, 09-06, 09-07, 09-08]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Confirm-don't-rebuild: verify shipped screen values against UI-SPEC, pin with widget tests, apply source delta only on drift"
    - "Pump-screen fake: subclass ConnectionService with a fake DeviceStore + overridden chipStatus/isAuthed/sendReliable, injected via connectionServiceProvider override"

key-files:
  created:
    - app/remote_control/test/media/media_screen_test.dart
  modified:
    - app/remote_control/test/browser/browser_screen_test.dart

key-decisions:
  - "Both MediaScreen and BrowserMacroGrid already matched the 09-UI-SPEC exactly — zero source deltas; the plan closed as pure test-pinning"
  - "Assert transport sizes via getSize on the button SizedBox ancestors (64/48/48) rather than tapping, keeping the test geometry-focused"
  - "Assert Refresh full-width by comparing its rendered Container width against a paired key (Back) rather than asserting tree shape"

patterns-established:
  - "Press-flash test: hold a startGesture (no up) and assert label/border flip to kAccent, then release and assert relax to kText/kHairline"

requirements-completed: []

# Metrics
duration: 12min
completed: 2026-07-16
---

# Phase 9 Plan 04: Media + Browser Visual Confirm Summary

**Pinned the shipped Media transport/volume-block and Browser macro-grid to the 09-UI-SPEC with widget tests (Play/Pause 64 + Prev/Next 48 circles, tabular "--" readout, full-width Refresh, accent press-flash) — both screens already conformed, so no source changed.**

## Performance

- **Duration:** ~12 min
- **Started:** 2026-07-16
- **Completed:** 2026-07-16
- **Tasks:** 2
- **Files modified:** 2 (1 created, 1 strengthened)

## Accomplishments
- New `media_screen_test.dart` pumps `MediaScreen` over a fake service and asserts the three transport icons render, Play/Pause is a 64×64 tappable region while Prev/Next are 48×48, and the pre-snapshot readout is a right-aligned `--` carrying `FontFeature.tabularFigures()`.
- Strengthened `browser_screen_test.dart`: Refresh renders full-width on its own row (unpaired, verified by width comparison), and a held key flashes `kAccent` border + label then relaxes to `kText`/`kHairline` on release. Existing 7-action vocabulary + routing coverage retained.
- Confirmed zero locked-token change — the theme-token guard passes.

## Task Commits

Each task was committed atomically:

1. **Task 1: Confirm Media transport + volume block (new widget test)** - `4f4670c` (test)
2. **Task 2: Confirm Browser 2+2+1+2 macro grid + press-flash** - `c26a003` (test)

## Files Created/Modified
- `app/remote_control/test/media/media_screen_test.dart` - NEW: transport-size (64/48/48) + tabular `--` readout assertions.
- `app/remote_control/test/browser/browser_screen_test.dart` - Added full-width-Refresh + accent press-flash assertions.

## Decisions Made
- Both `MediaScreen` and `BrowserMacroGrid` already matched the spec (transport sizes, mute button, slider theme, readout format; grid rows, 56px height, radius 8, icon+label sizing, press-flash). No source delta was needed — the plan is a confirm, so it closed as pure test-pinning.
- Used `getSize` on the icon's `SizedBox` ancestor for transport geometry and a width comparison (Refresh > 1.5× Back) for the full-width Refresh row, keeping assertions robust against tree-shape refactors.

## Deviations from Plan
None - plan executed exactly as written. No named delta was required; every checked value was already in parity with the 09-UI-SPEC.

## Issues Encountered
- The Media header chip runs a periodic ticker; each `testWidgets` unmounts the tree with `pumpWidget(const SizedBox())` after asserting so no timer is pending at teardown.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Media + Browser rows of the per-screen delta table are confirmed and pinned. Remaining Phase 9 plans (09-05..09-08) cover the other screens.
- `flutter analyze` clean; `flutter test test/media/ test/browser/ test/theme_tokens_guard_test.dart` green (22 tests).

## Self-Check: PASSED

- FOUND: app/remote_control/test/media/media_screen_test.dart
- FOUND: app/remote_control/test/browser/browser_screen_test.dart
- FOUND commit: 4f4670c (Task 1)
- FOUND commit: c26a003 (Task 2)

---
*Phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr*
*Completed: 2026-07-16*
