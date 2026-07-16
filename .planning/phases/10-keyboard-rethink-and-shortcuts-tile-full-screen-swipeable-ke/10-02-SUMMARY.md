---
phase: 10-keyboard-rethink-and-shortcuts-tile
plan: 02
subsystem: ui
tags: [shortcuts, flutter, riverpod, hub-tile, key-macro, registry, material-symbols]

# Dependency graph
requires:
  - phase: 10-01
    provides: "kClientKeyCodes extended by 18 codes (letters A C D E F I R S V X Y Z, main-row 0, PrintScreen, promoted T W Plus Minus) — the vocabulary the Shortcuts catalog fires"
  - phase: 05-02
    provides: "kBrowserActions/kHubTiles registry pattern + _TransportButton press-down + house screen chrome"
provides:
  - "kShortcutCatalog — 4-section / 25-button ordered registry (ShortcutSpec + ShortcutSection)"
  - "ShortcutButton widget — house press-DOWN + haptic + 100ms accent flash + muted-not-red gate"
  - "ShortcutsScreen — sectioned 2-column grid firing KeyMsg(action:'tap', mods) on the reliable path"
  - "kShortcutsTitle = 'Shortcuts' (tile label + app-bar title)"
  - "Shortcuts HubTileSpec at kHubTiles index 2 (9-tile grid)"
affects: [10-03-keyboard-pads]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Registry-driven catalog (kShortcutCatalog) drives BOTH the render and the vocabulary coverage test — one ordered source of truth (the kBrowserActions/kHubTiles pattern)"
    - "Vocabulary-membership gate: every ShortcutSpec.code cross-checked against kClientKeyCodes; excluded combos (Alt+Tab/Win+L/Ctrl+Alt+Del) asserted absent"

key-files:
  created:
    - app/remote_control/lib/shortcuts/shortcuts_screen.dart
    - app/remote_control/test/shortcuts/shortcuts_screen_test.dart
  modified:
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/test/hub_tiles_test.dart
    - app/remote_control/test/hub/hub_screen_test.dart

key-decisions:
  - "All 26 named Symbols.*_rounded glyphs verified present in the pinned material_symbols_icons 4.2951.0 — zero icon substitutions needed (grepped the vendored symbols.dart before authoring)"
  - "ShortcutsScreen front-loaded into the Task-1 file alongside the catalog + button (Task 2 became test-only additions), keeping one cohesive shortcuts module"
  - "The 100ms accent-flash Future.delayed leaves a pending timer at widget-tree teardown; connected-tap widget tests pump(120ms) before unmount to settle it (the media-screen unmount idiom)"
  - "Bare-grid hub test viewports bumped 1400->1800 for the 9th tile's 5th row (the test's own 'grow height as the registry grows' contract); production HubScreen scrolls so no source change needed"

patterns-established:
  - "Pattern: a new tool tile = one HubTileSpec insert at its index + the import; HubTileGrid's odd-tail chunker renders the Nth half-width tile with zero grid change"

requirements-completed: [KEY-03]

# Metrics
duration: 14min
completed: 2026-07-16
---

# Phase 10 Plan 02: Shortcuts tile + catalog Summary

**Shipped the Shortcuts hub tile (position 3) and its tool screen — a 4-section / 25-button registry-driven catalog of one-tap Windows chords, each effect-labeled with the combo as subtext, firing exactly one `key {action:tap, mods}` on the existing reliable path over the house press-down + muted-not-red button pattern; every catalog code is proven a member of the locked kClientKeyCodes vocabulary and the excluded combos never render.**

## Performance

- **Duration:** ~14 min
- **Completed:** 2026-07-16
- **Tasks:** 3
- **Files created:** 2, modified: 3

## Accomplishments
- `kShortcutCatalog` — 4 sections (`Windows & Desktop` 7 / `Screenshot` 3 / `Browser & App` 9 / `Editing` 6 = 25), copied verbatim from 10-UI-SPEC (labels, combos, icons, codes, mods all binding).
- `ShortcutSpec` / `ShortcutSection` data classes + `kShortcutsTitle` const (no inline copy literals).
- `ShortcutButton` — the media `_TransportButton` press-DOWN twin: `kSurface` fill, radius 12, minHeight 64, icon 24 + effect 14/w600 + combo 12/w400, 100ms accent flash, fire-and-forget, gated muted-not-red.
- `ShortcutsScreen` — media/browser chrome (app bar + `ConnectionHeaderChip` + `ReconnectingBannerSlot`, xl top padding) over a sectioned 2-column grid with the odd-tail half-width pattern; each button fires `sendReliable(KeyMsg(code, action:'tap', mods))`, `enabled: authed`.
- Shortcuts `HubTileSpec` (`Symbols.bolt_rounded`) inserted at `kHubTiles` index 2 → 9-tile order Trackpad, Keyboard, Shortcuts, Media, Apps, Clipboard, Power, Presenter, Browser; `HubTileGrid` body untouched.
- Full test coverage: catalog integrity (counts + headers + anchor rows), vocabulary membership (every code ∈ `kClientKeyCodes`), excluded-combo absence, button press/gating, screen render (4 headers + 25 buttons), connected-tap KeyMsg wiring (Win+D, Ctrl+C), unauthed zero-send + kMuted gating, and the reworked 9-tile hub grid.

## Task Commits

1. **Task 1 (TDD): catalog + ShortcutButton + ShortcutsScreen** — `1202f1c` (feat). RED: the integrity/vocabulary/press test failed to compile (symbols absent). GREEN: authored the catalog + button + screen; 10 tests green.
2. **Task 2: screen-level render + reliable-path wiring tests** — `bd0725a` (test). The ShortcutsScreen source landed in Task 1, so Task 2 was the screen-level widget tests (render, connected-tap KeyMsg, unauthed gating); 14 tests green.
3. **Task 3: Shortcuts hub tile at position 3** — `b8e3107` (feat). Inserted the tile + import; reworked hub_tiles_test to 9 tiles with the half-width tail; bumped two bare-grid test viewports.

## Files Created/Modified
- `app/remote_control/lib/shortcuts/shortcuts_screen.dart` (new) — catalog + `ShortcutSpec`/`ShortcutSection` + `ShortcutButton` + `ShortcutsScreen` + `kShortcutsTitle`.
- `app/remote_control/test/shortcuts/shortcuts_screen_test.dart` (new) — 14 tests (catalog integrity + vocabulary + button + screen wiring).
- `app/remote_control/lib/hub/hub_screen.dart` — Shortcuts import + `HubTileSpec` at index 2 + class-doc updated to 9 tiles.
- `app/remote_control/test/hub_tiles_test.dart` — 9-tile order, Shortcuts at index 2, AspectRatio ×9, InkWell ×9, half-width tail reading-order.
- `app/remote_control/test/hub/hub_screen_test.dart` — bare-grid viewport 1400→1800 for the 5th row.

## Decisions Made
- Verified all 26 `Symbols.*_rounded` names exist in the pinned `material_symbols_icons 4.2951.0` (grepped the vendored `symbols.dart`) — no icon substitutions, so all labels/codes/mods and icons match the UI-SPEC byte-for-byte.
- Front-loaded `ShortcutsScreen` into the Task-1 module so the shortcuts feature is one cohesive file; Task 2 added only the screen-level tests.
- Catalog codes reuse existing vocabulary members exactly: `Tab`/`Left`/`Right`/`Esc`/`F5` (pre-existing), plus the 10-01 additions (letters, `0`, `PrintScreen`, `Plus`/`Minus`). `Win+Tab` (Task view) uses `code:'Tab', mods:['win']` — distinct from the excluded Alt+Tab (`mods` never contains `alt` with `Tab`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Pending accent-flash timer at widget-tree teardown**
- **Found during:** Task 2
- **Issue:** The two connected-tap widget tests fired `ShortcutButton._fire`, which schedules a 100ms `Future.delayed` for the accent flash; the test unmounted before it settled, tripping Flutter's "A Timer is still pending" invariant.
- **Fix:** Added `await t.pump(const Duration(milliseconds: 120))` before the final unmount in both tests (the media-screen unmount idiom).
- **Files modified:** `app/remote_control/test/shortcuts/shortcuts_screen_test.dart`
- **Commit:** `bd0725a`

**2. [Rule 3 - Blocking] Bare-grid hub tests overflowed with the 9th tile**
- **Found during:** Task 3
- **Issue:** `hub_screen_test.dart` (in the plan's verify command, not its file list) pumps the bare grid with no scroll host; the 9th tile added a 5th row that overflowed the 800×1400 surface (RenderFlex overflow → test failure). The test's own comment says to grow the surface height as the registry grows.
- **Fix:** Bumped that test's `physicalSize` 1400→1800 and the hub_tiles_test reading-order viewport 1400→1800. Production `HubScreen` wraps the grid in a `SingleChildScrollView`, so no source change was needed.
- **Files modified:** `app/remote_control/test/hub/hub_screen_test.dart`, `app/remote_control/test/hub_tiles_test.dart`
- **Commit:** `b8e3107`

### Doc hygiene
- Updated `hub_screen.dart`'s library doc from "8 tools / 2×4 grid" to "9 tools" with the Shortcuts-at-position-3 order and the odd-tail note (keeps the class doc honest).

## Issues Encountered
None beyond the two auto-fixed items above. The 10-01 vocabulary extension held: every one of the 25 catalog codes resolved against `kClientKeyCodes` on the first pass with zero drift.

## User Setup Required
None — no external service configuration, no new packages (reuses `material_symbols_icons` already present, T-10-SC accept).

## Threat Surface
No new network surface, no new auth path, no new message type — the shortcut buttons reuse the existing authed `key {action:tap, mods}` path (T-10-02 accept). The vocabulary-membership test enforces T-10-03 (catalog-vs-server drift fails the build). Excluded combos (Alt+Tab, Win+L, Ctrl+Alt+Del) are asserted absent by test. No threat flags.

## Next Phase Readiness
- Shortcuts tile is live at hub position 3; the 25-button catalog fires real Windows chords over the reliable path, gated muted-not-red offline.
- 10-03 (keyboard pads rebuild) is independent of this plan's surface; no blockers introduced.

## Self-Check: PASSED

- Commits `1202f1c`, `bd0725a`, `b8e3107` found in git log.
- `lib/shortcuts/shortcuts_screen.dart` + `test/shortcuts/shortcuts_screen_test.dart` exist on disk.
- Full verification (22 tests across the 4 named files) green; `flutter analyze lib/shortcuts lib/hub` clean; keyboard vocabulary gate (11 tests) still green.

---
*Phase: 10-keyboard-rethink-and-shortcuts-tile*
*Completed: 2026-07-16*
