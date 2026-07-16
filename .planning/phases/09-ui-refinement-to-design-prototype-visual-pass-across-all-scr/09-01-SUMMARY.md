---
phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
plan: 01
subsystem: ui
tags: [flutter, custompainter, trackpad, dot-grid, riverpod]

# Dependency graph
requires:
  - phase: 08-floating-trackpad-bubble
    provides: shared TrackpadCore hot-path engine mounted by both the full screen and the floating window
provides:
  - DotGridPainter leaf CustomPainter + tile/radius/hint consts (dot_grid.dart)
  - dotTile parameter on TrackpadCore (24px full / 22px window)
  - height parameter on MouseButtonsBar (64px full / 56px window)
  - decorative dot-grid texture on both trackpad surfaces + #4a505c hint color
affects: [09-ui-refinement remaining plans, trackpad, floating-window]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Leaf CustomPainter mounted UNDER the raw Listener (no child, no hitTest) = purely decorative, never intercepts pointer events"
    - "Non-token color as a local const (kTrackpadHintColor #4A505C) mirrors connection_header.dart, keeping the D-12 seven-token guard untripped"

key-files:
  created:
    - app/remote_control/lib/trackpad/dot_grid.dart
    - app/remote_control/test/trackpad/dot_grid_test.dart
  modified:
    - app/remote_control/lib/trackpad/trackpad_core.dart
    - app/remote_control/lib/trackpad/floating_trackpad_window.dart
    - app/remote_control/lib/trackpad/mouse_buttons.dart

key-decisions:
  - "Dot layer is a CustomPaint with no child, layered as Stack child[0] under the Listener; the hint Text sits above in IgnorePointer so neither swallows a touch"
  - "MouseButtonsBar per-button minHeight derived from height-16 (64->48 byte-identical to before, 56->40 for the window) rather than a hardcoded 48 — no overflow on the shorter bar"
  - "No fake cursor dot / no tap ripple (locked exclusion, STATE.md 2026-07-16) — proven by asserting exactly one grid painter in the tree"

patterns-established:
  - "Tile-parameterized shared painter serves both 24px and 22px surfaces off one widget"

requirements-completed: []

# Metrics
duration: 6min
completed: 2026-07-16
---

# Phase 9 Plan 01: Dot-Grid Trackpad Texture Summary

**Decorative dot-grid texture (white @ 4.5%, 1.2px dots) on both trackpad surfaces via a leaf DotGridPainter mounted under the Listener — 24px full / 22px window — plus the #4a505c hint color and a 56px window mouse bar, with zero locked-token change.**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-16T03:54:57Z
- **Completed:** 2026-07-16T04:00:50Z
- **Tasks:** 3
- **Files modified:** 5 (2 created, 3 modified)

## Accomplishments
- `DotGridPainter` — a leaf `CustomPainter` that fills `kBg` then draws one 1.2px `rgba(255,255,255,0.045)` dot per tile cell; `shouldRepaint` compares only the `tile` field.
- Both trackpad surfaces render the grid (full 24px, window 22px) as a decorative layer that never intercepts pointer events — a drag still moves and a tap still left-clicks (proven).
- Trackpad hint text now renders in the UI-SPEC `#4a505c` hue (via `kTrackpadHintColor`) instead of `kMuted`; fake cursor dot and tap ripple confirmed absent.
- Floating-window mouse bar dropped to 56px; full-trackpad bar unchanged at 64px (per-button floor derived from `height-16`, no RenderFlex overflow).
- Zero locked-palette change — the D-12 theme-token guard still passes.

## Task Commits

Each task was committed atomically:

1. **Task 1: DotGridPainter + consts (TDD)** — `5b8d87e` (test, RED) → `5bee5be` (feat, GREEN)
2. **Task 2: Wire dot-grid + hint + 56px window bar** — `9f64b2d` (feat)
3. **Task 3: Prove presence / per-surface tile / non-interactivity** — `47eb219` (test)

**Plan metadata:** _(this commit)_

## Files Created/Modified
- `app/remote_control/lib/trackpad/dot_grid.dart` — `DotGridPainter` + `kTrackpadDotTileFull/Window`, `kTrackpadDotRadius`, `kTrackpadHintColor`.
- `app/remote_control/test/trackpad/dot_grid_test.dart` — const contract + per-surface tile + non-interactivity + hint-color suite (7 tests).
- `app/remote_control/lib/trackpad/trackpad_core.dart` — new `dotTile` field; build tree layers the painter under the Listener with the hint above in `kTrackpadHintColor`; dropped the now-unused `tokens.dart` import.
- `app/remote_control/lib/trackpad/floating_trackpad_window.dart` — passes `dotTile: 22` and `height: 56`.
- `app/remote_control/lib/trackpad/mouse_buttons.dart` — new `height` field (default 64); per-button `minHeight = height - 16`.

## Decisions Made
- Layered the grid as `Stack` child[0] (`CustomPaint`, no child) with the hint in `IgnorePointer` above — the opaque `Listener` still receives every pointer event, so decoration cannot swallow input.
- Derived the mouse-button touch floor from the bar height (`height-16`) so the 64px bar stays byte-identical (48px) while the 56px window bar renders ~40px buttons without overflow.
- Kept `kTrackpadHintColor` (`#4A505C`) as a local const in `dot_grid.dart` — a non-token hue, so the seven-literal D-12 guard is not tripped.

## Deviations from Plan

None — plan executed exactly as written. One incidental cleanup within Task 2 scope: removed the `../theme/tokens.dart` import from `trackpad_core.dart` after the flat `Container(color: kBg …)`/`kMuted` hint was replaced (both token symbols became unused), keeping `flutter analyze` clean. This is inside the task's named file set, not a new deviation.

## Issues Encountered
None.

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- The headline dot-grid delta is shipped and unit/widget-proven; remaining Phase 09 plans are per-screen confirm/refine passes.
- On-device visual parity is deferred to the phase UAT gate (09-08) per the plan's verification note.

## Self-Check: PASSED

- FOUND: app/remote_control/lib/trackpad/dot_grid.dart
- FOUND: app/remote_control/test/trackpad/dot_grid_test.dart
- FOUND commits: 5b8d87e, 5bee5be, 9f64b2d, 47eb219
- Verification: `flutter analyze` clean; `flutter test test/trackpad/ test/floating_trackpad_window_test.dart test/theme_tokens_guard_test.dart` = 70 passed.

---
*Phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr*
*Completed: 2026-07-16*
