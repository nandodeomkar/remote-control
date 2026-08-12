---
phase: 03-discovery-pairing-connection
plan: 04
subsystem: client-discovery
tags: [flutter, dart, udp, rawdatagramsocket, multicastlock, methodchannel, network-security-config, tdd, fixtures]

# Dependency graph
requires:
  - phase: 03-discovery-pairing-connection
    provides: "03-01: protocol/BEACON.md wire contract + 6 shared fixtures + server-core broadcaster (2s interval, UDP 17778)"
  - phase: 02-end-to-end-cursor-spike
    provides: "Trackpad manual-IP connect path (cleartext smoke vehicle) + _onFrame total-parse posture"
provides:
  - "Beacon model + strict total-parse Beacon.tryParse (kBeaconPort 17778, kMaxBeaconBytes 512) — byte-compatible with the Rust encoder via shared fixtures"
  - "BeaconListener: RawDatagramSocket wrapper exposing Stream<Beacon> with paired MulticastLock lifecycle (acquire before bind, release with socket, idempotent start/stop)"
  - "MulticastLock MethodChannel client ('remote_control/multicast') + MainActivity.kt handler (rc-discovery lock, reference-counting off)"
  - "D-10 cleartext swap: usesCleartextTraffic manifest flag replaced by scoped network_security_config.xml (base-config cleartext, CIDR-impossible rationale documented)"
  - "beacon_smoke_main.dart permanent field-diagnostic entrypoint (flutter run -t lib/dev/beacon_smoke_main.dart)"
  - "HARDWARE PROOF: beacon reception + cleartext ws:// verified on the owner's Xiaomi 25080RABDI (Android 16 / HyperOS) — carried STATE concern RETIRED"
affects: [03-05 ConnectionService (beaconSighted events + RFC1918 guard companion to the XML), 03-06 device list (Stream<Beacon> feed), 03-07 launch wiring]

# Tech tracking
tech-stack:
  added: []
  patterns: ["untrusted-datagram posture: size cap BEFORE parse, total parse inside try, null = silent drop, no throw paths (mirrors trackpad _onFrame)", "injectable seams: BeaconSocketBind typedef + optional MulticastLock ctor arg, production defaults construct the real ones", "MethodChannel platform shims no-op on MissingPluginException so unit tests and non-Android hosts never fail", "dev smoke entrypoints live in lib/dev/ with module doc marking them non-product"]

key-files:
  created:
    - app/remote_control/lib/net/beacon.dart
    - app/remote_control/lib/net/beacon_listener.dart
    - app/remote_control/lib/platform/multicast_lock.dart
    - app/remote_control/lib/dev/beacon_smoke_main.dart
    - app/remote_control/test/beacon_test.dart
    - app/remote_control/android/app/src/main/res/xml/network_security_config.xml
  modified:
    - app/remote_control/android/app/src/main/kotlin/com/example/remote_control/MainActivity.kt
    - app/remote_control/android/app/src/main/AndroidManifest.xml

key-decisions:
  - "Beacon.host is ALWAYS the datagram source address — payload fields can never redirect where the client dials (T-03-13 spoof containment)"
  - "start() bind failure releases the MulticastLock and rethrows (paired lifecycle, retryable); the broadcast StreamController stays open across stop/start cycles"
  - "MulticastLock acquire/release are silent no-ops on MissingPluginException — the lock is OEM insurance, not a requirement, so tests and non-Android hosts need no fakes"
  - "network_security_config.xml keeps base-config cleartext permitted with the CIDR-impossible rationale in-file; the real LAN-only scoping is the ConnectionService RFC1918 code guard (03-05)"

patterns-established:
  - "Beacon validation order (both languages): size cap -> UTF-8 JSON object -> v==1 -> app discriminator -> typed fields -> unknown keys ignored"
  - "kDebugMode beacon debugPrint prints decoded fields only, never raw datagram bytes"

requirements-completed: [CONN-01] # client half — server half shipped in 03-01

# Metrics
duration: 11min + human checkpoint
completed: 2026-07-08
---

# Phase 3 Plan 04: Client Discovery (Beacon Decoder + Listener + Cleartext Swap) Summary

**Fixture-locked Dart beacon decoder + RawDatagramSocket listener with paired MulticastLock lifecycle, D-10 cleartext swap to scoped network_security_config — all proven on the owner's real Xiaomi: beacons arrive in seconds and ws:// still connects, retiring the phase's biggest carried concern**

## Performance

- **Duration:** ~11 min execution (22:25–22:37 IST) + human-verify checkpoint approved next session
- **Started:** 2026-07-08T16:55:37Z
- **Completed:** 2026-07-08T17:17:27Z (checkpoint approval)
- **Tasks:** 3 (1 TDD, 1 auto, 1 checkpoint:human-verify)
- **Files modified:** 8

## Accomplishments

- Dart decoder proven byte-compatible with the Rust encoder: all 6 shared `protocol/fixtures/beacon/` fixtures drive tests on both sides — the only new cross-language wire artifact this phase is drift-locked
- `Beacon.tryParse` is strict and total: 512-byte cap before parse, typed field checks (v==1, app discriminator, name/guid ≤64, port 1..65535), silent null-drop for everything else, zero throw paths (T-03-12)
- `BeaconListener` pairs the MulticastLock with the socket lifecycle exactly (acquire BEFORE bind, release on stop AND on bind failure — Pitfall 8: never held while authed off the list screen)
- Cleartext policy moved from the app-wide manifest flag to `network_security_config.xml` in a single commit (Pitfall 7), with `CHANGE_WIFI_MULTICAST_STATE` added and the stale "Phase 3 polish" comment updated
- **EARLY on-device checkpoint PASSED (owner-verified, Xiaomi 25080RABDI, Android 16 / HyperOS):**
  - Beacon reception CONFIRMED — smoke app listed the PC within seconds; continuous 2s-interval log lines `beacon: MSI 192.168.29.42:17777 guid=f2a0a1e9-…` captured from the device. No MulticastLock failure, no OEM broadcast filtering observed — the carried STATE concern (Xiaomi/HyperOS UDP reception) is RETIRED
  - Cleartext smoke CONFIRMED — normal `flutter run`, manual IP 192.168.29.42:17777 reached the pairing PIN prompt with no "Insecure HTTP is not allowed by platform" error: the D-10 XML swap works on-device

## Task Commits

Each task was committed atomically:

1. **Task 1 (RED): Failing beacon decode fixture tests** - `89313f0` (test)
2. **Task 1 (GREEN): Strict total-parse beacon decoder** - `ac05f8a` (feat)
3. **Task 2: Beacon listener + MulticastLock channel + cleartext swap + smoke entrypoint** - `e46d8a3` (feat)
4. **Task 3: EARLY on-device test (checkpoint:human-verify)** - no commit (human gate, approved with evidence above)

_No REFACTOR commit — the GREEN implementation needed no cleanup._

## Files Created/Modified

- `app/remote_control/lib/net/beacon.dart` - Beacon model + tryParse; kBeaconPort=17778 (matches DEFAULT_BEACON_PORT in server-core beacon.rs), kMaxBeaconBytes=512; host derived from datagram source only
- `app/remote_control/lib/net/beacon_listener.dart` - BeaconListener (Stream<Beacon>, idempotent start/stop, injectable BeaconSocketBind + MulticastLock seams, kDebugMode decoded-fields-only debugPrint)
- `app/remote_control/lib/platform/multicast_lock.dart` - MethodChannel client for `remote_control/multicast`; MissingPluginException no-ops
- `app/remote_control/lib/dev/beacon_smoke_main.dart` - standalone smoke entrypoint rendering beacon rows (name, host:port, guid, seen-count) on #0E0F12; kept as a permanent field-diagnostic tool
- `app/remote_control/test/beacon_test.dart` - fixture-driven suite (all 6 shared fixtures, fails if the fixture dir is empty) + constructed edge cases (513-byte, non-UTF8, non-object JSON, 65-char name, port 0/65536)
- `app/remote_control/android/.../MainActivity.kt` - `remote_control/multicast` handler: lazy `createMulticastLock("rc-discovery")`, `setReferenceCounted(false)`, release-only-if-held, notImplemented for unknown methods
- `app/remote_control/android/.../AndroidManifest.xml` - usesCleartextTraffic removed, networkSecurityConfig added, CHANGE_WIFI_MULTICAST_STATE permission added
- `app/remote_control/android/.../res/xml/network_security_config.xml` - base-config cleartext=true with the CIDR-impossible rationale; code-level private-range guard lands in 03-05

## Decisions Made

- `Beacon.host` always returns the datagram source address — a spoofed payload can trigger at most a connect attempt to its own sender, and challenge-response auth makes that useless (T-03-13)
- Bind failure in `start()` releases the lock and rethrows so a later `start()` can retry; the broadcast stream survives stop/start cycles for re-listening without re-subscription
- MulticastLock is treated as insurance: MissingPluginException is swallowed on both calls so unit tests and future non-Android hosts need no platform fakes
- The XML keeps cleartext permitted at base level (Android network-security-config cannot express IP ranges); the enforcement split with the 03-05 ConnectionService RFC1918 guard is documented in the XML comment itself

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered

None. Notably, the two feared failure modes did NOT occur on the target device: no OEM UDP-broadcast filtering (beacons arrived without incident) and no cleartext regression under the new XML config.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 03-05 ConnectionService can consume `Stream<Beacon>` for beaconSighted short-circuits and must ship the RFC1918 private-range dial guard the XML comment promises (D-10 second half)
- 03-06 device list has its live data source (BeaconListener) plus the GUID identity to key against the 03-03 DeviceStore (`adoptGuid` for manual entries)
- `beacon_smoke_main.dart` remains available for field diagnosis if discovery ever misbehaves on new networks
- T-03-14 transient acceptance stands: app-wide cleartext at XML level until the 03-05 code guard lands — do not defer that guard

## Verification Results

- `flutter test test/beacon_test.dart` — green (Task 1 GREEN gate); full `flutter test` + `flutter analyze` + `flutter build apk --debug` green at Task 2 commit
- `grep -c "throw" lib/net/beacon.dart` — 0 (total parse, no throw paths)
- Manifest assertions: usesCleartextTraffic 0, networkSecurityConfig 1, CHANGE_WIFI_MULTICAST_STATE 1
- BeaconListener.stop() closes the socket AND releases the lock (both calls present)
- TDD gates: RED `89313f0` (`test(03-04)`) → GREEN `ac05f8a` (`feat(03-04)`) — sequence valid
- Human checkpoint (Task 3): APPROVED — beacon rows within seconds on the Xiaomi; ws:// connect reached the PIN prompt under the new config

## Self-Check: PASSED

- `app/remote_control/lib/net/beacon.dart` — FOUND
- `app/remote_control/lib/net/beacon_listener.dart` — FOUND
- `app/remote_control/lib/platform/multicast_lock.dart` — FOUND
- `app/remote_control/lib/dev/beacon_smoke_main.dart` — FOUND
- `app/remote_control/test/beacon_test.dart` — FOUND
- `app/remote_control/android/app/src/main/res/xml/network_security_config.xml` — FOUND
- Commit `89313f0` — FOUND
- Commit `ac05f8a` — FOUND
- Commit `e46d8a3` — FOUND

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-08*
