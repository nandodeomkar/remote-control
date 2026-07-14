---
phase: 07-server-shell-dashboard-polish
plan: 13
subsystem: ui
tags: [flutter, riverpod, dashboard, quick-bar, keyboard, D-08, D-09, D-10, D-11, UI-01]

# Dependency graph
requires:
  - phase: 07-server-shell-dashboard-polish
    provides: "07-09/07-10 theme/tokens.dart + hapticTick + ref-counted keepAwake; 07-11 UipiBanner (.forService seam, IgnorePointer-wrapped); 07-12 SettingsScreen (the gear destination); 04-05/04-06 KeyboardPanel (hidden_text_input/key_rows/modifier_fsm)"
provides:
  - "main.dart home = HubScreen (D-08): the app opens straight into the dashboard; the former device list is the add/switch-PC screen reached via Settings"
  - "hub_screen.dart final identity: kHubTiles LOCKED to Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser (D-09); HubTileGrid uniform 2-column chunking (full-width Trackpad primary row deleted, Pitfall 9); offline (ChipStatus.disconnected) renders every tool tile onTap-null + muted label; app-bar settings gear always pushes SettingsScreen (D-11)"
  - "keyboard/keyboard_screen.dart — KeyboardScreen: KeyboardPanel promoted to a first-class screen (always expanded, IME raised on entry, same reliable-path/auth-gate/D-12-reset seams the trackpad wires)"
  - "widgets/quick_bar_scaffold.dart — QuickBarScaffold({body, showQuickBar}): 56px kSurface bottom bar + kHairline top edge, centered accent touch_app + 'Trackpad' shortcut firing hapticTick then pushing TrackpadScreen; hosts UipiBanner as a top-anchored IgnorePointer overlay in BOTH modes"
  - "HubScreen._open wraps every tile destination in QuickBarScaffold centrally; HubTileSpec.showQuickBar (Trackpad tile = false) keeps the shortcut off the screen you are on while the banner still rides it"
affects:
  - "07-08 (server-side revoke) — unrelated surface; phase UAT gate exercises this dashboard end-to-end"
  - "Phase-gate on-device check: hub -> Presenter -> quick-bar -> Trackpad -> back keep-awake ref-count path is now navigable"

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Central route-wrap at the push seam: one _open site wraps all 8 tool destinations in QuickBarScaffold, driven by a data field on the tile spec (showQuickBar) instead of per-screen self-wrapping"
    - "Quick-bar's own push re-wraps TrackpadScreen with showQuickBar:false so the UIPI banner stays contextual on every navigation path (tile push AND quick-bar push)"
    - "Hub widget tests avoid pumpAndSettle entirely — the ConnectionHeaderChip's 500ms periodic setState poll never settles; push transitions are pumped with explicit durations"

key-files:
  created:
    - app/remote_control/lib/keyboard/keyboard_screen.dart
    - app/remote_control/lib/widgets/quick_bar_scaffold.dart
    - app/remote_control/test/hub_tiles_test.dart
    - app/remote_control/test/hub_offline_test.dart
    - app/remote_control/test/quick_bar_test.dart
  modified:
    - app/remote_control/lib/main.dart
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/test/widget_test.dart

key-decisions:
  - "Offline = ChipStatus.disconnected ONLY: reconnecting keeps tiles tappable (07-UI-SPEC §2's 'tiles never throw on tap while connecting' — tool screens gate their own sends); disconnected is the hard disable"
  - "HubTileSpec grew a showQuickBar field (default true, Trackpad false) instead of a label-string comparison at the push seam — data-driven, matches the registry-owns-the-grid house pattern"
  - "The quick-bar push wraps TrackpadScreen in QuickBarScaffold(showQuickBar:false) rather than pushing it bare, so the UIPI banner is hosted on the trackpad reached from ANY tool screen (the banner's most likely surface)"
  - "UipiBanner overlays TOP-anchored (the ReconnectingBannerSlot position, SafeArea'd) rather than above the quick-bar — mirrors the shipped banner pattern; IgnorePointer guarantees no touch interception either way"
  - "KeyboardScreen does NOT self-wrap in QuickBarScaffold — the central _open wrap covers it (quick-bar visible via the default showQuickBar:true), keeping the screen wrapper-agnostic like every other tool screen"

patterns-established:
  - "Uniform tile grid: HubTileGrid chunks ALL tiles from i=0 into 2-column AspectRatio(1.4) rows; enabled=false propagates onTap-null + muted label to every tile with zero layout shift"

requirements-completed: [UI-01]

# Metrics
duration: ~20min
completed: 2026-07-14
---

# Phase 7 Plan 13: Dashboard Rewire + Persistent Trackpad Quick-Bar Summary

**The app now opens straight into its final dashboard — 8 uniform tiles in the locked D-09 order (Keyboard promoted to a first-class screen), offline-disabled tiles, an always-tappable settings gear — with a persistent accent Trackpad quick-bar + UIPI banner riding every tool screen via one central QuickBarScaffold wrap.**

## Performance

- **Duration:** ~20 min
- **Tasks:** 2/2
- **Files created:** 5 (2 lib, 3 test)
- **Files modified:** 3 (main.dart, hub_screen.dart, widget_test.dart)
- **Tests:** 8 new (3 hub_tiles, 2 hub_offline, 3 quick_bar) — full suite 351/351 green
- **Analyze:** `flutter analyze lib` clean

## Accomplishments

1. **Dashboard as home (D-08):** `main.dart` reroutes `home:` from `DeviceListScreen` to `HubScreen`. The D-01 silent launch kick and D-06 resume listener stay verbatim — a remembered PC still silently reconnects with no navigation, the user just lands on the dashboard instead of the list.
2. **Final 8-tile identity (D-09):** Keyboard tile (`Icons.keyboard`) inserted at index 1; `kHubTiles` is now EXACTLY Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser. `HubTileGrid` dropped the full-width `SizedBox(height: 96)` Trackpad primary row (Pitfall 9) — all 8 tiles chunk into uniform 2-column `AspectRatio(1.4)` rows.
3. **Offline-disabled tiles (D-08):** `HubScreen` derives `offline` from the already-watched `connectionStatusProvider` (`ChipStatus.disconnected`) and passes `enabled: !offline` into the grid; disabled tiles render `onTap: null` (no ripple) with a muted label but identical fill/border so the layout never shifts.
4. **Settings gear (D-11):** app-bar `IconButton(Icons.settings)` after the header chip, ALWAYS tappable — pushes the 07-12 `SettingsScreen` (which hosts add/switch-PC), so pairing/management stays reachable offline.
5. **KeyboardScreen (D-09):** the existing modular `KeyboardPanel` mounted `expanded: true` on a `kBg` canvas under a "Keyboard" app bar — IME raised on entry, chips/caps auth-gated, diffs on the reliable path, D-12 disconnect reset intact. Zero new keyboard logic.
6. **QuickBarScaffold (D-10):** 56px `kSurface` bar, 1px `kHairline` top edge, one centered accent `Icons.touch_app` + "Trackpad" button (the reserved accent affordance) that fires `hapticTick()` then pushes the full Trackpad screen. The bar reserves its height in a Column (never overlaps content); `UipiBanner.forService` rides a top-anchored `SafeArea` overlay in both modes.
7. **Central wrap:** `HubScreen._open` wraps every tile destination; `HubTileSpec.showQuickBar` (Trackpad tile `false`) removes the redundant shortcut on the Trackpad itself while keeping the banner host.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] widget_test.dart smoke test updated for the home reroute**
- **Found during:** Task 1
- **Issue:** the app-shell smoke test asserted `DeviceListScreen` is home + `kDevicesTitle` renders — both intentionally broken by the D-08 reroute this plan exists to make.
- **Fix:** assertions updated to `HubScreen` home + the fallback "Remote" dashboard title; fake-store/stub-list overrides unchanged.
- **Files modified:** `app/remote_control/test/widget_test.dart`
- **Commit:** 029d1c5

No other deviations — plan executed as written.

## Task Commits

| Task | Name | Commit |
| ---- | ---- | ------ |
| 1 | Dashboard-as-home + uniform 2×4 grid + 8 tiles + KeyboardScreen + offline-disabled + gear | 029d1c5 |
| 2 | QuickBarScaffold — persistent Trackpad shortcut + UipiBanner host + central wrap | 44725fc |

## Verification Evidence

- `flutter test test/hub_tiles_test.dart test/hub_offline_test.dart test/quick_bar_test.dart` — all green (plan `<verification>` row 1).
- `flutter analyze lib` — "No issues found!" (row 2).
- Full app suite: 351/351 green (includes the pre-existing `test/hub/hub_screen_test.dart`, which still passes under the uniform grid).
- `grep "home: const HubScreen" lib/main.dart` matches; `grep "height: 96" lib/hub/hub_screen.dart` empty (no full-width primary row).
- On-device checks (dashboard-is-home, quick-bar navigation, keep-awake ref-count across Presenter→quick-bar→Trackpad→back) are the PHASE gate, per the plan.

## Threat Model Disposition

- **T-07-29 (Spoofing/UI — offline tiles):** mitigated — offline tiles are visibly disabled (`onTap: null`, muted, no ripple) so no action can fire into a dead connection; tool screens keep their own send gates as the second line.
- **T-07-30 (Info disclosure — device name in app bar):** accepted per plan (already-shipped hub behavior; no token/secret).
- **T-07-SC (Tampering — package installs):** held — zero new packages.

## Known Stubs

None — all tiles, the gear, the quick-bar, and the banner host are wired to real screens/services.

## Next Steps

- 07-08 (final incomplete plan): server-side revoke push path.
- Phase UAT gate: on-device verification of the dashboard identity + quick-bar + keep-awake ref-count path.

## Self-Check: PASSED

- `lib/keyboard/keyboard_screen.dart` — FOUND
- `lib/widgets/quick_bar_scaffold.dart` — FOUND
- `test/hub_tiles_test.dart` / `test/hub_offline_test.dart` / `test/quick_bar_test.dart` — FOUND
- Commits 029d1c5, 44725fc — FOUND in `git log`
