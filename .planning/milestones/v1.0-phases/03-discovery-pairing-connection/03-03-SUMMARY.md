---
phase: 03-discovery-pairing-connection
plan: 03
subsystem: storage
tags: [flutter, flutter_secure_storage, shared_preferences, tdd, secrets, multi-pc]

# Dependency graph
requires:
  - phase: 02-end-to-end-cursor-spike
    provides: "In-memory token spike (D-09 removable) + latency_probe.dart constructor-injection house style"
provides:
  - "DeviceStore: GUID-keyed multi-PC CRUD — tokens in flutter_secure_storage (token.<deviceKey>), metadata in shared_preferences ('devices' JSON map + 'lastDeviceGuid' pointer)"
  - "SecureKv/PrefsKv injected seams + real adapters (SecureStorageKv v10 defaults, SharedPrefsKv over SharedPreferencesAsync)"
  - "Pitfall-5 keystore-invalidation fallback: PlatformException -> unpaired + dead-entry cleanup, never a crash"
  - "manualDeviceKey('h', p) -> manual:<host>:<port> synthetic keys + adoptGuid migration for D-03 manual connections"
affects: [03-05 ConnectionService (reads tokens per device key), 03-06 device list (loadDevices/adoptGuid), 03-04 pairing flow (saveToken)]

# Tech tracking
tech-stack:
  added: [flutter_secure_storage 10.3.1, shared_preferences 2.5.5]
  patterns: ["storage seams constructor-injected (SecureKv/PrefsKv) so tests run on fakes incl. PlatformException-armed secure store", "secrets discipline: DeviceMeta has no token field by construction; test asserts no token substring in prefs JSON"]

key-files:
  created:
    - app/remote_control/lib/store/device_store.dart
    - app/remote_control/test/device_store_test.dart
  modified:
    - app/remote_control/pubspec.yaml
    - app/remote_control/pubspec.lock

key-decisions:
  - "loadDevices returns Map<String, DeviceMeta> keyed by deviceKey; DeviceMeta.toJson excludes the key (it is the enclosing JSON map key) so the prefs schema byte-matches RESEARCH Pattern 7"
  - "SharedPrefsKv wraps SharedPreferencesAsync (current 2.5.x API), kept thin so the API choice is invisible to DeviceStore"
  - "deleteToken swallows PlatformException like the read path — every SecureKv read/delete is Pitfall-5-wrapped, writes stay raw so pairing failures surface"

patterns-established:
  - "Pattern 7 storage schema: secure 'token.<deviceKey>', prefs 'devices' JSON object + 'lastDeviceGuid' string pointer"
  - "Manual-connection identity: manual:<host>:<port> synthetic keys, adoptGuid re-keys token+meta+pointer on beacon sighting"

requirements-completed: [CONN-03]

# Metrics
duration: 8min
completed: 2026-07-08
---

# Phase 3 Plan 03: GUID-Keyed Device Store Summary

**GUID-keyed multi-PC DeviceStore: raw tokens only in flutter_secure_storage 10.3.1 (`token.<deviceKey>`), metadata in shared_preferences Pattern-7 JSON, PlatformException keystore fallback test-proven, plus manual:<host>:<port> keys with adoptGuid migration**

## Performance

- **Duration:** 8 min
- **Started:** 2026-07-08T13:49:24Z
- **Completed:** 2026-07-08T13:57:06Z
- **Tasks:** 2 (TDD RED + GREEN)
- **Files modified:** 4

## Accomplishments

- Replaced the Phase-2 in-memory token (D-10 spec-locked) with per-device-GUID persistence that survives app restarts — the storage half of CONN-03 silent reconnect
- 17-test fake-backed suite: token round-trip, keystore-invalidation degradation (Pitfall 5 / flutter_secure_storage issue #853), metadata round-trip, lastDeviceGuid pointer, manualDeviceKey/adoptGuid migration, and a secrets-discipline assertion that no 16-char token slice ever appears in the prefs JSON
- Multi-PC memory (D-07) ready for the 03-06 device list: `loadDevices` map, `upsertDevice`/`removeDevice`, last-device pointer for D-01 auto-reconnect
- Manual-connection identity (D-03): by-IP entries stored under `manual:<host>:<port>`; `adoptGuid` moves token + metadata + pointer to the real GUID once a beacon identifies the PC

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): Fake-seam test suite for DeviceStore** - `a6f2ea8` (test) — 17 failing tests + UnimplementedError stubs + both deps added
2. **Task 2 (GREEN): Implement DeviceStore + real adapters** - `8bcad81` (feat) — full implementation, all 81 project tests green

_No REFACTOR commit — the GREEN implementation needed no cleanup._

## Files Created/Modified

- `app/remote_control/lib/store/device_store.dart` - SecureKv/PrefsKv seams, SecureStorageKv (v10 defaults, no options overridden), SharedPrefsKv (SharedPreferencesAsync), DeviceMeta (no token field by construction), DeviceStore CRUD + adoptGuid, manualDeviceKey
- `app/remote_control/test/device_store_test.dart` - FakeSecureKv (throwOnRead/throwOnDelete arming, delete-attempt recording) + FakePrefsKv; 17 tests over 6 behaviors
- `app/remote_control/pubspec.yaml` - flutter_secure_storage ^10.3.1, shared_preferences ^2.5.5 (both Approved in the RESEARCH Package Legitimacy Audit)
- `app/remote_control/pubspec.lock` - resolved exactly 10.3.1 / 2.5.5

## Decisions Made

- `loadDevices` returns `Map<String, DeviceMeta>` keyed by deviceKey, and `DeviceMeta.toJson` excludes `key` — the prefs `devices` value schema matches RESEARCH Pattern 7 exactly (`{"name","host","port","lastConnectedAt"}`)
- `SharedPrefsKv` wraps `SharedPreferencesAsync` (the current 2.5.x API); the adapter is thin so DeviceStore never sees the choice
- `deleteToken` swallows `PlatformException` like the read path (every SecureKv read/delete is Pitfall-5-wrapped); `write` stays unwrapped so pairing-time save failures surface to the caller

## Deviations from Plan

None - plan executed exactly as written.

(One wording note, not a deviation: the SecureStorageKv doc comment originally named the deprecated v9 flag literally, which would have tripped the `grep -c "encryptedSharedPreferences" == 0` acceptance criterion; reworded to "the deprecated encrypted-prefs flag from v9" before the GREEN commit.)

## Issues Encountered

None.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 03-05 ConnectionService can read/write tokens per device key (`tokenFor`/`saveToken`) — CONN-03 persistence half done
- 03-06 device list has `loadDevices`, `lastDeviceKey`, and the `adoptGuid` migration for manual entries
- Real adapters (`SecureStorageKv`/`SharedPrefsKv`) are wired but untested on-device; keystore behavior on the owner's Xiaomi should be sanity-checked when 03-05 integrates (fallback path is test-proven)

## Verification Results

- `flutter test` — all 81 tests green (17 new device_store + 64 existing)
- `flutter analyze` on both new files — no issues
- `grep -c "encryptedSharedPreferences" lib/store/device_store.dart` — 0
- Token strings flow only through `_secure.read/write/delete`; `DeviceMeta.toJson` has no token field; secrets test asserts no token slice in prefs JSON
- TDD gates: RED `a6f2ea8` (`test(03-03)`) → GREEN `8bcad81` (`feat(03-03)`) — sequence valid

## Self-Check: PASSED

- `app/remote_control/lib/store/device_store.dart` — FOUND
- `app/remote_control/test/device_store_test.dart` — FOUND
- Commit `a6f2ea8` — FOUND
- Commit `8bcad81` — FOUND

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-08*
