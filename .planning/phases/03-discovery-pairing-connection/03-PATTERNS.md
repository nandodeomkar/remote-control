# Phase 3: Discovery, Pairing & Connection - Pattern Map

**Mapped:** 2026-07-08
**Files analyzed:** 19 new/modified files
**Analogs found:** 14 / 19 (5 have no in-repo analog — RESEARCH.md patterns are the source)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `app/remote_control/lib/net/reconnect_fsm.dart` (NEW) | model/FSM | event-driven | `lib/net/handshake_fsm.dart` | exact |
| `app/remote_control/lib/net/connection_service.dart` (MOD: reconnect driver + send policy) | service | event-driven + request-response | `lib/net/handshake.dart` (driver) + `lib/trackpad/trackpad_screen.dart` `_onFrame`/`_connect` (listener routing) | exact |
| `app/remote_control/lib/net/beacon.dart` (NEW: decode + validate) | codec/model | transform | `remote_protocol` decode discipline as used in `trackpad_screen._onFrame` + fixture format `protocol/fixtures/handshake/04-auth-fail.json` | role-match |
| `app/remote_control/lib/net/beacon_listener.dart` (NEW) | service | streaming (UDP in) | none (RESEARCH Pattern 3) — dispose/error posture from `trackpad_screen` listener | partial |
| `app/remote_control/lib/store/device_store.dart` (NEW) | store | CRUD | none (RESEARCH Pattern 7) — injectable-seam style from `latency_probe.dart` constructor injection | partial |
| `app/remote_control/lib/screens/device_list_screen.dart` (NEW) | screen/component | event-driven UI | `lib/trackpad/trackpad_screen.dart` | exact |
| `app/remote_control/lib/screens/pairing_dialog.dart` (NEW) | component | request-response UI | `trackpad_screen.dart` PIN block + `_statusLine()` reason mapping | exact |
| `app/remote_control/lib/widgets/connection_header.dart` (NEW) | component | streaming (throttled read) | `lib/hud/latency_hud.dart` | exact |
| `app/remote_control/lib/trackpad/trackpad_screen.dart` (MOD: slimmed to consumer) | screen | event-driven | itself — remove connect UI, keep hot-path gating (lines 158-166) | exact |
| `app/remote_control/lib/main.dart` (MOD: home → device list, auto-reconnect kick) | config/composition | — | itself | exact |
| `app/remote_control/android/.../MainActivity.kt` (MOD: MulticastLock channel) | platform glue | request-response | none (RESEARCH Pattern 4 — verbatim Kotlin sketch) | none |
| `app/remote_control/android/.../res/xml/network_security_config.xml` (NEW) + AndroidManifest (MOD) | config | — | none (RESEARCH Pattern 5 — verbatim XML) | none |
| `server/server-core/src/transport/beacon.rs` (NEW) | service/task | event-driven (timer + UDP out) | `src/transport/listener.rs` (task style) + `server-windows/src/main.rs` re-pair loop (tokio interval task) | role-match |
| `server/server-core/src/transport/mod.rs` (MOD: export beacon) | config | — | itself (module wiring + `ServerDeps` injection doc style) | exact |
| `server/server-windows/src/notify.rs` (NEW) | utility | request-response | `main.rs` PIN println block (lines 55-63) + RESEARCH Pattern 2 | role-match |
| `server/server-windows/src/main.rs` (MOD: beacon identity, spawn beacon, notify_pin) | composition root | — | itself (numbered-step layout, re-pair loop lines 70-86) | exact |
| `app/remote_control/test/reconnect_fsm_test.dart` (NEW) | test | — | `test/handshake_fsm_test.dart` | exact |
| `app/remote_control/test/{beacon,device_store,device_list_store,pairing_flow}_test.dart` (NEW) | test | — | `test/latency_probe_test.dart` (fake clock/sink) + `test/handshake_fsm_test.dart` | exact |
| `protocol/fixtures/beacon/*.json` + `protocol/BEACON.md` (NEW) | fixture/doc | — | `protocol/fixtures/handshake/04-auth-fail.json` + `protocol/fixtures/README.md` | exact |

## Pattern Assignments

### `lib/net/reconnect_fsm.dart` (pure FSM, event-driven) — THE keystone pattern

**Analog:** `app/remote_control/lib/net/handshake_fsm.dart` — copy its entire shape.

**Structure to copy** (all IO-free, no Flutter imports; only `remote_protocol` if needed):

1. **Doc header declaring purity + who does IO** (lines 1-16): "This class is IO-free and unit-tested in isolation; the `handshake.dart` driver wires it to a live WebSocket channel."
2. **States as an enum with doc comments per value** (lines 25-40):
```dart
enum HandshakeState { awaitingChallenge, awaitingPin, awaitingAuthResult, authed, failed }
```
Reconnect FSM states per RESEARCH Pattern 6: `idle · connecting · handshaking · authed · backoff(attempt, delay) · needPairing`.
3. **Effects as a sealed class hierarchy carrying data to UI** (lines 43-81):
```dart
sealed class HandshakeEffect { const HandshakeEffect(); }
final class NeedPinEffect extends HandshakeEffect { const NeedPinEffect(); }
final class PairedEffect extends HandshakeEffect { final String token; const PairedEffect(this.token); }
final class FailedEffect extends HandshakeEffect {
  final String reason;
  final int? attemptsRemaining;
  final int? retryAfterSecs;
  const FailedEffect(this.reason, {this.attemptsRemaining, this.retryAfterSecs});
}
```
Extend with connection-state effects (e.g. `DialEffect(device, host, port)`, `StartBackoffTimerEffect(delay)`, `ClearTokenEffect(guid)`, `NeedPairingEffect(explanation)`).
4. **Step object: `{emit?, effect?}` both nullable, with a `none` constant** (lines 85-97):
```dart
class HandshakeStep {
  final RemoteMessage? emit;
  final HandshakeEffect? effect;
  const HandshakeStep({this.emit, this.effect});
  static const HandshakeStep none = HandshakeStep();
}
```
5. **One `receive`/input method with an exhaustive `switch (_state)`, stray inputs return `.none`, never throw** (lines 133-178). Terminal states ignore replays (lines 173-176).
6. **Secrets discipline comment** (lines 10-15): pin/mac/token never logged; delegate crypto to `authProof(hexDecode(token), hexDecode(nonce))` (line 197) — never hand-roll.

**Composition rule (anti-pattern guard):** the reconnect FSM wraps *around* `HandshakeFsm` (connection lifecycle only) — it must NOT duplicate pin/auth states. Backoff delays/jitter are data in the state, timers are driver-side (like `awaitingPin` waits on the user, lines 144-149: "Waiting on the local user, not the wire").

---

### `lib/net/connection_service.dart` (service — grows into reconnect driver + send policy)

**Keep verbatim:** the existing `connectNoDelay` path (`lib/net/connection_service.dart` lines 25-68) — gate-proven TCP_NODELAY construction. Every dial this phase goes through `connectNoDelay(Uri)`; do not touch `setTcpNoDelay`/`noDelayTask`/`buildNoDelayHttpClient`.

**Analog for the driver half:** `lib/net/handshake.dart` (HandshakeDriver).

**Driver-applies-step pattern** (handshake.dart lines 82-112) — copy the `_apply` shape: send `emit` via sink, switch on sealed effect, derive coarse status:
```dart
void _apply(HandshakeStep step) {
  final emit = step.emit;
  if (emit != null) { channel.sink.add(encodeMessage(emit)); }
  final effect = step.effect;
  switch (effect) {
    case NeedPinEffect(): _status = HandshakeStatus.needPin;
    case PairedEffect(): _status = HandshakeStatus.authed;
    case FailedEffect(): _failure = effect; _status = HandshakeStatus.failed;
    case null: /* derive from _fsm.state */
  }
}
```

**Single-listener routing pattern** (moves here from `trackpad_screen.dart` lines 93-138) — exactly one `channel.stream.listen`; decode once, route by type, malformed frames silently dropped:
```dart
channel.stream.listen(
  (frame) => _onFrame(frame, driver, probe),
  onError: (_) => _onDisconnected(),
  onDone: _onDisconnected,
);
// ...
if (frame is! String) return;
final RemoteMessage msg;
try { msg = decodeText(frame).msg; } on FormatException { return; }
if (msg is PongMsg) { probe.onPong(msg); return; }
driver.onMessage(msg);
```
Route `pong` → probe, handshake families → HandshakeDriver, stream error/done → transport-failure FSM input. Never add a second subscribe (throws in Dart).

**Auth gating pattern** (trackpad_screen.dart lines 158-166): volatile sends check `driver.isAuthed` and drop otherwise — this becomes the send-policy seam (RESEARCH Pattern 6 table: volatile drop-if-!authed, reliable queue ≤10).

**Private-range guard:** new code — use RESEARCH Pattern 5's `isPrivateLanAddress` verbatim; apply before every `connectNoDelay` dial.

---

### `lib/net/beacon.dart` + `protocol/fixtures/beacon/` (codec + fixtures)

**Analog:** fixture discipline in `protocol/fixtures/handshake/04-auth-fail.json`:
```json
{
  "name": "auth-fail-bad-mac",
  "description": "Server authFail with reason badMac — HMAC verification failed (SPEC section 5 reason enum).",
  "wire": { "t": "authFail", "p": { "reason": "badMac" } },
  "expect": { "t": "authFail", "p": { "reason": "badMac" } }
}
```
Copy this `name`/`description`/`wire`/`expect` shape for beacon fixtures (valid + malformed-drop cases, where `expect` for malformed is a drop marker consistent with `protocol/fixtures/README.md` conventions — read it when writing fixtures). `Beacon.tryParse` follows the total-parse posture of `trackpad_screen._onFrame` (never throw out of the listener; return null to drop) plus RESEARCH's strict validation: ≤512 bytes, `v==1`, `app=="remote-control"`, typed fields.

---

### `lib/net/beacon_listener.dart` (streaming service — no direct analog)

Use RESEARCH Pattern 3 (`RawDatagramSocket.bind(anyIPv4, 17778, reuseAddress: true)` → `Stream<Beacon>`). Borrow from the codebase:
- Lifecycle ownership like `trackpad_screen.dart` dispose (lines 62-70): socket closed deterministically on release; acquire/release paired with MulticastLock calls (Pitfall 8: listen only while device list visible or FSM in backoff).
- Silent-drop of malformed input (`_onFrame` FormatException pattern, lines 126-130).

---

### `lib/store/device_store.dart` (store, CRUD — no direct analog)

Use RESEARCH Pattern 7 schema (secure storage `token.<guid>`; prefs `devices` JSON map + `lastDeviceGuid`). Copy the **constructor-injection seam** style from `lib/hud/latency_probe.dart` (lines 24-55): dependencies (`FlutterSecureStorage`, `SharedPreferences` — or thin function seams) injected via constructor so tests use fakes, exactly like `nowMillis`/`send`:
```dart
LatencyProbe({ required this.nowMillis, required void Function(Object frame) send, ... }) : _send = send;
```
Every secure-storage read wrapped in `try { } on PlatformException { /* treat as unpaired, delete entry */ }` (RESEARCH code example; Pitfall 5). Token never enters prefs/logs/toString.

---

### `lib/screens/device_list_screen.dart` + `lib/screens/pairing_dialog.dart` (screens)

**Analog:** `lib/trackpad/trackpad_screen.dart`.

- **Screen skeleton** (lines 32-70): `StatefulWidget`, controllers created as fields, `dispose()` releases every controller/resource.
- **Theme constants** (lines 199, 216, 257, 299): background `Color(0xFF0E0F12)`, text `Color(0xFFE6E8EB)`, muted `Color(0xFF6B7280)`, error `Color(0xFFFF6B6B)`, accent `Color(0xFF4C8DFF)` (from `main.dart` seed + `latency_hud.dart` line 71), border `Color(0xFF2A2D34)` (latency_hud line 62).
- **PIN entry block to lift into pairing_dialog** (lines 281-294): `TextField(maxLength: 6, keyboardType: number)` + `FilledButton` → `driver.feedPin(...)`.
- **authFail reason → copy mapping** (`_statusLine()`, lines 168-189): switch on `HandshakeStatus`, render `attemptsRemaining` / `retryAfterSecs` extras from `FailedEffect`. Extend per D-05: `noPairing`/`badMac` → "This PC no longer recognizes this phone — pair again".
- **Connect-by-IP sheet** reuses the IP/port `TextField` row + validation (lines 72-78, 250-279): `int.tryParse` port, inline error via `setState`.
- **Riverpod:** `ProviderScope` already at root (`main.dart` line 7); new stores use Riverpod 3 unified `Notifier` (project convention; no existing Notifier to copy — follow Riverpod 3 docs, NOT StateNotifier).

**Trackpad slimming (MOD):** delete `_ipCtrl/_portCtrl/_pinCtrl`, `_connect`, `_controls`; keep wakelock (lines 55-64), `Listener.onPointerMove` hot path with authed gating (lines 158-166, 202-220) reading ConnectionService state instead of a local driver.

---

### `lib/widgets/connection_header.dart` (throttled status chip)

**Analog:** `lib/hud/latency_hud.dart` — copy nearly whole; delete `lib/hud/latency_hud.dart` after (D-08).

**Throttled-poll pattern** (lines 31-48) — preserves the no-rebuild-on-hot-path invariant:
```dart
_ticker = Timer.periodic(kHudReadThrottle, (_) { if (mounted) setState(() {}); });
```
`kHudReadThrottle` (500ms) lives in `latency_probe.dart` line 128 — reuse the constant. Null-safe formatting `_fmt` (line 50): `v == null ? '--' : '${v}ms'`. Container styling (lines 56-88) is the chip's visual base; show p50 + status color per RESEARCH Open Question 3.

`lib/hud/latency_probe.dart` itself is **extended, not rewritten**: add the ~2s idle-ping timer + missed-pong counter feeding a dead-connection callback; keep `onMove`/`onPong`/percentile logic untouched.

---

### `server/server-core/src/transport/beacon.rs` (tokio task)

**Analogs:** `src/transport/listener.rs` (task/module style) + `server-windows/src/main.rs` re-pair loop (interval task).

- **Module doc + never-die loop posture** (listener.rs lines 1-31): `//!` doc header stating scope; per-iteration errors `continue`/`let _ =`, never kill the loop:
```rust
let (stream, peer) = match listener.accept().await {
    Ok(conn) => conn,
    Err(_) => continue, // transient errors must not kill the server
};
let _ = stream.set_nodelay(true); // log-and-continue semantics
```
Apply the same to `sock.send_to(...)` per interface: `let _ =`.
- **Identity injection** (transport/mod.rs lines 25-32, `ServerDeps` doc style): `BeaconIdentity { name, guid, ws_port }` struct injected by the composition root — keeps server-core Windows-free (winreg/COMPUTERNAME live in server-windows). RESEARCH Pattern 1 is the body (per-interface directed broadcast via `if-addrs`, re-enumerate every tick; verify `Ifv4Addr` field names at first compile — Assumption A1).
- **Timer-loop shape** (main.rs lines 71-86): `tokio::spawn(async move { loop { tokio::time::sleep/interval ... } })`. Use `tokio::time::interval(Duration::from_secs(2))` + tokio `test-util`/`start_paused` for interval unit tests.
- **mod.rs wiring** (transport/mod.rs lines 12-13): add `pub mod beacon;` (public — composition root spawns it), keep `listener`/`session` private.

---

### `server/server-windows/src/notify.rs` + `main.rs` (MOD)

**Analog:** `main.rs` PIN display block (lines 55-63) — the exact call sites to reroute:
```rust
let pin = auth.lock().expect("auth mutex poisoned at startup").begin_pairing();
println!("Pairing PIN: {pin}");            // line 63 → notify::notify_pin(&pin)
// ...
println!("Pairing PIN (refreshed): {refreshed}");  // line 84 → notify::notify_pin(&refreshed)
```
`notify.rs` body is RESEARCH Pattern 2 verbatim (console println FIRST, then `Toast::new(Toast::POWERSHELL_APP_ID)`, `.show()` failure → `tracing::warn!`, never panic; PIN never through tracing — T-02-ID comment discipline as in main.rs lines 36-37, 56-57).

**main.rs additions follow its numbered-step comment layout** (steps 1-8): insert beacon identity assembly (machine GUID via winreg — RESEARCH code example `machine_guid()`, fallback to COMPUTERNAME-derived + warn, never crash) and `tokio::spawn(server_core::transport::beacon::run_beacon(identity, beacon_port))` before step 8's `server_core::run`. Port pattern: copy the `RC_PORT` env-override block (lines 98-103) for `RC_BEACON_PORT`, default 17778.

---

### Tests (all new Dart suites)

**Analog 1:** `test/handshake_fsm_test.dart` — pure-FSM test style for `reconnect_fsm_test.dart`:
- Fixed constants at top (lines 20-23), `group` per path (start / pair / reconnect / failure), each test: construct FSM → feed inputs → assert `out.emit` type/fields, `out.effect` type, `fsm.state`, with `reason:` strings citing the spec (lines 61-62, 89, 100-101).

**Analog 2:** `test/latency_probe_test.dart` — injected fakes for `device_store_test.dart`, `beacon_test.dart`, cadence/backoff timing:
```dart
class _FakeClock {
  int _now = 0;
  int call() => _now;
  void advance(int millis) => _now += millis;
  set now(int millis) => _now = millis;
}
class _RecordingSink {
  final List<Object?> added = [];
  void add(Object? frame) => added.add(frame);
}
```
Backoff/jitter tests inject clock + (if jitter) a seeded/fake random; device_store tests inject a fake secure-storage map that can throw `PlatformException` on demand.

**`pairing_flow_test.dart`** (widget test): analog is the `flutter_test` setup in existing suites; assert authFail-reason → error copy mapping per D-05.

## Shared Patterns

### Pure FSM + thin driver (project-locked convention)
**Source:** `lib/net/handshake_fsm.dart` + `lib/net/handshake.dart`
**Apply to:** `reconnect_fsm.dart` + ConnectionService driver. FSM: no IO, no Flutter, no timers — timers/sockets/storage are driver effects. Effects are sealed classes carrying data; steps are `{emit?, effect?}`.

### Single stream listener, decode-once routing
**Source:** `trackpad_screen.dart` lines 93-138 (moving into ConnectionService)
**Apply to:** ConnectionService (the only `channel.stream.listen`), beacon listener (same total-parse silent-drop posture for datagrams).

### Secrets discipline
**Source:** `handshake_fsm.dart` lines 10-15, `main.rs` lines 36-37 & 56-57
**Apply to:** everything touching pin/token/mac. PIN → stdout + toast only, never tracing; token → secure storage only, never prefs/logs/`toString()`; crypto only via `authProof` from `remote_protocol`.

### Never-crash-on-bad-input (untrusted wire data)
**Source:** `trackpad_screen._onFrame` (FormatException → return), `listener.rs` (Err → continue), `handshake_fsm` stray-input → `HandshakeStep.none`
**Apply to:** beacon decode (silent drop), reconnect FSM stray inputs, secure-storage reads (PlatformException → unpaired).

### Throttled UI reads off the hot path
**Source:** `latency_hud.dart` lines 31-48 + `kHudReadThrottle` (latency_probe.dart line 128)
**Apply to:** connection_header.dart; any provider exposing probe percentiles.

### Dependency injection for testability
**Source:** `latency_probe.dart` constructor (clock + sink), `ServerDeps` (transport/mod.rs lines 25-32)
**Apply to:** device_store (storage seams), beacon.rs (`BeaconIdentity` injected), reconnect driver (clock/random/timer seams).

### Dark-minimal theme tokens
**Source:** `main.dart` (seed `0xFF4C8DFF`), `trackpad_screen.dart` / `latency_hud.dart`
**Apply to:** all new screens/widgets: bg `0xFF0E0F12`, text `0xFFE6E8EB`, muted `0xFF6B7280`, error `0xFFFF6B6B`, border `0xFF2A2D34`, chip bg `0xCC0E0F12`.

## No Analog Found

Files with no close match in the codebase (use RESEARCH.md patterns as the source):

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `android/.../MainActivity.kt` MulticastLock channel | platform glue | request-response | No MethodChannel exists yet — RESEARCH Pattern 4 Kotlin sketch is the template |
| `android/.../res/xml/network_security_config.xml` | config | — | No XML config exists — RESEARCH Pattern 5 verbatim (single commit with manifest attr swap; on-device ws:// smoke test mandatory, Pitfall 7) |
| `lib/net/beacon_listener.dart` (socket half) | service | streaming | First UDP code in the app — RESEARCH Pattern 3 |
| `lib/store/device_store.dart` (storage half) | store | CRUD | First persistence code in the app — RESEARCH Pattern 7 + secure-token code example |
| Riverpod `Notifier` stores (device list state) | store/provider | event-driven | `ProviderScope` exists but no Notifier yet — Riverpod 3 unified Notifier (v3 docs; StateNotifier forbidden) |

## Metadata

**Analog search scope:** `app/remote_control/lib/**`, `app/remote_control/test/**`, `server/server-core/src/transport/**`, `server/server-windows/src/**`, `protocol/fixtures/**`
**Files scanned:** 12 read in full/part (handshake_fsm, handshake, connection_service, latency_probe, latency_hud, trackpad_screen, main.dart, handshake_fsm_test, latency_probe_test, listener.rs, transport/mod.rs, server-windows main.rs, fixture 04-auth-fail.json)
**Pattern extraction date:** 2026-07-08
