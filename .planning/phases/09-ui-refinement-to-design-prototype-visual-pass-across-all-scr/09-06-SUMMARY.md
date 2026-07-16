---
phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
plan: 06
subsystem: ui
tags: [flutter, power, presenter, ui-refinement, design-parity]

# Dependency graph
requires:
  - phase: 05-control-center-thin-key-macros
    provides: Power (slide-to-confirm tracks + countdown dialog) and Presenter (split zones + footer timer) screens
  - phase: 09-ui-refinement (09-UI-SPEC)
    provides: Per-screen delta table + Component State Contract + Copywriting Contract + Motion Budgets + Radii to confirm against
provides:
  - Confirmed Power screen parity (four 64px tracks, 56px radius-12 thumb, 4px inset, 0.2 fill, 200ms spring-back, safe accent / destructive kError pairs, countdown dialog copy + colors)
  - Confirmed Presenter screen parity (split zones flex 1/2 + 1px kHairline divider, 64px footer, 28/600 tabular timer with three state colors, verbatim copy)
affects: [09-08 on-device UAT]

# Tech tracking
tech-stack:
  added: []
  patterns: [confirm-pass — verify named spec values against shipped source, apply delta only on drift]

key-files:
  created: []
  modified: []

key-decisions:
  - "Both Power and Presenter screens were already byte-for-byte at-spec — zero source or test deltas required (pure confirm-pass)"
  - "The single-action-path power gate (SendPower always effect[0]) and the client-local presenter timer FSM were confirmed untouched — behavior stays covered by confirm_track_fsm_test + presenter_timer_test"

patterns-established:
  - "Confirm-pass with zero drift produces no per-task code commit — only the SUMMARY/STATE/ROADMAP docs commit"

requirements-completed: []

# Metrics
duration: 5min
completed: 2026-07-16
---

# Phase 9 Plan 06: Power + Presenter Confirm-Pass Summary

**Power and Presenter screens confirmed byte-for-byte at-spec against 09-UI-SPEC (slide-track geometry + spring-back, destructive countdown dialog copy/colors, split tap zones + 1px divider, 64px footer, 28/600 tabular timer with running/paused/stopped colors) — zero source drift, all FSM + guard tests green.**

## Performance

- **Duration:** ~5 min
- **Completed:** 2026-07-16
- **Tasks:** 2 (both confirm-only)
- **Files modified:** 0 (pure confirm-pass — no drift found)

## Accomplishments

- **Task 1 — Power parity confirmed:** four `_SlideTrack`s in reading order Lock, Sleep (safe pair, `kAccent`), Restart, Shut down (destructive pair, `kError`), md (16px) gap within a pair + lg (24px) gap between pairs; track height 64 / radius 16, thumb 56 square / radius 12 / inset 4, fill = actionColor at 0.2 alpha, centered label 14/`w400` `kMuted` fading with progress, action icon 20 + `chevron_right` 16 both in `kBg` on the thumb, 200ms spring-back on release below 0.9, full-fill flash + `hapticTickMedium` on completion, inert `kMuted` (never red) when not authed; labels exactly "Slide to lock / sleep / restart / shut down". `_CountdownDialog`: title "{Restart|Shut down} PC?" 16/`w600` with `Icons.warning_amber_rounded` in `kError`, body "This will close everything open on your PC." 14/`w400`, sub "Confirm within {n}s" 12/`w400` with `FontFeature.tabularFigures()`, Cancel `TextButton` `kMuted` / verb `FilledButton` `kError` bg + `kBg` fg (min 48h); `kPowerConfirmWindowSeconds == 10`. The single-action-path gate (SendPower always effect[0]) confirmed untouched.
- **Task 2 — Presenter parity confirmed:** split tap zones — Prev `flex: 1` (`Icons.chevron_left` + "Previous"), Next `flex: 2` (`Icons.chevron_right` + "Next"), separated by a 1px `kHairline` `ColoredBox` divider; chevron 48 + caption 12/`w400`, 100ms accent press-down flash, muted `kMuted` (never red) when not authed; footer `Container` height 64 with a top `kHairline` border holding Start show / End show `_BarButton`s (radius 8, 16/`w600`) + the `_BlankToggle` (accent outline when active) + a right-aligned timer 28/`w600` with `FontFeature.tabularFigures()` whose color is `kAccent` (running) / `kText` (paused) / `kMuted` (stopped). Copy "Previous" / "Next" / "Start show" / "End show" / "Blank" matches the Copywriting Contract. Client-local timer FSM + keep-awake ref-count confirmed untouched.
- **Zero locked-token change** — theme-token D-12 guard passes.

## Task Commits

Both tasks were confirm-only with **zero source/test drift** — no per-task code commit was produced (nothing to stage). Verification was run and passed for each:

1. **Task 1: Confirm Power slide tracks + countdown dialog parity** — no delta; `flutter analyze` clean, `confirm_track_fsm_test` + `theme_tokens_guard_test` green.
2. **Task 2: Confirm Presenter split zones + footer + timer parity** — no delta; `presenter_timer_test` + `theme_tokens_guard_test` green.

**Plan metadata:** docs commit (SUMMARY + STATE + ROADMAP).

## Files Created/Modified

None — both `power_screen.dart` and `presenter_screen.dart` already matched every named 09-UI-SPEC value exactly.

## Verification

- `flutter analyze` → **No issues found!**
- `flutter test test/power/confirm_track_fsm_test.dart test/presenter/presenter_timer_test.dart test/theme_tokens_guard_test.dart` → **25 passed**

## Decisions Made

- Neither screen had drifted from the spec, so no named delta was applied. Consistent with the 09-02/03/04/05 confirm-pass outcomes; behavior (the no-single-action-path power gate, the client-local presenter timer) is already covered by `confirm_track_fsm_test` and `presenter_timer_test`, and on-device visual parity is carried by 09-08 — so this plan produced no code artifact.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Power + Presenter are pinned at-spec; their exact geometry/copy/motion is documented above for the 09-08 on-device UAT checklist.
- Remaining Phase 9 plans: 09-07 (screen confirms), then 09-08 (UAT gate).

## Self-Check: PASSED

- FOUND: 09-06-SUMMARY.md
- FOUND commit: (recorded in final docs commit below)

---
*Phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr*
*Completed: 2026-07-16*
