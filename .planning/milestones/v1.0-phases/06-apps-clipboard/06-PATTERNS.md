# Phase 6: Apps & Clipboard - Pattern Map

**Mapped:** 2026-07-11
**Files analyzed:** 16 (new + modified)
**Analogs found:** 16 / 16 (every seam clones a green Phase-5 precedent)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `server-windows/src/apps_thread.rs` (new) | provider (OS thread) | event-driven poll + command | `server-windows/src/audio_thread.rs` | exact |
| `server-windows/src/clip_thread.rs` (new) | provider (OS thread) | event-driven poll + command | `server-windows/src/audio_thread.rs` | exact |
| `server-windows/src/executors/apps.rs` (new) | executor | request-response | `server-windows/src/executors/media.rs` | exact |
| `server-windows/src/executors/clipboard.rs` (new) | executor | request-response | `server-windows/src/executors/media.rs` | exact |
| `server-windows/src/main.rs` (mod) | config/composition root | wiring | `main.rs` audio-thread block (self) | exact |
| `server-core/src/transport/mod.rs` (mod) | model/config | data struct | `VolumeState`/`ServerDeps` (self) | exact |
| `server-core/src/transport/session.rs` (mod) | transport | pub-sub push | `session.rs` `volume.changed()` branch | exact |
| `server-core/src/executors/mod.rs` (mod) | model/trait | — | `WindowInfo`/`Apps`/`Clipboard` (self) | exact |
| `server-core/src/dispatch/router.rs` (mod) | router | request-response | `router.rs` apps/clip arms (self) | exact |
| `server-core/src/codec/json.rs` (mod) | codec | transform | `json.rs` `WindowInfo` serde (self) | exact |
| `remote_protocol/lib/src/json_codec.dart` (mod) | codec | transform | `json_codec.dart` `WindowInfo`/`AppsChangedMsg` (self) | exact |
| `app/.../apps/apps_screen.dart` (new) | component (screen) | pub-sub render | `app/.../media/media_screen.dart` | role-match |
| `app/.../apps/apps_store.dart` (new) | store/notifier | pub-sub + persistence | `volume_store.dart` + `store/device_store.dart` | exact |
| `app/.../clipboard/clipboard_screen.dart` (new) | component (screen) | pub-sub + lifecycle | `media_screen.dart` | role-match |
| `app/.../clipboard/clip_store.dart` (new) | store/notifier | pub-sub + persistence | `volume_store.dart` + `device_store.dart` | exact |
| `app/.../net/connection_service.dart` (mod) | transport | pub-sub park | `connection_service.dart` `VolChangedMsg` arm | exact |
| `app/.../hub/hub_screen.dart` (mod) | config registry | — | `hub_screen.dart` `kHubTiles` (self) | exact |

## Pattern Assignments

### `server-windows/src/apps_thread.rs` + `clip_thread.rs` (provider OS thread, event-driven)

**Analog:** `server/server-windows/src/audio_thread.rs` (read in full — the exact template)

**Copy this structure verbatim** — command enum, pure testable predicate, `recv_timeout` loop, `push_if_changed`, `CoInitializeEx`/`CoUninitialize` bracketing:

**Command enum + pure helper** (audio_thread.rs lines 29-54): define `AppsCmd { Focus(u64), Close(u64), Launch(String) }` and `ClipCmd { Set(String) }` the way `AudioCmd` is defined. Factor the Alt-Tab filter predicate and the clip sensitive/large/echo gate into pure functions beside the thread (mirrors `pct_from_scalar` at lines 47-54) so Wave-0 unit tests hit them without OS calls.

**push_if_changed value-equality** (audio_thread.rs lines 116-124):
```rust
fn push_if_changed(tx: &Sender<VolumeState>, last: &mut Option<VolumeState>) {
    let Some(state) = read_state() else { return; };
    if *last != Some(state) {
        let _ = tx.send(state);
        *last = Some(state);
    }
}
```
Clone for `Vec<WindowInfo>` (apps) and `ClipState` (clip). This is the anti-flood discipline the research calls mandatory. For clip, the echo-suppression fingerprint is recorded here before pushing (skip a push whose hash matches the last `ClipCmd::Set`).

**Run loop** (audio_thread.rs lines 130-161): `CoInitializeEx(None, COINIT_MULTITHREADED)` once at top (apps thread needs it for shell icon APIs; clip thread does not require COM but arboard must stay on this one thread), `recv_timeout` with `Ok(cmd) => execute + push`, `Timeout => push_if_changed`, `Disconnected => break`, `CoUninitialize()` on exit. Apps poll 500 ms, clip poll 250 ms (per research A5).

**Error discipline:** every HRESULT `.ok()?`-to-`None` or `let _ =`-dropped, never a panic (audio_thread.rs lines 60-71, SAFETY comments).

---

### `server-windows/src/executors/apps.rs` + `clipboard.rs` (executor, request-response)

**Analog:** `server/server-windows/src/executors/media.rs` (read in full)

**Sender-only struct** (media.rs lines 20-35) — the executor holds ONLY `Send + Sync` channel senders + a `watch::Receiver` for reads:
```rust
pub struct WinMedia {
    input_tx: Sender<Cmd>,
    audio_tx: Sender<AudioCmd>,
}
impl WinMedia {
    pub fn new(input_tx: Sender<Cmd>, audio_tx: Sender<AudioCmd>) -> Self { ... }
}
```
`WinApps` holds `mpsc::Sender<AppsCmd>` + `watch::Receiver<Vec<WindowInfo>>`; `list()` reads `rx.borrow().clone()` (the only synchronous, non-blocking touch), `focus/close/launch` send an `AppsCmd`. `WinClipboard` holds `Sender<ClipCmd>` + `watch::Receiver<ClipState>`; `get()` reads the snapshot, `set()` sends `ClipCmd::Set`.

**Send-and-forget** (media.rs lines 37-58): every command is `let _ = self.tx.send(...)` — a closed channel drops the frame, never blocks the read task, never runs Win32/COM on a tokio worker.

**Trait signature change (Phase-6-owned):** `server-core/src/executors/mod.rs` lines 85-90 — amend `Apps::focus/close/launch` to return `bool` so the router can emit `err`. `Clipboard` (lines 93-96) unchanged.

---

### `server-core/src/transport/session.rs` (transport, pub-sub push)

**Analog:** the `volume.changed()` authed-gated `select!` branch, lines 159-172 (read):
```rust
changed = volume.changed(), if volume_alive && ctx.auth_state == AuthState::Authed => {
    match changed {
        Ok(()) => {
            let state = *volume.borrow_and_update();
            if tx.send(vol_changed_frame(state)).await.is_err() { break 'read; }
        }
        Err(_) => volume_alive = false,
    }
}
```
Add two branches: `apps.changed()` → `AppsChanged` frame, and `clip.changed()` → `ClipChanged` frame. The `== AuthState::Authed` guard is the privacy backstop (T-05-05).

**Two deltas from the volume branch (research Pattern 2 note):**
1. Apps: no after-auth snapshot required (client sends `apps.list` on screen open). Volume sends one after-auth snapshot (lines 165 `borrow_and_update`); do NOT clone that for apps unless pre-warming is wanted.
2. Clip: **must NOT send an after-auth snapshot** — dumping the PC clipboard to every connecting phone is a privacy leak (Pitfall 8). Clip is pull-only (`clip.get`) + change-push.

---

### `server-core/src/dispatch/router.rs` (router, request-response)

**Analog:** existing apps/clip arms, lines 194-218 (read). Currently:
```rust
Msg::AppsFocus(p) => { exec.apps.focus(p.id); Vec::new() }
Msg::AppsClose(p) => { exec.apps.close(p.id); Vec::new() }
Msg::AppsLaunch(p) => { exec.apps.launch(&p.path); Vec::new() }
```
Change to emit `err` on `false` (research Flag 4):
```rust
Msg::AppsFocus(p) => if exec.apps.focus(p.id) { Vec::new() } else { vec![err("windowGone", ...)] },
```
Same for `close` (`windowGone`) and `launch` (`launchFailed`). The `err(...)` helper already exists (used at line 238). `AppsChanged`/`ClipChanged` stay in the S→C-only ignore arm (lines 250-258) — clients cannot spoof them. `is_executor_bound` (lines 264-279) already pause-gates `AppsLaunch/Focus/Close` + `ClipSet` and exempts `apps.list`/`clip.get`. Update the two router tests (lines 783-810) that assert empty replies — `MockExecutors` return `true`.

---

### `server-core/src/executors/mod.rs` + `codec/json.rs` (model + codec, transform)

**Analog:** `WindowInfo` struct, mod.rs lines 40-44 (read):
```rust
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct WindowInfo { pub id: u64, pub title: String }
```
Add two optional fields (research Flag 2, mirrors the Phase-5 `vol.changed` 1.1 amendment):
```rust
#[serde(default, skip_serializing_if = "Option::is_none")]
pub icon: Option<String>,   // base64 PNG 32×32
#[serde(default, skip_serializing_if = "Option::is_none")]
pub path: Option<String>,   // resolved exe path; None = non-pinnable (UWP)
```
`Eq` derive: `Option<String>` is fine. Bump `SERVER_PROTO_VERSION` → `"1.2"` in json.rs. Add golden fixtures: one `WindowInfo` with `icon`+`path`, one legacy without (mirror the `volume/` fixture dir from 05-01). Codec round-trip tests live at json.rs lines 505-530.

**Add core `ClipState` struct** in transport/mod.rs beside `VolumeState` (lines 32-38 template):
```rust
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct VolumeState { pub value: u8, pub muted: bool }
```
Clone shape for `ClipState { pub text: String, /* + gate flags if needed */ }`. Add `apps`/`clip` receivers to `ServerDeps` (mod.rs lines 45-55) beside `pub volume: watch::Receiver<VolumeState>`.

---

### `remote_protocol/lib/src/json_codec.dart` (codec, transform)

**Analog:** `WindowInfo` (lines 59-67), `_windowList` (lines 46-54), `AppsChangedMsg` (523-535), `ClipSetMsg`/`ClipChangedMsg` (547-586) — all already exist and pass round-trip. Add optional `icon`/`path` to `WindowInfo` and its parse in `_windowList` (line 54) with unknown-field tolerance (already the codec's proven behavior, D-05).

---

### `server-windows/src/main.rs` (composition root, wiring)

**Analog:** the audio-thread wiring block, lines 52-72 (read):
```rust
let (audio_tx, audio_rx) = std::sync::mpsc::channel::<AudioCmd>();
let (volume_tx, volume_rx) = tokio::sync::watch::channel(VolumeState::default());
std::thread::spawn(move || audio_thread::run_audio_thread(audio_rx, volume_tx));
let executors = Executors {
    mouse_keys: Arc::new(EnigoMouseKeys::new(tx.clone())),
    media: Arc::new(WinMedia::new(tx, audio_tx)),
    power: Arc::new(WinPower),
    apps: Arc::new(StubApps),          // ← replace with WinApps
    clipboard: Arc::new(StubClipboard),// ← replace with WinClipboard
};
```
Spawn `run_apps_thread` + `run_clip_thread`, build `WinApps`/`WinClipboard` from their `(cmd_tx, snapshot_rx)` pairs, and add `apps: apps_rx, clip: clip_rx` to the `ServerDeps` (lines 115-119). Delete the `StubApps`/`StubClipboard` imports (line 24) — the stubs in `executors/stubs.rs` become dead and can be removed.

---

### `app/.../net/connection_service.dart` (transport, pub-sub park)

**Analog:** the `VolChangedMsg` arm, lines 462-469 (read) + `VolumeSnapshot` class lines 116-128 + field/getter lines 193/274:
```dart
if (msg is VolChangedMsg) {
  _volumeSnapshot = VolumeSnapshot(value: msg.value, muted: msg.muted);
  _notify();
  return;
}
```
Add value-equal `AppsSnapshot`/`ClipSnapshot` classes (clone lines 116-128, with `operator ==`/`hashCode`), parked fields + getters, and arms for `AppsListMsg` (the `apps.list` reply), `AppsChangedMsg`, `ClipChangedMsg`, `ClipSetMsg` (the `clip.get` reply), and `ErrMsg` (park `_lastError` for toast surfacing). S→C only — never routed to the driver, no payload logged (SPEC §12).

---

### `app/.../apps/apps_store.dart` + `clipboard/clip_store.dart` (store/notifier)

**Analog A (Notifier):** `volume_store.dart` `VolumeNotifier` lines 176-241 + `VolumeViewState` 140-171:
```dart
class VolumeNotifier extends Notifier<VolumeViewState> {
  @override VolumeViewState build() {
    _service = ref.watch(connectionServiceProvider);
    _sub = _service.changes.listen((_) => _onChange());
    ref.onDispose(() => _sub?.cancel());
    _ingestSnapshot();
    return _view();
  }
  void _onChange() { _ingestSnapshot(); state = _view(); }
}
```
`AppsNotifier` re-snapshots `service.appsSnapshot` into a value-equal `AppsViewState`; `ClipNotifier` ingests `clipSnapshot` and gates apply-vs-ignore on its local auto-sync toggle (research A4: server pushes always post-auth; client decides). Expose via `NotifierProvider` (line 244-245). Sends go through `service.sendReliable(...)` (line 187).

**Analog B (PrefsKv persistence):** `store/device_store.dart` — the `PrefsKv` seam (lines 49-56), `SharedPrefsKv` adapter (79-92), constructor-injected store (149-159), JSON list load/save with total-by-construction corruption tolerance (206-221, 275-289):
```dart
Future<Map<String, Object?>> _loadRawDevices() async {
  final json = await _prefs.getString(_devicesPrefsKey);
  if (json == null) return {};
  try { return (jsonDecode(json) as Map).cast(); }
  on Object { return {}; } // corrupt → degrade, never throw
}
```
Favorites store: prefs key `apps.favorites` (JSON list `[{name,path,icon}]`); history store: `clip.history` (JSON list ≤5, consecutive dedupe); `clip.autosync` bool default false. Non-secrets → `PrefsKv`/shared_preferences ONLY, never SecureKv (house rule; device_store lines 12-15). Constructor-inject the seam so tests run against fakes.

---

### `app/.../apps/apps_screen.dart` + `clipboard/clipboard_screen.dart` (component screen)

**Analog:** `media/media_screen.dart` lines 1-55 (read) — `ConsumerStatefulWidget`, locked palette constants (lines 40-45: `_bg 0xFF0E0F12`, `_surface 0xFF16181D`, `_hairline 0xFF2A2D34`, `_text 0xFFE6E8EB`, `_accent 0xFF4C8DFF`, `_muted 0xFF6B7280`), app bar + inherited `connection_header.dart` chip + reconnecting banner, `ref.watch(providerFrom store)` to render, `sendReliable` on interaction. Clipboard screen adds an `AppLifecycleListener` (Flutter 3.13+) for the D-08 resume→`clip.set` phone→PC sync and a persistent honesty note.

---

### `app/.../hub/hub_screen.dart` (config registry)

**Analog:** `kHubTiles` list, lines 71-101 (read). Insert two `HubTileSpec` entries (the spec is `{label, icon, builder}`, lines 50-66):
```dart
HubTileSpec(label: 'Apps', icon: Icons.apps, builder: (_) => const AppsScreen()),
HubTileSpec(label: 'Clipboard', icon: Icons.content_paste, builder: (_) => const ClipboardScreen()),
```
The grid (lines 105-149) handles any count with no structural change — placement is Claude's discretion.

## Shared Patterns

### Dedicated OS thread + watch producer + mpsc commands
**Source:** `server-windows/src/audio_thread.rs` (full file)
**Apply to:** `apps_thread.rs`, `clip_thread.rs`
Any Win32/COM/blocking work runs here, never on a tokio worker (anti-pattern). Pure predicates factored out for testing (`pct_from_scalar` precedent, lines 47-54).

### Authed-gated S→C push branch
**Source:** `server-core/src/transport/session.rs` lines 159-172
**Apply to:** `apps.changed` and `clip.changed` branches
The `if ... && ctx.auth_state == AuthState::Authed` guard is the access-control boundary (ASVS V2/V4). `borrow_and_update()` clears the changed flag.

### Client value-equal snapshot Notifier
**Source:** `app/.../media/volume_store.dart` `VolumeNotifier` (176-241) + `connection_service.dart` `VolChangedMsg` arm (462-469)
**Apply to:** `AppsNotifier`, `ClipNotifier`, and the new `_onFrame` arms
Park a value-equal snapshot in ConnectionService → ping `changes` → Notifier re-snapshots → screen renders. Value-equality skips no-op rebuilds.

### PrefsKv client persistence (non-secrets)
**Source:** `app/.../store/device_store.dart` lines 49-92, 149-159, 206-289
**Apply to:** favorites store, history store, auto-sync toggle
Constructor-injected `PrefsKv` seam; JSON blob load/save with corruption-tolerant `try/on Object` degrade; secrets discipline — nothing sensitive here (clipboard sensitive clips are *skipped server-side*, never persisted).

### Sender-only executor over the OS thread
**Source:** `server-windows/src/executors/media.rs` (full file)
**Apply to:** `WinApps`, `WinClipboard`
Executor holds only `Send + Sync` senders + a `watch::Receiver` for reads; every command `let _ =` send-and-forget.

## No Analog Found

None. Every seam this phase needs has a green Phase-5 precedent in-repo. The only genuinely new code with no direct analog is the *Win32 body* of the poll functions (Alt-Tab filter predicate, DWM cloak check, icon extraction/PNG-encode, exe-path resolution, sensitive-clip format check) — the research §"Resolving the Four Research Flags" + §"Code Examples" supply those recipes verbatim; use RESEARCH.md for the Win32 call sequences, this file for the surrounding structure.

## Metadata

**Analog search scope:** `server/server-core/src/{executors,transport,dispatch,codec}`, `server/server-windows/src/{,executors}`, `app/remote_control/lib/{media,hub,net,store}`, `app/packages/remote_protocol/lib/src`
**Files scanned:** ~14 read first-hand
**Pattern extraction date:** 2026-07-11
