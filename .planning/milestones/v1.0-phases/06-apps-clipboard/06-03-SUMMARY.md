---
phase: 06-apps-clipboard
plan: 03
subsystem: ui
tags: [flutter, riverpod, apps, favorites, shared_preferences, websocket, protocol]

# Dependency graph
requires:
  - phase: 06-apps-clipboard
    provides: "protocol 1.2 WindowInfo icon/path fields, apps.changed push seam, err{windowGone|launchFailed}, window_info golden fixtures (06-01)"
  - phase: 05-control-center
    provides: "VolumeSnapshot value-equal park + VolumeNotifier template, media_screen scaffold, kHubTiles registry, PrefsKv/device_store persistence seam"
provides:
  - "Dart WindowInfo icon/path mirror (protocol 1.2) with tolerant _windowList parse + value equality; window_info fixture group"
  - "ConnectionService AppsSnapshot value-equal park + appsSnapshot getter; _lastError/lastError getter; _onFrame arms for apps.changed/apps.list/err"
  - "FavoritesStore (PrefsKv key apps.favorites): pin/unpin/load, UWP path==null non-pinnable, dedupe-by-path, corruption-tolerant"
  - "AppsViewState value-equal view + AppsNotifier (subscribe/re-snapshot) with focus/close/launch/pin/unpin/primeList; appsStateProvider"
  - "AppsScreen (favorites grid + open-windows list) per 06-UI-SPEC; Apps hub tile after Media"
affects: [06-07 on-device UAT, Phase-7 dashboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Value-equal S->C snapshot park in ConnectionService -> changes ping -> Notifier re-snapshot (cloned from VolChanged/VolumeNotifier)"
    - "err frame parked but NOT returned early — still forwarded to handshake driver so err{versionMismatch} keeps working"
    - "Client-side favorites via PrefsKv only (non-secret, D-02); pin path originates from server-resolved WindowInfo.path (T-06-04)"
    - "err-toast surfaced off the raw service.changes stream (identity-tracked) since the value-equal view never rebuilds on an err park"

key-files:
  created:
    - "app/remote_control/lib/apps/apps_store.dart"
    - "app/remote_control/lib/apps/apps_screen.dart"
    - "app/remote_control/test/apps/apps_store_test.dart"
  modified:
    - "app/packages/remote_protocol/lib/src/json_codec.dart"
    - "app/packages/remote_protocol/test/fixture_test.dart"
    - "app/remote_control/lib/net/connection_service.dart"
    - "app/remote_control/test/connection_service_test.dart"
    - "app/remote_control/lib/hub/hub_screen.dart"

key-decisions:
  - "err frames are parked as _lastError AND forwarded to the handshake driver (not returned early) so err{versionMismatch} still reaches handshake_fsm"
  - "AppsSnapshot/AppsViewState equality is hand-rolled element-wise (no package:collection dependency — collection is not a direct dep and no new packages this plan, T-06-SC)"
  - "The Apps screen surfaces err toasts off the raw service.changes stream with identity-tracked dedupe, because the value-equal AppsViewState does not rebuild on an err park"
  - "err.msg (operator-facing prose from 06-01) shown verbatim in toasts — it already omits HWND/path (T-06-14), so no client re-templating needed"

patterns-established:
  - "Optional additive Dart protocol field: Option<String> mirror via _opt in _windowList + skip-none toJson keeps legacy decode + value equality"
  - "FavoritesStore.load returns a GROWABLE list (never const []) so pin/unpin can mutate in place"
  - "Pressed-accent-flash tile/row widgets (fire on tap-down + haptic) cloned from media_screen _TransportButton"

requirements-completed: [APPS-01, APPS-02, APPS-03]

# Metrics
duration: 30min
completed: 2026-07-11
---

# Phase 6 Plan 03: Apps Client Screen Summary

**The Apps screen — a client-side favorites launch grid over the live running-window list — wired to the 06-01 contract: Dart WindowInfo icon/path mirror, a value-equal AppsSnapshot park + err arms in ConnectionService, a PrefsKv favorites store (UWP-safe, dedupe-by-path), and an AppsScreen with focus/close/pin/launch through sendReliable.**

## Performance

- **Duration:** ~30 min
- **Completed:** 2026-07-11
- **Tasks:** 3 (2 TDD)
- **Files modified:** 8 (3 created, 5 modified)

## Accomplishments
- **Dart protocol 1.2 mirror:** `WindowInfo` gains optional `icon`/`path` with a tolerant `_windowList` parse (absent → null, unknown fields dropped — D-05), skip-none `toJson`, and value equality; both `window_info` golden fixtures (01-with-icon-path, 02-legacy) decode and round-trip through the shared harness.
- **ConnectionService push seam:** value-equal `AppsSnapshot` (element-wise ==) parked from `apps.changed` and the `apps.list` reply; `_lastError`/`lastError` parked from `err`; the `err` arm forwards to the handshake driver so `err{versionMismatch}` still fails the handshake.
- **Favorites store:** `FavoritesStore` over `PrefsKv` (`apps.favorites`) — `pin` rejects UWP (`path==null`), dedupes by path, `unpin` by path, corruption-tolerant load; `Favorite` model + value-equal `AppsViewState` + `AppsNotifier` cloning `VolumeNotifier`.
- **Apps screen + hub tile:** `AppsScreen` renders the favorites grid (≥64px tiles, pin marker, tap→launch, long-press→unpin) over the open-windows list (server Z-order, ≥56px rows, tap→focus, close button, long-press→pin/UWP toast), decoded base64 PNG icons with a `desktop_windows` fallback, empty states + inline hint per UI-SPEC, primes `apps.list` on open, and surfaces err toasts; the Apps `HubTileSpec` lands after Media, before Power.

## Task Commits

Each task was committed atomically (TDD tasks: test → feat):

1. **Task 1 (RED): window_info fixture + AppsSnapshot/err arm cases** - `35203fb` (test)
2. **Task 1 (GREEN): WindowInfo icon/path mirror + ConnectionService AppsSnapshot/err arms** - `11c2ad2` (feat)
3. **Task 2 (RED): FavoritesStore + AppsViewState cases** - `41ced03` (test)
4. **Task 2 (GREEN): AppsNotifier + favorites PrefsKv store** - `1776dd4` (feat)
5. **Task 3: Apps screen (favorites grid + open-windows list) + hub tile** - `c9ac453` (feat)

## Files Created/Modified
- `app/packages/remote_protocol/lib/src/json_codec.dart` - WindowInfo icon/path fields, tolerant `_windowList`, skip-none toJson, ==/hashCode
- `app/packages/remote_protocol/test/fixture_test.dart` - `window_info` fixture group
- `app/remote_control/lib/net/connection_service.dart` - AppsSnapshot class, `_appsSnapshot`/`_lastError` fields + getters, `_onFrame` apps.changed/apps.list/err arms
- `app/remote_control/test/connection_service_test.dart` - apps snapshot value-equality + err park cases
- `app/remote_control/lib/apps/apps_store.dart` - Favorite, FavoritesStore, AppsViewState, AppsNotifier, providers (created)
- `app/remote_control/test/apps/apps_store_test.dart` - FavoritesStore + AppsViewState tests (created)
- `app/remote_control/lib/apps/apps_screen.dart` - AppsScreen + tiles/rows/close-button/icon/empty-state widgets (created)
- `app/remote_control/lib/hub/hub_screen.dart` - Apps HubTileSpec inserted after Media

## Decisions Made
- **err parked AND forwarded (not returned early).** Unlike the pure S→C `vol.changed`/`apps.changed` arms, the `err` arm sets `_lastError` + notifies but falls through to the handshake driver, so a handshake-phase `err{versionMismatch}` still reaches `handshake_fsm`'s terminal-fail path. Verified: the full app suite (291 tests) stays green.
- **Hand-rolled list equality, no new package.** `AppsSnapshot`/`AppsViewState` compare element-wise by hand rather than pulling `package:collection` (not a direct dependency; T-06-SC accepts no new packages this plan).
- **err toasts off the raw changes stream.** The value-equal `AppsViewState` never rebuilds on an `err` park, so the screen subscribes to `service.changes` directly and shows a toast when `service.lastError` is a new instance (identity-tracked dedupe).
- **`err.msg` shown verbatim.** The server prose is already operator-facing and omits HWND/path (06-01, T-06-14), so the toast uses it directly with no client re-templating.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] FavoritesStore.load returned a const (unmodifiable) list**
- **Found during:** Task 2 (GREEN, running apps_store_test)
- **Issue:** `load()` returned `const []` on the empty/corrupt paths; `pin`'s `favs.add(...)` and `unpin`'s `removeWhere` then threw `Unsupported operation: Cannot add to an unmodifiable list`.
- **Fix:** Return growable `<Favorite>[]` on both the null-blob and corrupt-blob paths.
- **Files modified:** app/remote_control/lib/apps/apps_store.dart
- **Verification:** `flutter test test/apps/apps_store_test.dart` → 8/8 pass
- **Committed in:** `1776dd4` (Task 2 GREEN commit)

**2. [Rule 3 - Blocking] errorBuilder wildcard lint**
- **Found during:** Task 3 (flutter analyze lib/apps)
- **Issue:** `errorBuilder: (_, __, ___)` tripped `unnecessary_underscores` (2 infos).
- **Fix:** Switched to single-underscore wildcards `(_, _, _)`.
- **Files modified:** app/remote_control/lib/apps/apps_screen.dart
- **Verification:** `flutter analyze lib/apps lib/hub` → No issues found
- **Committed in:** `c9ac453` (Task 3 commit)

---

**Total deviations:** 2 auto-fixed (1 bug, 1 blocking)
**Impact on plan:** Both mechanical fixes surfaced by the tests/analyzer. No scope creep.

## Issues Encountered
- None beyond the two auto-fixed items above. Full suite: `remote_protocol` 10 tests + `remote_control` 291 tests green; `flutter analyze lib/apps lib/hub` clean.

## Known Stubs
- None. Real focus/close/launch behavior + live icon rendering are on-device UAT (06-07) — the wire path is fully implemented; only the physical-device confirmation is pending, which is not a stub.

## Threat Flags
None — no new security surface beyond the plan's threat register. Favorites are pinned only from a server-resolved `WindowInfo.path` (no manual-path field anywhere; T-06-04), stored in shared_preferences via PrefsKv (never SecureKv; T-06-15), and err toasts show operator-facing prose with no HWND/path (T-06-14). No new packages (T-06-SC).

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The Apps slice is code-complete on the phone end-to-end (contract 06-01 + server 06-02 + client 06-03). 06-07 on-device UAT can exercise live focus/close/launch, live `apps.changed` refresh, favorites pin/relaunch, and icon rendering against a real server.
- No blockers. The Clipboard track (06-04/05/06) is independent and unaffected.

---
*Phase: 06-apps-clipboard*
*Completed: 2026-07-11*

## Self-Check: PASSED

- Created files verified on disk: apps_store.dart, apps_screen.dart, apps_store_test.dart, 06-03-SUMMARY.md
- Task commits verified in git log: 35203fb, 11c2ad2, 41ced03, 1776dd4, c9ac453
