# Remote Control — Design Spec

**Date:** 2026-07-07
**Status:** Approved for planning

## 1. Purpose

An Android app that turns a phone into a wireless mouse, keyboard, and control center for a Windows laptop, plus the Windows companion server it talks to. Replaces the Remote Mouse app: every feature free, modern UI.

Long-term goal: expand to iOS (client) and Linux/macOS (server). The design is protocol-first so new platforms only need to implement the wire protocol.

## 2. Scope

### In scope (v1)

- Trackpad: cursor movement, left/middle/right click, tap-to-click, two-finger scroll, drag
- Keyboard: free text typing, F1–F12, numpad, arrows/nav cluster, sticky modifiers (Ctrl/Alt/Shift/Win) for combos
- Media controls: play/pause, next/prev, volume slider, mute
- Power controls: lock, sleep, restart, shutdown — each behind slide-to-confirm
- App launcher/switcher: list running windows (focus/close), pinned favorites (launch)
- Cross-device clipboard: manual send/fetch both directions, optional auto-sync, last-5 history
- Presentation remote: next/prev, start/end show, blank screen, elapsed timer
- Browser controls: back/forward, new/close tab, refresh, zoom (key-macro based)
- Auto-discovery of PCs on LAN, one-time PIN pairing, remembered devices with silent reconnect
- Windows server: tray app, auto-start with Windows, settings window

### Out of scope (v1)

- Bluetooth or USB transport (WiFi LAN only)
- iOS app, Linux/macOS servers (architecture supports them; not built now)
- Installer/MSI (v1 ships a bare exe), gyro/air mouse, file transfer, widgets

## 3. Architecture

```
┌─────────────── Android (Flutter) ───────────────┐
│ UI screens → Controller layer → Protocol client │
└────────────────────┬────────────────────────────┘
                     │ WebSocket (JSON + binary frames)
                     │ UDP broadcast for discovery
┌────────────────────┴──────────── Windows (Rust) ─┐
│ ws server → dispatcher → executor modules        │
│ tray icon + settings window, autostart           │
└──────────────────────────────────────────────────┘
```

Monorepo, three top-level directories:

| Directory   | Contents                                                                                                  |
| ----------- | --------------------------------------------------------------------------------------------------------- |
| `protocol/` | Versioned protocol spec (markdown + JSON schema) and shared test fixtures. Single source of truth.        |
| `server/`   | Rust workspace: `server-core` (OS-agnostic) + `server-windows` (tray binary). Future: `server-linux` etc. |
| `app/`      | Flutter app. Android first; same codebase targets iOS later.                                              |

**Stack decision:** Flutter client + Rust server. Rationale: one client codebase covers Android→iOS; Rust `enigo` covers input injection on Windows/Linux/macOS from one core; small single-binary server (~5MB, no runtime).

**Transport decision:** WebSocket only for v1. LAN RTT (~1–3ms) is sufficient for smooth cursor movement. Transport is abstracted behind an interface on both sides so a UDP channel for mouse deltas can be added later if real-world jitter appears. Rejected alternatives: UDP+TCP hybrid (roughly 2x transport code and failure modes, premature), raw TCP binary (effort without payoff).

## 4. Discovery and pairing

1. Server broadcasts a UDP beacon every 2s: device name, machine GUID, port, protocol version.
2. Phone listens, lists discovered PCs (GUID disambiguates duplicate names; IP shown).
3. First connect: server shows a 6-digit PIN in a Windows notification. Phone sends PIN.
4. Server verifies and issues a 32-byte random auth token. Phone stores it in secure storage; server stores its SHA-256 hash in config.
5. Subsequent connects: phone sends token in `auth` message immediately after WebSocket opens. Silent reconnect.

PIN rules: 60s expiry, 5 attempts, then 5-minute lockout per source IP.

## 5. Wire protocol

WebSocket carries two frame types.

**Binary frames** — hot path (mouse) only. 9 bytes: `[opcode u8][dx f32 LE][dy f32 LE]`. Opcodes: `0x01` move, `0x02` scroll. Sent at input rate (~60–120Hz), fire-and-forget.

**JSON text frames** — everything else:

```json
{ "t": "key", "seq": 41, "p": { "code": "F5", "mods": ["ctrl"], "action": "tap" } }
```

| Family                                        | Purpose                                                                                       |
| --------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `hello`, `pin`, `auth`, `authOk`, `authFail`  | Handshake, version negotiation, pairing, token auth                                           |
| `click`, `drag`                               | Mouse buttons (reliable → JSON, not binary)                                                   |
| `key`, `text`                                 | `key` is a single key with modifiers; `text` carries text incrementally as typed — characters or whole words as the phone IME commits them (autocomplete-friendly) |
| `media`                                       | playpause, next, prev, volup, voldown, mute, setvol (absolute 0–100 for the volume slider)    |
| `power`                                       | shutdown, restart, sleep, lock — server requires a follow-up `confirm` before executing       |
| `apps.list`, `apps.launch`, `apps.focus`, `apps.close` | Window/launcher control; server pushes `apps.changed`                                |
| `clip.set`, `clip.get`                        | Clipboard both directions; server pushes `clip.changed` when auto-sync enabled                |
| `browser`                                     | back, forward, newtab, closetab, refresh, zoomin, zoomout (server sends key-combo macros)     |
| `present`                                     | next, prev, start, end, blank (F5/arrows/B — PowerPoint standard)                             |
| `ping`/`pong`                                 | Latency display, dead-connection detection                                                    |
| `err`                                         | Server → client failure report with human-readable message                                    |

Versioning: `hello` carries `protoVersion`; server rejects mismatched major version and the rejection includes both versions. Every message is documented with a JSON schema in `protocol/`; both sides are written against that spec and validated by shared fixtures.

Auth gating: everything before `authOk` is ignored except the handshake family.

## 6. Windows server (Rust)

Workspace with two crates.

**`server-core`** (OS-agnostic):

- `transport` — tokio + tungstenite WebSocket listener; UDP beacon broadcaster; session/auth manager (hashed tokens in config)
- `dispatch` — frame parsing and routing; drops pre-auth traffic; drops input messages when paused
- Executor traits: `MouseKeys`, `Media`, `Power`, `Apps`, `Clipboard`. Core depends only on traits.

**`server-windows`** (binary):

- `MouseKeys`/`Media` via `enigo` (SendInput, media virtual keys); absolute volume (`setvol`) via Core Audio `IAudioEndpointVolume`
- `Power` via `shutdown.exe` arguments and `LockWorkStation`
- `Apps` via Win32 `EnumWindows` (list/focus/close) and `ShellExecute` (launch)
- `Clipboard` via `arboard` + change polling
- Tray via `tray-icon`: status tooltip (connected device count), menu — settings, pause input, quit
- Settings window: device name, port, paired-device list with revoke, autostart toggle (registry `Run` key), clipboard auto-sync toggle
- Config at `%APPDATA%/RemoteControl/config.toml`; file logging with level filter

Security posture:

- Binds LAN interface only; no UPnP, no port forwarding, never internet-exposed
- Tokens stored hashed (SHA-256); plaintext lives only on the phone in secure storage
- Power actions require a second `confirm` message (pairs with slide-to-confirm UI)
- "Pause input" in tray drops input messages while keeping the connection alive
- Startup self-test warns in tray if the port is blocked (firewall hint in settings)

## 7. Android app (Flutter)

**Screens:**

| Screen            | Content                                                                                                         |
| ----------------- | ---------------------------------------------------------------------------------------------------------------- |
| Discovery/connect | Beacon list; PIN dialog on first pair; skipped when a remembered device is reachable                             |
| Dashboard (home)  | Device name + status/latency header; 2×4 tile grid: Trackpad, Keyboard, Media, Apps, Clipboard, Power, Presenter, Browser |
| Trackpad          | Full-screen touch area: 1-finger move, tap = left click, 2-finger tap = right click, 2-finger drag = scroll, long-press drag = drag; L/M/R buttons |
| Keyboard          | System keyboard for text (send-as-you-type); toggleable rows: F1–F12, numpad, arrows/nav (Home/End/PgUp/PgDn/Del/Esc/Tab); sticky modifier chips |
| Media             | Large play/pause/next/prev, volume slider, mute — usable without looking                                          |
| Apps              | Running windows (focus/close), pinned favorites grid (launch); server-push refresh                                |
| Clipboard         | Send/fetch buttons, auto-sync toggle, last-5 history                                                              |
| Power             | Lock, sleep, restart, shutdown; each behind slide-to-confirm; red-zone styling                                    |
| Presenter         | Giant next/prev zones, start/end, blank, elapsed timer                                                            |
| Browser           | Back/forward, new/close tab, refresh, zoom                                                                        |
| Settings          | Paired PCs, trackpad sensitivity, scroll direction, accent color, haptics toggle                                  |

A persistent bottom quick-bar with a trackpad shortcut is visible on every screen (dashboard-home + quick-trackpad hybrid, per mockup selection).

**Internals:**

- Riverpod for state management
- `ConnectionService` singleton: WebSocket lifecycle, auto-reconnect with backoff, beacon listener, token store (`flutter_secure_storage`)
- Protocol layer mirrors the spec: binary encoder for mouse frames, JSON codecs for the rest
- Haptic tick on clicks/keys (toggleable); keep-awake during trackpad/presenter use

**Visual style:** dark minimal (per mockup selection) — near-black `#0E0F12` background, flat tiles, single blue accent, OLED-friendly. Latency shown in header.

## 8. Error handling and edge cases

| Case                            | Behavior                                                                                                     |
| ------------------------------- | ------------------------------------------------------------------------------------------------------------ |
| WiFi drop / laptop sleep        | Status "reconnecting"; exponential backoff 1s→2s→4s (cap 10s); beacon re-listen in parallel (handles IP change); sticky modifiers reset on disconnect |
| Server killed mid-session       | Same path; dashboard shows "PC offline", tiles disabled except Settings                                       |
| Stale/revoked token             | `authFail` → phone clears token, returns to pairing flow with explanation (no silent retry loop)              |
| PIN timeout/exhausted           | Clear error + retry; lockout message shows remaining wait                                                     |
| Two phones connected            | Allowed — both control; tray paired-device list handles revoke                                                |
| Mouse frames while disconnected | Dropped client-side, never queued (queued deltas would teleport the cursor on reconnect)                      |
| Text/clipboard during blips     | Queued up to 10 messages, then dropped with a toast                                                           |
| App launch fails / window gone  | Server replies `err` with human-readable message; phone shows toast                                           |
| Protocol version mismatch       | Rejection includes both versions; phone shows "update server/app" screen                                      |
| Firewall blocks port            | Server startup self-test warns in tray; settings shows fix hint                                               |
| Duplicate device names          | Beacon machine GUID disambiguates; list shows IP                                                              |

## 9. Testing

- **Protocol contract tests** — codec unit tests in both Rust and Dart against shared fixture files in `protocol/fixtures/`; identical bytes must decode identically on both sides. This is the cross-ecosystem contract.
- **Server unit tests** — dispatcher auth gating, PIN lockout, token hashing.
- **Server integration tests** — real server + fake WebSocket client drive pair→auth→input flows; executors replaced by mock trait impls (no real input injection in CI).
- **Flutter widget tests** — screens with mocked `ConnectionService`; Dart codec tests as above.
- **Manual smoke checklist** — real phone + PC: cursor, all key groups, media, power (lock only), clipboard, apps, presenter, browser. Input injection is not CI-testable.
- **Latency acceptance** — debug overlay shows ping RTT and frame rate; cursor response visually instant on same LAN (<30ms end-to-end).

## 10. Decisions log

| Decision            | Choice                                | Rejected alternatives                                     |
| ------------------- | ------------------------------------- | --------------------------------------------------------- |
| Connection          | WiFi LAN only                         | Bluetooth HID fallback, USB tether                        |
| Server form         | Tray app, auto-start                  | Manual-start tray, headless service                       |
| Pairing             | Auto-discover + one-time PIN          | QR scan, no-auth LAN trust                                |
| Client stack        | Flutter                               | Kotlin Multiplatform/Compose, native per-platform         |
| Server stack        | Rust (`enigo`, `tray-icon`)           | C#/.NET + Avalonia, Go + robotgo                          |
| Transport           | WebSocket only, abstracted            | UDP+TCP hybrid (revisit if jitter), raw TCP binary        |
| Home layout         | Dashboard grid + persistent trackpad quick-bar | Trackpad-home with tabs, edge-swipe full-screen pad |
| Visual style        | Dark minimal, blue accent             | Material You dynamic color, glass gradient                |
