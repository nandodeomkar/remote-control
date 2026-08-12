---
phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
plan: 03
subsystem: ui
tags: [flutter, keyboard, modifier-chip, key-caps, visual-contract, widget-tests]

# Dependency graph
requires:
  - phase: 04-06
    provides: KeyboardPanel (key_rows, modifier_chip, modifier_fsm) — the shipped keyboard chrome confirmed here
  - phase: 07-13
    provides: KeyboardScreen — the dedicated tool screen whose empty canvas got the hint copy
  - phase: 09-01
    provides: kTrackpadHintColor #4A505C local-const pattern mirrored for the keyboard hint
provides:
  - Keyboard hint copy "The system keyboard handles typing. These are the extra keys." (#4a505c, centered) — the one genuine Keyboard delta closed
  - Pinned Nav/Fn/Num switcher visual contract (accent label + 2px underline vs muted 12/w400) via key_rows_test.dart
  - New modifier_chip_test.dart — 3-state (rest/armed/locked) + disabled visual suite
affects: [09-ui-refinement, keyboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Keyboard hint uses a screen-local non-token const (_kKeyboardHintColor = Color(0xFF4A505C)) mirroring dot_grid's kTrackpadHintColor — outside the seven D-12 locked tokens, so the palette guard stays untripped"
    - "Copy literal hoisted to a named const (kKeyboardHint) per the no-inline-copy house rule (mirrors kKeyboardTitle)"

key-files:
  created:
    - app/remote_control/test/keyboard/modifier_chip_test.dart
  modified:
    - app/remote_control/lib/keyboard/keyboard_screen.dart
    - app/remote_control/test/keyboard/key_rows_test.dart

key-decisions:
  - "Keyboard hint color is a keyboard-screen-local const (not a shared import from trackpad/dot_grid) — keeps the keyboard module free of a cross-module coupling to the trackpad, per the plan's local-const directive"
  - "Switcher, key caps, and modifier chips were already byte-at-spec — this plan closed test-coverage gaps only; no source change to key_rows.dart or modifier_chip.dart"

patterns-established:
  - "Confirm-pass plan: named spec values already matched source, so the delta closed was the missing hint copy plus locking the switcher/chip states behind tests"

requirements-completed: []

# Metrics
duration: 8min
completed: 2026-07-16
---

# Phase 9 Plan 03: Keyboard Visual Pass Summary

**Closed the missing Keyboard hint copy (#4a505c centered above the panel) and pinned the Nav/Fn/Num switcher plus the 3-state modifier-chip contract behind widget tests — zero source change to the already-at-spec key rows and chips, zero locked-token change.**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-07-16
- **Completed:** 2026-07-16
- **Tasks:** 2
- **Files modified:** 3 (1 created, 2 modified)

## Accomplishments
- Added `kKeyboardHint` copy const + a centered 13/w400 `#4a505c` hint widget in the previously-empty `Expanded(SizedBox.expand())` canvas above `KeyboardPanel` — the single genuine Keyboard delta from the 09-UI-SPEC per-screen table.
- Strengthened `key_rows_test.dart`: the switcher renders Nav/Fn/Num, the selected label is `kAccent` with a 2px accent underline, unselected tabs are `kMuted` 12/w400, and each segment meets the 48px touch-target floor.
- New `modifier_chip_test.dart` proving all three chip states (rest = kSurface/kHairline/kText, armed = kSurface fill + accent border/label, locked = accent fill + kBg label + lock glyph) plus the disabled muted state, the 48×48/radius-8 floor, and the 200ms ease transition.

## Task Commits

Each task was committed atomically:

1. **Task 1: Add Keyboard hint copy + pin Nav/Fn/Num switcher states** - `79812be` (feat)
2. **Task 2: Pin 3-state modifier-chip visual contract** - `30a8756` (test)

**Plan metadata:** committed with this SUMMARY (docs: complete plan)

## Files Created/Modified
- `app/remote_control/lib/keyboard/keyboard_screen.dart` - `kKeyboardHint` copy const + `_kKeyboardHintColor` local const + centered hint widget replacing the empty canvas
- `app/remote_control/test/keyboard/key_rows_test.dart` - switcher label/underline/color/48px assertions + tokens import
- `app/remote_control/test/keyboard/modifier_chip_test.dart` - NEW 3-state + disabled chip visual suite

## Decisions Made
- Kept the hint color as a keyboard-screen-local const rather than importing `kTrackpadHintColor` from `trackpad/dot_grid.dart` — the plan explicitly directs a local non-token const, and this avoids coupling the keyboard module to the trackpad module. Both resolve to the same `#4a505c`.
- No source edit to `key_rows.dart` or `modifier_chip.dart`: every named spec value (cap sizes/radii/state colors, chip 3-state mapping, switcher styling) already matched the 09-UI-SPEC. The plan's "confirm or apply small named delta" resolved to confirm across the board.

## Deviations from Plan

None - plan executed exactly as written. The switcher, key caps, and modifier chips were confirmed at-spec (no delta to apply); the only source change was the planned hint copy addition.

## Issues Encountered
None.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Keyboard row of the 09-UI-SPEC per-screen delta table is closed and test-locked. Remaining Phase 9 plans (Media, Apps, Clipboard, Power, Presenter, Browser, Settings) proceed independently.

## Self-Check: PASSED

All created/modified files exist on disk; both task commits (`79812be`, `30a8756`) present in git history. `flutter analyze` clean, `flutter test test/keyboard/ test/theme_tokens_guard_test.dart` green (45 tests).

---
*Phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr*
*Completed: 2026-07-16*
