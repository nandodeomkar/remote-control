---
phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
plan: 02
subsystem: ui
tags: [flutter, widget-test, connection-header, hub, confirm-pass]

# Dependency graph
requires:
  - phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
    provides: dot-grid trackpad texture (09-01) — sibling confirm pass, no code dependency
provides:
  - Test-pinned parity for ConnectionHeaderChip + ReconnectingBanner (chip latency segment, banner retry ≥48px)
  - Test-pinned parity for HubTileGrid/_HubTile (1.4:1 aspect ratio, offline non-tappable grid)
affects: [09-ui-refinement remaining plans, hub, connection-header]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Confirm-pass plan: verify each named UI-SPEC value against source, pin with a widget-test assertion, zero source delta when parity holds"

key-files:
  created: []
  modified:
    - app/remote_control/test/connection_header_test.dart
    - app/remote_control/test/hub_tiles_test.dart

key-decisions:
  - "Both rows ('Status chip + banner', 'Hub') were confirmed As-is against the 09-UI-SPEC — no production source changed; the deltas closed were test-coverage gaps only"
  - "Retry-now min-size pinned by resolving TextButton.style.minimumSize to Size(48,48) rather than measuring rendered geometry (target floor is the contract, not layout size)"

patterns-established:
  - "Pin AspectRatio contract by iterating widgetList<AspectRatio> and asserting aspectRatio == 1.4 (per-cell, not just count)"

requirements-completed: []

# Metrics
duration: 2min
completed: 2026-07-16
---

# Phase 9 Plan 02: Status Chip + Banner + Hub Parity Confirm Summary

**Confirmed the "Status chip + banner" and "Hub" rows of the 09-UI-SPEC delta table are already As-is in source, and pinned the previously-unasserted values (chip latency segment presence/absence, banner Retry-now 48px floor, hub tile 1.4:1 aspect ratio, offline non-tappable grid) with widget tests — zero production source change, zero palette change.**

## Performance

- **Duration:** ~2 min
- **Started:** 2026-07-16T04:05:10Z
- **Completed:** 2026-07-16T04:07:33Z
- **Tasks:** 2
- **Files modified:** 2 (0 created, 2 modified — both test files)

## Accomplishments
- **Task 1 — chip + banner parity confirmed.** Verified every named value in `connection_header.dart`: chip padding 8h/4v, radius 8, `_chipFill` (#CC0E0F12), `kHairline` border; 8px dot in an `AnimatedContainer` at 200ms `Curves.ease` (color only); word 12/w600; latency `· {n} ms` 12/w400 with `tabularFigures`, connected-only; state colors connected `kAccent` / reconnecting `#E8A33D` / disconnected `kMuted`; banner `kSurface` + top/bottom hairlines, `wifi_off` amber size 20, "Reconnecting…" 14/w400, "Retry now" `TextButton` accent min 48×48; slot 150ms `SizeTransition`+`SlideTransition`. All matched — no source delta.
- Strengthened `connection_header_test.dart`: added a test asserting the connected chip renders the `· … ms` latency segment while reconnecting/disconnected omit it, and pinned the Retry-now button minimum size to `Size(48, 48)`.
- **Task 2 — Hub uniform 2×4 grid + offline muting confirmed.** Verified `HubTileGrid`/`_HubTile`: uniform 2-col rows with 16px inter-row/inter-column gaps, `AspectRatio(1.4)` per `_halfTile`, `kSurface` fill + `kHairline` 1px `RoundedRectangleBorder` radius 16, centered `Icon(size:32, color:kMuted)` + 4px gap + label 16/w600 (`kText` enabled / `kMuted` disabled), `InkWell` `onTap` null when disabled, grid padding `fromLTRB(16,32,16,16)`, app-bar title 16/w600, settings gear always tappable, `kHubTiles` 8-tile D-09 order. All matched — no source delta.
- Strengthened `hub_tiles_test.dart`: pinned each `AspectRatio` cell to exactly 1.4:1, and added a `HubTileGrid(enabled: false)` test proving all 8 `InkWell`s render with a null `onTap` (offline non-tappable, layout stable).
- `_reconnectingColor` (#E8A33D) and `_chipFill` (#CC0E0F12) remain declared and unchanged; the D-12 theme-token guard still passes.

## Task Commits

Each task was committed atomically:

1. **Task 1: Confirm status chip + reconnecting banner parity** — `43a93ce` (test)
2. **Task 2: Confirm Hub uniform 2×4 grid + offline muting** — `4d5d380` (test)

**Plan metadata:** _(final commit)_

## Files Created/Modified
- `app/remote_control/test/connection_header_test.dart` — added latency-segment presence/absence test + Retry-now 48×48 min-size assertion (+44 lines).
- `app/remote_control/test/hub_tiles_test.dart` — added `enabled` param to `_host`, per-cell 1.4 aspect-ratio pin, and disabled-grid non-tappable test (+28/-2 lines).

## Decisions Made
- Confirmed both delta-table rows As-is with no production change — the only work was closing test-coverage gaps (retry min-size, latency-segment, aspect-ratio value, direct `enabled:false` grid path). Existing offline coverage via `hub_offline_test.dart` (full `HubScreen`) was kept intact; the new test pins the grid widget in isolation.
- Pinned the Retry-now touch floor by resolving `TextButton.style?.minimumSize` to `Size(48,48)` — the style contract is the UI-SPEC requirement, not the rendered box size.

## Deviations from Plan

None — plan executed exactly as written. Both tasks were confirm-passes; no source deviation (Rules 1–3) was triggered because every named value already matched the 09-UI-SPEC.

## Issues Encountered
None.

## User Setup Required
None — no external service configuration required.

## Next Phase Readiness
- Chip + banner + Hub visual contract is now pinned by tests; remaining Phase 09 plans are the other per-screen confirm/refine passes.
- On-device visual parity remains deferred to the phase UAT gate (09-08).

## Self-Check: PASSED

- FOUND: app/remote_control/test/connection_header_test.dart
- FOUND: app/remote_control/test/hub_tiles_test.dart
- FOUND commits: 43a93ce, 4d5d380
- Verification: `flutter analyze` clean (No issues found); `flutter test test/connection_header_test.dart test/hub_tiles_test.dart test/hub_offline_test.dart test/theme_tokens_guard_test.dart` = 15 passed.

---
*Phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr*
*Completed: 2026-07-16*
