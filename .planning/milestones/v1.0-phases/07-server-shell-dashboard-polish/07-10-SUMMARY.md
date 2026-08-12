---
phase: 07-server-shell-dashboard-polish
plan: 10
subsystem: ui
tags: [flutter, theme, tokens, haptics, wakelock, riverpod, UI-02]

# Dependency graph
requires:
  - phase: 07-server-shell-dashboard-polish
    provides: "07-09's theme/tokens.dart (kBg/kSurface/kHairline/kText/kMuted/kAccent/kError + buildAppTheme()), settings/haptics.dart (hapticTick/hapticTickMedium/bindHapticsCache), and widgets/keep_awake.dart (ref-counted keepAwake singleton) — this plan is the migration wave that wires every screen onto them"
provides:
  - "Every screen (+ modifier_chip/key_rows/mouse_buttons/pairing_dialog/the beacon-smoke dev tool) imports theme/tokens.dart instead of declaring or inlining its own palette consts — single D-12 source of truth, locked by a grep-guard test"
  - "main.dart uses buildAppTheme() instead of an inline ThemeData"
  - "All ~19 HapticFeedback.lightImpact()/mediumImpact() call sites route through hapticTick()/hapticTickMedium(); main.dart installs bindHapticsCache(ref) once at app start"
  - "Trackpad and Presenter keep-awake through the shared keepAwake ref-counted singleton instead of raw WakelockPlus calls — closes the Pitfall-8 quick-bar leak before the quick-bar (07-11) exists"
  - "test/theme_tokens_guard_test.dart — whole-lib scan blocking any future re-introduction of a locked palette hex literal outside tokens.dart"
affects:
  - "07-11/07-12/07-13 (dashboard, quick-bar, settings screen) build on a codebase where every screen already shares one token/haptics/keep-awake source — no new screen should reintroduce local palette consts or raw HapticFeedback/WakelockPlus calls"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Grep-guard regression test: a whole-lib-tree scan (excluding doc-comment lines) that fails the moment a locked design-system literal is copy-pasted outside its single source file"
    - "Hot-path haptics gate installed exactly once at the app root (main.dart initState) via bindHapticsCache(ref), mirroring the trackpad's D-05 sensitivity-cache seam"
    - "Ref-counted platform-flag wrapper (keepAwake) shared by every screen that needs the wakelock, replacing per-screen enable()/disable() pairs that assumed exclusive ownership"

key-files:
  created:
    - app/remote_control/test/theme_tokens_guard_test.dart
  modified:
    - app/remote_control/lib/main.dart
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/lib/trackpad/mouse_buttons.dart
    - app/remote_control/lib/presenter/presenter_screen.dart
    - app/remote_control/lib/media/media_screen.dart
    - app/remote_control/lib/apps/apps_screen.dart
    - app/remote_control/lib/clipboard/clipboard_screen.dart
    - app/remote_control/lib/browser/browser_screen.dart
    - app/remote_control/lib/power/power_screen.dart
    - app/remote_control/lib/keyboard/keyboard_panel.dart
    - app/remote_control/lib/keyboard/key_rows.dart
    - app/remote_control/lib/keyboard/modifier_chip.dart
    - app/remote_control/lib/screens/device_list_screen.dart
    - app/remote_control/lib/screens/pairing_dialog.dart
    - app/remote_control/lib/widgets/connection_header.dart
    - app/remote_control/lib/dev/beacon_smoke_main.dart

key-decisions:
  - "The grep-guard test scans the WHOLE lib/ tree (not just the 12 screens literally named in the plan's files_modified list) because the plan's own acceptance criteria demands `grep -rn '0xFF16181D' lib` return ONLY tokens.dart — a narrower scan would pass the letter of the file list but fail the stated acceptance check"
  - "Migrating the whole tree surfaced 5 additional palette-literal offenders the plan didn't name (key_rows.dart, modifier_chip.dart, pairing_dialog.dart, mouse_buttons.dart, dev/beacon_smoke_main.dart) — auto-fixed under Rule 2 (the D-12 truth statement requires zero locked literals outside tokens.dart, not a partial migration)"
  - "connection_header.dart keeps two local Color consts (_reconnectingColor #E8A33D, _chipFill translucent #CC0E0F12) — neither is one of the seven D-12 locked tokens, so they are intentionally NOT migrated (the guard test only forbids the LOCKED literal set)"
  - "power_screen.dart's local _destructive alias is fully replaced by kError (not kept as a local alias) — every screen deletes its local block per the plan's literal instruction, not just re-points it at a token"
  - "Removed now-unnecessary `package:flutter/services.dart` imports from 7 files after routing haptics through the settings/haptics.dart helper — material.dart already re-exports the symbols still used (e.g. FontFeature), and flutter analyze flagged the redundant imports"

patterns-established:
  - "Whole-tree grep-guard as the D-12 regression backstop — future palette work is caught immediately by `flutter test test/theme_tokens_guard_test.dart`"

requirements-completed: [UI-02]

# Metrics
duration: ~30min
completed: 2026-07-12
---

# Phase 7 Plan 10: UI-02 Screen Migration onto Palette/Haptics/Keep-Awake Primitives Summary

**Every screen in the app (17 files touched) now imports the single `theme/tokens.dart` palette source, routes all ~19 haptic call sites through the cached `hapticTick()`/`hapticTickMedium()` gate, and shares one ref-counted `keepAwake` wakelock — locked in by a new whole-lib grep-guard test.**

## Performance

- **Duration:** ~30 min
- **Tasks:** 2/2
- **Files modified:** 17 (12 named in the plan + 5 additional palette offenders found by the grep-guard test)
- **Files created:** 1 (`test/theme_tokens_guard_test.dart`)
- **Tests:** 327 passed (full `flutter test` suite, including the new guard test)
- **Analyze:** `flutter analyze lib` clean, 0 issues

## Accomplishments
- Deleted every per-screen `const Color _bg/_surface/_hairline/_text/_muted/_accent` block (and the trackpad screen's dozens of inline `Color(0xFF...)` literals) in favor of `theme/tokens.dart` imports — `main.dart` now calls `buildAppTheme()`.
- Added a whole-lib grep-guard test that fails if any of the seven locked palette hex literals ever reappears outside `tokens.dart`, with doc-comment lines exempted.
- Rerouted all ~19 `HapticFeedback.lightImpact()`/`.mediumImpact()` call sites (direct calls and injected callbacks) through `hapticTick()`/`hapticTickMedium()`; installed `bindHapticsCache(ref)` once in `main.dart`'s `initState` so the cache is primed before the first tap.
- Rerouted Trackpad's and Presenter's keep-awake through the shared `keepAwake` ref-counted singleton instead of raw `WakelockPlus.enable()/disable()`, closing the Pitfall-8 leak that the future quick-bar (`Presenter -> Trackpad -> back`) would otherwise trigger.

## Task Commits

1. **Task 1: Palette consolidation across all screens + buildAppTheme() + grep-guard test** - `86748fc` (feat)
2. **Task 2: Route all haptic call sites through the gated helper + keep-awake ref-count** - `0aef4e8` (feat)

## Files Created/Modified
- `app/remote_control/test/theme_tokens_guard_test.dart` - New whole-lib D-12 regression guard
- `app/remote_control/lib/main.dart` - `buildAppTheme()` + `bindHapticsCache(ref)` install
- `app/remote_control/lib/hub/hub_screen.dart`, `trackpad/trackpad_screen.dart`, `trackpad/mouse_buttons.dart`, `presenter/presenter_screen.dart`, `media/media_screen.dart`, `apps/apps_screen.dart`, `clipboard/clipboard_screen.dart`, `browser/browser_screen.dart`, `power/power_screen.dart`, `keyboard/keyboard_panel.dart`, `keyboard/key_rows.dart`, `keyboard/modifier_chip.dart`, `screens/device_list_screen.dart`, `screens/pairing_dialog.dart`, `widgets/connection_header.dart`, `dev/beacon_smoke_main.dart` - palette migration; trackpad/presenter/keyboard_panel also migrated haptics + (trackpad/presenter) keep-awake

## Decisions Made
See `key-decisions` in frontmatter — summarized: (1) grep-guard scans the whole `lib/` tree per the plan's own acceptance criteria, not just the named file list; (2) 5 additional non-listed files with palette literals were migrated under Rule 2 since the D-12 truth statement is "no screen declares its own palette consts" full stop; (3) `connection_header.dart`'s two non-locked colors intentionally stay local; (4) redundant `flutter/services.dart` imports removed where `material.dart` already re-exports the remaining used symbols.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Migrated 5 palette-literal offenders not named in the plan's file list**
- **Found during:** Task 1 verification (`flutter test test/theme_tokens_guard_test.dart` failed on first run)
- **Issue:** The plan's `files_modified` list named 12 screen files, but `lib/keyboard/key_rows.dart`, `lib/keyboard/modifier_chip.dart`, `lib/screens/pairing_dialog.dart`, `lib/trackpad/mouse_buttons.dart`, and `lib/dev/beacon_smoke_main.dart` also declared local copies of the locked palette hex literals. The plan's own acceptance criteria (`grep -rn "0xFF16181D" lib` returns ONLY tokens.dart) is stricter than the named file list and would fail with these left unmigrated.
- **Fix:** Migrated all 5 onto `theme/tokens.dart` the same way as the named screens (deleted local const blocks / inline literals, added the import).
- **Files modified:** `lib/keyboard/key_rows.dart`, `lib/keyboard/modifier_chip.dart`, `lib/screens/pairing_dialog.dart`, `lib/trackpad/mouse_buttons.dart`, `lib/dev/beacon_smoke_main.dart`
- **Commit:** `86748fc` (part of Task 1 commit)

**2. [Rule 1 - Bug] Removed 7 now-unnecessary `flutter/services.dart` imports**
- **Found during:** Task 2 (`flutter analyze lib` after haptics rerouting)
- **Issue:** After routing haptics through `settings/haptics.dart`, seven files (`apps_screen.dart`, `browser_screen.dart`, `media_screen.dart`, `power_screen.dart`, `presenter_screen.dart`, `trackpad_screen.dart`, `keyboard_panel.dart`) no longer used any symbol exclusive to `package:flutter/services.dart` — `material.dart` already re-exports the remaining used symbols (e.g. `FontFeature`). `keyboard_panel.dart` had a genuine `unused_import` warning; the other six had `unnecessary_import` info-level lints.
- **Fix:** Removed the redundant import line from all 7 files.
- **Files modified:** the 7 files listed above
- **Commit:** `0aef4e8` (part of Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 missing-critical migration completeness, 1 lint cleanup)
**Impact on plan:** Both auto-fixes were required to satisfy the plan's own acceptance criteria and keep `flutter analyze lib` clean. No scope creep — no new behavior, no new screens, no new haptics/keep-awake call sites (D-13/D-14 remain gate-and-consolidate only).

## Issues Encountered
None beyond the two auto-fixes above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- 07-11 (dashboard/quick-bar) and 07-12/07-13 (settings screen) now build on a codebase where every screen already shares tokens/haptics/keep-awake — no migration debt carries forward.
- The grep-guard test (`test/theme_tokens_guard_test.dart`) will immediately catch any future screen that copy-pastes a local palette block instead of importing `theme/tokens.dart`.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-12*

## Self-Check: PASSED

- FOUND: app/remote_control/test/theme_tokens_guard_test.dart
- FOUND: app/remote_control/lib/theme/tokens.dart
- FOUND: commit 86748fc (Task 1)
- FOUND: commit 0aef4e8 (Task 2)
