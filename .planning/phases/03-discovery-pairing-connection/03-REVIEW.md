---
phase: 03-discovery-pairing-connection
reviewed: 2026-07-09T12:22:52Z
depth: standard
files_reviewed: 21
files_reviewed_list:
  - app/remote_control/lib/hud/latency_probe.dart
  - app/remote_control/lib/main.dart
  - app/remote_control/lib/net/beacon.dart
  - app/remote_control/lib/net/beacon_listener.dart
  - app/remote_control/lib/net/connection_providers.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/lib/net/reconnect_fsm.dart
  - app/remote_control/lib/net/send_policy.dart
  - app/remote_control/lib/platform/multicast_lock.dart
  - app/remote_control/lib/screens/connection_copy.dart
  - app/remote_control/lib/screens/device_list_screen.dart
  - app/remote_control/lib/screens/pairing_dialog.dart
  - app/remote_control/lib/store/device_list_store.dart
  - app/remote_control/lib/store/device_store.dart
  - app/remote_control/lib/trackpad/trackpad_screen.dart
  - app/remote_control/lib/widgets/connection_header.dart
  - server/server-core/src/transport/beacon.rs
  - server/server-core/src/transport/mod.rs
  - server/server-core/src/transport/session.rs
  - server/server-windows/src/main.rs
  - server/server-windows/src/notify.rs
findings:
  critical: 1
  warning: 3
  info: 3
  total: 7
status: issues_found
---

# Phase 3: Code Review Report

**Reviewed:** 2026-07-09T12:22:52Z
**Depth:** standard
**Files Reviewed:** 21
**Status:** issues_found

## Summary

The Phase-3 connection layer is unusually disciplined: the FSMs are pure and test-seamed, secrets discipline is enforced by construction (no token field on `DeviceMeta`, connect-time-only token flow), the RFC1918 dial guard is real code, and untrusted network input (beacons, inbound frames) is total-parsed with silent drops. The accepted design facts in the brief (single-pairing server, cleartext `ws://` scoped by the dial guard, `noPairing`/`badMac` copy collapse) were respected and not counted against the code.

That said, the review found one correctness defect on the hot path serious enough to block: the `LatencyProbe` liveness engine shares one unanswered-ping counter between fast move-driven pings and slow idle pings, so a live-but-laggy connection can be falsely declared dead mid-drag and torn down. Three warnings concern the uncancellable backoff timer (stale timers can fire an early redial), a defensive-parsing gap in `DeviceStore` that diverges from the codebase's own Pitfall-5 posture, and an unbounded RTT sample. No injection, auth-bypass, secret-leak, or crash-guaranteed defect was found.

## Critical Issues

### CR-01: Liveness counter conflates fast move-pings with slow idle-pings — false dead-connection teardown mid-drag

**File:** `app/remote_control/lib/hud/latency_probe.dart:166-177` (with `app/remote_control/lib/net/connection_service.dart:483-488`)

**Issue:** `_emitPing` is the single place the unanswered-ping counter (`_pingsAwaited`) is incremented and compared to `missedPongLimit` (default 3), and it is called by BOTH `onMove` (the hot pointer path, cadence `min(movesPerPing=8 moves, pingIntervalMillis=250ms)`) and `onIdleTick` (cadence `idlePingIntervalMillis=2000ms`). The `missedPongLimit=3` threshold is documented and tuned for the idle cadence — "3 missed pongs ≈ 6s dead" (see the class doc and `connection_service.dart:149`). But during an active drag, three pings are emitted in roughly 130–750 ms (fast moves hit the 8-move trigger well under 250 ms). If the round-trip latency exceeds the time to accumulate three move-pings — i.e. any RTT spike above ~130–500 ms, which is common on congested 2.4 GHz WiFi — then `_pingsAwaited` reaches 3 before the first pong returns and `onDead` fires on a perfectly live socket.

`onDead` routes to `ConnectionService._onDeadConnection`, which tears the channel down and feeds `transportFailed()` → 1s+ backoff → silent redial. The net effect is a visible ≥1s cursor freeze and reconnect in the middle of a drag on a merely-laggy (not dead) network — a direct failure of the locked "cursor visually instant" core feature, triggered under realistic (non-adversarial) conditions.

**Fix:** Decouple dead-detection from move cadence. Either count only idle-tick misses, or (cleaner) make liveness time-based rather than count-based — declare dead when no pong has arrived for a fixed wall-clock window regardless of how many pings were emitted:

```dart
// Track the last pong time and last emit time; onDead when a ping is emitted
// and (now - lastPongAtMillis) exceeds a deadline, independent of ping count.
int? _lastPongAtMillis;

void onPong(PongMsg pong) {
  _lastPongAtMillis = nowMillis();
  _pingsAwaited = 0;
  // ...record rtt as before...
}

void _emitPing(int now) {
  _movesSincePing = 0;
  _lastPingAtMillis = now;
  _send(encodeMessage(PingMsg(ts: now)));
  final lastPong = _lastPongAtMillis ?? now;
  // e.g. missedPongLimit * idlePingIntervalMillis == 6000ms of true silence
  if (now - lastPong >= missedPongLimit * idlePingIntervalMillis && !_deadFired) {
    _deadFired = true;
    onDead?.call();
  }
}
```

This keeps the ~6s dead window whether the session is idle or under drag load, so fast move-pings can no longer trip it.

## Warnings

### WR-01: Uncancellable backoff timers let a stale timer fire a premature redial

**File:** `app/remote_control/lib/net/connection_service.dart:325-328` (with `reconnect_fsm.dart:237-266`)

**Issue:** `StartBackoffEffect` is executed via the `_schedule` seam, which has no cancellation handle (`_timerSchedule` just constructs a bare `Timer`). Staleness is guarded only by the FSM state check inside `backoffElapsed()`. That guard is insufficient when the FSM leaves and re-enters `backoff`: e.g. `backoff` → user taps "Retry now"/beacon short-circuit → `connecting` → dial fails fast → `transportFailed()` → `backoff` again. Now two timers are pending, both from a backoff episode. When the *older* timer fires while the FSM is in `backoff`, `backoffElapsed()` returns `_dialNow()` and redials — earlier than the current episode's jittered delay intended. Exponential backoff is not honored, and the server can be dialed more aggressively than the §8 policy allows (the same "don't hammer" concern the FSM doc calls out for auth). No infinite loop or double-socket results (`_dial` tears down first and the second timer no-ops on the changed state), but the backoff schedule is violated.

**Fix:** Give backoff timers the same generation guard the liveness ticks already use, or thread a cancel handle through the schedule seam:

```dart
int _backoffGen = 0;
// on StartBackoffEffect:
final gen = ++_backoffGen;
_schedule(delay, () {
  if (gen != _backoffGen) return; // stale episode — ignore
  unawaited(_applyStep(_fsm.backoffElapsed()));
});
// bump _backoffGen on any transition that leaves backoff (dial, short-circuit,
// disconnect) so a prior episode's timer is invalidated.
```

### WR-02: `DeviceStore.loadDevices` throws on corrupt prefs JSON and callers don't guard it

**File:** `app/remote_control/lib/store/device_store.dart:201-210, 264-268` (with `store/device_list_store.dart:312-320`)

**Issue:** `_loadRawDevices` does `jsonDecode(json) as Map` and `loadDevices` does `(entry.value! as Map).cast(...)` plus `DeviceMeta.fromJson` with `json['name']! as String`. A single malformed or schema-drifted `devices` entry throws (`FormatException` / `TypeError` / null-check). `DeviceListNotifier._reloadStored` (`device_list_store.dart:312`) calls `await store.loadDevices()` with no try/catch, and it is invoked as an unawaited future in `build()`, so the failure becomes an unhandled async error and stored-row loading + manual→GUID adoption silently break on every rebuild. This is inconsistent with the codebase's own defensive posture — `tokenFor` and `_launchKick` go to lengths to "never crash on credential reads" (Pitfall 5), but the prefs path has no equivalent guard.

**Fix:** Make `loadDevices` total (skip unparseable entries, return the good ones) and/or wrap `_reloadStored` in try/catch that degrades to an empty overlay:

```dart
Future<Map<String, DeviceMeta>> loadDevices() async {
  final raw = await _loadRawDevices(); // already returns {} on absent
  final out = <String, DeviceMeta>{};
  for (final entry in raw.entries) {
    try {
      out[entry.key] =
          DeviceMeta.fromJson(entry.key, (entry.value! as Map).cast());
    } catch (_) {
      // skip a corrupt row rather than failing the whole load
    }
  }
  return out;
}
```
and guard `_loadRawDevices` against a corrupt top-level blob the same way.

### WR-03: `onPong` records an unbounded RTT sample that can poison the percentile window

**File:** `app/remote_control/lib/hud/latency_probe.dart:139-146`

**Issue:** `rtt = nowMillis() - pong.ts` is added to the window with no sanity bound. The `ts` is the client's own stamp echoed by the server, so a buggy/hostile server echoing an arbitrary `ts`, or a system-clock adjustment between ping and pong, yields a negative or absurdly large `rtt` that then skews `p50`/`p95` for up to `windowSize` (120) subsequent reads. Impact is confined to the header latency display (no functional path consumes p50/p95), so this is a robustness/quality issue rather than a correctness break — but the probe is otherwise treated as the authoritative latency source (D-08), so a garbage reading is user-visible.

**Fix:** Clamp/reject implausible samples before adding, e.g. `if (rtt < 0 || rtt > someCeiling) return;` (or `rtt = rtt.clamp(0, ceiling)`), keeping the liveness reset (`_pingsAwaited = 0`) unconditional since a pong of any kind still proves the socket alive.

## Info

### IN-01: Two independent `DeviceStore` instances back the same data

**File:** `app/remote_control/lib/net/connection_providers.dart:31-36` and `app/remote_control/lib/store/device_list_store.dart:232-234`

**Issue:** `connectionServiceProvider` constructs its own `DeviceStore(secure: SecureStorageKv(), prefs: SharedPrefsKv())`, while `deviceStoreProvider` constructs a separate one. `main.dart:_launchKick` reads through the latter; the service persists through the former. It works today only because the underlying backends are process-wide singletons (`SecureStorageKv._storage` is `static const`, `SharedPreferencesAsync` targets one platform store). If `DeviceStore` ever gains an in-memory cache, the two instances would diverge silently.

**Fix:** Have `connectionServiceProvider` depend on `deviceStoreProvider` (`ref.watch(deviceStoreProvider)`) so there is a single store instance.

### IN-02: `_maybeAdopt` marks a manual key adopted even if the migration later fails

**File:** `app/remote_control/lib/store/device_list_store.dart:217-226` (with `_adopt` at 324-327)

**Issue:** `_adopted.add(entry.key)` latches before the async `onAdopt` callback runs, and `_adopt` → `store.adoptGuid` has no failure handling. If the storage migration throws, the manual key is permanently marked adopted for the model's lifetime and never retried, leaving a stranded `manual:` entry. Low likelihood (adoption writes rarely fail) and self-corrects on next app launch (fresh model), so informational.

**Fix:** Only mark adopted after `adoptGuid` succeeds, or wrap `_adopt` so a failure un-latches `_adopted` for retry.

### IN-03: `beaconSighted` never refreshes the target address outside `backoff`

**File:** `app/remote_control/lib/net/reconnect_fsm.dart:281-303`

**Issue:** A matching beacon updates `_target.host/port` only in the `backoff` branch; in `connecting`/`handshaking`/`authed` it is a pure no-op. That is correct for the immediate reconnect story (an authed session doesn't need the new address), but it means a PC IP change observed while `connecting`/`handshaking` is not captured for the *next* dial — recovery then waits for the following beacon after a transport failure. Behaviorally acceptable per the D-06 design, noted only because the doc comment ("update the target's last-known address") reads broader than the implementation.

**Fix:** None required; optionally update `_target` (without changing state) on a matching beacon in non-authed transient states so the freshest address is always staged for the next dial.

---

_Reviewed: 2026-07-09T12:22:52Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
