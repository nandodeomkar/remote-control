# Phase 5: Media, Power, Presenter & Browser - Research

**Researched:** 2026-07-10
**Domain:** Windows system control (WASAPI volume, power APIs, media keys) + Flutter control-surface UI + one additive wire-protocol amendment
**Confidence:** HIGH

## Summary

Phase 5 is mostly *thin*: the router already routes every message family this phase needs (`media`, `power`+`confirm` double-gate, `browser`, `present`), keymap.rs already maps every browser/present macro code (04-02), and the client already has `sendReliable`, the header chip, and the wakelock/haptics precedent. The genuinely new work splits into four blocks: (1) real Windows `Media`/`Power` executors replacing `StubMedia`/`StubPower` — enigo media keys via the existing input thread, `IAudioEndpointVolume` on a new dedicated COM audio thread, `LockWorkStation`/`SetSuspendState`/`ExitWindowsEx` with SE_SHUTDOWN_NAME privilege enablement; (2) the `vol.changed` S→C push — a new `tokio::sync::watch<VolumeState>` seam in `ServerDeps` mirroring the existing `pause` watch, a new select! branch in `run_session`, and a full additive protocol amendment (SPEC row, schema, golden fixtures, both codecs, minor version bump to `"1.1"`); (3) the client volume store + four tool screens (Media, Power, Presenter, Browser) reachable from a new hub screen that replaces the row-tap→trackpad route; (4) pure-FSM state for slide-to-confirm and the presenter timer, per house style.

The two verification-sensitive facts are both confirmed against Microsoft's official docs: `SetSuspendState(FALSE, …)` suspends (sleep) — never hibernates — and requires SE_SHUTDOWN_NAME enabled via `AdjustTokenPrivileges`; `ExitWindowsEx` is asynchronous, also requires SE_SHUTDOWN_NAME, and `EWX_SHUTDOWN` alone does NOT power off — `EWX_POWEROFF` is the correct shutdown flag. For MED-02's volume-state mechanism, D-03 delegated callback-vs-poll to research: **the decision is poll** (250 ms on a dedicated audio thread with per-tick endpoint re-acquisition). `RegisterControlChangeNotify` requires implementing a COM callback interface with strict unregister/ref-count lifetime rules and silently orphans itself when the default audio device changes; polling costs nothing perceptible, reuses the input-thread house pattern, and survives device switches for free.

**Primary recommendation:** No new dependencies anywhere — only new `windows`-crate *features*. Build the audio thread as a clone of the input-thread pattern (mpsc commands + `recv_timeout(250ms)` poll tick), push volume state through a `watch` channel shaped exactly like the existing `pause` watch, and keep every new stateful client piece (confirm track, presenter timer, volume slider throttle) a pure IO-free FSM.

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

#### Control-surface navigation (pre-Phase-7)
- **D-01:** Interim **Remote hub screen**: tapping a connected device row opens
  a slim hub with the trackpad (existing) plus tiles for Media, Power,
  Presenter, Browser. The hub is built as the skeleton the Phase-7 dashboard
  grows into — NOT throwaway UI. Browser controls get their own small screen
  off the hub.
- **D-02:** Existing Phase-3 flow (row tap → trackpad) changes to row tap →
  hub; trackpad is the first/primary tile. Header status/latency chip + banner
  (Phase-3 surface) appears on every connected-capable screen including the new
  hub and tool screens.

#### Volume slider + state sync (MED-02)
- **D-03:** Wire amendment (additive, minor proto version bump): new S→C
  message `vol.changed {value: 0-100, muted: bool}` pushed (a) right after
  auth, (b) whenever server-side volume/mute changes externally. Server side
  uses IAudioEndpointVolume state (change callback if practical, else short
  poll — researcher decides mechanism).
- **D-04:** Slider sends **throttled `setvol` while dragging** (~50ms cadence)
  for live audio feedback; incoming `vol.changed` pushes are IGNORED during an
  active drag so the finger always wins; after release the pushed state is
  authoritative again.

#### Power confirm UX (PWR-01..03)
- **D-05:** All four power actions sit behind a **slide-to-confirm track**.
  Lock/sleep: completing the slide sends `power` immediately followed by
  `confirm` (single deliberate gesture; two wire messages per SPEC §7).
- **D-06:** Restart/shutdown: completing the slide sends `power` only, then a
  red countdown dialog ("Restart PC? 10s") appears; its confirm button sends
  the `confirm` message. Dialog auto-dismisses when the SPEC 10s window
  expires. Two distinct deliberate gestures — no single-action path (satisfies
  PWR-03 and roadmap SC3).

#### Presenter screen (PRES-01/02)
- **D-07:** Full-screen split tap zones: giant Next (right ~2/3) / Prev (left
  ~1/3), bottom bar with Start show / End show / Blank toggle + elapsed timer.
  Haptic tick per slide advance.
- **D-08:** Timer is **manual**: starts on "Start show" tap; tapping the timer
  pauses/resets. Timer is client-local (no wire involvement).
- **D-09:** Keep-awake (wakelock_plus) active while the presenter screen is
  open (per PROJECT stack notes; trackpad already has it).

### Claude's Discretion
Owner delegated area selection and confirmed all recommended options. Exact
styling, tile layout, slider widget, tunable constants (throttle ms, dialog
countdown rendering), media screen composition (transport buttons + slider on
one screen), mute button placement, browser screen button grid, and slice
ordering are Claude/planner discretion within the decisions above. MVP mode:
expect vertical slices during planning.

### Deferred Ideas (OUT OF SCOPE)
- None new from this discussion.
- **Server one-pairing-per-run** (todo) — pairing lifecycle, closes with
  Phase-7 persistent token storage. Deferred.
- **Overloaded `noPairing` reason copy** (todo) — server-protocol/pairing
  copy, not control-center scope. Deferred to Phase 7 / protocol follow-up.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MED-01 | Play/pause, next, previous system-wide | enigo `Key::MediaPlayPause/MediaNextTrack/MediaPrevTrack` verified present in 0.6.1; inject via existing input thread (`Cmd::KeyTap` + new keymap entries). Router `media` arm already routes to the `Media` trait |
| MED-02 | Absolute volume slider + mute, accurate via server volume-state push | `IAudioEndpointVolume` methods verified (Get/SetMasterVolumeLevelScalar, Get/SetMute); poll mechanism decided (250 ms audio thread); `vol.changed` push via new `watch<VolumeState>` seam in ServerDeps + select! branch in run_session; full amendment recipe below |
| PWR-01 | Lock behind slide-to-confirm | `LockWorkStation()` (`Win32_System_Shutdown`, no privilege needed); client confirm-track FSM; router double-gate already enforces `power`→`confirm` |
| PWR-02 | Sleep (SetSuspendState) behind slide-to-confirm | `SetSuspendState(false, …)` = suspend not hibernate [CITED]; SE_SHUTDOWN_NAME privilege helper; dispatch off the session task (dedicated thread) |
| PWR-03 | Restart/shutdown behind slide-to-confirm PLUS server confirm message | Server 10s window already implemented + tested (router.rs); client D-06 countdown dialog maps 1:1 onto it; `ExitWindowsEx(EWX_REBOOT / EWX_POWEROFF \| EWX_FORCEIFHUNG, planned-reason)` verified |
| PRES-01 | Slides next/prev, start/end show, blank | `present` macro table + keymap coverage ALREADY working server-side since 04-02 (verified: router `present_macro` → `map_key` covers Right/Left/F5/Esc/B). Client screen only |
| PRES-02 | Elapsed presentation timer | Client-local manual timer (D-08); pure FSM + Stopwatch pattern; no wire involvement |
| BROW-01 | Browser back/forward, new/close tab, refresh, zoom via key macros | `browser` macro table + keymap ALREADY working server-side since 04-02 (BrowserBack/BrowserForward/Ctrl+T/Ctrl+W/F5/Ctrl+Plus/Ctrl+Minus all map). Client screen only; zoom layout nuance flagged for device check |
</phase_requirements>

## Project Constraints (from CLAUDE.md)

- Tech stack locked: Rust server (tokio, tokio-tungstenite, enigo 0.6, `windows` 0.62, tray-icon), Flutter client (Riverpod 3, web_socket_channel, wakelock_plus) — no substitutions.
- `windows` crate is the designated tool for `IAudioEndpointVolume` + `LockWorkStation` (explicitly listed in stack notes).
- enigo media keys (`Key::MediaPlayPause` etc.) are the designated media-transport mechanism.
- wakelock_plus for presenter keep-awake; `HapticFeedback` (built-in) for haptics — do not add the `vibration` package.
- Non-secrets go in shared_preferences, never flutter_secure_storage.
- Hand-written Dart codecs (no freezed/json_serializable) — the `vol.changed` codec additions are hand-written like the other 27 message classes.
- Plain `Navigator` (no go_router) — hub/tool screens use `MaterialPageRoute` pushes like device_list → trackpad does today.
- GSD workflow enforcement: all edits through GSD commands.
- Secrets/redaction discipline (SPEC §12): volume state is not secret, but never log PINs/tokens/text payloads in any new code path.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Media transport keys (play/pause/next/prev) | Server input thread (enigo) | server-core router (existing) | VK_MEDIA_* injection is OS-side; system-wide by SMTC design |
| Absolute volume + mute + state read | Server audio thread (COM/WASAPI) | server-core `watch` plumbing | IAudioEndpointVolume is per-process COM; state producer must live server-side |
| `vol.changed` push | server-core session (select! branch) | server-windows producer | Session owns the write channel; producer is OS-specific, injected via ServerDeps |
| Volume slider UX + drag-ignore | Flutter client (Riverpod store) | — | D-04 finger-wins policy is pure client state |
| Power action execution | Server (Win32 power APIs) | — | LockWorkStation/SetSuspendState/ExitWindowsEx are OS calls |
| Power double-confirm gate | server-core router (DONE, Phase 1) | Flutter confirm UX | 10s window + noPendingAction already enforced + tested server-side |
| Slide-to-confirm + countdown dialog | Flutter client (pure FSM) | — | UX-only; server gate is the security boundary |
| Presenter/browser macros | server-core router + keymap (DONE, 04-02) | Flutter tool screens | Key tables already map and execute; phase adds only the client surfaces |
| Presenter elapsed timer | Flutter client only | — | D-08: client-local, no wire involvement |
| Hub navigation | Flutter client | — | Route change in device_list_screen + new screens |

## Standard Stack

### Core (no new dependencies — additions are features/modules only)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `windows` | 0.62 (already a dep) | IAudioEndpointVolume, LockWorkStation, SetSuspendState, ExitWindowsEx, AdjustTokenPrivileges | Locked by CLAUDE.md; already in server-windows/Cargo.toml [VERIFIED: Cargo.toml in repo] |
| enigo | 0.6 (already a dep) | Media transport keys | `Key::MediaPlayPause`, `MediaNextTrack`, `MediaPrevTrack`, `VolumeUp/Down/Mute` all confirmed in 0.6.1 [CITED: docs.rs/enigo/0.6.1/enigo/enum.Key.html] |
| tokio `sync::watch` | 1.52 (already a dep) | Volume-state push seam | Latest-value semantics are exactly right for volume state; mirrors existing `pause` watch in ServerDeps [VERIFIED: transport/mod.rs in repo] |
| flutter_riverpod | 3.3.2 (already a dep) | Volume store, screen state | House pattern: value-equal snapshots + notifier |
| wakelock_plus | 1.6.1 (already a dep) | Presenter keep-awake (D-09) | Trackpad precedent at trackpad_screen.dart:145/155 [VERIFIED: repo] |
| HapticFeedback (flutter/services) | built-in | Slide-advance haptic tick (D-07) | Trackpad precedent at trackpad_screen.dart:112/185 [VERIFIED: repo] |

**New `windows` crate features required (server-windows/Cargo.toml):**

```toml
windows = { version = "0.62", features = [
    # ... existing features ...
    "Win32_Media_Audio",            # IMMDeviceEnumerator, MMDeviceEnumerator, eRender/eConsole
    "Win32_Media_Audio_Endpoints",  # IAudioEndpointVolume
    "Win32_System_Com",             # CoInitializeEx, CoCreateInstance
    "Win32_System_Power",           # SetSuspendState
    "Win32_System_Shutdown",        # LockWorkStation, ExitWindowsEx, EWX_*, SHTDN_REASON_*
    "Win32_Security",               # OpenProcessToken, AdjustTokenPrivileges, LookupPrivilegeValueW, SE_SHUTDOWN_NAME
    "Win32_System_Threading",       # GetCurrentProcess
] }
```

Feature names follow the windows-rs module-path convention (feature = module path with `_` separators) [CITED: microsoft.github.io/windows-docs-rs — module paths verified for SetSuspendState, LockWorkStation, IAudioEndpointVolume]. Exact feature list must be confirmed by `cargo check` at implementation time — docs pages verified the module paths; the feature-per-path rule is the crate's documented convention. [ASSUMED: exact minimal feature set — compiler will surface any missing feature by name]

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| 250 ms poll on audio thread | `RegisterControlChangeNotify` COM callback | Callback needs `windows` `implement` feature + `#[implement]` macro, strict unregister-before-release lifetime rules, and re-registration when the default device changes (it silently orphans otherwise) [CITED: learn.microsoft.com RegisterControlChangeNotify Remarks]. Poll is ~4 cheap COM calls per 250 ms, matches the input-thread house pattern, and handles device switches by re-acquiring per tick. **Decision: poll** (D-03 delegated this) |
| `ExitWindowsEx` | `shutdown.exe /r /t 0` via CreateProcess | Shelling out loses error surface and is un-Rust-like; native API is 1 call + a privilege helper |
| `Cmd::KeyTap` + keymap entries for media keys | New dedicated `Cmd::MediaKey` variant | Keymap entries reuse the existing coverage-test pattern (ROUTER_MACRO_CODES precedent) and are the smallest diff. Either is acceptable — planner discretion; recommendation is keymap entries |
| `watch<VolumeState>` in ServerDeps | `broadcast` channel / per-session mpsc registry | broadcast can lag/drop and buffers history nobody needs; watch gives exactly "latest state" + connect-time snapshot via `borrow()` — the precise MED-02 semantics |

**Installation:** none. `cargo check` after adding features; no pubspec changes.

## Package Legitimacy Audit

**No new packages are installed in this phase.** All work uses dependencies already present in `server/server-windows/Cargo.toml` and `app/remote_control/pubspec.yaml` (windows 0.62, enigo 0.6, tokio 1.52, flutter_riverpod, wakelock_plus, shared_preferences, remote_protocol path package). The only manifest change is adding feature flags to the existing `windows` crate dependency.

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
 Android client                          Rust server
┌─────────────────────────┐   WebSocket ┌──────────────────────────────────────────┐
│ Hub screen (D-01)       │             │ run_session (session.rs)                 │
│  ├ Trackpad (existing)  │             │  ├ read loop → router::route             │
│  ├ Media screen ────────┼─ media ────▶│  │   ├ Msg::Media ──▶ Media trait        │
│  │   slider ─throttled──┼─ setvol ───▶│  │   │   ├ playpause/next/prev           │
│  │   (drag-ignores push)│             │  │   │   │   └▶ mpsc ▶ INPUT THREAD      │
│  ◀──────────────────────┼─vol.changed─│  │   │   │        (enigo VK_MEDIA_*)     │
│  │   Riverpod vol store │   (S→C push)│  │   │   └ setvol/mute                   │
│  ├ Power screen         │             │  │   │       └▶ mpsc ▶ AUDIO THREAD      │
│  │   slide-to-confirm ──┼─ power ────▶│  │   ├ Msg::Power → pending_power (10s)  │
│  │   countdown dialog ──┼─ confirm ──▶│  │   ├ Msg::Confirm → Power trait        │
│  ├ Presenter screen ────┼─ present ──▶│  │   │   (Lock/SetSuspendState/          │
│  │   local timer (D-08) │             │  │   │    ExitWindowsEx on spawn thread) │
│  └ Browser screen ──────┼─ browser ──▶│  │   └ Msg::Browser/Present → key_tap    │
│                         │             │  │       └▶ keymap (DONE 04-02)          │
│ ConnectionService       │             │  └ NEW select! branch:                   │
│  _onFrame:              │             │      volume watch changed + Authed       │
│   pong → probe          │             │        └▶ encode vol.changed ▶ tx queue  │
│   volChanged → vol store│             │                    ▲                     │
│   else → driver         │             │  AUDIO THREAD ─────┘                     │
└─────────────────────────┘             │   CoInitializeEx(MTA)                    │
                                        │   loop: recv_timeout(250ms)              │
                                        │     cmd → SetMasterVolumeLevelScalar /   │
                                        │           SetMute → immediate re-poll    │
                                        │     tick → GetDefault→Activate→read      │
                                        │            state changed? watch.send     │
                                        └──────────────────────────────────────────┘
```

### Recommended Project Structure (new/changed files)

```
protocol/
├── SPEC.md                          # §7 row: vol.changed; §2 version note → "1.1"
├── schema/messages.schema.json      # $defs volChanged
└── fixtures/volume/                 # NEW family dir: 01-vol-changed.json, 02-vol-changed-muted.json,
                                     #   03-vol-changed-missing-muted.json (negative)
server/server-core/src/
├── codec/json.rs                    # Msg::VolChanged(VolChangedPayload)
├── executors/mod.rs                 # UNCHANGED traits (Media/Power exist)
├── transport/mod.rs                 # ServerDeps += volume: watch::Receiver<VolumeState>
└── transport/session.rs             # select! branch (authed-gated push) + after-auth snapshot;
                                     #   VolumeState {value: u8, muted: bool} (core-owned, no OS deps)
server/server-windows/src/
├── audio_thread.rs                  # NEW: COM thread, poll + AudioCmd (SetVol/MuteToggle/StepUp/StepDown)
├── executors/media.rs               # NEW: WinMedia {input_tx, audio_tx} impl Media
├── executors/power.rs               # NEW: WinPower impl Power (+ privilege helper)
├── executors/keymap.rs              # += MediaPlayPause/MediaNextTrack/MediaPrevTrack codes
├── executors/stubs.rs               # StubMedia/StubPower deleted (Apps/Clipboard stubs remain)
└── main.rs                          # spawn audio thread, build watch channel, wire ServerDeps
app/packages/remote_protocol/lib/src/
├── json_codec.dart                  # VolChangedMsg (decode registry + class)
└── version.dart                     # protoVersion '1.1', protoMinor 1
app/remote_control/lib/
├── net/connection_service.dart      # _onFrame: VolChangedMsg → volume snapshot + notify
├── screens/device_list_screen.dart  # row tap → HubScreen (2 call sites, lines ~135/~221)
├── hub/hub_screen.dart              # NEW: tile grid (Trackpad, Media, Power, Presenter, Browser)
├── media/media_screen.dart          # NEW: transport buttons + slider + mute
├── media/volume_store.dart          # NEW: Riverpod notifier, drag-ignore + 50ms throttle FSM
├── power/power_screen.dart          # NEW: 4 slide-to-confirm tracks + countdown dialog
├── power/confirm_track_fsm.dart     # NEW: pure FSM (idle→dragging→completed)
├── presenter/presenter_screen.dart  # NEW: split zones + bottom bar + timer + wakelock
├── presenter/presenter_timer.dart   # NEW: pure FSM (stopped/running/paused) over injected clock
└── browser/browser_screen.dart      # NEW: button grid → BrowserMsg
```

### Pattern 1: `vol.changed` push via watch channel (mirrors `pause`)

**What:** Server-side volume state flows through `tokio::sync::watch`, injected into `ServerDeps` exactly like the existing `pause` receiver; each session adds a select! branch gated on Authed.
**When to use:** This is THE integration point for MED-02's push requirement.
**Example (server-core, session.rs — shape, not final code):**

```rust
// Source: repo transport/session.rs pause-branch pattern + tokio watch docs
// In ServerDeps (transport/mod.rs):
pub struct VolumeState { pub value: u8, pub muted: bool }   // core-owned, zero OS deps
pub volume: tokio::sync::watch::Receiver<VolumeState>,

// In run_session: clone receiver per session; track volume_alive like pause_alive.
// select! branch (only meaningful once authed):
changed = volume.changed(), if volume_alive && ctx.auth_state == AuthState::Authed => {
    match changed {
        Ok(()) => {
            let st = *volume.borrow_and_update();
            let frame = Message::text(json::encode_msg(&Msg::VolChanged(VolChangedPayload {
                value: st.value as u64, muted: st.muted,
            }), None));
            if tx.send(frame).await.is_err() { break 'read; }
        }
        Err(_) => volume_alive = false,   // producer dropped — disable branch
    }
}

// Connect-time snapshot (D-03 "right after auth"): at BOTH Authed transitions
// (pairOk path and authOk path), read volume.borrow_and_update() and queue one
// vol.changed frame immediately after the pairOk/authOk reply.
```

**Key detail:** `borrow_and_update()` (not `borrow()`) in the branch so the changed-flag clears; the explicit after-auth snapshot handles "state changed before auth" without relying on the watch waking pre-auth (the `if` guard keeps the branch disabled pre-auth, and the snapshot covers anything missed).

### Pattern 2: Dedicated COM audio thread (clone of input-thread pattern)

**What:** One `std::thread` owns all WASAPI COM objects. Commands arrive on `std::sync::mpsc`; polling rides `recv_timeout`.
**When to use:** All volume operations (setvol, mute toggle, volup/voldown) and the 250 ms state poll.
**Example (server-windows, audio_thread.rs — shape):**

```rust
// Source: MS Endpoint Volume Controls sample pattern + windows-docs-rs signatures
// (GetMasterVolumeLevelScalar -> Result<f32>, SetMasterVolumeLevelScalar(f32, *const GUID),
//  GetMute -> Result<BOOL>, SetMute(bool, *const GUID))
pub enum AudioCmd { SetVol(u8), MuteToggle, StepUp, StepDown }

pub fn run_audio_thread(
    rx: std::sync::mpsc::Receiver<AudioCmd>,
    tx: tokio::sync::watch::Sender<VolumeState>,
) {
    unsafe { CoInitializeEx(None, COINIT_MULTITHREADED).ok() };  // once, this thread
    let mut last = None::<VolumeState>;
    loop {
        // Endpoint is re-acquired fresh each pass: survives default-device
        // switches (headphones) with zero notification plumbing.
        // CoCreateInstance::<MMDeviceEnumerator> -> GetDefaultAudioEndpoint(eRender, eConsole)
        //   -> Activate::<IAudioEndpointVolume>(CLSCTX_ALL, None)
        match rx.recv_timeout(Duration::from_millis(250)) {
            Ok(cmd) => { /* execute cmd; then read state + push immediately */ }
            Err(RecvTimeoutError::Timeout) => { /* poll: read state; push iff != last */ }
            Err(RecvTimeoutError::Disconnected) => break,
        }
        // read state: value = (GetMasterVolumeLevelScalar()? * 100.0).round() as u8;
        //             muted = GetMute()?.as_bool();
        // if Some(state) != last { tx.send(state).ok(); last = Some(state); }
        // ALL HRESULT failures: skip this tick, never panic (send-and-forget rule).
    }
}
```

**Immediate re-poll after a command** means the client gets the authoritative post-`setvol` state without waiting for the next tick — D-04's drag-ignore makes the self-echo harmless.

### Pattern 3: Power executor with privilege enablement, off the session task

**What:** `WinPower` implements the `Power` trait; each method spawns a short-lived thread that enables SE_SHUTDOWN_NAME (idempotent) and calls the API.
**When to use:** All four power actions.
**Example (server-windows, executors/power.rs — shape):**

```rust
// Source: learn.microsoft.com ExitWindowsEx + SetSuspendState + AdjustTokenPrivileges docs
fn enable_shutdown_privilege() -> bool {
    // OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &mut tok)
    // LookupPrivilegeValueW(None, SE_SHUTDOWN_NAME, &mut luid)
    // AdjustTokenPrivileges(tok, false, Some(&tp /* SE_PRIVILEGE_ENABLED */), 0, None, None)
    // MUST check GetLastError() != ERROR_NOT_ALL_ASSIGNED — AdjustTokenPrivileges
    // "succeeds" even when it assigned nothing.
}

impl Power for WinPower {
    fn lock(&self) {
        // No privilege needed. Fast, but stay uniform: never block the session task.
        std::thread::spawn(|| unsafe { let _ = LockWorkStation(); });
    }
    fn sleep(&self) {
        std::thread::spawn(|| {
            if enable_shutdown_privilege() {
                // hibernate=FALSE → suspend (sleep), per docs; bForce has no effect.
                // Run on this throwaway thread: community reports the call can block
                // until resume — must never pin a tokio worker either way.
                unsafe { let _ = SetSuspendState(false, false, false); }
            }
        });
    }
    fn restart(&self) { Self::exit_windows(EWX_REBOOT); }
    fn shutdown(&self) { Self::exit_windows(EWX_POWEROFF); }  // NOT EWX_SHUTDOWN — doesn't power off
}
// exit_windows: privilege helper, then
// ExitWindowsEx(flags | EWX_FORCEIFHUNG,
//   SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_MINOR_OTHER | SHTDN_REASON_FLAG_PLANNED)
// dwReason MUST NOT be zero (docs: zero triggers unplanned-shutdown state capture, delays shutdown).
// EWX_FORCEIFHUNG only force-closes HUNG apps — a couch user can't see "Save changes?" dialogs;
// without it an unsaved Notepad blocks the shutdown invisibly and un-abortably from the phone.
```

### Pattern 4: Client `_onFrame` routing for the S→C push

**What:** `connection_service.dart` gets one new typed branch before the driver fallthrough, plus a value-equal snapshot read by a Riverpod notifier — the exact `ConnectionStatus` pattern.

```dart
// Source: repo connection_service.dart _onFrame + Phase-3 value-equal snapshot decision
if (msg is PongMsg) { _probe?.onPong(msg); return; }
if (msg is VolChangedMsg) {              // NEW
  _lastVolume = VolumeSnapshot(value: msg.value, muted: msg.muted); // value-equal (==/hashCode)
  _notify();                             // volume store reads snapshot off `changes`
  return;
}
// ... driver routing unchanged
```

The volume store (Riverpod `Notifier`) merges: pushed snapshots (ignored while `dragging == true`, D-04), local drag position, and a ~50 ms send throttle (`MediaMsg(action: 'setvol', value: v)` via `sendReliable`). Throttle + drag flag live in a pure, clock-injected class so tests are deterministic (house style).

### Pattern 5: Slide-to-confirm + countdown as pure FSMs

**What:** `ConfirmTrackFsm` (idle → dragging(progress 0..1) → completed | cancelled) with zero IO; the widget renders progress and the screen executes effects on `completed`:
- lock/sleep: `sendReliable(PowerMsg(action))` then `sendReliable(ConfirmMsg(action))` — same-tick, FIFO order guaranteed by SendPolicy (D-05).
- restart/shutdown: `sendReliable(PowerMsg(action))`, open countdown dialog seeded with 10s (mirror of server `CONFIRM_WINDOW`); dialog confirm sends `ConfirmMsg(action)`; dialog auto-dismisses at 0 (D-06). A late confirm just earns `err{noPendingAction}` from the server — surface as a "timed out, try again" snackbar or ignore (planner discretion).

**Post-confirm expectation:** sleep/restart/shutdown drops the socket (PC suspends/reboots). This is NOT an error: the ReconnectFsm handles it (backoff + beacon re-listen recovers on wake). The power screen should treat transport loss right after a confirmed action as expected — at minimum, don't stack an error dialog on top of the countdown UI.

### Anti-Patterns to Avoid

- **Calling power APIs inline on the session read task:** `SetSuspendState` may block until resume; even `ExitWindowsEx` does token work. Always thread-spawn (send-and-forget executor rule from input_thread.rs).
- **`EWX_SHUTDOWN` for the shutdown action:** documented as "safe to turn off power" WITHOUT powering off. Use `EWX_POWEROFF`.
- **`EWX_FORCE`:** skips WM_QUERYENDSESSION entirely — data loss; docs say emergency only. Use `EWX_FORCEIFHUNG`.
- **COM callback for volume change (this phase):** lifetime traps + device-switch orphaning; poll decision is final unless on-device testing shows poll latency is unacceptable (it won't be at 250 ms).
- **Sharing one `IAudioEndpointVolume` across threads or creating it on the tokio runtime:** keep the input-thread discipline — COM objects live and die on the audio thread.
- **Client-side volume echo fights:** never apply an incoming `vol.changed` while the user is dragging (D-04). The store owns this policy, not the widget.
- **Adding `vol.changed` handling to the server router's executor path:** it is S→C-only. In Rust, add `Msg::VolChanged(_)` to the existing "S→C-only types arriving FROM a client are ignored" arm in `route()` (the exhaustive match forces this — good).
- **Re-implementing a codec app-side:** `VolChangedMsg` goes in `remote_protocol` with fixtures, like every other message (pubspec comment mandates this).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| System-wide media control | Per-app automation / SMTC session manager | enigo VK_MEDIA_* key injection | The OS media stack routes media keys to the active session (Spotify, browsers, players) — exactly MED-01's "whatever is playing" |
| Absolute volume | Repeated VK_VOLUME_UP steps to approximate a target | `IAudioEndpointVolume::SetMasterVolumeLevelScalar` | Key-stepping is ±2-unit granular, slow, and unreadable; the COM API is exact and readable (the push needs reads anyway) |
| Sleep | `powrprof` P/Invoke clones, `rundll32 powrprof.dll,SetSuspendState` | `SetSuspendState(false,…)` via windows crate | The rundll32 incantation famously *hibernates* instead of sleeping; the direct call with `bHibernate=FALSE` is the documented suspend path |
| Shutdown scheduling/confirm window | New server-side timer machinery | Existing `pending_power` + `CONFIRM_WINDOW` in router.rs | Already implemented, tokio-paused-clock tested, threat-modeled (T-01-23) |
| Presenter/browser key tables | New macro plumbing | Existing `browser_macro`/`present_macro` + keymap.rs | Working since 04-02; coverage-tested (`router_macro_codes_covered`) |
| Reliable C→S sends | New queue for tool screens | `ConnectionService.sendReliable` | Bounded FIFO ≤10 with auth-flush already built and tested |

**Key insight:** the entire server-side security surface of this phase (auth gate, pause gate, double-confirm) already exists and is tested. New server code is *executors and one push seam only* — resist any plan that touches the router's gate logic.

## Runtime State Inventory

Not a rename/refactor/migration phase — omitted by design. (One adjacent note: the protocol minor bump changes the beacon's `proto` field from "1.0" to "1.1"; the client treats beacon `proto` as a display/compat hint only [VERIFIED: beacon.dart:46], so no stored state migrates.)

## Common Pitfalls

### Pitfall 1: SE_SHUTDOWN_NAME must be *enabled*, not just held
**What goes wrong:** `ExitWindowsEx`/`SetSuspendState` fail with access denied even though every interactive user token *holds* SeShutdownPrivilege.
**Why it happens:** The privilege is disabled by default; both APIs require it enabled [CITED: learn.microsoft.com ExitWindowsEx Remarks; SetSuspendState Remarks].
**How to avoid:** `OpenProcessToken` → `LookupPrivilegeValueW(SE_SHUTDOWN_NAME)` → `AdjustTokenPrivileges(SE_PRIVILEGE_ENABLED)` before the call; check `GetLastError() != ERROR_NOT_ALL_ASSIGNED` because AdjustTokenPrivileges returns success even when it assigned nothing.
**Warning signs:** power actions no-op only when the exe runs under a restricted token/service context.

### Pitfall 2: `EWX_SHUTDOWN` leaves the machine powered on
**What goes wrong:** "Shutdown" halts Windows but the box stays at "It's now safe to turn off" state on some configs.
**How to avoid:** `EWX_POWEROFF` for the `shutdown` action [CITED: ExitWindowsEx flag table]. Optionally OR `EWX_HYBRID_SHUTDOWN` for fast-startup parity with the Start-menu shutdown — planner discretion; plain `EWX_POWEROFF` satisfies PWR-03.

### Pitfall 3: `dwReason = 0` delays shutdown
**What goes wrong:** Shutdown logged as undefined/unplanned; depending on config Windows captures system state first, visibly delaying the action.
**How to avoid:** Pass `SHTDN_REASON_MAJOR_OTHER | SHTDN_REASON_MINOR_OTHER | SHTDN_REASON_FLAG_PLANNED` [CITED: ExitWindowsEx dwReason docs: "do not use zero for this parameter"].

### Pitfall 4: Power calls on the session read task
**What goes wrong:** `SetSuspendState` can block the calling thread until resume (docs are silent; widely reported behavior) — pinning a tokio worker for hours; the liveness deadline then can't even tear the session down cleanly.
**How to avoid:** every `Power` method body is `std::thread::spawn(…)` fire-and-forget, mirroring the input-thread send-and-forget contract. [ASSUMED: blocking-until-resume behavior — mitigation is correct regardless of whether it blocks]

### Pitfall 5: Executor traits are sync and called inline — audio ops must not do COM on the caller
**What goes wrong:** Naively creating COM objects inside `Media::set_volume` runs `CoInitializeEx` on a tokio worker (wrong apartment lifecycle, latent panics).
**How to avoid:** `WinMedia` holds only two `Sender`s (input thread cmd + audio thread cmd) — identical to `EnigoMouseKeys` holding its `Sender<Cmd>`.

### Pitfall 6: Default-device switch silently freezes volume state
**What goes wrong:** Cache the `IAudioEndpointVolume` once and plugging in headphones leaves the server reading/writing the *old* device; a registered change-callback stops firing entirely (notifications last only as long as the registered object [CITED: RegisterControlChangeNotify Remarks]).
**How to avoid:** re-acquire `GetDefaultAudioEndpoint(eRender, eConsole)` every poll tick (cheap), or at minimum on any HRESULT failure.

### Pitfall 7: Volume percent round-trip drift
**What goes wrong:** `set_volume(55)` → scalar 0.55 → read back 54 (truncation) → `vol.changed{54}` snaps the released slider to 54.
**How to avoid:** `(scalar * 100.0).round() as u8` on read; `pct as f32 / 100.0` on write; compare pushed states by value so no-change ticks push nothing. Router already drops `setvol > 100` [VERIFIED: router.rs:152].

### Pitfall 8: `vol.changed` leaking pre-auth
**What goes wrong:** The watch branch fires while a session is still AwaitingHello and sends state to an unauthenticated peer (info disclosure + off-SPEC frame pre-auth).
**How to avoid:** select! branch guard `ctx.auth_state == AuthState::Authed` (Pattern 1) + explicit snapshot at the two Authed transitions. Test both: pre-auth silence and after-auth snapshot.

### Pitfall 9: Rust exhaustive-match ripple from the new Msg variant
**What goes wrong:** Adding `Msg::VolChanged` breaks compilation in `route()` and `is_executor_bound` matchers.
**Why it's actually good:** the compiler enumerates every site. Put it in the S→C-only ignore arm of `route()`; it is NOT executor-bound (S→C push is exempt from the pause gate — same class as `pong`). Fixture suite (`fixtures.rs` / `fixture_test.dart`) auto-picks up the new `volume/` fixture dir only if the loaders glob directories — verify loader behavior; if families are hard-coded, add the new family in both loaders.

### Pitfall 10: Minor version bump ripple ("1.0" literals)
**What goes wrong:** Bumping `SERVER_PROTO_VERSION`/Dart `protoVersion` to "1.1" fails tests that assert "1.0" (`handshake_fsm_test.dart`, `integration.rs`, `beacon_test.dart`, `connection_service_test.dart` all contain the literal [VERIFIED: grep]).
**How to avoid:** referencing the constants in tests instead of literals where the assertion means "current version"; only fixtures that pin historical wire bytes keep "1.0" (valid: minor mismatch is accepted, §2). The beacon's `proto` field inherits the bump automatically via `SERVER_PROTO_VERSION` [VERIFIED: 03-01 decision in STATE.md].

### Pitfall 11: Ctrl+Plus zoom on non-US layouts / numpad expectations
**What goes wrong:** `Key::Unicode('+')` resolves through `VkKeyScanW` — on US layouts that's Shift+`=`, so the chord lands as Ctrl+Shift+`=`. Chromium/Firefox treat that as zoom-in, so it works; exotic layouts where `+` needs AltGr can misfire.
**How to avoid:** Nothing to build now — keymap is locked and works for the owner's setup; verify zoomin/zoomout at the phase-gate device check. Fallback if it misfires: map zoomin to `Key::Unicode('=')` (Ctrl+`=` is also zoom-in in Chromium). [ASSUMED: browser chord equivalence — verify on device]

### Pitfall 12: Reliable-queue staleness during a mid-drag transport blip
**What goes wrong:** Slider drag during a WiFi blip queues up to 10 stale `setvol` frames that flush on re-auth, briefly yanking volume through old values.
**How to avoid:** Cheapest correct policy: volume store only emits `setvol` when `service.isAuthed` (drop, don't queue — volume is continuous state, not a command to replay). One-line policy in the store; note it in the plan.

### Pitfall 13: Presenter timer and screen lifecycle
**What goes wrong:** Timer keeps "running" visually via periodic rebuilds after navigation away, or wakelock leaks to other screens.
**How to avoid:** Trackpad precedent — `WakelockPlus.enable()` in initState, `disable()` in dispose [VERIFIED: trackpad_screen.dart:145,155]. Timer FSM holds a start-instant + accumulated-pause offset over an injected clock; the widget derives elapsed on a 1 s `Timer.periodic` that's cancelled in dispose. D-08: timer is presentational only — no wire messages.

### Pitfall 14: Hub reroute misses the second nav call site
**What goes wrong:** `device_list_screen.dart` pushes `TrackpadScreen` from TWO places (~line 135 row tap, ~line 221) [VERIFIED: grep]; rerouting only one leaves an inconsistent D-02 experience.
**How to avoid:** Extract one `_openHub(context)` helper; both call sites use it.

## Code Examples

### Media transport keys through the existing input thread

```rust
// Source: docs.rs/enigo/0.6.1 Key enum (variants verified) + repo keymap.rs pattern
// keymap.rs additions (mirror ROUTER_MACRO_CODES precedent + coverage test):
pub const MEDIA_KEY_CODES: &[&str] = &["MediaPlayPause", "MediaNextTrack", "MediaPrevTrack"];
// in map_key():
"MediaPlayPause" => Key::MediaPlayPause,
"MediaNextTrack" => Key::MediaNextTrack,
"MediaPrevTrack" => Key::MediaPrevTrack,

// executors/media.rs:
impl Media for WinMedia {
    fn play_pause(&self) { let _ = self.input_tx.send(Cmd::KeyTap(KeyCode("MediaPlayPause".into()), vec![])); }
    fn next(&self)       { let _ = self.input_tx.send(Cmd::KeyTap(KeyCode("MediaNextTrack".into()), vec![])); }
    fn prev(&self)       { let _ = self.input_tx.send(Cmd::KeyTap(KeyCode("MediaPrevTrack".into()), vec![])); }
    fn set_volume(&self, pct: u8) { let _ = self.audio_tx.send(AudioCmd::SetVol(pct)); }
    fn mute(&self)       { let _ = self.audio_tx.send(AudioCmd::MuteToggle); }
    fn vol_up(&self)     { let _ = self.audio_tx.send(AudioCmd::StepUp); }    // IAudioEndpointVolume::VolumeStepUp
    fn vol_down(&self)   { let _ = self.audio_tx.send(AudioCmd::StepDown); }
}
```

### Default endpoint acquisition (audio thread interior)

```rust
// Source: MS Core Audio "Endpoint Volume Controls" pattern, windows-docs-rs signatures
unsafe {
    let enumerator: IMMDeviceEnumerator =
        CoCreateInstance(&MMDeviceEnumerator, None, CLSCTX_ALL)?;
    let device = enumerator.GetDefaultAudioEndpoint(eRender, eConsole)?;
    let vol: IAudioEndpointVolume = device.Activate(CLSCTX_ALL, None)?;
    let value = (vol.GetMasterVolumeLevelScalar()? * 100.0).round() as u8;
    let muted = vol.GetMute()?.as_bool();
    // SetMasterVolumeLevelScalar(pct as f32 / 100.0, std::ptr::null()) — null event-context GUID is fine
}
```

### `vol.changed` wire shape + fixtures

```jsonc
// protocol/fixtures/volume/01-vol-changed.json (follows fixtures/README.md schema)
{
  "name": "vol-changed",
  "description": "S→C volume-state push (SPEC §7, protoVersion 1.1 addition). value 0-100, muted bool.",
  "wire":   { "t": "vol.changed", "p": { "value": 55, "muted": false, "future": "ignored" } },
  "expect": { "t": "vol.changed", "p": { "value": 55, "muted": false } }
}
// 02: muted=true at value 0; 03 (negative): missing `muted` → {"error": true}
// (both fields REQUIRED — missing required field is a hard decode error, SPEC §1)
```

Schema `$defs` addition: `volChanged: {value: integer 0..100, muted: boolean, required: [value, muted]}`. SPEC §7 row: `vol.changed | S→C | value (integer 0–100), muted (bool) | — | Server push: after auth and on any server-side volume/mute change`. SPEC §2 note: protoVersion `"1.1"`, listing `vol.changed` as the 1.1 addition.

### Dart codec addition

```dart
// Source: repo json_codec.dart house pattern (MediaMsg shape)
final class VolChangedMsg extends RemoteMessage {
  final int value;       // 0-100
  final bool muted;
  const VolChangedMsg({required this.value, required this.muted});
  factory VolChangedMsg.fromPayload(Map<String, dynamic> p) => VolChangedMsg(
      value: _req<int>(p, 'value'), muted: _req<bool>(p, 'muted'));
  @override String get t => 'vol.changed';
  @override Map<String, Object?> toPayload() => {'value': value, 'muted': muted};
}
// + registry entry in decodeText's type switch, like the other 27 types.
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `keybd_event` volume keys for absolute volume | IAudioEndpointVolume (WASAPI, Vista+) | Vista | Exact 0–100 set/read; the push requirement is only satisfiable this way |
| `rundll32 powrprof.dll,SetSuspendState` | Direct `SetSuspendState(FALSE,…)` call | always broken | The rundll32 form hibernates; direct call sleeps (SC2 depends on this) |
| Polling deprecated `waveOut` volume | MMDevice/endpoint volume with device re-acquisition | Vista | Handles per-device volume + default-device switches |
| `InitiateSystemShutdownEx` for local restart | `ExitWindowsEx` for the interactive session | n/a | ExitWindowsEx is the documented path when the caller IS the interactive user (our case: tray exe in the user session) |

**Deprecated/outdated:** nothing else in scope; enigo 0.6 / windows 0.62 / Riverpod 3 patterns from CLAUDE.md remain current (verified 2026-07-07 registry sweep recorded there).

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `SetSuspendState` may block the calling thread until resume (docs silent; community-reported) | Pitfall 4 | None — thread-spawn mitigation is correct in either case |
| A2 | Ctrl+Shift+`=` (what `Key::Unicode('+')` yields on US layout) triggers browser zoom-in in Chromium/Edge/Firefox | Pitfall 11 | Zoom-in misfires → one-line keymap change to `Key::Unicode('=')`; verify at phase gate |
| A3 | Exact minimal `windows` feature set (list derived from documented module paths) | Standard Stack | `cargo check` names any missing feature; zero design risk |
| A4 | 250 ms poll cadence is imperceptible for slider tracking of PC-side changes (MED-02 acceptance) | Pattern 2 | Lower to 100–150 ms — same architecture, one constant |
| A5 | Media keys injected via SendInput control SMTC-aware apps system-wide (Spotify, browsers, film players) | MED-01 | Owner's player ignores media keys → nothing we can do client-side; acceptance test at phase gate |
| A6 | Fixture loaders (Rust `fixtures.rs`, Dart `fixture_test.dart`) discover family dirs by glob; if hard-coded, the new `volume/` family must be registered in both | Pitfall 9 | Silent fixture non-execution — verify loader code in Wave 0/first slice |

## Open Questions

1. **Does the client surface `err{noPendingAction}` after a late restart/shutdown confirm?**
   - What we know: server replies with it; countdown auto-dismiss (D-06) makes the race window small; `_onFrame` currently drops post-auth ErrMsg into the (terminal) handshake driver, i.e. effectively ignores it.
   - What's unclear: whether a "timed out, slide again" snackbar is worth the plumbing.
   - Recommendation: planner discretion; simplest compliant behavior is ignore (the dialog already vanished at 0s).
2. **Hub tile enablement while disconnected**
   - What we know: header chip/banner (D-02) already communicates status; tool screens' sends silently no-op or queue via SendPolicy when unauthed.
   - Recommendation: keep tiles always tappable, rely on the header + Pitfall-12 authed-gate for setvol; do not build per-tile disabled states this phase (dashboard polish is Phase 7).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain | server build | ✓ | cargo/rustc 1.89.0 | — |
| Flutter SDK | app build | ✓ | 3.44.5 stable / Dart 3.12.2 | — |
| Windows 11 host | power/volume APIs, on-device verify | ✓ | 10.0.26200 | — |
| PowerPoint (or slideshow app) | PRES-01/02 phase-gate manual check | ? (owner's machine) | — | Any F5/Esc/B-convention slideshow (LibreOffice Impress uses same keys); flag in verify checklist |
| Android device | end-to-end verify | ✓ (Xiaomi 25080RABDI, proven Phases 2–4) | — | — |
| Audio output device | MED-02 verify | ✓ (laptop speakers) | — | — |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** PowerPoint availability is unconfirmed; Impress/Google-Slides-in-fullscreen accept the same key macros for next/prev/start/end (blank 'B' is PowerPoint/Impress convention).

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Rust) | built-in `#[cfg(test)]` + `#[tokio::test]` (+ paused-clock via `start_paused`) |
| Framework (Dart) | `flutter_test` |
| Config file | none needed (existing conventions) |
| Quick run command | `cd server && cargo test` / `cd app/remote_control && flutter test` |
| Full suite command | `cd server && cargo test` + `cd app/remote_control && flutter test` + `cd app/packages/remote_protocol && flutter test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MED-01 | media codes map to enigo keys (coverage gate) | unit | `cargo test -p server-windows keymap` | ✅ pattern exists; extend `keymap_covers_all_codes` |
| MED-02 | vol.changed encode/decode byte-identical both codecs | fixture | `cargo test -p server-core --test fixtures` / `flutter test test/fixture_test.dart` (remote_protocol) | ❌ Wave 0 (new `volume/` fixtures) |
| MED-02 | push after auth, none pre-auth, push on watch change | integration | `cargo test -p server-core --test integration vol_` | ❌ Wave 0 |
| MED-02 | slider store: drag-ignore, 50ms throttle, authed gate | unit (FSM) | `flutter test test/media/volume_store_test.dart` | ❌ Wave 0 |
| PWR-01..03 | power→confirm gate (window, mismatch, expiry) | unit | `cargo test -p server-core confirm` | ✅ (router.rs tests) |
| PWR-01..03 | confirm-track FSM transitions; lock/sleep dual-send; restart/shutdown dialog flow | unit (FSM) | `flutter test test/power/confirm_track_fsm_test.dart` | ❌ Wave 0 |
| PWR-02 | sleep = SetSuspendState(false) actually suspends | manual | phase-gate on-device (roadmap SC2) | manual |
| PRES-01 | present macro table maps every action | unit | `cargo test -p server-core present_macro_table` | ✅ (router.rs) |
| PRES-02 | timer FSM start/pause/reset over injected clock | unit (FSM) | `flutter test test/presenter/presenter_timer_test.dart` | ❌ Wave 0 |
| BROW-01 | browser macro table maps every action | unit | `cargo test -p server-core browser_macro_table` | ✅ (router.rs) |
| BROW-01/PRES-01 | macros act on focused browser/PowerPoint | manual | phase-gate on-device (SC4, SC5) | manual |

### Sampling Rate
- **Per task commit:** `cargo test` or `flutter test` for the touched crate/package.
- **Per wave merge:** full `cargo test` (workspace) + both `flutter test` suites (app + remote_protocol fixtures).
- **Phase gate:** on-device checks before `/gsd-verify-work`: media keys against Spotify/YouTube, PC-side volume change → slider follows (MED-02 acceptance), sleep actually suspends (SC2), restart/shutdown two-gesture path (SC3), PowerPoint slide driving + blank + timer (SC4), browser macros incl. zoom (SC5, Pitfall 11).

### Wave 0 Gaps
- [ ] `protocol/fixtures/volume/01..03-*.json` — covers MED-02 wire contract (both codec suites consume them; verify loader family discovery, A6)
- [ ] `server/server-core/tests/integration.rs` vol-push cases (or new `volume.rs` test) — covers MED-02 push gating
- [ ] `app/remote_control/test/media/volume_store_test.dart` — D-04 policy
- [ ] `app/remote_control/test/power/confirm_track_fsm_test.dart` — D-05/D-06
- [ ] `app/remote_control/test/presenter/presenter_timer_test.dart` — D-08
- [ ] Framework install: none — existing infrastructure covers everything

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes (inherited) | Existing challenge-response gate; `vol.changed` push MUST be Authed-gated (Pitfall 8) — the one new auth-adjacent surface |
| V3 Session Management | yes (inherited) | Existing session FSM; sleep/shutdown-induced disconnects ride existing CONN-07 cleanup |
| V4 Access Control | yes | Power double-confirm (`power`→`confirm`, 10s, single-shot take) already enforced server-side; client UX must never create a single-action path (D-05/D-06 satisfy PWR-03) |
| V5 Input Validation | yes | Router drops `setvol > 100` and unknown action strings (existing); `vol.changed` required-field decode strictness via fixtures; unknown key codes drop whole command (keymap convention) |
| V6 Cryptography | no (unchanged) | No new crypto; token/HMAC paths untouched |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Unauthed peer receives volume-state pushes | Information disclosure | Authed guard on the select! branch + explicit test (pre-auth silence) |
| Single message triggers restart/shutdown | Elevation/Tampering | Existing pending_power gate (never call executor from `power` alone — router.rs comment + tests); do not add any "convenience" combined message |
| Privilege over-grant | Elevation | Enable ONLY SE_SHUTDOWN_NAME, only in the power executor, never other privileges |
| Blocking API pins server runtime (DoS-by-self) | DoS | Thread-spawned power calls; audio ops on dedicated thread; session task never blocks |
| Stale confirm replay | Replay | Existing single-shot `take()` + 10s window (mismatch clears pending) — already tested |
| Volume-push channel flood | DoS | watch channel = latest-value only (no backlog); write mpsc capacity 64 with `.await` backpressure |

## Sources

### Primary (HIGH confidence)
- Repo source (read this session): `protocol/SPEC.md`, `server-core` router.rs/session.rs/mod.rs/executors, `server-windows` main.rs/input_thread.rs/keymap.rs/stubs.rs/Cargo.toml, `connection_service.dart`, `json_codec.dart`, `version.dart`, fixtures README, schema — all integration claims grounded here
- [learn.microsoft.com — SetSuspendState](https://learn.microsoft.com/en-us/windows/win32/api/powrprof/nf-powrprof-setsuspendstate) — hibernate=FALSE suspends; SE_SHUTDOWN_NAME required; bForce no-op
- [learn.microsoft.com — ExitWindowsEx](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-exitwindowsex) — async semantics, EWX flag table, privilege requirement, dwReason≠0
- [learn.microsoft.com — RegisterControlChangeNotify](https://learn.microsoft.com/en-us/windows/win32/api/endpointvolume/nf-endpointvolume-iaudioendpointvolume-registercontrolchangenotify) — callback lifetime rules driving the poll decision
- [microsoft.github.io/windows-docs-rs](https://microsoft.github.io/windows-docs-rs/) — Rust signatures/module paths for SetSuspendState, LockWorkStation, IAudioEndpointVolume methods
- [docs.rs/enigo/0.6.1 Key enum](https://docs.rs/enigo/0.6.1/enigo/enum.Key.html) — MediaPlayPause/MediaNextTrack/MediaPrevTrack/Volume* variants confirmed

### Secondary (MEDIUM confidence)
- CLAUDE.md stack research (2026-07-07 registry sweep) — versions, enigo/windows-crate division of labor

### Tertiary (LOW confidence)
- SetSuspendState blocking-until-resume behavior (community-reported, docs silent) — A1, mitigated by design
- Browser zoom chord equivalence across layouts — A2, phase-gate device check

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — zero new dependencies; every API verified against official docs this session
- Architecture: HIGH — every integration point read directly from repo source; the one new seam (volume watch) is a copy of an existing, tested pattern (pause watch)
- Pitfalls: HIGH for Win32 semantics (official docs); MEDIUM for the two device-behavior assumptions (A2, A5) — both covered by the phase-gate manual checklist

**Research date:** 2026-07-10
**Valid until:** ~2026-08-10 (stable Win32 APIs + locked stack; repo facts valid until Phase 5 execution changes them)
