---
phase: 09-ui-refinement-to-design-prototype-visual-pass-across-all-scr
plan: 09
subsystem: flutter-client-ui
tags: [icons, material-symbols, theme, tree-shaking, gap-closure]
gap_closure: true
requires:
  - 09-01..09-07 (all Wave 1 refinement plans landed)
provides:
  - material_symbols_icons dependency
  - Symbols.<name>_rounded glyphs across the whole client
  - buildAppTheme IconThemeData axis pin (opsz 24 / wght 400 / FILL 0 / GRAD 0)
  - test/icons_guard_test.dart (permanent classic-Icons ban)
  - amended 09-UI-SPEC icon-library contract
affects:
  - every screen that renders a glyph (16 lib files)
tech_stack_added:
  - "material_symbols_icons ^4.2951.0 (const IconData, tree-shakeable)"
patterns:
  - "Icon axes pinned once via ThemeData.iconTheme, not per-call-site wrappers"
  - "grep-guard test mirrors theme_tokens_guard_test (recursive lib/ scan, // lines skipped)"
key_files_created:
  - app/remote_control/test/icons_guard_test.dart
key_files_modified:
  - app/remote_control/pubspec.yaml
  - app/remote_control/lib/theme/tokens.dart
  - "16 lib icon files + 11 test files (see commits)"
  - .planning/phases/09-ui-refinement-to-design-prototype-visual-pass-across-all-scr/09-UI-SPEC.md
decisions:
  - "All four style-suffix classic names map onto the axis-expressed rounded glyph (info_outline/lock_outline->lock_rounded, bedtime_outlined, warning_amber_rounded)"
  - "Doc-comment Icons.* mentions were migrated too (kept truthful) even though the guard skips // lines"
metrics:
  tasks: 3
  files_changed: 32
  completed: 2026-07-16
---

# Phase 9 Plan 09: Material Symbols Rounded Icon Migration Summary

Migrated the entire Flutter client off classic filled Material `Icons.*` onto
`Symbols.<name>_rounded` from `material_symbols_icons`, pinned the prototype's
exact icon axes app-wide (`opsz 24 / wght 400 / FILL 0 / GRAD 0`), and locked the
migration in place with a permanent grep-guard — closing the last visual delta
the 09-08 on-device UAT flagged (glyph style skew vs the design prototype).

## What Was Built

- **Task 1 (`c8ba938`)** — Added `material_symbols_icons ^4.2951.0`; migrated all
  63 `Icons.*` references across 16 lib files to `Symbols.<name>_rounded`; pinned
  `IconThemeData(fill: 0, weight: 400, grade: 0, opticalSize: 24)` in
  `buildAppTheme()`. Analyzer clean; zero bare `Icons.` remain in lib/.
- **Task 2 (`29bb194`)** — Migrated all 41 `Icons.*` references across 11 test
  files in lockstep (finders stay pointer-equal with the migrated widgets); added
  `test/icons_guard_test.dart` banning classic `Icons.*` in lib/. Full suite green
  (423 tests) including the D-12 `theme_tokens_guard_test`.
- **Task 3 (`2f85d46`)** — Release-build sanity: `flutter build apk --release`
  exits 0 with the Symbols font tree-shaken; amended the 09-UI-SPEC icon-library
  row to the new Material Symbols Rounded contract.

## Mapping Applied

Every distinct name migrated exactly per the plan's `icon_mapping` table. No
nearest-equivalent substitutions were needed — every `Symbols.<name>_rounded`
constant resolved against `material_symbols_icons` 4.2951.0 (analyzer reported
zero issues). The four style-suffix special cases were applied as specified:

| Classic | Symbols Rounded target |
|---|---|
| `info_outline` | `info_rounded` |
| `lock_outline` | `lock_rounded` (same target as `lock`) |
| `bedtime_outlined` | `bedtime_rounded` |
| `warning_amber_rounded` | `warning_rounded` |

All other names took the mechanical `Icons.x -> Symbols.x_rounded` rule.
Doc-comment mentions of classic names (`apps_screen.dart`, `clipboard_screen.dart`,
`media_screen.dart`, `trackpad_bubble.dart`) were also migrated so the docs name
the real constants.

## Release-Build Sanity (Task 3)

- **Baseline APK** (09-08 fresh release build, 2026-07-16 10:08): `52,661,857` bytes
- **New APK**: `52,725,028` bytes
- **Delta**: `+63,171` bytes (`+61.7 KB` / `0.060 MB`) — well under the 1 MB gate
- **Tree-shake log line (the one that matters):**
  `Font asset "MaterialSymbolsRounded.ttf" was tree-shaken, reducing it from 15036080 to 95932 bytes (99.4% reduction).`
  The unused Outlined/Sharp bundled variants tree-shook to ~2.4 KB each (100%),
  and the legacy MaterialIcons font to 1,420 bytes (99.9%). The shaker fired
  cleanly — const IconData usage, no `get()`/`SymbolsGet` runtime lookups.

## Verification Results

1. `flutter analyze` — No issues found.
2. `flutter test` — All 423 tests passed (full Phase 1–9 suite + new guard + D-12
   theme-token guard).
3. `grep -rn "Icons\." lib` (minus `CupertinoIcons.`) — zero matches; permanently
   enforced by `icons_guard_test.dart`.
4. `flutter build apk --release` — exit 0; MaterialSymbolsRounded tree-shaken;
   +61.7 KB delta.
5. 09-UI-SPEC Icon-library row now names `material_symbols_icons` +
   `Symbols.*_rounded` + the pinned axes with the 2026-07-16 amendment note.

The `icons_guard_test` was RED-proven during execution: temporarily reintroducing
`Icons.add` into `lib/widgets/uipi_banner.dart` failed the guard as expected, then
the scratch line was reverted.

## Deviations from Plan

None — plan executed exactly as written. No nearest-equivalent icon substitutions
were required; no auto-fixes (Rules 1–3) or architectural decisions (Rule 4) arose.

## Known Stubs

None.

## Next Step (NOT part of this plan)

The 09-08 on-device visual UAT gate must now **re-run against a FRESH**
`flutter build apk --release` (per the 08-06 stale-APK lesson: `flutter install`
reuses the last-built APK). The current build already includes the migrated icons,
but the UAT gate owns its own rebuild-then-install-then-walkthrough sequence.

## Self-Check: PASSED

- `test/icons_guard_test.dart` exists
- `09-09-SUMMARY.md` exists
- `lib/theme/tokens.dart` (axis pin) exists
- Commits `c8ba938`, `29bb194`, `2f85d46` all present in git log
