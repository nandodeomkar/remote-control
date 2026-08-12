---
phase: 03-discovery-pairing-connection
plan: 05
subsystem: client-connection
tags: [flutter, dart, websocket, riverpod, reconnect, fsm, tcp-nodelay, rfc1918, liveness, tdd]

# Dependency graph
requires:
  - phase: 03-discovery-pairing-connection
    provides: "03-02: pure ReconnectFsm (effect objects, backoff policy, auth-stop) + SendPolicy; 03-03: DeviceStore (token + metadata seams); 03-04: Beacon type + Stream<Beacon> source + cleartext XML awaiting its code guard"
  - phase: 02-end-to-end-cursor-spike
    provides: "connectNoDelay TCP_NODELAY construction (gate-proven), HandshakeDriver/HandshakeFsm, LatencyProbe, MoveSender, single-listener _onFrame pattern"
provides:
  - "ConnectionService: the reconnect driver — executes every ReconnectFsm effect with real IO (Dial/StartBackoff/ClearToken/AuthStop/Close), one fresh HandshakeDriver per dial, token flowing store -> driver ctor only"
  - "Silent reconnect (CONN-03): stored token takes the auth branch with no PIN prompt; raw token never on the wire (sink-log asserted)"
  - "Automatic recovery (CONN-04): drop -> jittered backoff redial; app-resume / retry-now / beacon-sighting short-circuits"
  - "isPrivateLanAddress RFC1918+link-local dial guard (CONN-05, code half of D-10) — public-address dials refused before any socket opens"
  - "Idle-ping liveness (CONN-06): LatencyProbe extended with onIdleTick/pingsAwaited/onDead; 3 missed pongs close the channel and feed transportFailed"
  - "connection_providers.dart: connectionServiceProvider (real deps) + connectionStatusProvider (value-equal ChipStatus+fsmState snapshots via Riverpod 3 unified Notifier)"
affects: [03-06 device list (connectTo/adoptGuid consumers), 03-07 header chip + pairing sheet + trackpad slimming (reads connectionStatusProvider, feedPin, sendMove)]

# Tech tracking
tech-stack:
  added: []
  patterns: ["FSM-effect executor: one private _applyEffects switch is the ONLY place effects become IO", "generation-counter liveness: schedule-seam tick chain invalidated by bumping _livenessGen (no cancelable Timer needed, stale ticks no-op)", "value-equal snapshot classes for Riverpod Notifier state so no-op changes pings cost no rebuild", "guard refusal = terminal user-input error -> idle with lastDialError; transportFailed is reserved for real transport blips"]

key-files:
  created:
    - app/remote_control/lib/net/connection_providers.dart
    - app/remote_control/test/connection_service_test.dart
  modified:
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/hud/latency_probe.dart
    - app/remote_control/test/latency_probe_test.dart

key-decisions:
  - "Liveness tick chain rides the injected schedule seam with a generation counter instead of Timer.periodic — fully deterministic in tests, no cancel handle to leak"
  - "probe.reset() keeps the RTT window (header shows last-known latency through a teardown); only pingsAwaited and the dead latch clear"
  - "connectTo while authed applies disconnectRequested first — switching PCs is disconnect + fresh dial, never two live sockets"
  - "Reliable queue survives transport blips (teardown only drops volatile gating); AuthStopEffect clears it — a revoked target must re-pair before anything flushes"
  - "ConnectionStatus implements == / hashCode so Notifier skips notifications when a changes ping doesn't alter the visible status"

patterns-established:
  - "Stale-dial defense: after every await in _dial, re-check fsm.state before wiring the channel (the world may have moved on during the await)"
  - "Per-connection probe: LatencyProbe constructed fresh at dial with nowMillis + sink.add, nulled at teardown — no cross-connection RTT bleed"

requirements-completed: [CONN-03, CONN-04, CONN-05, CONN-06]

# Metrics
duration: ~25min across two sessions
completed: 2026-07-09
---

# Phase 3 Plan 05: ConnectionService Reconnect Driver Summary

**ConnectionService turns the pure ReconnectFsm into real connectivity — silent token reconnect, backoff redial with beacon/resume short-circuits, RFC1918 dial guard, idle-ping liveness — all proven against fakes (14-case suite), with Riverpod 3 providers exposing value-equal status snapshots for the 03-07 header**

## Performance

- **Duration:** ~25 min active execution, split across two sessions (Task 1 + red suite 2026-07-09 00:40–00:45 IST; implementation resumed and completed next session)
- **Started:** 2026-07-08T19:10:16Z (first RED commit)
- **Completed:** 2026-07-09 (resumed session)
- **Tasks:** 2 (both TDD)
- **Files modified:** 5

## Accomplishments

- **CONN-03 silent reconnect proven with secrets discipline:** stored token → auth branch, no PIN surface; the test asserts the raw token appears in NO sink frame (challenge-response `mac` only, T-03-17/T-03-20)
- **CONN-04 recovery matrix green:** authed drop schedules a jittered backoff redial; firing the captured timer redials; `onAppResumed` and a beacon sighting of the target GUID dial immediately (beacon also retargets host:port — the redial goes to the NEW address)
- **CONN-05/D-10 guard shipped:** `isPrivateLanAddress` (RFC1918 + 169.254/16, IPv4-only) refuses public dials before any socket opens — 8-case truth table green; the cleartext XML's promised code half is no longer outstanding (T-03-14 transient acceptance closed)
- **CONN-06 liveness engine:** LatencyProbe extended (not rewritten — D-08) with idle-ping cadence sharing the move-ping baseline, `missedPongLimit(3)` → `onDead` exactly once (latched); ConnectionService owns the 2s tick chain and converts dead → close + backoff
- **D-05 auth-stop wired end-to-end:** authFail noPairing clears the token, closes, lands in needPairing with the revoked explanation — fake connect called exactly once (no retry loop, T-03-18)
- Riverpod 3 providers: `connectionServiceProvider` wires DeviceStore over SecureStorageKv + SharedPrefsKv with the gate-proven `connectNoDelay` default; `connectionStatusProvider` is a unified Notifier re-snapshotting off `changes`

## Task Commits

Each task was committed atomically (TDD: test → feat):

1. **Task 1 (RED): failing idle-ping liveness tests** - `e112d10` (test)
2. **Task 1 (GREEN): LatencyProbe idle-ping engine** - `33f377f` (feat)
3. **Task 2 (RED): failing ConnectionService lifecycle suite** - `eb6d04d` (test)
4. **Task 2 (GREEN): ConnectionService + providers** - `048a081` (feat)

_No REFACTOR commits — GREEN implementations needed no cleanup._

## Files Created/Modified

- `app/remote_control/lib/net/connection_service.dart` - ConnectionService (FSM-effect executor, dial pipeline, single listener, liveness, send API) grown around the byte-identical Phase-2 connectNoDelay functions; `isPrivateLanAddress`; `ChipStatus`; `kDefaultDeviceName`
- `app/remote_control/lib/net/connection_providers.dart` - `connectionServiceProvider` + `ConnectionStatus`/`ConnectionStatusNotifier`/`connectionStatusProvider` (Riverpod 3, no StateNotifier)
- `app/remote_control/lib/hud/latency_probe.dart` - `onIdleTick`, `reset`, `pingsAwaited`, `onDead` latch; onMove/onPong/percentile logic untouched; stale "spike-only" doc sentence deleted
- `app/remote_control/test/latency_probe_test.dart` - 7 new liveness cases on the existing fake clock/sink
- `app/remote_control/test/connection_service_test.dart` - 14-case lifecycle suite: FakeWsChannel (StreamController + recording sink via noSuchMethod), RecordingStore over in-memory KV seams, captured schedule callbacks, fixed clock/jitter

## Decisions Made

- Liveness uses a generation-guarded tick chain on the injected `schedule` seam (bump `_livenessGen` to invalidate) rather than a cancelable `Timer.periodic` — keeps the probe timer-free and the suite deterministic
- `probe.reset()` preserves the RTT window so the header can show last-known latency during reconnects; only the awaited-counter and dead latch clear (documented option taken from the plan)
- `connectTo` on a live session disconnects first — never two sockets
- Teardown keeps the reliable queue (blip frames flush after redial auth); `AuthStopEffect` is the only queue-clearing path
- `ConnectionStatus` is value-equal so Notifier state assignment suppresses no-op rebuild notifications

## Deviations from Plan

None material — plan executed as written. Two lint-level cleanups alongside Task 2 (committed with it): `// ignore: prefer_initializing_formals` on the ctor (same convention as device_store.dart), and the test fakes renamed `_MemSecureKv`/`_MemPrefsKv` → `MemSecureKv`/`MemPrefsKv` to clear `library_private_types_in_public_api` on the public RecordingStore fields.

## Issues Encountered

None. Session resumed cleanly mid-plan: red suite was already committed (`eb6d04d`), implementation was completed and verified against it.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- 03-06 (device list) has everything it needs: `connectTo(DeviceTarget)`, `DeviceStore.adoptGuid` for manual entries, `Stream<Beacon>` via `attachBeacons`
- 03-07 (launch wiring + header) consumes `connectionStatusProvider` (ChipStatus mapping already per UI-SPEC), `feedPin` for the pairing sheet, `sendMove`/`sendReliable` to slim trackpad_screen.dart down to UI
- The D-10 enforcement split is now complete: XML cleartext + code RFC1918 guard both shipped
- `lastDialError` distinguishes guard refusals (terminal, idle) from transport errors (backoff) — manual-IP UX in 03-06 can surface the right copy

## Verification Results

- `flutter test` — 108/108 green (14 new ConnectionService cases, 7 new probe cases, all prior suites untouched)
- `flutter analyze` — no issues
- `grep -c "\.stream\.listen(" connection_service.dart` — 1 (single-listener invariant)
- `git diff` non-doc deletions in kept functions — 0 (setTcpNoDelay/noDelayTask/noDelayConnectionFactory/buildNoDelayHttpClient/connectNoDelay byte-identical)
- `grep -c "StateNotifier" connection_providers.dart` — 0
- `grep -c "Timer" latency_probe.dart` — 0 (probe stays timer-free)
- Token never on any sink frame; revoked test dials exactly once; truth table 8/8 — all suite-asserted
- TDD gates: RED `e112d10` → GREEN `33f377f`; RED `eb6d04d` → GREEN `048a081` — sequences valid

## Self-Check: PASSED

- `app/remote_control/lib/net/connection_service.dart` — FOUND (ConnectionService, ChipStatus, isPrivateLanAddress, connectNoDelay exports)
- `app/remote_control/lib/net/connection_providers.dart` — FOUND (connectionServiceProvider, connectionStatusProvider)
- `app/remote_control/lib/hud/latency_probe.dart` — FOUND (onIdleTick, reset, pingsAwaited)
- `app/remote_control/test/connection_service_test.dart` — FOUND
- Commit `e112d10` — FOUND
- Commit `33f377f` — FOUND
- Commit `eb6d04d` — FOUND
- Commit `048a081` — FOUND

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-09*
