# Phase 5: Media, Power, Presenter & Browser - Pattern Map

**Mapped:** 2026-07-10
**Files analyzed:** 22 new/modified files
**Analogs found:** 20 / 22 (2 partial — hub tiles + countdown dialog have no exact precedent; composites of existing patterns)

## File Classification

### Protocol (modify)
| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| `protocol/SPEC.md` (§2, §7) | config/contract | — | existing §7 rows (`media`, `pong`) | exact |
| `protocol/schema/messages.schema.json` | config/contract | — | existing `$defs` entries | exact |
| `protocol/fixtures/volume/01..03-*.json` | test fixture | — | `protocol/fixtures/handshake/02-challenge.json` | exact |

### Rust server (new/modify)
| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| `server/server-core/src/codec/json.rs` (modify: `Msg::VolChanged`) | codec/model | transform | its own `MediaPayload`/`Msg::Media` entries (lines 134, 249–261, 310, 375) | exact |
| `server/server-core/src/transport/mod.rs` (modify: `ServerDeps.volume`) | config/DI seam | — | `ServerDeps.pause` field (mod.rs:34) | exact |
| `server/server-core/src/transport/session.rs` (modify: select! branch + after-auth snapshot) | service | event-driven push | its own `pause` watch branch (session.rs:107–108, 132–143) + reply-queue send (173–177) | exact |
| `server/server-core/src/dispatch/router.rs` (modify: `Msg::VolChanged` ignore arm) | controller | request-response | its own S→C-only ignore arm (router.rs:247–257) | exact |
| `server/server-windows/src/audio_thread.rs` (NEW) | worker thread | event-driven + poll | `server/server-windows/src/input_thread.rs` (`Cmd` enum + `run_input_thread`) | role+flow match |
| `server/server-windows/src/executors/media.rs` (NEW: `WinMedia`) | executor/service | send-and-forget | `server/server-windows/src/executors/mouse_keys.rs` (`EnigoMouseKeys`) | exact |
| `server/server-windows/src/executors/power.rs` (NEW: `WinPower`) | executor/service | send-and-forget | `mouse_keys.rs` (trait impl shape) + `input_thread.rs` (never-panic rule) | role match |
| `server/server-windows/src/executors/keymap.rs` (modify: media key codes) | utility/table | transform | its own `ROUTER_MACRO_CODES` + coverage tests (keymap.rs:65–66, 160–179) | exact |
| `server/server-windows/src/executors/stubs.rs` (modify: delete StubMedia/StubPower) | executor stub | — | itself | exact |
| `server/server-windows/src/main.rs` (modify: spawn audio thread, wire watch) | composition root | — | its own steps 3–6 (main.rs:44–100) | exact |
| `server/server-core/tests/integration.rs` or new `volume.rs` (vol-push tests) | test | — | existing integration tests + `fixtures.rs` per-family test fns | exact |

### Flutter protocol package (modify)
| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| `app/packages/remote_protocol/lib/src/json_codec.dart` (modify: `VolChangedMsg`) | codec/model | transform | `MediaMsg` (json_codec.dart:352–374) + decode switch (742–773) | exact |
| `app/packages/remote_protocol/lib/src/version.dart` (modify: `'1.1'`) | config | — | itself | exact |

### Flutter app (new/modify)
| File | Role | Data Flow | Closest Analog | Match Quality |
|------|------|-----------|----------------|---------------|
| `lib/net/connection_service.dart` (modify: `_onFrame` VolChanged branch) | service | event-driven | its own `PongMsg` branch (connection_service.dart:432–435) | exact |
| `lib/screens/device_list_screen.dart` (modify: reroute 2 nav sites) | screen | — | its own `MaterialPageRoute` pushes (lines 136, 222) | exact |
| `lib/hub/hub_screen.dart` (NEW) | screen | — | `trackpad_screen.dart` (chrome/header composition) + device_list (nav) | partial (tile grid is new) |
| `lib/media/media_screen.dart` (NEW) | screen | request-response | `trackpad_screen.dart` (header chip, sendReliable, sensitivity Slider at 213–222) | role match |
| `lib/media/volume_store.dart` (NEW) | store/provider | event-driven | `ConnectionStatusNotifier` (connection_providers.dart:45–89) | exact |
| `lib/power/power_screen.dart` (NEW) | screen | request-response | trackpad screen chrome + `showModalBottomSheet` precedent | partial (countdown dialog is new) |
| `lib/power/confirm_track_fsm.dart` (NEW) | pure FSM | transform | `lib/keyboard/modifier_fsm.dart` (no-Flutter no-IO house style) | exact style |
| `lib/presenter/presenter_screen.dart` (NEW) | screen | request-response | `trackpad_screen.dart` (wakelock 145/155, haptics 112/185, split layout) | exact |
| `lib/presenter/presenter_timer.dart` (NEW) | pure FSM | transform | `modifier_fsm.dart` + `GestureClassifier` (injected `nowMillis` clock seam) | exact style |
| `lib/browser/browser_screen.dart` (NEW) | screen | request-response | `MouseButtonsBar` usage + trackpad button-cluster styling (trackpad_screen.dart:324–383) | role match |

## Pattern Assignments

### Server: `vol.changed` watch seam (transport/mod.rs + session.rs)

**Analog:** the existing `pause` watch — the seam is a literal clone.

**ServerDeps field pattern** (`server/server-core/src/transport/mod.rs:28-35`):
```rust
pub struct ServerDeps {
    pub executors: Executors,
    pub auth: Arc<Mutex<AuthManager>>,
    /// Server-side pause flag; sessions observe changes live (SPEC §11).
    pub pause: tokio::sync::watch::Receiver<bool>,
}
// ADD: pub volume: tokio::sync::watch::Receiver<VolumeState>,  (VolumeState core-owned, no OS deps)
```

**Alive-flag + select! branch pattern** (`session.rs:106-111, 132-143`):
```rust
// The pause watch sender may drop before the session ends; disable the
// branch then (`changed()` would return Err forever and busy-loop).
let mut pause_alive = true;
...
changed = pause.changed(), if pause_alive => {
    match changed {
        Ok(()) => {
            if *pause.borrow() {
                ctx.held.release_all(&*executors.mouse_keys);
            }
        }
        Err(_) => pause_alive = false,
    }
}
```
New branch mirrors this with an extra guard: `if volume_alive && ctx.auth_state == AuthState::Authed`, and uses `borrow_and_update()` to clear the changed flag (Pitfall 8 in RESEARCH).

**Queue-a-frame pattern** (`session.rs:172-177` — how replies reach the wire):
```rust
for reply in replies {
    let frame = Message::text(json::encode_msg(&reply, None));
    if tx.send(frame).await.is_err() {
        break 'read; // write task gone → session over
    }
}
```
The after-auth snapshot (D-03 "right after auth") queues one `vol.changed` frame the same way, immediately after the `pairOk`/`authOk` reply at BOTH Authed transitions (`handle_text` pin path session.rs:315-319 and auth path 331-345 — note `handle_text` returns `Vec<Msg>`, so the cleanest hook is appending to those reply vectors or reading the watch in `run_session` after a status transition; planner picks the seam).

**Constant/version pattern** (`session.rs:44-45`):
```rust
pub(crate) const SERVER_PROTO_VERSION: &str = "1.0";  // → "1.1"; SERVER_PROTO_MAJOR unchanged
```

---

### Server: `audio_thread.rs` (NEW)

**Analog:** `server/server-windows/src/input_thread.rs` — the ONLY existing dedicated-OS-thread worker; copy its whole shape.

**Cmd enum pattern** (`input_thread.rs:36-59`):
```rust
/// Command sent from the executor (hot path, non-blocking mpsc send) to the
/// input thread. NOT `Copy`: ... the mpsc send is a move, so `Clone` alone
/// is sufficient.
#[derive(Debug, Clone, PartialEq)]
pub enum Cmd {
    Move(f32, f32),
    ...
}
```
→ `pub enum AudioCmd { SetVol(u8), MuteToggle, StepUp, StepDown }`

**Thread loop pattern** (`input_thread.rs:182-186` + drop rule at 214-215):
```rust
pub fn run_input_thread(rx: std::sync::mpsc::Receiver<Cmd>) {
    let mut enigo = Enigo::new(&Settings::default()).expect("enigo init on input thread");
    ...
    while let Ok(cmd) = rx.recv() { ... }
}
// Every arm follows the non-fatal-drop rule (T-04-01):
// injection failures and unknown key codes drop, never panic.
```
Audio thread differs in ONE way: `rx.recv_timeout(Duration::from_millis(250))` instead of `recv()` so the timeout arm is the poll tick (RESEARCH Pattern 2). COM objects (`CoInitializeEx`, endpoint re-acquired per tick) live and die on this thread, exactly like `Enigo` does on the input thread. All HRESULT failures: skip the tick, never panic. Push state via `watch::Sender<VolumeState>` only when != last.

**Win32-unsafe style** (`input_thread.rs:148-173` `inject_absolute`): SAFETY comments on each unsafe block; `let _ =` on fallible OS calls; helper fns returning `Option`/dropping on failure (`cursor_pos`, lines 133-137).

---

### Server: `executors/media.rs` (NEW: `WinMedia`)

**Analog:** `server/server-windows/src/executors/mouse_keys.rs` — identical role (sync trait impl holding only channel senders).

**Full pattern** (`mouse_keys.rs:18-61`):
```rust
/// Enigo-backed `MouseKeys`: holds only the `Send + Sync` channel sender;
/// the `!Sync` `Enigo` handle lives on the input thread.
pub struct EnigoMouseKeys {
    tx: Sender<Cmd>,
}
impl EnigoMouseKeys {
    pub fn new(tx: Sender<Cmd>) -> Self { Self { tx } }
}
impl MouseKeys for EnigoMouseKeys {
    fn move_rel(&self, dx: f32, dy: f32) {
        let _ = self.tx.send(Cmd::Move(dx, dy));   // send-and-forget, never blocks/panics
    }
    ...
}
```
→ `WinMedia { input_tx: Sender<Cmd>, audio_tx: Sender<AudioCmd> }`; transport keys go `input_tx.send(Cmd::KeyTap(KeyCode("MediaPlayPause".into()), vec![]))`, volume ops go `audio_tx.send(AudioCmd::...)`. Trait to implement: `server_core::executors::Media` (method list visible in `stubs.rs:15-23`: play_pause, next, prev, vol_up, vol_down, mute, set_volume(u8)).

---

### Server: `executors/power.rs` (NEW: `WinPower`)

**Analog:** trait shape from `stubs.rs:29-34` (`Power`: lock/sleep/restart/shutdown); execution style from input_thread's never-block/never-panic contract, but via `std::thread::spawn` per call (RESEARCH Pattern 3 — no existing power analog; the pattern is spelled out in RESEARCH with the privilege helper, `EWX_POWEROFF | EWX_FORCEIFHUNG`, non-zero `dwReason`).

```rust
impl Power for WinPower {
    fn lock(&self) {
        std::thread::spawn(|| unsafe { let _ = LockWorkStation(); });
    }
    // sleep/restart/shutdown: enable_shutdown_privilege() then API call, on a throwaway thread
}
```

---

### Server: `keymap.rs` additions (modify)

**Analog:** its own `ROUTER_MACRO_CODES` table + coverage test.

**Table pattern** (`keymap.rs:64-66`):
```rust
#[allow(dead_code)]
pub const ROUTER_MACRO_CODES: &[&str] =
    &["BrowserBack", "BrowserForward", "T", "W", "B", "Plus", "Minus"];
```

**map_key arm pattern** (`keymap.rs:118-127`) and **coverage-test pattern** (`keymap.rs:171-179`):
```rust
#[test]
fn router_macro_codes_covered() {
    for code in ROUTER_MACRO_CODES {
        assert!(
            map_key(&KeyCode((*code).to_string())).is_some(),
            "router macro code {code:?} must map to Some(enigo Key)"
        );
    }
}
```
→ add `MEDIA_KEY_CODES` const + `"MediaPlayPause" => Key::MediaPlayPause` etc. arms + a `media_key_codes_covered` test in the same style.

---

### Server: `main.rs` composition-root wiring (modify)

**Analog:** its own steps 3–6 (`main.rs:44-100`):
```rust
// 3. Dedicated input thread: the only place the !Sync Enigo lives.
let (tx, rx) = std::sync::mpsc::channel::<Cmd>();
std::thread::spawn(move || input_thread::run_input_thread(rx));

// 4. Executor bundle: real enigo mouse path + Phase 4-6 stub seeds.
let executors = Executors {
    mouse_keys: Arc::new(EnigoMouseKeys::new(tx)),
    media: Arc::new(StubMedia),      // → Arc::new(WinMedia::new(tx.clone(), audio_tx))
    power: Arc::new(StubPower),      // → Arc::new(WinPower)
    ...
};
// 6. Server-side pause flag (SPEC §11)
let (_pause_tx, pause_rx) = tokio::sync::watch::channel(false);
let deps = ServerDeps { executors, auth, pause: pause_rx };  // += volume: volume_rx
```
Audio thread spawn mirrors step 3; the volume `watch::channel(VolumeState::default())` mirrors step 6, with the sender handed to the audio thread.

---

### Server: router `Msg::VolChanged` arm (modify)

**Analog:** the existing S→C-only ignore arm (`router.rs:247-257`):
```rust
// S→C-only types arriving FROM a client are known-but-invalid
...
| Msg::Pong(_)
| Msg::Err(_) => Vec::new(),
```
Add `Msg::VolChanged(_)` here. It is NOT executor-bound (`is_executor_bound`, router.rs:263 — same class as `pong`). The exhaustive match will force every site; that's the point.

---

### Rust codec: `Msg::VolChanged` (modify `codec/json.rs`)

**Analog:** its own `MediaPayload`/`Msg::Media` entries — four touch points, same file:
- payload struct at line 134 (`pub struct MediaPayload { action, value }` shape, serde derives)
- enum variant at lines 249–261 (`Media(MediaPayload)`)
- decode arm at line 310 (`"media" => Msg::Media(payload(p)?)`)
- encode arm at line 375 (`Msg::Media(pl) => ("media", val(pl))`)

→ `VolChangedPayload { value: u64, muted: bool }` (both REQUIRED — missing field = hard decode error, matching fixture 03), wire type string `"vol.changed"`.

---

### Fixtures: `protocol/fixtures/volume/` (NEW family)

**Analog:** `protocol/fixtures/handshake/02-challenge.json`:
```jsonc
{
  "name": "challenge",
  "description": "Server challenge with a fixed 64-lowercase-hex nonce ...",
  "wire":   { "t": "challenge", "p": { "nonce": "..." } },
  "expect": { "t": "challenge", "p": { "nonce": "..." } }
}
```
**IMPORTANT (RESEARCH A6, resolved):** both loaders enumerate FILES within a family dir at runtime (`fixtures.rs:28-38` `fixture_files(family)`, `fixture_test.dart:34-45` `fixtureFiles(family)`), but the FAMILIES themselves are hard-coded as per-family test functions (e.g. `codec_fixtures_mouse_binary` in fixtures.rs:49; `fixture_test.dart` groups). The new `volume/` family needs a new test fn in `server/server-core/tests/fixtures.rs` AND a new group in `app/packages/remote_protocol/test/fixture_test.dart` — copy the existing text-family fn/group shape.

---

### Dart codec: `VolChangedMsg` (modify `json_codec.dart`)

**Analog:** `MediaMsg` (`json_codec.dart:352-374`):
```dart
final class MediaMsg extends RemoteMessage {
  final String action;
  final int? value;
  const MediaMsg({required this.action, this.value});
  factory MediaMsg.fromPayload(Map<String, dynamic> p) =>
      MediaMsg(action: _req<String>(p, 'action'), value: _opt<int>(p, 'value'));
  @override
  String get t => 'media';
  @override
  Map<String, Object?> toPayload() => {'action': action, if (value != null) 'value': value};
}
```
Plus one entry in the `decodeText` switch (`json_codec.dart:742-773`): `'vol.changed' => VolChangedMsg.fromPayload(p),`. Use `_req<int>` and `_req<bool>` (both required). Version bump in `version.dart`: `protoVersion = '1.1'`, `protoMinor = 1` (watch Pitfall 10: tests asserting `'1.0'` literals in handshake_fsm_test.dart, integration.rs, beacon_test.dart, connection_service_test.dart).

---

### Client: `connection_service.dart` `_onFrame` branch (modify)

**Analog:** its own `PongMsg` branch (`connection_service.dart:422-440`):
```dart
void _onFrame(dynamic frame) {
  if (frame is! String) return;
  final RemoteMessage msg;
  try {
    msg = decodeText(frame).msg;
  } on FormatException {
    return;
  }
  if (msg is PongMsg) {
    _probe?.onPong(msg);
    return;
  }
  final driver = _driver;
  ...
}
```
Insert the `VolChangedMsg` branch after the pong branch, before driver routing: store a value-equal `VolumeSnapshot` field + `_notify()` (the `changes` stream is at line 252, `_notify()` at 552-556). Snapshot field pattern mirrors `_lastAuthFailure` (line 170) — read surface getter + `changes` ping.

---

### Client: `volume_store.dart` (NEW Riverpod notifier)

**Analog:** `ConnectionStatusNotifier` (`connection_providers.dart:45-89`) — the house Riverpod-3 pattern:

**Value-equal snapshot** (lines 45-63):
```dart
class ConnectionStatus {
  final ChipStatus chip;
  final ReconnectState fsmState;
  const ConnectionStatus({required this.chip, required this.fsmState});
  @override
  bool operator ==(Object other) =>
      other is ConnectionStatus && other.chip == chip && other.fsmState == fsmState;
  @override
  int get hashCode => Object.hash(chip, fsmState);
}
```

**Notifier over `changes` stream** (lines 66-89):
```dart
class ConnectionStatusNotifier extends Notifier<ConnectionStatus> {
  StreamSubscription<void>? _sub;
  @override
  ConnectionStatus build() {
    final service = ref.watch(connectionServiceProvider);
    _sub?.cancel();
    _sub = service.changes.listen((_) => state = _snapshot(service));
    ref.onDispose(() { _sub?.cancel(); _sub = null; });
    return _snapshot(service);
  }
}
final connectionStatusProvider =
    NotifierProvider<ConnectionStatusNotifier, ConnectionStatus>(ConnectionStatusNotifier.new);
```
Volume store adds: drag-ignore flag (D-04 — pushed snapshots ignored while dragging), ~50ms send throttle over an injected clock (see `ConnectionService`'s `nowMillis`/`schedule` ctor seams, connection_service.dart:190-206, for the injectable-seam style), and the authed-gate policy `if (!service.isAuthed) return;` on setvol emission (Pitfall 12). Sends via `service.sendReliable(MediaMsg(action: 'setvol', value: v))`.

---

### Client: pure FSMs (`confirm_track_fsm.dart`, `presenter_timer.dart`)

**Analog:** `lib/keyboard/modifier_fsm.dart` — the house pure-FSM style (header, `modifier_fsm.dart:1-27`):
```dart
/// Pure sticky-modifier FSM (KEY-03, D-10/D-12) — no Flutter, no IO.
///
/// Per-modifier state machine ... in the reconnect_fsm house style: events
/// in, effects out, the driver ... executes every effect. This class holds
/// no timers, no channel, and imports nothing from Flutter or the IO
/// libraries.
```
State enums like `ModifierState { rest, armed, locked }` (lines 44-53). For the timer's clock seam, copy `GestureClassifier`'s injected clock (`trackpad_screen.dart:105-107`):
```dart
_classifier = GestureClassifier(
  nowMillis: () => DateTime.now().millisecondsSinceEpoch,
);
```
Tests go in `test/power/confirm_track_fsm_test.dart` / `test/presenter/presenter_timer_test.dart` mirroring `test/keyboard/modifier_fsm_test.dart`'s deterministic style.

---

### Client: navigation reroute (`device_list_screen.dart`, modify)

**Analog:** its own two push sites (lines 136 and 222 — Pitfall 14 confirms exactly two):
```dart
unawaited(
  Navigator.of(context).push(
    MaterialPageRoute<void>(builder: (_) => const TrackpadScreen()),
  ),
);
```
Replace `TrackpadScreen` with `HubScreen` at BOTH sites; extract one `_openHub(context)` helper so they can't drift. Hub → tool screens use the same plain `MaterialPageRoute` push (no go_router, per CLAUDE.md).

---

### Client: screens (`hub_screen.dart`, `media_screen.dart`, `power_screen.dart`, `presenter_screen.dart`, `browser_screen.dart`)

**Analog:** `trackpad_screen.dart` throughout — the only existing connected-capable screen.

**Screen skeleton + service caching** (`trackpad_screen.dart:48-62, 91-94`):
```dart
class TrackpadScreen extends ConsumerStatefulWidget { ... }
class _TrackpadScreenState extends ConsumerState<TrackpadScreen> {
  /// Cached once — the provider is an app-lifetime singleton.
  late final ConnectionService _service;
  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
```

**Header chip + banner chrome (D-02, apply to every new screen)** (`trackpad_screen.dart:230-235, 273-295`):
```dart
final status = ref.watch(connectionStatusProvider);
final authed = status.chip == ChipStatus.connected;
...
ReconnectingBannerSlot(
  visible: status.chip == ChipStatus.reconnecting,
  onRetry: _service.retryNow,
),
Align(
  alignment: Alignment.topRight,
  child: Padding(
    padding: const EdgeInsets.all(16),
    child: IgnorePointer(child: ConnectionHeaderChip.forService(_service)),
  ),
),
```
(`ConnectionHeaderChip`/`ReconnectingBannerSlot` come from `lib/widgets/connection_header.dart`; the chip self-polls on `kHudReadThrottle` — no wiring needed beyond the factory.)

**Wakelock (presenter, D-09)** (`trackpad_screen.dart:144-145, 155`):
```dart
// initState:
WakelockPlus.enable();
// dispose:
WakelockPlus.disable();
```

**Haptics + reliable send (all tool buttons)** (`trackpad_screen.dart:183-186`):
```dart
void _onMouseButton(String button) {
  _service.sendReliable(ClickMsg(button: button));
  unawaited(HapticFeedback.lightImpact());
}
```
→ presenter tap zones: `sendReliable(PresentMsg(action: 'next'))` + haptic; browser grid: `sendReliable(BrowserMsg(action: ...))`; power lock/sleep: `PowerMsg` then `ConfirmMsg` same-tick (FIFO guaranteed by SendPolicy).

**Dark-theme styling constants** (locked palette, seen at `trackpad_screen.dart:241, 195-197` and `connection_header.dart:29-36`):
```dart
backgroundColor: const Color(0xFF0E0F12),   // bg
const Color(0xFF16181D)                     // surface
const Color(0xFF2A2D34)                     // hairline
const Color(0xFFE6E8EB)                     // text
const Color(0xFF4C8DFF)                     // accent
const Color(0xFF6B7280)                     // muted
```

**Button/tile chrome** (`trackpad_screen.dart:333-356` — the circular-button cluster; reuse `Material` + `InkWell` + hairline-border shape for hub tiles and browser grid buttons):
```dart
Material(
  color: const Color(0xFF16181D),
  shape: const CircleBorder(side: BorderSide(color: Color(0xFF2A2D34))),
  child: InkWell(
    customBorder: const CircleBorder(),
    onTap: ...,
    child: SizedBox(width: 48, height: 48, child: Icon(..., color: Color(0xFFE6E8EB))),
  ),
)
```

**Slider styling (media volume)** (`trackpad_screen.dart:213-222` — the sensitivity slider):
```dart
Slider(
  value: ref.watch(sensitivityProvider),
  min: kSensitivityMin, max: kSensitivityMax,
  activeColor: const Color(0xFF4C8DFF),
  inactiveColor: const Color(0xFF2A2D34),
  onChanged: ref.read(sensitivityProvider.notifier).set,
)
```

**Gated-muted disabled state** (`trackpad_screen.dart:388-390` "muted, not red"):
```dart
MouseButtonsBar(onPress: _onMouseButton, enabled: authed),
```

## Shared Patterns

### Send-and-forget executor contract (server)
**Source:** `input_thread.rs` (module doc + `let _ =` on every OS call) and `mouse_keys.rs:31`
**Apply to:** `audio_thread.rs`, `media.rs`, `power.rs` — every OS interaction drops on failure, never blocks the session task, never panics.

### Value-equal snapshot + `changes` ping (client)
**Source:** `connection_providers.dart:45-63` + `connection_service.dart:552-556`
**Apply to:** volume snapshot, any new read surface on ConnectionService.

### Injected seams for testability
**Source:** `ConnectionService` ctor (`connection_service.dart:190-200`: `connect`, `schedule`, `nowMillis`, `random`) and `GestureClassifier(nowMillis: ...)`
**Apply to:** volume-store throttle, confirm-track FSM, presenter timer — clock and timers injected, logic pure.

### No-secrets logging (both sides)
**Source:** `session.rs:13-14`, `input_thread.rs:252` (SPEC §12)
**Apply to:** all new code. Volume state is not secret but the discipline holds — no payload logging.

### Additive protocol amendment recipe
**Source:** Phase-1 discipline, concretized by the challenge fixture + json.rs/json_codec.dart Media entries
**Apply to:** the `vol.changed` amendment — SPEC §7 row + §2 note, schema `$defs`, `fixtures/volume/` (positive x2 + negative x1), Rust codec 4 touch points, Dart codec 2 touch points, version constants both sides, NEW per-family test fn/group in both fixture loaders.

## No Analog Found

| File | Role | Data Flow | Reason / Guidance |
|------|------|-----------|-------------------|
| Hub tile grid layout (`hub_screen.dart` interior) | UI composite | — | No grid/dashboard exists yet. Compose from the Material+InkWell tile chrome above; build for 8-tile growth (Phase 7), 5 tiles now |
| Slide-to-confirm track widget + red countdown dialog (`power_screen.dart` interior) | UI composite | — | No drag-track or countdown widget exists. FSM side has the modifier_fsm analog; widget renders FSM progress. Countdown mirrors server `CONFIRM_WINDOW` (10s, `router.rs:26`); a late confirm earns `err{noPendingAction}` (`router.rs:186-190`) — treat as ignorable |
| COM/WASAPI calls (`audio_thread.rs` interior) | OS integration | — | First COM usage in repo. Thread-ownership pattern from input_thread applies; API shapes are in RESEARCH Code Examples (verified against windows-docs-rs) |

## Metadata

**Analog search scope:** `server/server-core/src`, `server/server-windows/src`, `server/server-core/tests`, `app/remote_control/lib`, `app/packages/remote_protocol` (lib + test), `protocol/fixtures`
**Files scanned:** ~20 read/grepped (session.rs, input_thread.rs, mouse_keys.rs, stubs.rs, keymap.rs, main.rs, transport/mod.rs, router.rs (targeted), json.rs (targeted), fixtures.rs, connection_service.dart, connection_providers.dart, trackpad_screen.dart, device_list_screen.dart (targeted), json_codec.dart (targeted), version.dart, modifier_fsm.dart, connection_header.dart, fixture_test.dart, challenge fixture)
**Pattern extraction date:** 2026-07-10
