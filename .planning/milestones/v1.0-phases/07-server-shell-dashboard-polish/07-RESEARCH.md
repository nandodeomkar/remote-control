# Phase 7: Server Shell, Dashboard & Polish - Research

**Researched:** 2026-07-12
**Domain:** Windows tray-daemon shell (winit/tray-icon/egui/auto-launch) + config persistence + failure surfacing (firewall/UIPI) + Flutter dashboard identity & polish
**Confidence:** HIGH for stack/versions and app-side seams; MEDIUM for the tray/egui event-loop topology and firewall/UIPI detection (verified against docs, needs a small on-device spike)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Paired token **hashes persist** across runs in `%APPDATA%/RemoteControl/config.toml` (`toml` + `dirs` + `serde`). This is the mechanism behind revoke, multi-device, and re-pair.
- **D-02:** Pairing a **new** device is **on-demand** — a "Pair new device" action in BOTH the tray menu AND the settings window opens a fresh PIN window (`begin_pairing()`). Decouples the PIN lifecycle from a single process run (rework the `break`-on-`is_paired` loop in `main.rs`; `pin.rs` single-use `active=None` is correct and stays).
- **D-03:** **Smart startup** — auto-open a PIN window at startup ONLY when zero devices paired. ≥1 paired → start silent.
- **D-04:** Multiple paired phones allowed; the settings paired-device list manages them.
- **D-05:** **Revoke** drops the revoked phone's live session **immediately** → server returns `authFail` → phone clears token and returns to pairing with an explanation. No silent retry loop.
- **D-06 (firewall, SRV-04):** startup self-test; firewall-blocked → **tray warning state + a Windows notification with a one-line fix hint** + a persistent hint in settings. Loud on purpose.
- **D-07 (UIPI, SRV-05):** input dropped by an elevated foreground window → phone shows a **transient, non-blocking banner** ("Can't control this window — it's running as administrator") that auto-dismisses. Detection mechanism + status-message shape → this research; likely a minor protocol amendment reusing the authed-gated push seam.
- **D-08 (home model):** the **Dashboard (8-tile grid) is home**, with an offline state (tiles disabled except Settings when PC offline). The current device-list becomes the **add/switch-PC** screen.
- **D-09 (8 tiles):** add the **Keyboard** tile and reorder to: **Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser** (today `kHubTiles` = 7 tiles, no Keyboard). Keyboard is currently a panel inside the trackpad screen — planner picks the least-rework path to a Keyboard tile.
- **D-10 (quick-bar):** persistent bottom quick-bar = a **single Trackpad shortcut button**; tap pushes the full Trackpad screen. Hidden/no-op on the Trackpad screen. Visible on every other screen. NOT a live mini-pad.
- **D-11 (settings entry):** an **app-bar gear icon** on the dashboard (reachable offline). App Settings screen holds: paired PCs, trackpad sensitivity (existing `settings/sensitivity.dart`), scroll direction, haptics toggle, accent (display-only, fixed).
- **D-12 (accent):** **fixed blue `#4C8DFF`.** Work = **consolidating** the palette consts (`_bg #0E0F12`, `_surface #16181D`, `_hairline #2A2D34`, `_text #E6E8EB`, `_muted #6B7280`, `_accent #4C8DFF`, error `#FF6B6B`) into one shared theme/tokens source. No accent picker.
- **D-13 (haptics toggle):** add a haptics-enabled setting (default ON, `shared_preferences`) and gate the existing `HapticFeedback.*Impact()` call sites behind it.
- **D-14 (keep-awake):** already implemented via `WakelockPlus` in trackpad + presenter — work is an **audit only** (confirm no leak past those screens).

### Claude's Discretion
- Settings-window toolkit = `eframe`/`egui` on the same `winit` event loop as `tray-icon` (stack-locked); exact window layout.
- Tray icon asset + pause-input **visual feedback**; surviving an Explorer restart (tray re-registration).
- Autostart mechanism = `auto-launch` / HKCU `...\Run` key (stack-locked); toggle wiring.
- `config.toml` schema (device name, port, autostart flag, clip-sync flag, paired token hashes + device metadata).
- Whether a **port change** re-binds live or is restart-required — research flag.
- Quick-bar exact height/placement + hide-on-trackpad mechanic.
- Theme file structure (e.g. `lib/theme/app_theme.dart`) and how shared tokens replace per-file consts.
- Scroll-direction setting plumbing into the trackpad driver.
- AUMID registration for a proper tray/notification identity (Phase-5 used `POWERSHELL_APP_ID` interim).

### Deferred Ideas (OUT OF SCOPE)
- User-selectable accent presets (fixed blue chosen).
- Live "peek" trackpad overlay on tool screens (nav button chosen).
- noPairing copy split todo (reviewed, not folded — may be closed opportunistically with the pairing rework, not a commitment).
- MSI installer + firewall-rule setup (v2 FEAT-04); Play Store release / crash reporting (v2 FEAT-05).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| SRV-01 | Server lives in the tray: status tooltip (connected device count), pause-input toggle, quit; icon survives Explorer restart | Shell thread with `winit` 0.30 event loop (`with_any_thread(true)`) owning `tray-icon` 0.24; connected-count `watch<usize>` in server-core; reuse the existing (currently-dropped) `pause_tx`; TaskbarCreated re-registration (Pitfall 1) |
| SRV-02 | Auto-start with Windows (toggle) | `auto-launch` 0.6 `AutoLaunchBuilder` → HKCU `...\Run`; per-user (no admin); mirror flag in config.toml (§Autostart) |
| SRV-03 | Settings window: device name, port, paired-device revoke, clipboard sync | `config.toml` (toml+dirs+serde) as source of truth; `AuthManager` grows persisted paired devices + `revoke`; egui settings window on the shell loop; on-demand `begin_pairing()` (D-02/D-03) |
| SRV-04 | Firewall self-test → tray warning + fix hint | Bind-in-use catch + `windows` crate `INetFwPolicy2` inbound-rule check on the active profile; extend `notify.rs`; tray warning icon state (§SRV-04) |
| SRV-05 | Phone shows clear status when input blocked by elevated window (UIPI) | **Proactive** integrity-level compare of the foreground window (SendInput cannot report UIPI); minor protocol amendment `input.blocked` (proto 1.3) reusing the authed-gated S→C watch seam; transient client banner |
| UI-01 | Dashboard home with 8 tool tiles + persistent trackpad quick-bar on every screen | `main.dart` home → `HubScreen`; add Keyboard tile + reorder `kHubTiles`; offline-disabled tiles; shared quick-bar scaffold (§UI-01) |
| UI-02 | Dark minimal theme (#0E0F12, blue accent), haptics toggle, keep-awake during trackpad/presenter | Single `lib/theme` token source (D-12); cached-pref haptics gate over ~15 call sites (D-13); keep-awake audit — **finds a real ref-count leak once the quick-bar exists** (§UI-02 / Pitfall 8) |
</phase_requirements>

## Summary

Phase 7 has two independent halves. **Server half:** wrap the existing `server-windows` binary — today a headless `#[tokio::main]` composition root that spawns dedicated OS threads for input/audio/apps/clip and calls `server_core::run` — in a tray-daemon shell. The single biggest architectural decision is *where the winit event loop lives*: `eframe::run_native` **owns and cannot share** a winit event loop, and `tray-icon` **must be created on a thread that runs a win32 event loop**. The clean, codebase-idiomatic answer is a **dedicated "shell thread"** (the established dedicated-OS-thread pattern already used four times in `main.rs`) that builds a `winit` 0.30 event loop with `EventLoopBuilderExtWindows::with_any_thread(true)`, creates the tray icon on `StartCause::Init`, and hosts the settings window with **egui-on-winit** (not the `eframe` wrapper). `main.rs` stays `#[tokio::main]`; the shell thread and the tokio runtime communicate over channels + an `EventLoopProxy` (both `Send + Sync`).

The persistence/pairing rework (D-01/02/03/05) is a **server-core change**: `AuthManager` currently holds `Vec<[u8;32]>` hashes in memory and the composition root pairs exactly one device per run via an unconditional `begin_pairing()` + a re-pin loop. Phase 7 turns paired state into persisted `PairedDevice{hash,name,paired_at}` records loaded from `config.toml`, makes pairing on-demand, and adds a **revoke → force-disconnect** signal into the session `select!` loop so a revoked phone drops immediately and re-auth fails (the existing D-05 `kRevokedExplanation` path). The two failure-surfacing features need care: **SendInput cannot report a UIPI drop** (neither return value nor `GetLastError`), so UIPI detection must be **proactive** (compare the foreground window's integrity level to ours), and a **firewall block does not fail `bind`** (bind is local), so the self-test must query the Windows Firewall API, not just try to listen.

**App half** is lower-risk and mostly rewiring existing, well-factored widgets: reroute home to the existing `HubScreen`, add a `KeyboardScreen` that reuses the modular `KeyboardPanel`, add the 8th tile, add a shared quick-bar scaffold, consolidate the copy-pasted palette consts into one token file, gate the ~15 haptic call sites behind one cached pref, and audit keep-awake. The keep-awake "audit only" is a trap: `WakelockPlus` is a **global, non-ref-counted** flag, and the new D-10 quick-bar introduces a *tool → Trackpad → back* navigation path that can disable keep-awake while a still-live screen wants it (Pitfall 8).

**Primary recommendation:** Build the tray/settings shell as a dedicated winit-0.30 thread using **egui directly on winit** (the locked "egui" toolkit, minus the `eframe` wrapper which cannot share its loop with `tray-icon`); keep `main.rs` on `#[tokio::main]`; make `AuthManager` persistence- and revoke-aware in server-core; detect UIPI proactively and firewall via `INetFwPolicy2`; ship the UIPI status as a proto-1.3 `input.blocked` amendment following the exact `vol.changed`/`apps.changed`/`clip.changed` precedent. On the app, reuse existing widgets and add a ref-counted keep-awake helper rather than trusting the raw global `WakelockPlus` flag.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Tray icon + menu + tooltip (SRV-01) | server-windows (shell thread / winit) | — | Win32 UI must run on a win32-message-loop thread; not server-core (keeps its zero-Windows-deps invariant) |
| Connected-device count (tooltip source) | server-core (session lifecycle) | server-windows (reads watch) | Only session.rs sees the Authed transition + cleanup; expose as `watch<usize>` |
| Pause-input toggle (SRV-01) | server-core (existing pause watch) | server-windows (tray flips it) | The pause seam already exists in `session.rs`; the tray just drives `pause_tx` (currently dropped) |
| Autostart registry (SRV-02) | server-windows | — | HKCU Run key is Windows-specific; `auto-launch` |
| Config persistence + paired store (SRV-03, D-01) | server-core (`AuthManager` paired set + change signal) | server-windows (toml+dirs file I/O) | Hashes/paired records are auth state (core); file read/write is a Windows side effect (keep out of core) |
| On-demand pairing + smart startup (D-02/D-03) | server-windows (composition root) | server-core (`begin_pairing`/`is_paired`) | The startup/tray trigger policy lives in the binary; the mechanism is core |
| Revoke → drop live session (D-05) | server-core (session `select!` + AuthManager) | server-windows (settings triggers) | Force-disconnect must reach a live session task → core |
| Firewall self-test (SRV-04) | server-windows (Win32 firewall COM) | — | Windows Firewall API; not core |
| UIPI detection (SRV-05) | server-windows (input thread / Win32 token) | server-core (`input.blocked` push seam) | Integrity-level check is Win32; the S→C message is a core protocol amendment |
| Dashboard home + 8 tiles + quick-bar (UI-01) | Flutter app (widgets/routing) | — | Pure client UI |
| Theme tokens / haptics gate / keep-awake (UI-02) | Flutter app | — | Pure client UI + platform-channel haptics/wakelock |

## Standard Stack

### Core (new to this phase — all locked in CLAUDE.md, versions re-verified against crates.io 2026-07-12)
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| tray-icon | 0.24.1 | Tray icon + menu (`muda` re-export) | tauri-apps, actively maintained; the locked choice `[CITED: docs.rs/tray-icon]` |
| winit | 0.30.x | Event loop hosting the tray + settings window | The loop `tray-icon`/`egui` run on; **stay on 0.30** (eframe 0.35 pins it) `[VERIFIED: crates.io]` |
| egui | 0.35.0 | Settings window (immediate-mode UI) | Lightest single-binary Rust GUI; locked `[VERIFIED: crates.io]` |
| eframe | 0.35.0 | (see Alternatives — likely NOT the wrapper to use) | Bundles the winit loop; cannot share it with `tray-icon` `[CITED: github.com/emilk/egui#2875]` |
| auto-launch | 0.6.0 | Autostart toggle (HKCU Run key) | Cross-platform, locked `[VERIFIED: crates.io]` |
| toml | 1.1.x | `config.toml` codec | Native Rust TOML, pairs with serde; locked `[VERIFIED: crates.io]` |
| dirs | 6.0.0 | Resolve `%APPDATA%` | `config_dir()` = `%APPDATA%\Roaming` on Windows; locked `[VERIFIED: crates.io]` |

### Supporting (already in the tree — extend, don't add)
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| windows | 0.62 | `INetFwPolicy2` (firewall), token/integrity APIs (UIPI), current_exe | Add features `Win32_NetworkManagement_WindowsFirewall`, `Win32_Security` (already present), `Win32_System_Threading` (present) |
| serde / serde_json | 1.x | Derive on config structs | `#[derive(Serialize, Deserialize)]` on the config + `[[paired]]` records |
| tauri-winrt-notification | 0.8 | Firewall + PIN toasts | Extend `notify.rs` with `notify_firewall_warning` |
| winreg | 0.56 | Autostart fallback (HKCU Run) | Only if `auto-launch`'s HKCU/admin behavior fights the spec (Assumption A2) |
| flutter_riverpod | 3.3.2 | Settings providers, haptics/scroll prefs | Unified `Notifier` (like `sensitivity.dart`) |
| shared_preferences | 2.5.5 | haptics toggle, scroll direction, device_name | Non-secret prefs — never secure storage |
| wakelock_plus | 1.6.1 | Keep-awake (audit) | Wrap in a ref-count helper (Pitfall 8) |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| egui-on-winit (shell thread hosts egui directly) | `eframe::run_native` | `eframe` owns its winit loop and **cannot run on an existing loop** (issue #2875) — a tray-first daemon whose window is on-demand fights `eframe`'s window==loop lifecycle. `eframe`'s `run_on_demand`/`continue_running` partially helps but the tray must outlive the window. Use egui directly; still the locked "egui" toolkit. `[CITED: github.com/emilk/egui#2875]` |
| Shell thread `with_any_thread(true)` | Invert: winit on main thread, tokio runtime on a spawned thread | Both valid. The shell-thread approach matches the four existing dedicated-OS-thread spawns in `main.rs` and keeps `#[tokio::main]` — least structural churn. `[ASSUMED]` |
| `windows` crate `INetFwPolicy2` | `windows_firewall` crate / `netsh` parsing | CLAUDE.md rule: use the official `windows` crate for raw Win32; avoid a new dep and brittle string-parsing of `netsh` output. `[CITED: microsoft.github.io/windows-docs-rs WindowsFirewall]` |
| `auto-launch` | `winreg` direct HKCU `Run` write | If `auto-launch`'s default targets HKLM/admin (A2), the winreg fallback is already a dep. `[CITED: docs.rs/auto-launch]` |
| New `KeyboardScreen` reusing `KeyboardPanel` | Keyboard tile opens Trackpad with panel pre-expanded | A dedicated screen is a truer "Keyboard" tile; the panel widgets (`keyboard_panel.dart`, `hidden_text_input.dart`, `key_rows.dart`, `modifier_fsm.dart`) are already modular. `[ASSUMED]` |

**Installation (server):**
```bash
# server/server-windows/Cargo.toml — add:
tray-icon = "0.24"
winit = "0.30"
egui = "0.35"
egui-winit = "0.35"          # egui <-> winit glue (immediate-mode window on the shell loop)
egui-glow = "0.35"           # or egui-wgpu — pick the lighter renderer for a device-list + toggles UI
auto-launch = "0.6"
toml = "1.1"
dirs = "6.0"
serde = { version = "1", features = ["derive"] }
# windows crate: add features Win32_NetworkManagement_WindowsFirewall (firewall self-test).
# Win32_Security + Win32_System_Threading are already present (token/integrity for UIPI).
```
> **Version verification (2026-07-12):** `cargo search` confirms tray-icon 0.24.1, eframe/egui 0.35.0, winit top-of-registry is `0.31.0-beta.2` (**do not use the beta** — stay on 0.30 for eframe 0.35 compat), auto-launch 0.6.0, toml 1.1.2, dirs 6.0.0, muda 0.19.3 (re-exported by tray-icon — do **not** add a separate `muda` pin). `[VERIFIED: crates.io]`

**Installation (app):** No new packages — `wakelock_plus`, `shared_preferences`, `flutter_riverpod` already present.

## Package Legitimacy Audit

> `gsd-tools` seam not on PATH in this session; verdicts derived from `cargo search` + known maintainers + the CLAUDE.md registry audit (2026-07-07). All crates are established and already stack-locked.

| Package | Registry | Age / Maintainer | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|------------------|-----------|-------------|---------|-------------|
| tray-icon 0.24.1 | crates.io | mature; tauri-apps | high | github.com/tauri-apps/tray-icon | OK | Approved (locked) |
| winit 0.30 | crates.io | foundational; rust-windowing | very high | github.com/rust-windowing/winit | OK | Approved (locked) |
| egui 0.35.0 | crates.io | mature; emilk | very high | github.com/emilk/egui | OK | Approved (locked) |
| eframe 0.35.0 | crates.io | mature; emilk | very high | github.com/emilk/egui | OK | Approved — but see Alternatives (wrapper likely unused) |
| egui-winit / egui-glow 0.35 | crates.io | mature; emilk (egui workspace) | high | github.com/emilk/egui | OK | Approved |
| auto-launch 0.6.0 | crates.io | mature; zzzgydi | high | github.com/zzzgydi/auto-launch | OK | Approved (locked) |
| toml 1.1.x | crates.io | foundational; toml-rs | very high | github.com/toml-rs/toml | OK | Approved (locked) |
| dirs 6.0.0 | crates.io | foundational; dirs-rs | very high | github.com/dirs-dev/directories-rs | OK | Approved (locked) |

**Packages removed due to [SLOP] verdict:** none.
**Packages flagged as suspicious [SUS]:** none. **Version trap (not a package):** `winit 0.31.0-beta.2` sits at the top of `cargo search` — pinning it breaks eframe/egui 0.35 compat. Pin `winit = "0.30"` explicitly.

## Architecture Patterns

### System Architecture Diagram

```
                          server-windows process (#[tokio::main] stays on main)
  ┌──────────────────────────────────────────────────────────────────────────────┐
  │  MAIN THREAD: tokio runtime                                                    │
  │    startup ──► load config.toml (toml+dirs) ──► seed AuthManager.paired        │
  │    server_core::run(listener, ServerDeps{auth, pause, volume, apps, clip,      │
  │                                           conn_count, revoke})                 │
  │      accept_loop ─► run_session (select!):                                     │
  │        ├─ auth/pause/volume/apps/clip branches  (existing)                     │
  │        ├─ NEW conn_count++ on Authed / -- on cleanup  ──► watch<usize> ──┐     │
  │        ├─ NEW revoke branch: hash gone from paired ⇒ break 'read ─────────┐    │
  │        └─ NEW input_blocked watch branch (authed-gated) ─► "input.blocked"│    │
  │    dedicated OS threads (existing): input, audio, apps, clip               │   │
  │      input_thread: on Move/Click, NEW foreground-IL check ─► blocked watch ┘   │
  └───────────────┬──────────────────────────────┬────────────────────────────────┘
                  │ channels + EventLoopProxy     │ watch<usize> (tooltip),
                  │ (Send+Sync)                   │ pause_tx, revoke_tx, config sink
  ┌───────────────▼──────────────────────────────▼────────────────────────────────┐
  │  SHELL THREAD: winit 0.30 EventLoop (with_any_thread + with_user_event)         │
  │    StartCause::Init ─► create TrayIcon(muda menu: Settings / Pause / Pair / Quit)│
  │    TrayIconEvent/MenuEvent ─► proxy.send_event(UserEvent)                        │
  │    tooltip ← conn_count;  Pause menu ⇄ pause_tx;  icon state ⇄ paused/firewall   │
  │    Settings menu ─► open egui-on-winit window (device name/port/clip-sync/       │
  │                     autostart/paired list+revoke/Pair-new/firewall hint)         │
  │    startup firewall self-test (INetFwPolicy2) ─► warn icon + notify.rs toast     │
  └─────────────────────────────────────────────────────────────────────────────────┘

  Flutter app:  main.dart home=HubScreen ─► tiles (8) ─► tool screens (each wrapped
     in QuickBarScaffold: Trackpad button, hidden on Trackpad)
     _onFrame decodes NEW input.blocked ─► transient banner (auto-dismiss)
```

### Recommended Project Structure
```
server/server-windows/src/
├── main.rs              # keep #[tokio::main]; load config, seed AuthManager, spawn shell thread
├── shell/
│   ├── mod.rs           # spawn_shell_thread(deps) — winit EventLoop (with_any_thread)
│   ├── tray.rs          # TrayIcon + muda menu, icon states (normal/paused/warning), TaskbarCreated
│   └── settings.rs      # egui-on-winit settings window (on-demand create/destroy)
├── config.rs            # serde structs + load()/save() at dirs::config_dir()/RemoteControl/config.toml
├── firewall.rs          # INetFwPolicy2 inbound-allowed check (dedicated thread / COM)
├── autostart.rs         # auto-launch AutoLaunchBuilder wrapper (enable/disable/is_enabled)
├── notify.rs            # + notify_firewall_warning (extend existing)
├── input_thread.rs      # + foreground integrity-level check → blocked watch (SRV-05)
server/server-core/src/
├── auth/mod.rs          # AuthManager: paired: Vec<PairedDevice>, from_paired, revoke, change signal
├── transport/session.rs # + conn_count, + revoke branch, + input.blocked push branch
└── codec/json.rs        # + Msg::InputBlocked (proto 1.3)

app/remote_control/lib/
├── theme/tokens.dart          # D-12 single palette/token source + buildAppTheme()
├── settings/
│   ├── sensitivity.dart       # existing seam (reused)
│   ├── haptics.dart           # D-13 cached-pref gate + hapticTick()
│   ├── scroll_direction.dart  # D-11 new pref → trackpad driver
│   └── settings_screen.dart   # D-11 app Settings screen (gear icon)
├── keyboard/keyboard_screen.dart  # D-09 new tile reusing KeyboardPanel
├── widgets/quick_bar_scaffold.dart # D-10 shared shell wrapper
├── widgets/keep_awake.dart    # D-14 ref-counted WakelockPlus wrapper (Pitfall 8)
```

### Pattern 1: Tray + settings on a dedicated winit thread (SRV-01, D-discretion)
**What:** A `std::thread` runs a winit 0.30 event loop off the main thread; the tray is created on `StartCause::Init`; tray/menu events route through an `EventLoopProxy` user event.
**When to use:** The whole server shell. Matches the four existing dedicated-OS-thread spawns in `main.rs`.
```rust
// Source: https://github.com/tauri-apps/tray-icon/blob/dev/examples/winit.rs
//         + https://docs.rs/winit/latest/.../trait.EventLoopBuilderExtWindows.html
use winit::event_loop::EventLoop;
use winit::platform::windows::EventLoopBuilderExtWindows;
use tray_icon::{TrayIconBuilder, TrayIconEvent, menu::{Menu, MenuItem, MenuEvent}};

enum UserEvent { Tray(TrayIconEvent), Menu(MenuEvent), Tooltip(usize) }

fn spawn_shell_thread(/* deps: pause_tx, conn_count_rx, auth, config sink ... */) {
    std::thread::spawn(move || {
        let event_loop = EventLoop::<UserEvent>::with_user_event()
            .with_any_thread(true)   // off-main: keeps main.rs on #[tokio::main]
            .build()
            .expect("winit event loop");
        let proxy = event_loop.create_proxy();
        // forward tray + menu events into THIS loop (Send+Sync proxy):
        let p = proxy.clone();
        TrayIconEvent::set_event_handler(Some(move |e| { let _ = p.send_event(UserEvent::Tray(e)); }));
        let p = proxy.clone();
        MenuEvent::set_event_handler(Some(move |e| { let _ = p.send_event(UserEvent::Menu(e)); }));
        // Tray MUST be built on StartCause::Init (see ApplicationHandler::new_events).
        // ... run the loop; on Menu(Quit) exit; on Tooltip(n) tray.set_tooltip(...).
    });
}
```
**Cross-thread wiring:** `EventLoopProxy` is `Send + Sync` — the tokio side sends `UserEvent::Tooltip(n)` whenever the `conn_count` watch changes; the shell thread drives `pause_tx` / `auth.begin_pairing()` in response to menu clicks.

### Pattern 2: Config as source of truth, mirrored to AuthManager (SRV-03, D-01)
**What:** `config.toml` at `dirs::config_dir().join("RemoteControl/config.toml")`; loaded at startup, re-serialized on every paired-set mutation.
```rust
// Source: docs.rs/toml + docs.rs/dirs (config_dir() == %APPDATA%\Roaming on Windows)
#[derive(serde::Serialize, serde::Deserialize, Default)]
struct Config {
    device_name: Option<String>,   // overrides COMPUTERNAME beacon name
    port: Option<u16>,             // resolved: RC_PORT env > config.port > DEFAULT_PORT
    autostart: bool,
    clipboard_sync: bool,          // gates the clip auto-sync/push
    #[serde(default)] paired: Vec<PairedDeviceCfg>,
}
#[derive(serde::Serialize, serde::Deserialize)]
struct PairedDeviceCfg { name: String, hash: String /*64 hex*/, paired_at: u64 }
```
**Load path:** parse → decode each `hash` hex to `[u8;32]` (skip malformed, never panic — V5) → `AuthManager::from_paired(...)`. **Save path:** `AuthManager` pulses a change signal (a `watch::Sender<u64>` version bump on any paired mutation); the composition root subscribes and re-serializes the whole file. Keeps **all file I/O in server-windows** so server-core stays Windows-free.

### Pattern 3: On-demand pairing + smart startup (D-02/D-03)
**What:** Replace the unconditional `begin_pairing()` + re-pin loop in `main.rs` (steps 5/5a) with:
- **Startup:** `if auth.is_paired() { /* silent */ } else { begin_pairing(); notify_pin(); /* bounded refresh while unpaired */ }`.
- **On demand (tray/settings "Pair new device"):** `auth.begin_pairing(); notify_pin();` — opens a fresh window any time.
`pin.rs` line ~126 (`self.active = None` on success = single-use) is **correct and unchanged**. The thing to remove is the *permanent* auto-refresh loop; refresh only bounded while a pairing window is open and no device has paired for it.

### Pattern 4: Revoke → force-disconnect (D-05)
**What:** A `tokio::sync::watch::Sender<u64>` "revocation epoch" in `ServerDeps`. On revoke: `AuthManager.revoke(hash)` + config save + `revoke_tx.send(epoch+1)`. Each session records **which hash authed it** (change `verify_auth` to return the matching hash, stored on the session at Authed). Add a `select!` branch: when the revoke epoch advances, if this session's auth hash is no longer in `AuthManager.paired` → `break 'read`. The existing straight-line CONN-07 cleanup closes the socket; the client reconnects, `verify_auth` now returns false → `authFail(badMac/noPairing)` → the existing `kRevokedExplanation` → re-pair (D-05 exact behavior).

### Pattern 5: UIPI status via proto-1.3 amendment (SRV-05, D-07)
**What:** Follow the `vol.changed` (05-01) / `apps.changed` / `clip.changed` (06-01) precedent exactly.
- **Detect (input_thread):** before/around a Move/Click, `GetForegroundWindow` → `GetWindowThreadProcessId` → `OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION)` → `OpenProcessToken(TOKEN_QUERY)` → `GetTokenInformation(TokenIntegrityLevel)`; if the foreground IL > our process IL (or `OpenProcess` returns `ERROR_ACCESS_DENIED`, itself a higher-IL signal) → the injection is being silently dropped. Debounce to a transition (don't fire per frame).
- **Push:** the input thread advances a `watch<u64>` "blocked epoch"; `session.rs` adds an **authed-gated** `select!` branch (identical privacy backstop to volume/apps/clip) that emits `input.blocked` when the epoch advances.
- **Protocol:** `json.rs` — add `InputBlockedPayload` + `Msg::InputBlocked` + encode/decode `"input.blocked"` arms; bump `SERVER_PROTO_VERSION` to `"1.3"` (minor/additive — 1.0–1.2 clients still accepted, `SERVER_PROTO_MAJOR` unchanged). Add a golden fixture under `protocol/fixtures/input_blocked/` with the unknown-field-ignored discipline. Mirror in the `remote_protocol` Dart package (`json_codec.dart`) + Dart fixture test.
- **Client:** `connection_service.dart _onFrame` — decode `InputBlockedMsg`, park a transient snapshot, `_notify()`; a banner widget shows D-07 copy and auto-dismisses (a `Timer`), contextual not permanent.

### Pattern 6: Flutter shared quick-bar scaffold (UI-01, D-10)
**What:** A `QuickBarScaffold({required Widget body, bool showQuickBar = true})` that renders `body` + a persistent bottom bar with one Trackpad button (`Navigator.push(TrackpadScreen)`). Every tool screen wraps its body in it; `TrackpadScreen` passes `showQuickBar: false` (or the wrapper is simply omitted there). Applied either inside each tool screen's `Scaffold.bottomNavigationBar` or centrally in `HubScreen._open` when pushing `spec.builder`.

### Anti-Patterns to Avoid
- **`eframe::run_native` for the settings window in a tray daemon** — it owns the winit loop and cannot share it with `tray-icon`; the window==loop lifecycle fights an on-demand window. Use egui-on-winit. `[CITED: github.com/emilk/egui#2875]`
- **Treating `bind` success as "port reachable"** — bind is local and unaffected by the firewall; a firewall block passes bind and still refuses LAN peers (Pitfall 5).
- **Relying on `SendInput` return / `GetLastError` to detect UIPI** — it does not report UIPI drops (Pitfall 6).
- **Trusting the raw global `WakelockPlus` flag** across the new quick-bar navigation paths (Pitfall 8).
- **Leaving palette consts copy-pasted per file** — D-12 explicitly consolidates them.
- **Reading a Riverpod/prefs value inside a haptic call on every tap** — cache it (mirror the `sensitivity.dart` cached-double pattern).

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Tray icon + context menu | Raw `Shell_NotifyIcon` + `TrackPopupMenu` | `tray-icon` 0.24 + `muda` (its re-export) | Handles HICON, menus, and (Pitfall 1) TaskbarCreated |
| Autostart registry | Hand-written HKCU `Run` write | `auto-launch` 0.6 (winreg fallback) | Path quoting + `is_enabled` round-trip are fiddly |
| Config parse/serialize | Manual TOML string building | `toml` + `serde` derive | Forward-compat + type-safe defaults |
| `%APPDATA%` path | `env!("APPDATA")` string-glue | `dirs::config_dir()` | Cross-platform, correct known-folder |
| Firewall block detection | Parsing `netsh advfirewall` text | `windows` crate `INetFwPolicy2` | Stable API vs locale-dependent CLI text |
| Foreground elevation check | Guessing from window title / heuristics | `OpenProcessToken` + `GetTokenInformation(TokenIntegrityLevel)` | The only reliable IL comparison |
| Protocol codec (input.blocked) | New app-side JSON handling | `remote_protocol` package + golden fixtures | Byte-identical Rust/Dart is a locked project rule |
| Palette in every widget | `const Color _bg = ...` per file | One `lib/theme/tokens.dart` | D-12 is exactly this consolidation |
| Per-call haptic pref reads | `ref.read(pref)` at each call site | One cached `hapticTick()` helper | Hot-path cheapness + single toggle point |
| Keep-awake bookkeeping | Bare `WakelockPlus.enable/disable` per screen | Ref-counted `keep_awake.dart` helper | Global flag double-toggle leak (Pitfall 8) |

**Key insight:** Nearly every Phase-7 primitive already exists as a maintained crate/package or an established in-repo seam. The genuinely new *engineering* is topology (where the winit loop lives, how tokio and the shell thread talk) and two Win32 detection quirks (firewall ≠ bind, UIPI is undetectable reactively). Custom code should be confined to those.

## Runtime State Inventory

> Phase 7 introduces persisted server state and OS registrations for the first time. This inventory is REQUIRED even though it is greenfield-adjacent.

| Category | Items Found | Action Required |
|----------|-------------|------------------|
| Stored data | **NEW this phase:** `%APPDATA%/RemoteControl/config.toml` (device name, port, autostart, clipboard_sync, paired SHA-256 hashes + name/paired_at). Today paired state is in-memory only (`AuthManager.paired_hashes`). | Create the file on first pairing; load at startup; re-write on every paired-set change and settings change. Corrupt/partial file must fail safe (defaults). |
| Live service config | None external. The beacon `device_name` currently comes from `COMPUTERNAME`; once config carries `device_name` it overrides the env — verify nothing else reads `COMPUTERNAME`. | Route beacon `name` through config → env fallback. |
| OS-registered state | **NEW:** HKCU `...\CurrentVersion\Run` entry via `auto-launch` (autostart). Its `app_path` MUST be the absolute `current_exe()`; a moved/renamed exe orphans the entry and `is_enabled()` returns false. | On enable, write absolute exe path; document that moving the binary requires re-toggling autostart. |
| Secrets / env vars | Auth **tokens** never touch config — only SHA-256 hashes (T-01-08). `RC_PORT` / `RC_BEACON_PORT` env overrides still exist (dev). Client token stays in `flutter_secure_storage`; new app prefs (haptics/scroll) are NON-secret → `shared_preferences`. | Enforce "hashes only, never raw token" in config serde; keep env override precedence `RC_PORT > config.port > DEFAULT_PORT`. |
| Build artifacts | The tray needs an **icon asset** embedded/bundled with the exe (normal + paused + warning states). None exists yet. | Add icon resource(s); `tray-icon` needs RGBA/`Icon` at runtime. Also: adding autostart means the exe location becomes semantically load-bearing. |

**Nothing found for:** external databases, n8n/scheduler/service registrations, Datadog/Tailscale/Cloudflare tags — none apply to this project.

## Common Pitfalls

### Pitfall 1: Tray icon disappears after an Explorer restart (SRV-01 SC1)
**What goes wrong:** When `explorer.exe` restarts (crash or update), all tray icons are dropped; a naive `Shell_NotifyIcon` app never re-adds its icon.
**Why it happens:** Windows broadcasts a registered `TaskbarCreated` message that each tray app must handle to re-register.
**How to avoid:** Verify `tray-icon` 0.24 re-registers on `TaskbarCreated` internally (recent versions do). If it does not, handle the message and rebuild the `TrayIcon`. This is a named success criterion — add an explicit on-device check (kill+restart Explorer, confirm the icon returns). `[ASSUMED — verify against tray-icon 0.24 source/on-device]`
**Warning signs:** Icon gone after `taskkill /f /im explorer.exe && start explorer`.

### Pitfall 2: winit event loop refuses to build off the main thread
**What goes wrong:** `EventLoop::build()` on a spawned thread panics ("can only be created on the main thread").
**Why it happens:** winit defaults to main-thread-only for platform portability.
**How to avoid:** `EventLoopBuilder::with_user_event().with_any_thread(true).build()` (the `EventLoopBuilderExtWindows` trait). Note the caveat: windows created on that thread die when the thread ends — fine, the shell thread lives for the whole process. `[CITED: docs.rs/winit EventLoopBuilderExtWindows]`

### Pitfall 3: Tray created before `StartCause::Init`
**What goes wrong:** Building the `TrayIcon` too early (before the loop pumps) yields a missing/dead icon.
**How to avoid:** Create it in `ApplicationHandler::new_events` on `StartCause::Init` (or `resumed`), never in `main`/thread-spawn. `[CITED: docs.rs/tray-icon]`

### Pitfall 4: `eframe` cannot host the settings window on the tray's loop
**What goes wrong:** Planning "eframe settings window + tray on one loop" hits a wall — `eframe::run_native` creates its own loop and blocks.
**How to avoid:** Use `egui` + `egui-winit` + `egui-glow`/`egui-wgpu` directly on the shell thread's loop, creating/destroying the settings window on demand. Still the locked "egui" toolkit. `[CITED: github.com/emilk/egui#2875]`

### Pitfall 5: Firewall block does not fail `bind` (SRV-04)
**What goes wrong:** A "can I listen?" self-test always passes even when the firewall blocks all inbound LAN connections — the warning never fires.
**Why it happens:** `bind(0.0.0.0:port)` is a local operation; the Windows Firewall filters *inbound connections from other hosts*, not the bind.
**How to avoid:** Separate two failures. (a) **Port in use:** `bind` returns `AddrInUse` — today `main.rs` `?`-propagates and crashes; Phase 7 must catch it and surface a distinct tray warning. (b) **Firewall inbound blocked (bind OK):** query `INetFwPolicy2` — is the firewall on for the active profile, and is there an allow rule for our exe/TCP-port? No rule + default-block inbound → warn. Reading firewall state is **unprivileged** (only modifying needs admin). A fully reliable test needs a second host; the rule-check is the best single-host heuristic — document the limitation. `[CITED: microsoft.github.io/windows-docs-rs WindowsFirewall; A3]`

### Pitfall 6: UIPI drops are invisible to SendInput (SRV-05)
**What goes wrong:** Trying to detect the elevated-window block by checking `SendInput`'s return value or `GetLastError` — neither reports UIPI. `SendInput` returns the count inserted; `0` means "already blocked *by another thread* (BlockInput)", **not** UIPI.
**Why it happens:** By design, UIPI silently discards input from a lower-integrity process into a higher-integrity window.
**How to avoid:** Detect **proactively** — compare the foreground window's process integrity level to our own (medium/non-elevated). Foreground High IL (elevated app / UAC prompt) ⇒ our input is dropped. `OpenProcess`/`OpenProcessToken` failing with `ERROR_ACCESS_DENIED` on the foreground PID is itself a higher-IL signal. Precedent: the apps thread already uses `PROCESS_QUERY_LIMITED_INFORMATION` + `QueryFullProcessImageNameW`. `[CITED: learn.microsoft.com SendInput UIPI; A4]`
**Warning signs:** Input "works everywhere except Task Manager / UAC / an app run as admin" with no error.

### Pitfall 7: `auto-launch` may default to HKLM (admin) not HKCU (SRV-02)
**What goes wrong:** `enable()` throws access-denied, or writes a system-wide entry needing admin, contradicting the spec's HKCU `Run` requirement.
**Why it happens:** Docs note the crate "tries the system registry by default" on some paths.
**How to avoid:** Configure the builder for per-user (HKCU) and pass the absolute `current_exe()` as `app_path`; verify `is_enabled()` round-trips without elevation. If it insists on HKLM, fall back to a direct `winreg` HKCU `...\Run` write (already a dep, CLAUDE.md alternative). `[CITED: docs.rs/auto-launch; A2]`

### Pitfall 8: Keep-awake "audit only" hides a real ref-count leak once the quick-bar exists (UI-02, D-14)
**What goes wrong:** `WakelockPlus` is a **global, non-ref-counted** flag. Today only `trackpad_screen` and `presenter_screen` enable/disable it (paired in initState/dispose — currently correct). The **new D-10 quick-bar** adds a *tool → Trackpad → back* navigation path: e.g. `hub → Presenter → (quick-bar) → Trackpad → pop`. `Trackpad.dispose()` calls `WakelockPlus.disable()` **globally**, dropping keep-awake while the underlying Presenter still wants it.
**Why it happens:** Two screens both driving one global boolean; the later `disable()` wins regardless of the other's intent.
**How to avoid:** Introduce a small **ref-counted** `keep_awake.dart` helper (an int of active requesters; `enable()` only when 0→1, `disable()` only when 1→0). Route both screens through it. The audit's actionable output is this helper, not "confirmed fine". `[ASSUMED — grep confirms only trackpad+presenter use it today; the leak is a consequence of the new quick-bar path]`

### Pitfall 9: Grid tension — full-width Trackpad vs uniform 2×4 (UI-01, D-09)
**What goes wrong:** `HubTileGrid` renders `tiles.first` full-width + the rest as half-tiles (the D-02 Trackpad-primary layout). With 8 tiles this yields a full-width Trackpad + 7 halves, not the design spec's literal "2×4" grid.
**How to avoid:** Decide explicitly (Open Q1). Recommendation: **uniform 2×4** now that the persistent quick-bar (a dedicated Trackpad shortcut on every screen) carries the Trackpad-primacy role that the full-width tile used to. `HubTileGrid` "chunks any list", so this is a small layout change, not a rewrite. Flag for the planner + UI-safety gate.

## Code Examples

### Autostart toggle (SRV-02)
```rust
// Source: https://docs.rs/auto-launch
use auto_launch::AutoLaunchBuilder;
let exe = std::env::current_exe()?;
let auto = AutoLaunchBuilder::new()
    .set_app_name("Remote Control")
    .set_app_path(exe.to_string_lossy().as_ref())
    .build()?;
auto.enable()?;                 // writes HKCU ...\Run (verify: not HKLM — Pitfall 7)
let on = auto.is_enabled()?;    // round-trip for the settings toggle state
auto.disable()?;                // clean off
```

### Foreground integrity-level check (SRV-05 detection, sketch)
```rust
// Source: learn.microsoft.com SendInput/UIPI + windows crate token APIs
// (runs on the input thread; Win32 only, never blocks a tokio worker)
// GetForegroundWindow -> GetWindowThreadProcessId -> OpenProcess(
//   PROCESS_QUERY_LIMITED_INFORMATION) -> OpenProcessToken(TOKEN_QUERY)
//   -> GetTokenInformation(TokenIntegrityLevel); compare SID RID to ours.
// If foreground RID > SECURITY_MANDATORY_MEDIUM_RID (our level), or OpenProcess
// returns ERROR_ACCESS_DENIED, our SendInput to that window is being dropped.
// Debounce to a transition, advance a watch<u64> "blocked epoch".
```

### input.blocked amendment shape (SRV-05, mirrors vol.changed fixture)
```jsonc
// protocol/fixtures/input_blocked/01-input-blocked.json  (unknown fields ignored, D-05)
{ "wire":   { "t": "input.blocked", "p": { "reason": "elevated", "future": "ignored" } },
  "expect": { "t": "input.blocked", "p": { "reason": "elevated" } } }
```
```rust
// server-core/src/codec/json.rs — additive, proto minor bump to "1.3"
pub struct InputBlockedPayload { pub reason: String }   // "elevated"
// Msg::InputBlocked(InputBlockedPayload); "input.blocked" => decode; encode arm;
// SERVER_PROTO_VERSION = "1.3"; SERVER_PROTO_MAJOR unchanged (1.0–1.2 still accepted).
```

### Haptics gate (UI-02, D-13)
```dart
// app/remote_control/lib/settings/haptics.dart — cached bool (mirrors sensitivity cache)
// hapticsEnabledProvider (shared_preferences, default true) + a cached bool the
// hot paths read; call sites become:
void hapticTick() { if (_hapticsCached) HapticFeedback.lightImpact(); }
// Injected callbacks (onHaptic:, onPressHaptic:) pass `hapticTick` instead of
// `HapticFeedback.lightImpact`. ~15 sites (browser, apps x3, clipboard x2, media,
// keyboard_panel x3, trackpad x2, power x2 [mediumImpact], presenter x5).
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| One pairing per process run (in-memory token) | Persisted paired set (config.toml) + on-demand pairing | This phase (folds the pending todo) | Multi-device + revoke + re-pair become real (SRV-03) |
| `eframe` for any desktop egui app | egui-on-winit when a tray/multi-window/on-demand loop is needed | egui issue #2875 (open) | eframe's single-loop model is wrong for a tray daemon |
| winit 0.29-era main-thread-only loops | `with_any_thread(true)` off-main loops | winit 0.30 | Lets the shell thread coexist with `#[tokio::main]` |
| `wakelock` (dead) | `wakelock_plus` (already in use) | pre-phase | D-14 audit only — but needs a ref-count wrapper (Pitfall 8) |

**Deprecated/outdated:**
- `winit 0.31.0-beta.2` — top of `cargo search` but a **beta**; incompatible with eframe/egui 0.35. Pin `winit = "0.30"`.
- `encryptedSharedPreferences: true` (flutter_secure_storage) — irrelevant here (new app prefs are non-secret → `shared_preferences`), but reaffirm the CLAUDE.md rule.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `tray-icon` 0.24 auto-handles `TaskbarCreated` re-registration | Pitfall 1 | Icon vanishes after Explorer restart (a named SC) — needs a manual re-register + on-device check |
| A2 | `auto-launch` 0.6 writes HKCU (per-user, no admin) when configured so | Pitfall 7 | `enable()` fails without elevation; fall back to `winreg` HKCU write |
| A3 | Reading `INetFwPolicy2` firewall state is unprivileged | Pitfall 5 | If it needs admin, the self-test degrades to bind-only + a generic hint |
| A4 | Foreground IL > our IL (or OpenProcess ACCESS_DENIED) reliably predicts a UIPI drop | Pitfall 6 | False positives/negatives on the UIPI banner; tune the debounce/threshold on-device |
| A5 | `dirs::config_dir()` = `%APPDATA%\Roaming` matches the spec's `%APPDATA%/RemoteControl` | Pattern 2 | Config lands in the wrong folder; use `config_dir` (Roaming) not `data_local_dir` |
| A6 | egui-on-winit (not eframe) is acceptable under the "eframe/egui stack-locked" decision | Pattern 1 / Pitfall 4 | If eframe is mandatory, the tray/window topology needs a redesign (run_on_demand) — recommend a spike |
| A7 | The phone's `hello` device name is available to record with the paired hash | Pattern 2 | Paired list shows a generic name; may need to thread `hello.name` into `complete_pairing(name)` |
| A8 | Keyboard tile = new `KeyboardScreen` reusing `KeyboardPanel` is the least-rework path | Standard Stack (Alt) | If the panel is too coupled to the trackpad, the tile may open Trackpad-with-panel instead |

## Open Questions

1. **Hub grid: full-width Trackpad vs uniform 2×4?**
   - Known: `HubTileGrid` currently renders `tiles.first` full-width + halves (D-02 legacy). D-09 gives an 8-tile order, not a grid shape.
   - Unclear: which the design spec's "2×4" intends now that a persistent Trackpad quick-bar exists.
   - Recommendation: uniform 2×4 (quick-bar carries Trackpad primacy); confirm at the UI-safety gate.
2. **eframe vs egui-on-winit for the settings window.**
   - Known: eframe cannot share the tray's loop (#2875); egui-on-winit can.
   - Recommendation: egui-on-winit; run a ~½-day spike to prove the tray + on-demand egui window share one loop before committing the plan.
3. **Port change: live re-bind or restart-required?** (explicit research flag)
   - Known: the listener is owned by `server_core::run` running to completion; live re-bind means dropping the `TcpListener`, restarting the beacon with a new `ws_port`, and migrating sessions.
   - Recommendation: **restart-required.** Settings writes the new port + shows "restart to apply" (optionally a Quit→autostart-relaunch). Live re-bind is a v2 nicety; the complexity/risk is not worth it for a personal daily driver.
4. **Proper AUMID registration now or defer?**
   - Known: unpackaged-exe AUMID needs a Start-Menu shortcut carrying `System.AppUserModel.ID`; interim `POWERSHELL_APP_ID` already works for toasts.
   - Recommendation: defer proper AUMID to the v2 installer (FEAT-04); keep the interim ID. Revisit only if branded tray notifications are wanted.
5. **clipboard_sync toggle wiring.** The clip thread (06-06) runs auto-sync/push; the settings toggle must gate it. Confirm whether `ClipCmd` already exposes an enable/disable, or add one, plus a shared flag the `clip.changed` push branch respects.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain (edition 2024) | server build | ✓ (project builds) | rustc ≥ 1.85 | — |
| cargo / crates.io | new crates | ✓ | — | — |
| Windows 11 (win32, COM, WindowsFirewall, integrity APIs) | tray/firewall/UIPI | ✓ | 11 | — |
| Flutter SDK | app build | ✓ | 3.44 / Dart ^3.12 | — |
| Windows Explorer (tray host) | SRV-01 SC | ✓ | — | — |

**Missing dependencies with no fallback:** none. **With fallback:** `auto-launch` HKCU behavior → `winreg` direct write (A2). All new crates are on crates.io and stack-locked; no external services.

## Validation Architecture

> `workflow.nyquist_validation` is enabled (config.json). Test seams identified below.

### Test Framework
| Property | Value |
|----------|-------|
| Framework (server) | `cargo test` (workspace `server-core` + `server-windows`); optional `cargo-nextest` |
| Framework (app) | `flutter_test` (widget + unit); shared golden fixtures in `protocol/fixtures/` |
| Config file | `server/Cargo.toml` workspace; `app/remote_control/pubspec.yaml` |
| Quick run command | `cd server && cargo test -p server-core` / `cd app/remote_control && flutter test test/<file>` |
| Full suite command | `cd server && cargo test` + `cd app/packages/remote_protocol && dart test` + `cd app/remote_control && flutter test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| SRV-03 | config.toml serde round-trip + malformed-safe load | unit | `cargo test -p server-windows config` | ❌ Wave 0 (`config.rs` tests) |
| SRV-03 | `AuthManager::from_paired` / `revoke` / `complete_pairing(name)` | unit | `cargo test -p server-core auth` | ⚠️ extend `auth/mod.rs` tests |
| SRV-03/D-03 | smart-startup: paired ⇒ silent, empty ⇒ begin_pairing | unit | `cargo test -p server-windows startup` | ❌ Wave 0 |
| SRV-03/D-05 | revoke drops a live authed session → reconnect authFail | integration | `cargo test -p server-core` (fake-ws client, existing suite pattern) | ⚠️ extend transport integration test |
| SRV-01 | conn_count watch increments on Authed / decrements on cleanup | unit/integration | `cargo test -p server-core session` | ❌ Wave 0 |
| SRV-01 | pause toggle drops input, keeps connection (existing pause seam) | integration | existing pause test extended | ⚠️ extend |
| SRV-01 | tray appears / tooltip / quit / **Explorer-restart survival** | manual (on-device) | UAT checklist | manual |
| SRV-02 | autostart enable/disable/is_enabled round-trip | integration (writes real HKCU — guard/cleanup) | `cargo test -p server-windows autostart -- --ignored` | ❌ Wave 0; reboot = manual |
| SRV-04 | bind-in-use surfaces a warning (not a crash) | unit/integration | `cargo test -p server-windows firewall` | ❌ Wave 0 |
| SRV-04 | firewall-check runs without panic; blocked ⇒ warn | smoke + manual | on-device (toggle a firewall rule) | manual |
| SRV-05 | `input.blocked` proto-1.3 golden fixture decodes identically (Rust + Dart) | unit | `cargo test -p server-core codec` + `dart test` | ❌ Wave 0 (fixture + both codecs) |
| SRV-05 | banner shows on `input.blocked`, auto-dismisses | widget | `flutter test test/uipi_banner_test.dart` | ❌ Wave 0 |
| SRV-05 | integrity-level detection fires on an elevated foreground | manual | run an admin app, attempt input | manual |
| UI-01 | home is `HubScreen`; 8 tiles present + correct order | widget | `flutter test test/hub_tiles_test.dart` | ⚠️ extend |
| UI-01 | offline ⇒ tiles disabled except Settings | widget | `flutter test test/hub_offline_test.dart` | ❌ Wave 0 |
| UI-01 | quick-bar present on tool screens, hidden on Trackpad | widget | `flutter test test/quick_bar_test.dart` | ❌ Wave 0 |
| UI-02 | haptics gate honors the pref (on/off) | unit | `flutter test test/haptics_gate_test.dart` | ❌ Wave 0 |
| UI-02 | keep-awake ref-count: enable at 0→1, disable at 1→0 | unit | `flutter test test/keep_awake_test.dart` | ❌ Wave 0 |
| UI-02 | theme tokens single-source (no per-file palette literal regressions) | unit/lint | grep-guard test or analyzer | ❌ Wave 0 (optional) |

### Sampling Rate
- **Per task commit:** the relevant `cargo test -p <crate> <module>` or single `flutter test <file>` (< 30s).
- **Per wave merge:** full `cargo test` + `dart test` (remote_protocol) + `flutter test`.
- **Phase gate:** full suite green + the on-device UAT checklist (tray/Explorer-restart, reboot autostart, firewall toggle, elevated-window banner, dashboard/quick-bar/haptics/keep-awake) before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `server-windows/src/config.rs` (+ tests) — serde round-trip, malformed-safe load, port precedence.
- [ ] `server-core/src/auth/mod.rs` — extend for `from_paired`/`revoke`/`complete_pairing(name)` + change signal.
- [ ] `server-core/src/transport/session.rs` — conn_count watch + revoke branch + input.blocked branch tests.
- [ ] `protocol/fixtures/input_blocked/*.json` + Rust (`codec/json.rs`) + Dart (`remote_protocol/json_codec.dart`) codec cases.
- [ ] `app` widget tests: hub offline state, quick-bar, uipi banner; unit tests: haptics gate, keep-awake ref-count.
- [ ] Firewall/autostart integration tests behind `--ignored` (touch real OS state) with cleanup.
- Framework install: none needed (cargo + flutter_test + dart test already in use).

## Security Domain

> `security_enforcement` enabled, ASVS Level 1.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Persist **SHA-256 hashes only** in config.toml (never raw tokens, T-01-08); PIN pairing unchanged (`sha2` 0.11, `subtle` constant-time) |
| V3 Session Management | yes | Revoke MUST drop the live session (D-05) and force re-auth; existing per-session challenge nonce + liveness deadline unchanged |
| V4 Access Control | yes | Autostart → **HKCU** (per-user, no privilege escalation, not a system-wide HKLM persistence vector); firewall API is **read-only** (no rule injection — that's the deferred v2 installer); the server does **not** attempt to bypass UIPI (no elevation/UIAccess) — surfacing the limitation honestly is the secure choice |
| V5 Input Validation | yes | config.toml parse fails safe: bad hex hash skipped, out-of-range port clamped, missing fields defaulted; settings inputs (port, device name) validated; `input.blocked` is S→C only, still forward-compat unknown-field-ignore on decode |
| V6 Cryptography | yes (no new crypto) | Reuse `sha2` 0.11 token hashing; never hand-roll |

### Known Threat Patterns for {Rust tray daemon + persisted auth + Flutter client}
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Raw token written to config.toml | Information disclosure | Serialize **hash hex only**; enforce in the serde struct + a test asserting no raw-token field exists |
| config.toml tampering to inject a paired device | Tampering | Local file write = already-compromised host (out of the LAN threat model); document; per-user `%APPDATA%` perms limit cross-user reach |
| Autostart entry as a persistence/EoP vector | Elevation of Privilege | HKCU-only (no admin, no system-wide), absolute exe path, user-toggleable + visible in the settings window |
| Firewall self-test used to *modify* rules | Elevation of Privilege | **Read-only** query (`INetFwPolicy2` get), never create/modify a rule; rule creation is deferred to the signed installer |
| UIPI status message leaking to an unauthed socket | Information disclosure | The `input.blocked` push rides the **authed-gated** `select!` branch (same backstop as vol/apps/clip); no after-auth snapshot needed |
| Revoke that doesn't actually disconnect | Spoofing / broken access control | Force-disconnect signal + re-auth failure is the control; integration-test it (revoked hash ⇒ session breaks ⇒ authFail) |
| Tray tooltip leaking paired device names on a shared screen | Information disclosure | Show device **count**, not names, in the tooltip (spec already says "connected device count") |

## Sources

### Primary (HIGH confidence)
- crates.io / `cargo search` (2026-07-12) — tray-icon 0.24.1, eframe/egui 0.35.0, winit 0.30 (beta 0.31 excluded), auto-launch 0.6.0, toml 1.1.2, dirs 6.0.0, muda 0.19.3.
- Existing codebase (read this session): `server-windows/src/main.rs`, `input_thread.rs`, `notify.rs`, `Cargo.toml`; `server-core/src/transport/{mod,session,listener}.rs`, `auth/{mod,pin,token}.rs`, `codec/json.rs`; `app/.../{main,hub_screen,trackpad_screen,connection_service,reconnect_fsm,connection_copy,sensitivity}.dart`; `pubspec.yaml`; `protocol/fixtures/`.
- CONTEXT.md (14 D-decisions), ROADMAP.md Phase 7, REQUIREMENTS.md (SRV-01..05, UI-01/02), CLAUDE.md stack lock table.

### Secondary (MEDIUM confidence — official docs via WebSearch)
- [tray-icon docs.rs](https://docs.rs/tray-icon/latest/tray_icon/) + [winit example](https://github.com/tauri-apps/tray-icon/blob/dev/examples/winit.rs) — StartCause::Init timing, EventLoopProxy user-event pattern.
- [winit EventLoopBuilderExtWindows](https://docs.rs/winit/latest/x86_64-pc-windows-msvc/winit/platform/windows/trait.EventLoopBuilderExtWindows.html) — `with_any_thread`.
- [egui issue #2875](https://github.com/emilk/egui/issues/2875) — eframe cannot run on an existing event loop.
- [auto-launch docs.rs](https://docs.rs/auto-launch) — AutoLaunchBuilder, HKCU/HKLM behavior.
- [Microsoft Learn: SendInput](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendinput) + [UIPI forum](https://social.msdn.microsoft.com/Forums/en-US/b68a77e7-cd00-48d0-90a6-d6a4a46a95aa) — SendInput does not report UIPI.
- [windows-docs-rs WindowsFirewall](https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/NetworkManagement/WindowsFirewall/) — INetFwPolicy2.

### Tertiary (LOW confidence — flagged for verification)
- TaskbarCreated auto-re-registration in tray-icon 0.24 (A1) — verify against source / on-device.
- auto-launch HKCU-by-default without admin (A2) — verify at implementation.

## Metadata

**Confidence breakdown:**
- Standard stack / versions: HIGH — cargo-search-verified + stack-locked.
- Server shell topology (winit thread + egui-on-winit): MEDIUM — docs-verified; recommend a spike (Open Q2).
- Firewall self-test: MEDIUM — API confirmed; single-host detection is heuristic (Pitfall 5).
- UIPI detection: MEDIUM-HIGH — the "SendInput can't report it, detect proactively" conclusion is well-sourced; thresholds need on-device tuning (A4).
- Persistence/pairing/revoke seams: HIGH — grounded directly in the read code.
- App-side (dashboard, tiles, quick-bar, theme, haptics, keep-awake): HIGH — existing widgets are modular; the keep-awake ref-count leak (Pitfall 8) is a concrete, defensible finding.

**Research date:** 2026-07-12
**Valid until:** ~2026-08-11 (30 days; stable crates. Re-check winit/eframe if the egui workspace ships 0.36 or winit 0.31 leaves beta.)
