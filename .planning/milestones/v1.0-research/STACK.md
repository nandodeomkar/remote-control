# Stack Research

**Domain:** Phone-as-remote-input system — Flutter Android client + Rust Windows input-injection tray server (WebSocket transport, UDP broadcast discovery)
**Researched:** 2026-07-07
**Confidence:** HIGH (all versions verified against crates.io / pub.dev registry APIs on 2026-07-07)

## Verdict on Locked Choices

The spec-locked stack (Flutter client; Rust server with tokio + tungstenite, enigo, tray-icon, arboard; WebSocket + UDP broadcast) **validates cleanly against the 2026 ecosystem**. Every locked crate/package is actively maintained as of mid-2026. No replacements needed. Two items carry caveats that affect implementation (not selection): enigo's Windows injection limitations and tray-icon's event-loop threading requirement — both detailed below.

| Locked choice | 2026 status | Verdict |
|---------------|-------------|---------|
| tokio | 1.52.3 (May 2026) — de facto async runtime | KEEP — HIGH |
| tokio-tungstenite | 0.29.0 (Mar 2026) — standard tokio WS binding | KEEP — HIGH |
| enigo | 0.6.1 (crate Aug 2025; repo pushed 2026-07-01, active) | KEEP, with Windows caveats — HIGH |
| tray-icon | 0.24.1 (Jun 2026) — tauri-apps, actively maintained | KEEP, needs win32 event loop — HIGH |
| arboard | 3.6.1 (Aug 2025) — standard Rust clipboard | KEEP — HIGH |
| Flutter | 3.44 stable (2026) | KEEP — HIGH |
| WebSocket + UDP broadcast | No ecosystem shift; still the standard LAN pattern | KEEP — HIGH |

## Recommended Stack

### Core Technologies — Rust server (`server/`)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Rust stable | 1.8x, edition 2024 | Server language | Locked by spec; single ~5MB binary, no runtime |
| tokio | 1.52 | Async runtime | Only serious choice for async Rust networking. Features needed: `rt-multi-thread`, `net`, `sync`, `time`, `macros` |
| tokio-tungstenite | 0.29 | WebSocket server | Standard tokio binding for tungstenite; handles text + binary frames natively (matches 9-byte mouse frame + JSON design) |
| enigo | 0.6 | Mouse/keyboard injection (SendInput) | Cross-platform (Windows/Linux/macOS) — the whole reason it was locked for future server ports. Has `Key::MediaPlayPause`, `MediaNextTrack`, `MediaPrevTrack`, `VolumeMute` etc. built in, and `text()` does layout-independent Unicode via `KEYEVENTF_UNICODE` |
| tray-icon | 0.24 | System tray icon + menu | tauri-apps project, releases monthly; re-exports `muda` for menus. The alternative (`trayicon` by Ciantic) is less maintained |
| arboard | 3.6 | Clipboard get/set | Standard Rust clipboard crate (1Password-maintained lineage); text is all v1 needs. Pair with a tokio interval poll for change detection — arboard has no change events |
| windows | 0.62 | Raw Win32 for volume/apps/power | Microsoft's official crate. Needed for everything enigo doesn't cover: `IAudioEndpointVolume` (absolute setvol), `EnumWindows`, `ShellExecuteW`, `LockWorkStation` |
| eframe / egui | 0.35 | Settings window | Lightest-weight Rust GUI that ships in one binary; pairs with tray-icon on the same winit loop. Alternatives (Tauri = webview overhead; native Win32 dialogs = misery) don't fit a ~5MB single-exe goal |

**`windows` crate feature flags to enable** (features mirror module paths — verified against microsoft.github.io/windows-docs-rs):

```toml
windows = { version = "0.62", features = [
  "Win32_Foundation",
  "Win32_System_Com",                 # CoCreateInstance for MMDeviceEnumerator
  "Win32_Media_Audio",                # IMMDeviceEnumerator, eRender/eConsole
  "Win32_Media_Audio_Endpoints",      # IAudioEndpointVolume (SetMasterVolumeLevelScalar)
  "Win32_UI_WindowsAndMessaging",     # EnumWindows, GetWindowTextW, SetForegroundWindow, WM_CLOSE
  "Win32_UI_Shell",                   # ShellExecuteW (app launch)
  "Win32_System_Shutdown",            # LockWorkStation
] }
```

### Supporting Libraries — Rust server

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| serde + serde_json | 1.0.228 / 1.0.150 | JSON protocol codecs | All JSON frames; derive on protocol structs in `server-core` |
| toml | 1.1 | Config file | `%APPDATA%/RemoteControl/config.toml` per spec; pairs with serde |
| dirs | 6.0 | Locate `%APPDATA%` | Config/log path resolution, cross-platform for future ports |
| tracing + tracing-subscriber | 0.1.44 / 0.3.23 | Structured logging with level filter | Spec requires file logging with level filter; `EnvFilter` gives it |
| tracing-appender | 0.2.5 | Rolling file logs | Non-blocking file writer; daily rotation |
| auto-launch | 0.6 | Autostart toggle | Writes HKCU `...\CurrentVersion\Run` exactly as spec says, cross-platform API for future Linux/macOS servers |
| winreg | 0.56 | Registry reads | Read `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` for the beacon's machine GUID; fallback if auto-launch is dropped |
| sha2 | 0.11 | Token hashing | SHA-256 of auth tokens (spec-locked). 0.11 is the current RustCrypto major |
| rand | 0.10 | 32-byte token + 6-digit PIN generation | Note 0.9+ API: `rand::rng()` replaced `thread_rng()` — 2024-era snippets won't compile |
| thiserror / anyhow | 2.0 / 1.0 | Error types | thiserror in `server-core` (typed errors), anyhow in the binary |
| winit | 0.30 | Event loop for tray + settings window | eframe 0.35 runs on winit 0.30; tray-icon must be created on this loop's thread (see Pitfalls handoff below) |

### Core Technologies — Flutter app (`app/`)

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Flutter SDK | 3.44 stable | Client framework | Current stable (2026); locked by spec |
| flutter_riverpod | 3.3.2 | State management | Spec says Riverpod; v3 is the current major (unified `Notifier`, no more `AutoDispose`/`Family` variants). Start on v3 — greenfield means zero migration cost, and v2 tutorials/snippets are now the legacy path |
| web_socket_channel | 3.0.3 | WebSocket client | Dart-team-owned, wraps the modern `package:web_socket`; `Stream`/`Sink` interface fits a `ConnectionService` with reconnect logic. Handles binary (`List<int>`) and text frames on one channel — matches the protocol |
| dart:io `RawDatagramSocket` | built-in | UDP beacon listener | Bind `0.0.0.0:<beacon port>`, listen for broadcast datagrams. **No package needed** — the SDK primitive is sufficient and avoids a stale dependency (see What NOT to Use) |
| flutter_secure_storage | 10.3.1 | Auth token storage | The standard secure-storage plugin; v10 rewrote Android crypto (Jetpack Security deprecated). Caveats below |

### Supporting Libraries — Flutter app

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| wakelock_plus | 1.6.1 | Keep screen awake | Trackpad + presenter screens per spec (the original `wakelock` is dead; `_plus` is the maintained fork) |
| `HapticFeedback` (dart flutter/services) | built-in | Haptic tick on clicks/keys | Sufficient for "tick" feedback; only add the `vibration` package if custom waveforms are wanted later |
| shared_preferences | latest | Non-secret settings | Sensitivity, scroll direction, accent, haptics toggle — don't put non-secrets in secure storage (slower, riskier) |
| freezed + json_serializable | 3.2.5 / 6.14.0 | Codegen for protocol models | **Optional.** The protocol is small (~15 message types) and contract-tested against shared fixtures; hand-written codecs keep the fixture mapping explicit. Adopt codegen only if model count grows |
| go_router | 17.3.0 | Routing | **Optional.** ~11 screens with simple push/pop; plain `Navigator` is fine. Add go_router only if deep-linking ever matters (it won't for v1) |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| cargo workspace | `server-core` + `server-windows` split | `[workspace]` root in `server/`; core has zero Windows deps so it compiles on CI Linux |
| cargo-nextest (optional) | Faster Rust test runs | Nice-to-have for the integration suite |
| flutter_lints | Dart lint baseline | Default with Flutter 3.44 templates |
| build_runner | Dart codegen | Only if freezed/json_serializable adopted |

## Installation

```toml
# server/server-core/Cargo.toml
[dependencies]
tokio = { version = "1.52", features = ["rt-multi-thread", "net", "sync", "time", "macros"] }
tokio-tungstenite = "0.29"
serde = { version = "1", features = ["derive"] }
serde_json = "1"
toml = "1.1"
sha2 = "0.11"
rand = "0.10"
tracing = "0.1"
thiserror = "2"

# server/server-windows/Cargo.toml
[dependencies]
server-core = { path = "../server-core" }
enigo = "0.6"
tray-icon = "0.24"
arboard = "3.6"
eframe = "0.35"
windows = { version = "0.62", features = ["Win32_Foundation", "Win32_System_Com", "Win32_Media_Audio", "Win32_Media_Audio_Endpoints", "Win32_UI_WindowsAndMessaging", "Win32_UI_Shell", "Win32_System_Shutdown"] }
auto-launch = "0.6"
winreg = "0.56"
dirs = "6"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
tracing-appender = "0.2"
anyhow = "1"
```

```yaml
# app/pubspec.yaml
dependencies:
  flutter_riverpod: ^3.3.2
  web_socket_channel: ^3.0.3
  flutter_secure_storage: ^10.3.1
  wakelock_plus: ^1.6.1
  shared_preferences: ^2.5.0
```

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| enigo 0.6 | Raw `SendInput` via `windows` crate | If enigo's Windows behavior blocks a feature (e.g., injecting into elevated windows needs the server itself elevated regardless — not enigo's fault). Direct SendInput loses the cross-platform trait story, so only drop to it per-call, behind the `MouseKeys` trait |
| eframe/egui settings window | Native Win32 window / Tauri webview | Tauri if the settings UI grows rich (it won't); egui's immediate-mode look is fine for a device list + toggles |
| auto-launch | winreg direct `Run`-key write | If auto-launch's abstraction fights the spec's exact registry behavior; winreg is already a dependency |
| web_socket_channel | `dart:io WebSocket` directly | Zero-dep option; loses the platform-abstracted channel interface that keeps the door open for desktop/web clients |
| dart:io RawDatagramSocket | `bonsoir` 7.1.4 (mDNS/Bonjour) | Only if UDP broadcast proves unreliable on the owner's router AND the spec's discovery section is re-opened; mDNS is a bigger dependency and a protocol change |
| Hand-written Dart codecs | freezed + json_serializable | If protocol message count doubles; codegen output is harder to line up against `protocol/fixtures/` byte-for-byte |
| flutter_riverpod 3.x | Riverpod 2.6.x | Never for greenfield in 2026; v2 is maintenance-mode |

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `udp` pub package (5.0.3) | Last published March 2022 — four years stale | `dart:io RawDatagramSocket` (built-in) |
| `wakelock` (original) | Discontinued | `wakelock_plus` |
| `StateNotifier` / `flutter_riverpod` 2.x patterns | Legacy in Riverpod 3; `FamilyNotifier`/`AutoDisposeNotifier` removed | Riverpod 3 unified `Notifier` with constructor args |
| `flutter_secure_storage` `encryptedSharedPreferences: true` | Deprecated in v10 (Jetpack Security is dead); using it invites a migration later | v10 default cipher (RSA_ECB_OAEP + SHA-256) |
| `rdev` for input injection | Simulation support is weaker/less maintained than enigo; no benefit here | enigo |
| `trayicon` (Ciantic) crate | Less active than tauri-apps' tray-icon; Windows-only | tray-icon 0.24 |
| GetAsyncKeyState/`keybd_event` era APIs | Superseded; enigo already uses SendInput | enigo / SendInput |
| `sha2` 0.10.x pins | 0.11 is current major (digest 0.11); starting on 0.10 buys a migration | sha2 0.11 |
| Storing app settings in flutter_secure_storage | Keystore ops are slow and can throw after OS updates; only the token is secret | shared_preferences for non-secrets |

## Known Issues & Caveats (feed to PITFALLS/phase research)

1. **enigo on Windows — MEDIUM confidence, verify in smoke tests:**
   - `Enigo` is not `Sync`; create it on a dedicated input thread and feed it via an mpsc channel from the tokio dispatcher. This also keeps injection off the async runtime.
   - Injection into **elevated (admin) windows fails silently** unless the server runs elevated — Windows UIPI, not an enigo bug. Document it; don't chase it.
   - Held keys don't auto-repeat (enigo-rs/enigo#98) — irrelevant for `tap` semantics, relevant if long-press-repeat is ever added.
   - `text()` uses `KEYEVENTF_UNICODE`: layout-independent (good for phone IME text), but a few apps/games that read scancodes ignore it. The `key` message path (VK codes) covers those.
   - Crate release (0.6.1, Aug 2025) lags the active repo (pushed 2026-07-01) — a 0.7 with breaking API changes may land mid-project; pin `=0.6.1` if worried.
2. **tray-icon threading — HIGH confidence (documented):** on Windows the tray icon must be created on a thread running a win32 event loop, *after* the loop has started (e.g., winit `StartCause::Init`). With eframe, create the tray inside the app's first frame/setup and forward `TrayIconEvent`/`MenuEvent` into the loop via proxy. Design the server so tokio runs on background threads and the main thread owns the winit loop + tray + settings window.
3. **flutter_secure_storage v10 — HIGH confidence (changelog):** minSdk 23+ required; `resetOnError` now effectively true (keystore errors are unrecoverable); after Android backup/restore or some OS updates the token can silently vanish. The spec's `authFail → clear token → re-pair` flow already absorbs this — just make sure a *null read* takes the same path as `authFail`.
4. **UDP broadcast on Android:** some devices need a `WifiManager.MulticastLock` for multicast, but plain 255.255.255.255 broadcast *reception* on a bound socket generally works without it; test early on the owner's device. Also request `ACCESS_NETWORK_STATE`/`INTERNET`; Android 13+ needs no location permission for pure broadcast listening (only for WiFi scans).
5. **Riverpod 3 learning surface:** most blog content still targets v2; use riverpod.dev v3 docs (`/docs/whats_new`, `/docs/3.0_migration`) as the reference, not tutorials.
6. **Windows firewall:** first `bind` on a new port triggers the firewall prompt only for interactive apps; a tray exe launched at login may be silently blocked — spec's startup self-test + settings hint is the right mitigation. Consider `netsh advfirewall` hint text in settings.

## Stack Patterns by Variant

**If cursor jitter appears over real WiFi (spec's revisit trigger):**
- Add a UDP channel for the 9-byte mouse frames behind the existing transport trait; keep tokio's `UdpSocket`.
- Because tokio already owns the UDP beacon socket, the plumbing cost is small.

**If the settings window grows beyond device-list + toggles:**
- Reconsider Tauri 2.x (tray-icon and muda are its own subcrates, so migration is incremental).
- Because egui is fastest to ship but least "native-feeling."

**If Linux server milestone starts:**
- enigo (libei/x11), arboard, tray-icon, auto-launch all already support Linux — `server-core` traits stay untouched; only the `windows`-crate executors need Linux twins.

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| tokio-tungstenite 0.29 | tokio 1.x, tungstenite 0.29 | Don't add a separate `tungstenite` pin; use the re-export |
| eframe 0.35 | winit 0.30 | tray-icon 0.24 lists winit 0.30 + tao 0.34 as tested dev-deps — the trio aligns |
| tray-icon 0.24 | muda (re-exported) | Use the re-export for menus; a separate muda pin risks version skew |
| sha2 0.11 | digest 0.11 ecosystem | If any other RustCrypto crate is added later, keep majors aligned |
| rand 0.10 | — | `thread_rng()` → `rng()`, `gen()` → `random()` renames vs pre-0.9 examples |
| flutter_riverpod 3.3.2 | riverpod_annotation/generator 3.x | Only if codegen adopted; keep all riverpod packages on the same minor |
| flutter_secure_storage 10.x | Android minSdk 23 | Set `minSdkVersion 23`+ in `app/android` (Flutter 3.44 default is already ≥23) |

## Sources

- crates.io registry API (2026-07-07) — versions for all 25 Rust crates listed — HIGH
- pub.dev registry API (2026-07-07) — versions for all Flutter packages listed — HIGH
- [tray-icon docs.rs](https://docs.rs/tray-icon/latest/tray_icon/) — Windows event-loop requirement, StartCause::Init timing, muda re-export — HIGH
- [enigo GitHub](https://github.com/enigo-rs/enigo) (repo pushed 2026-07-01) + [issue #98](https://github.com/enigo-rs/enigo/issues/98) — maintenance status, held-key repeat, Unicode text behavior — HIGH
- [windows-docs-rs: IAudioEndpointVolume](https://microsoft.github.io/windows-docs-rs/doc/windows/Win32/Media/Audio/Endpoints/struct.IAudioEndpointVolume.html) — module path / feature mapping — HIGH
- [Riverpod: What's new in 3.0](https://riverpod.dev/docs/whats_new) + [3.0 migration](https://riverpod.dev/docs/3.0_migration) — v3 API changes — HIGH
- [flutter_secure_storage changelog](https://pub.dev/packages/flutter_secure_storage/changelog) + [issue #853](https://github.com/juliansteenbakker/flutter_secure_storage/issues/853) — v10 rewrite, minSdk 23, backup/restore caveat — HIGH
- [Flutter release notes](https://docs.flutter.dev/release/release-notes) — 3.44 current stable — MEDIUM (secondary confirmation via flutter docs site)
- UDP broadcast/multicast-lock behavior on Android — training-data knowledge, flagged for early device test — LOW

---
*Stack research for: Flutter Android remote-input client + Rust Windows injection server*
*Researched: 2026-07-07*
