---
phase: 03-discovery-pairing-connection
plan: 06
subsystem: client-ui
tags: [flutter, dart, riverpod, device-list, pairing, ui-spec, copywriting, tdd]

# Dependency graph
requires:
  - phase: 03-discovery-pairing-connection
    provides: "03-03: DeviceStore (loadDevices/isPaired/adoptGuid, manualDeviceKey); 03-04: Beacon (source-derived host) + BeaconListener broadcast stream; 03-05: ConnectionService (connectTo/feedPin/lastDialError/lastAuthFailure/pairingExplanation) + connectionStatusProvider"
  - phase: 03-discovery-pairing-connection
    provides: "03-UI-SPEC.md locked visual/copy contract (spacing, 4-size/2-weight typography, color roles, Copywriting Contract table)"
provides:
  - "DeviceListModel: pure GUID-merge/7s-evict/stored-overlay/manual-adoption logic — fake-clock unit-proven, no Flutter/Riverpod imports used by the model class"
  - "DeviceListNotifier + deviceListProvider (Riverpod 3): BeaconListener scoped to provider lifecycle (Pitfall 8), 2s sweep Timer, adoptGuid migration, listEquals-guarded publishes"
  - "connection_copy.dart: single source of truth for every UI-SPEC copy string + pairingErrorCopy whitelist mapping (raw enums never rendered)"
  - "DeviceListScreen: phase home — live rows, grayed remembered rows, empty state with scan spinner, Connect-by-IP TextButton + sheet reusing the shared connect path"
  - "PairingSheet + showPairingSheet: PIN sheet with reason-mapped errors, lockout countdown, fresh-dial retry model, auto-close on authed"
affects: [03-07 launch wiring (home -> DeviceListScreen, attachBeacons, header chip, trackpad slimming)]

# Tech tracking
tech-stack:
  added: []
  patterns: ["entry equality excludes volatile timestamps so unchanged beacons produce an equal list (no per-packet churn)", "sheet rebuilt via StreamBuilder over service.changes because handshake sub-status (needPin) never alters the coarse ConnectionStatus snapshot", "transition-edge detection (prev-state snapshots) before auto-opening modals so a dismissed sheet never loops back open", "reserved fixed-height error line so sheets never resize when errors appear"]

key-files:
  created:
    - app/remote_control/lib/store/device_list_store.dart
    - app/remote_control/lib/screens/connection_copy.dart
    - app/remote_control/lib/screens/device_list_screen.dart
    - app/remote_control/lib/screens/pairing_dialog.dart
    - app/remote_control/test/device_list_store_test.dart
    - app/remote_control/test/pairing_flow_test.dart
  modified: []

key-decisions:
  - "DeviceListEntry ==/hashCode exclude lastSeenMillis — the anti-churn contract lives in equality itself, so the Notifier's listEquals guard suppresses per-packet rebuilds for free"
  - "deviceStoreProvider added in device_list_store.dart (03-05's connectionServiceProvider builds its own inline DeviceStore over the same storage — equivalent state, no refactor of shipped code)"
  - "Connected-row marker: Notifier listens to service.changes and sets model.connectedKey — the screen renders entry.connected with no provider coupling of its own"
  - "Firewall copy fires only when a dial fails AND a live beacon row exists at that host (deviceListProvider liveness check) — otherwise the generic transport copy with ip:port"
  - "Post-authFail submit stores the PIN as pending, triggers a fresh connectTo, and auto-feeds on the new needPin (didUpdateWidget edge) — one tap, not two, despite the terminal client handshake FSM"

patterns-established:
  - "Copy contract module: screens import connection_copy.dart consts/functions; zero inline user-facing literals in widget files"
  - "Pure model + thin Notifier split for list state: all logic testable with a fake clock, seams (listener/timer/storage) live only in build()"

requirements-completed: [CONN-01, CONN-02, CONN-05]

# Metrics
duration: ~17min
completed: 2026-07-09
---

# Phase 3 Plan 06: Device List, Pairing Sheet & Connect-by-IP Summary

**The phase's user-facing home: a GUID-merged live device list with 7s gray-out and manual->GUID adoption, the PIN pairing sheet rendering every authFail reason's locked UI-SPEC copy with a live lockout countdown, and Connect by IP as a TextButton secondary affordance reusing the shared connect path**

## Performance

- **Duration:** ~17 min
- **Started:** 2026-07-08T19:31:07Z
- **Completed:** 2026-07-08T19:47Z (2026-07-09 IST)
- **Tasks:** 3 (Tasks 1 and 3 TDD)
- **Files modified:** 6 created

## Accomplishments

- **CONN-01 client UX proven:** two beacons with one GUID merge to one row (new host wins — PC IP change recovery); two GUIDs sharing a name stay distinct rows; eviction is strictly >7000ms of silence (~3 missed 2s intervals) — remembered rows gray out at their last-known address, discovery-only unpaired rows disappear
- **No per-packet churn (T-03-22):** an unchanged beacon produces an entries list equal to the previous one; the Notifier publishes only on real change (listEquals guard) so rows never blink
- **Manual->GUID adoption (D-03):** a beacon whose SOURCE host matches a stored `manual:<host>:<port>` row fires `DeviceStore.adoptGuid` exactly once (idempotence set), then the stored overlay re-syncs — manual connections converge with discovery
- **CONN-02 copy contract locked in code:** `pairingErrorCopy` maps every reason to its exact UI-SPEC string (plural/singular attempts, countdown seconds, the D-05 revoked line imported from reconnect_fsm.dart — single definition); unknown reasons get a generic retry line; widget tests negatively assert `badMac`/`noPairing` never render
- **CONN-05 manual entry:** Connect-by-IP sheet validates locally (kInvalidManualInputCopy), then calls the SAME `connectTo` with a manual key; inline error distinguishes RFC1918 guard refusal, firewall-shaped failure (live beacon + dead ws port), and generic transport failure with ip:port
- **Pairing UX complete:** Pair disabled until 6 digits, reserved error line (sheet height identical with/without error), lockout ticker disables field+button until zero then re-enables, fresh-dial retry auto-feeds the collected PIN, sheet auto-closes on authed and opens on needPin / revoked transitions from the device list

## Task Commits

Each task was committed atomically (TDD: test → feat):

1. **Task 1 (RED): failing DeviceListModel suite** - `38bf1d8` (test)
2. **Task 1 (GREEN): DeviceListModel + DeviceListNotifier** - `651bb59` (feat)
3. **Task 2: device list screen + Connect-by-IP sheet + copy contract** - `259ee11` (feat)
4. **Task 3 (RED): failing pairing sheet + reason-copy suite** - `0397511` (test)
5. **Task 3 (GREEN): PairingSheet + screen wiring** - `d3e3dbb` (feat)

_No REFACTOR commits — GREEN implementations needed no cleanup._

## Files Created/Modified

- `app/remote_control/lib/store/device_list_store.dart` - `DeviceListEntry` (equality excludes lastSeenMillis), pure `DeviceListModel` (onBeacon/sweep/mergeStored/entries, kBeaconEvictMillis=7000, onAdopt seam), `DeviceListNotifier`/`deviceListProvider`/`deviceStoreProvider`
- `app/remote_control/lib/screens/connection_copy.dart` - every Copywriting Contract string as const + `pairingErrorCopy`, `transportFailedCopy`, device-row metadata line builders
- `app/remote_control/lib/screens/device_list_screen.dart` - `DeviceListScreen` (64px rows, per-state metadata, accent literal only on the connected icon), empty state, `_ConnectByIpSheet`, needPin/revoked sheet-open wiring
- `app/remote_control/lib/screens/pairing_dialog.dart` - `PairingSheet` (constructor-injected state, lockout ticker, pending-PIN retry) + `showPairingSheet` (real-provider wiring, StreamBuilder over changes, auto-close on authed)
- `app/remote_control/test/device_list_store_test.dart` - 15 cases across the 6 behavior groups, fake clock throughout
- `app/remote_control/test/pairing_flow_test.dart` - 16 cases: pairingErrorCopy table + widget contract (field typography, disable/enable, error red, reserved space, countdown, retry model, negative enum assertions)

## Decisions Made

- Entry equality excludes `lastSeenMillis` so anti-churn falls out of `listEquals` — no separate dirty-tracking
- Added `deviceStoreProvider` here rather than refactoring 03-05's inline store construction; both operate on the same underlying prefs/keystore
- The Notifier (not the screen) tracks the connected row via `service.changes` → `model.connectedKey`
- Firewall copy requires BOTH a failed dial AND current liveness at that host in `deviceListProvider`
- `showPairingSheet` rebuilds via `StreamBuilder` over `service.changes` because `ConnectionStatus` is value-equal and needPin/failure transitions don't change it (coarse chip+fsmState only)
- Device list opens the pairing sheet on transition edges (prev-state snapshots), so dismissing it doesn't re-trigger on later unrelated pings

## Deviations from Plan

None material — plan executed as written. One pre-execution housekeeping item:

**[Rule 3 - Blocking] Restored stale .planning/STATE.md from HEAD**
- **Found during:** execution start (before Task 1)
- **Issue:** the working tree carried an uncommitted STATE.md that regressed committed 03-05 completion data (Plan: 1 of 7, 29% vs the committed Plan: 5 of 7, 31%) — end-of-plan state updates would have computed from stale counters
- **Fix:** targeted single-file `git checkout -- .planning/STATE.md` back to the authoritative committed version (2f15477)
- **Files modified:** .planning/STATE.md (restore only)
- **Commit:** n/a (restore of committed content)

## Issues Encountered

- One lint round-trip: `dart:ui show FontFeature` import was redundant (material re-exports it) — removed before the Task 3 commit, analyze clean

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 03-07 (launch wiring) can now: set `home: DeviceListScreen` (D-01 auto-reconnect + device-list fallback), call `service.attachBeacons` with the listener stream for the backoff short-circuit, build the header chip off `connectionStatusProvider`, and slim trackpad_screen.dart to a ConnectionService consumer
- The pairing sheet self-wires from the device list (needPin + revoked transitions) — 03-07 only needs navigation/home composition
- All 139 tests green; every user-facing string routes through connection_copy.dart, so 03-07's banner ("Reconnecting…", "Retry now") copy already exists

## Verification Results

- `flutter analyze` — no issues
- `flutter test` — 139/139 green (15 new device-list cases, 16 new pairing cases, all prior suites untouched)
- `grep -c "StateNotifier" device_list_store.dart` — 0; `kBeaconEvictMillis` == 7000 (suite-asserted)
- `Color(0xFF4C8DFF)` literal appears once in device_list_screen.dart (connected row icon); 'Connect by IP' is a TextButton.icon, never FilledButton
- Rows `SizedBox(height: 64)`; TextButton `minimumSize: Size(48, 48)`; sheet FilledButtons in 48px SizedBoxes
- Every UI-SPEC reason row asserted (pinInvalid plural+singular, pinExpired, lockedOut countdown, noPairing, badMac, versionMismatch); raw enums negatively asserted in rendered text
- TDD gates: RED `38bf1d8` → GREEN `651bb59`; RED `0397511` → GREEN `d3e3dbb` — sequences valid

## Self-Check: PASSED

- `app/remote_control/lib/store/device_list_store.dart` — FOUND
- `app/remote_control/lib/screens/connection_copy.dart` — FOUND
- `app/remote_control/lib/screens/device_list_screen.dart` — FOUND
- `app/remote_control/lib/screens/pairing_dialog.dart` — FOUND
- `app/remote_control/test/device_list_store_test.dart` — FOUND
- `app/remote_control/test/pairing_flow_test.dart` — FOUND
- Commit `38bf1d8` — FOUND
- Commit `651bb59` — FOUND
- Commit `259ee11` — FOUND
- Commit `0397511` — FOUND
- Commit `d3e3dbb` — FOUND

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-09*
