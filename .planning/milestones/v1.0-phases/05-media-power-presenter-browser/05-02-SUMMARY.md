---
phase: 05-media-power-presenter-browser
plan: 02
subsystem: ui
tags: [flutter, riverpod, navigation, browser, hub, material]

# Dependency graph
requires:
  - phase: 04-trackpad-keyboard
    provides: MouseButtonsBar callback pattern, key-cap pressed chrome, sendReliable + haptic press pattern, header chip/banner chrome
  - phase: 03-discovery-pairing-reconnect
    provides: ConnectionService (sendReliable, target, retryNow), connectionStatusProvider, ConnectionHeaderChip/ReconnectingBannerSlot
  - phase: 01-protocol-contract
    provides: BrowserMsg codec + server router browser_macro table (the 7-action vocabulary)
provides:
  - HubScreen with ordered kHubTiles registry (Trackpad full-width primary FIRST, Browser second) — the Phase-7 dashboard skeleton
  - HubTileGrid that chunks any tile count (05-04/05-06/05-07 insert tiles with zero structural change)
  - BrowserScreen + kBrowserActions (7 specs byte-matching router.rs) + BrowserMacroGrid (onAction/enabled callback widget)
  - Device-list reroute — one _openHub helper replaces both TrackpadScreen push sites (D-02)
affects: [05-04, 05-06, 05-07, 07-polish-dashboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Tool-screen skeleton: ConsumerStatefulWidget + cached _service + app bar chip + ReconnectingBannerSlot + gated callback grid"
    - "Ordered spec-list registry rendered by a growth-ready grid (kHubTiles)"

key-files:
  created:
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/lib/browser/browser_screen.dart
    - app/remote_control/test/hub/hub_screen_test.dart
    - app/remote_control/test/browser/browser_screen_test.dart
  modified:
    - app/remote_control/lib/screens/device_list_screen.dart

key-decisions:
  - "Browser grid rows derive from kBrowserActions with a data-driven pairing rule (refresh renders full-width) — no per-button layout hardcoding"
  - "kHubTiles is a final (non-const) list because tile builders reference screen constructors; registry order IS the render order"
  - "Hub tiles fire onAction-style onOpen(spec) callbacks so widget tests never touch the Navigator (MouseButtonsBar house pattern)"

patterns-established:
  - "Tool-screen pattern proven end-to-end: header chip + banner + sendReliable + haptic-on-press-down + gated-muted disabled state"
  - "Tile registry growth: later plans insert HubTileSpec entries; the grid chunks whatever it is given"

requirements-completed: [BROW-01]

# Metrics
duration: 8min
completed: 2026-07-11
---

# Phase 5 Plan 02: Hub + Browser Slice Summary

**Interim Remote hub (Phase-7 dashboard skeleton) replaces the row-tap→trackpad route, and the Browser tool screen ships end-to-end against the existing server browser_macro table — first user-visible Phase-5 slice with zero server changes**

## Performance

- **Duration:** ~8 min
- **Started:** 2026-07-11T01:43:06Z
- **Completed:** 2026-07-11T01:51:30Z
- **Tasks:** 3 (Task 1 TDD RED + Task 2 GREEN + Task 3)
- **Files modified:** 5

## Accomplishments

- `HubScreen` with the ordered `kHubTiles` registry: Trackpad full-width primary tile FIRST, Browser half-width — `HubTileGrid` chunks any tile count, so 05-04/05-06/05-07 and Phase 7 grow it in place with no structural change (D-01)
- `BrowserScreen` (BROW-01) end-to-end: `kBrowserActions` pins the 7 exact router action strings (back/forward/newtab/closetab/refresh/zoomin/zoomout), buttons fire `sendReliable(BrowserMsg(...))` + haptic on press-down, gated-muted when not connected
- Both device-list navigation call sites rerouted through one `_openHub` helper (D-02, Pitfall 14); `TrackpadScreen` import removed, D-01 silent-reconnect launch kick still performs NO navigation
- Header chip + reconnecting banner mounted on both new screens (D-02)

## Task Commits

Each task was committed atomically:

1. **Task 1: Failing tests — browser action vocabulary + hub tile grid** - `ecd7b6c` (test, TDD RED)
2. **Task 2: HubScreen + BrowserScreen implementation** - `39a6512` (feat, TDD GREEN)
3. **Task 3: Reroute device list to the hub (both call sites)** - `1990f7a` (feat)

## TDD Gate Compliance

- RED gate: `ecd7b6c` — both test files failed to load (lib files absent), verified before implementation
- GREEN gate: `39a6512` — all 5 new tests pass, `flutter analyze --no-pub` clean
- REFACTOR: not needed — implementation landed clean on the first pass

## Files Created/Modified

- `app/remote_control/lib/hub/hub_screen.dart` - HubScreen + HubTileSpec + kHubTiles registry + HubTileGrid (growth-ready, Trackpad-first primary)
- `app/remote_control/lib/browser/browser_screen.dart` - BrowserScreen + BrowserActionSpec + kBrowserActions (7 router actions) + BrowserMacroGrid key-cap grid
- `app/remote_control/lib/screens/device_list_screen.dart` - `_openHub` helper replacing both TrackpadScreen push sites
- `app/remote_control/test/hub/hub_screen_test.dart` - registry order (Trackpad first) + label render + tap-fires-entry
- `app/remote_control/test/browser/browser_screen_test.dart` - vocabulary byte-match vs router.rs + per-label tap recording + disabled inertness

## Decisions Made

- Browser grid layout derives from the spec list with one data rule (`refresh` renders full-width) instead of hardcoded rows — the vocabulary list stays the single source of truth
- `kHubTiles` is `final` (not `const`) because tile builders close over screen constructors; registry order is render order
- Browser buttons reuse the exact `_MouseButton` press mechanics (fire on tap-DOWN, momentary accent flash, no easing) for benchmark-consistent feel across all key-cap surfaces

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The tool-screen pattern (chip + banner + sendReliable + haptics + gated-muted) is proven end-to-end — 05-04 (Media), 05-06 (Power), 05-07 (Presenter) plug into it directly
- `kHubTiles` accepts new entries at any position; each remaining tool plan inserts exactly one tile
- Browser feature is live against the 04-02 server keymap; the zoom-chord check (Pitfall 11/A2 — Ctrl+'=' fallback) is deferred to the end-of-phase on-device gate

---
*Phase: 05-media-power-presenter-browser*
*Completed: 2026-07-11*

## Self-Check: PASSED

All claimed files exist on disk; all three task commits (ecd7b6c, 39a6512, 1990f7a) verified in git log.
