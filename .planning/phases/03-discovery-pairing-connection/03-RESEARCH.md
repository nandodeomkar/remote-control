# Phase 3: Discovery, Pairing & Connection - Research

**Researched:** 2026-07-08
**Domain:** LAN discovery (UDP broadcast), PIN pairing UX, reconnect FSM, secure token persistence — Flutter Android client + Rust Windows server
**Confidence:** HIGH (core patterns verified against codebase, crates.io/pub.dev registries, and official docs; Android OEM broadcast behavior MEDIUM — device-dependent by nature)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

User was offered all four gray areas (connect flow on launch, drop/failure UX, multi-PC memory, spike cleanup scope) and answered "no preference" — all four delegated to Claude's discretion. Defaults locked below so downstream agents don't re-litigate.

**Connect flow on launch**
- **D-01:** App launch **auto-reconnects to the last-connected paired PC** (silent challenge-response, no user action). If there is no remembered device or the quick attempt fails, land on the **device list**.
- **D-02:** The device list is the home of this phase's UX: discovered PCs appear live from the beacon listener (name, IP; GUID disambiguates duplicate names); remembered-but-currently-undiscovered devices show grayed with last-known address. Tap a paired device → silent connect; tap an unpaired device → PIN pairing flow.
- **D-03:** Manual IP:port entry (CONN-05) survives as a **secondary affordance from the device list** ("Connect by IP"), not the primary screen. It reuses the existing connect path; a successful manual connection is remembered like a discovered one.

**Drop/failure UX**
- **D-04:** Reconnection is **non-blocking**: the app header shows connection state (connected / reconnecting / disconnected) plus live latency (CONN-06). During drops an unobtrusive "Reconnecting…" banner appears; input surfaces stay visible but gated (input disabled until Authed — the Phase-2 gating pattern). A manual "Retry now" affordance is available.
- **D-05:** **Transport failures retry; auth failures stop.** Exponential backoff applies only to socket/network failures. A definitive auth rejection (`authFail` noPairing/badMac — revoked or stale token) terminates silent retry and returns the user to pairing with a plain explanation ("This PC no longer recognizes this phone — pair again"), per roadmap criterion 3. No silent retry loop on auth failures.
- **D-06:** Backoff parameters are planner/researcher discretion (exponential with a cap around 30s). Locked triggers that reset/short-circuit backoff: app resume → instant retry; beacon sighting of the target device → immediate attempt (handles PC IP changes).

**Multi-PC memory**
- **D-07:** **Multiple paired PCs supported from the start.** Storage is a map keyed by machine GUID → {device name, auth token, last-known IP:port}. The device list doubles as the switcher. One active session at a time (no simultaneous connections). Tokens live in flutter_secure_storage; non-secret device metadata may live in shared_preferences (stack rule: secrets only in secure storage).

**Spike cleanup scope (D-09 from Phase 2)**
- **D-08:** The **latency probe survives as the engine** behind the header's live latency display (CONN-06). The spike's debug HUD overlay widget is removed; its interleaved-ping probe and p50/p95 logic are reused, restyled into the header status chip.
- **D-09:** The **PIN moves to its real home**: the server shows the pairing PIN via a **Windows notification** (roadmap criterion 2). Console printing stays as a dev-visible fallback, no longer the primary path. Notification mechanism (win32 toast vs tray balloon — tray-icon proper is Phase 7) is researcher/planner discretion.
- **D-10:** The **in-memory token is replaced** by flutter_secure_storage persistence (spec-locked). Android **app-wide `usesCleartextTraffic` is replaced by a scoped network-security-config** permitting cleartext ws:// to LAN/private ranges only (carried Phase-3 item from 02-03).

### Claude's Discretion
- All decisions above are Claude-discretion defaults (user had no preference). Planner may refine details (exact screen composition, backoff constants, notification API, storage schema) as long as the observable contract holds: auto-reconnect to last PC with device-list fallback, live beacon-driven device list with manual-IP fallback, transport-retry/auth-stop policy with the revoked-token explanation, multi-PC GUID-keyed memory, latency probe reused for the header, PIN via Windows notification, secure-storage token, scoped cleartext config.

### Deferred Ideas (OUT OF SCOPE)
- Server tray icon, settings window, paired-device revoke UI — Phase 7 (this phase only adds the PIN notification + beacon broadcaster to `server-windows`).
- Trackpad sensitivity/acceleration and gesture set — Phase 4.
- TLS / channel binding for MITM defense — explicitly out of v1 threat model (protocol SPEC residual-risk note).
- "Absolute pointer injection so slow drags survive Windows pointer acceleration" — kept pending for Phase 4 (Trackpad & Keyboard).
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| CONN-01 | Laptops on the same LAN appear automatically in a device list (UDP beacon discovery) | Beacon broadcaster pattern (per-interface subnet-directed broadcast via `if-addrs` + tokio `UdpSocket`), beacon JSON wire format, Dart `RawDatagramSocket` listener, MulticastLock MethodChannel, device-list eviction rule |
| CONN-02 | One-time pairing via 6-digit PIN shown on the PC (60s expiry, 5 attempts, lockout) | Server auth stack already complete (Phase 1); this phase adds the Windows toast via `tauri-winrt-notification` (POWERSHELL_APP_ID for unpackaged exe) + console fallback; client PIN dialog maps `authFail` reasons to error copy |
| CONN-03 | Paired phone reconnects silently via challenge-response — token never crosses the wire | Existing `HandshakeFsm` reconnect branch reused verbatim; token persisted per-GUID in flutter_secure_storage 10.3.1; keystore-failure → pairing fallback pattern |
| CONN-04 | Connection recovers automatically after WiFi drops or PC IP changes (backoff + beacon re-listen) | Reconnect FSM design (pure FSM + driver, states/inputs/policy table below); backoff 1→2→4→8→10s cap + jitter; `AppLifecycleListener` resume trigger; beacon-sighting short-circuit updating last-known IP |
| CONN-05 | Manual IP:port entry when discovery fails | Shared connect routine for discovered + manual paths; private-range guard; "PC found but connection blocked — check Windows Firewall" error copy for beacon-seen-but-connect-fails |
| CONN-06 | Connection status and live latency in the app header | `LatencyProbe` reused; idle-ping timer extension (~2s cadence when authed & no move traffic); missed-pong dead-connection detection feeding the FSM; throttled header chip (no hot-path rebuilds) |
</phase_requirements>

## Summary

This phase is mostly **client-side composition around already-proven parts**. The handshake FSM, challenge-response crypto, PIN lifecycle, and TCP_NODELAY connect path all exist and are gate-proven; Phase 3 wraps them in a connection-lifecycle FSM (reconnect/backoff), adds a UDP beacon listener + device list, persists tokens per-GUID, and swaps two pieces of spike scaffolding (in-memory token, app-wide cleartext). Server-side work is deliberately small: a beacon broadcaster task (in `server-core` transport, identity injected from `server-windows`) and a PIN toast notification.

Three research findings materially shape the plan. **(1) Windows broadcasts `255.255.255.255` out one interface only** — the beacon must be sent per-interface to each subnet-directed broadcast address (`if-addrs` 0.15 provides ip/netmask/broadcast per interface), re-enumerating periodically because VPN/WSL/Hyper-V adapters come and go. **(2) Android network-security-config cannot express IP ranges or CIDR** — D-10's "cleartext for LAN ranges only" is not literally expressible in XML; the honest implementation is `base-config cleartextTrafficPermitted="true"` in a `network_security_config.xml` (replacing the manifest attribute) **plus a code-level private-range guard** in ConnectionService that refuses ws:// dials to non-RFC1918 addresses. **(3) Toast notifications from an unpackaged exe need an AUMID** — `tauri-winrt-notification` 0.8.0's `Toast::POWERSHELL_APP_ID` sidesteps registration at the cost of the toast being attributed to "Windows PowerShell"; acceptable for v1 (proper AUMID registration naturally lands in Phase 7 with the tray), and the console PIN print stays as fallback because Focus Assist can suppress toasts entirely.

The main risk is the carried STATE concern: **Android UDP broadcast reception varies by device**, and the owner's Xiaomi/HyperOS device is in the aggressive-OEM cohort. Mitigations are all cheap: acquire a `MulticastLock` (hand-written ~15-line MethodChannel — both pub.dev packages are stale or unproven) while the device list is visible, keep the app foreground-only, and treat manual IP entry as a first-class fallback. An early on-device beacon smoke test should be the first verification step of the discovery plan, not the last.

**Primary recommendation:** Build ConnectionService as a pure IO-free reconnect FSM + thin driver (the established Phase-2 pattern), wrapping — not rewriting — `HandshakeFsm`/`HandshakeDriver`/`connectNoDelay`; ship the beacon as a versioned JSON datagram documented in `protocol/BEACON.md` with shared fixtures.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Beacon broadcast (2s interval, per-interface) | Rust server (`server-core` transport) | `server-windows` (supplies name + GUID identity) | Spec §6 places the UDP beacon broadcaster in server-core transport; winreg/COMPUTERNAME are Windows-only so identity is injected — keeps core compiling on Linux CI |
| Machine GUID read | `server-windows` | — | `HKLM\...\Cryptography\MachineGuid` via winreg is Windows-specific |
| PIN display (toast + console) | `server-windows` (composition root) | — | main.rs already owns `begin_pairing()` + re-pair loop; notification is a display concern, zero server-core auth changes (CONTEXT lock) |
| Beacon listening + device list state | Flutter client (net layer + Riverpod) | — | `dart:io RawDatagramSocket`; device list is client UX state |
| MulticastLock acquire/release | Android platform (Kotlin MethodChannel) | Flutter (lifecycle calls) | WifiManager API has no Dart binding worth depending on |
| Reconnect FSM + send policy | Flutter client (pure Dart, IO-free) | driver does IO | Established Phase-2 pattern: transitions unit-tested without sockets |
| Token persistence | Flutter client (flutter_secure_storage) | — | Spec-locked: raw token lives only on the phone in secure storage |
| Device metadata (name, last IP, last-connected) | Flutter client (shared_preferences) | — | Non-secret; stack rule forbids non-secrets in secure storage |
| Auth verification, PIN lockout, challenge nonces | `server-core` auth (existing, unchanged) | — | Fully built + tested in Phase 1; Phase 3 adds NO server auth logic |
| Latency measurement + status header | Flutter client (probe engine + throttled chip) | — | D-08: probe survives, HUD widget dies |
| Cleartext policy | Android manifest/XML + client code guard | — | XML cannot scope to IP ranges; code guard enforces private-range-only |

## Standard Stack

### Core (new this phase)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| `if-addrs` | 0.15.0 | Enumerate up IPv4 interfaces with netmask/broadcast for per-interface directed beacon broadcast | Lightest maintained option (340k dl/wk, messense) [VERIFIED: crates.io registry] |
| `tauri-winrt-notification` | 0.8.0 | Windows toast for the pairing PIN from the unpackaged exe | tauri-apps-maintained WinRT toast wrapper; `POWERSHELL_APP_ID` works without AUMID registration (146k dl/wk) [VERIFIED: crates.io registry + docs.rs] |
| `winreg` | 0.56.0 | Read `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` | Already in project stack doc; 2.6M dl/wk [VERIFIED: crates.io registry] |
| `flutter_secure_storage` | 10.3.1 | Per-GUID auth token persistence | Stack-locked; v10 default cipher (RSA_ECB_OAEP+SHA-256), minSdk 23 [VERIFIED: pub.dev registry] |
| `shared_preferences` | 2.5.5 | Non-secret device metadata map + last-connected pointer | Stack-locked for non-secrets [VERIFIED: pub.dev registry] |

### Supporting (already present — reuse, do not re-add)

| Asset | Where | Use in Phase 3 |
|-------|-------|----------------|
| `tokio` UdpSocket (`net` feature) | server-core deps | Beacon send socket (`bind 0.0.0.0:0`, `set_broadcast(true)`) — feature already enabled |
| `serde`/`serde_json` | server-core deps | Beacon payload encoding |
| `HandshakeFsm`/`HandshakeDriver` | `app/.../lib/net/` | Composed by ConnectionService — reconnect FSM wraps connection lifecycle, never duplicates handshake states |
| `connectNoDelay` | `app/.../lib/net/connection_service.dart` | Every connection goes through it verbatim (gate-proven TCP_NODELAY) |
| `LatencyProbe` | `app/.../lib/hud/latency_probe.dart` | Header latency engine (D-08); add idle-ping cadence |
| `authProof`/codecs | `remote_protocol` package | Never re-implement; fixture-anchored |
| `AuthManager` (`begin_pairing`, `is_paired`, re-pair loop) | `server-core/src/auth/` + `server-windows/main.rs` | Unchanged; PIN display path swaps println→toast+println |
| `dart:io RawDatagramSocket` | Dart SDK built-in | Beacon listener — **no package** (stack doc forbids the stale `udp` package) |
| `AppLifecycleListener` / `WidgetsBindingObserver` | Flutter built-in | Resume → instant retry trigger (D-06) |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| `if-addrs` | `netdev` 0.45 / `network-interface` 2.0.5 | Heavier (gateway detection etc.) — unneeded; `if-addrs` returns ip+netmask+broadcast which is exactly the requirement |
| `if-addrs` | raw `GetAdaptersAddresses` via windows crate | Loses the cross-platform story for future Linux server; fiddly buffer API |
| `tauri-winrt-notification` | `notify-rust` 4.18 | notify-rust wraps the same WinRT path on Windows with a cross-platform API we don't need; direct dependency is smaller |
| `tauri-winrt-notification` | Shell_NotifyIcon balloon | Requires a tray icon — tray is Phase 7 |
| Hand-written MulticastLock MethodChannel | `flutter_multicast_lock` 1.2.1 / `multicast_lock` 0.0.5 | `multicast_lock` is dead (2018); `flutter_multicast_lock` is low-adoption [SUS-adjacent — see audit]. The platform API is ~15 lines of Kotlin; a dependency buys nothing |
| `COMPUTERNAME` env var for device name | `gethostname` crate | Env var is zero-dep and correct on Windows; crate only needed for future Linux port |
| JSON beacon datagram | Compact binary beacon | JSON is ~130 bytes (far under MTU), debuggable with any packet sniffer, and matches the project's JSON-everywhere-except-hot-path philosophy |

**Installation:**

```toml
# server/server-core/Cargo.toml — no new deps (tokio net + serde_json already present)

# server/server-windows/Cargo.toml — add:
if-addrs = "0.15"
tauri-winrt-notification = "0.8"
winreg = "0.56"
serde_json = "1"   # beacon identity plumbing if encoded windows-side; omit if core owns encoding
```

```yaml
# app/remote_control/pubspec.yaml — add:
flutter_secure_storage: ^10.3.1
shared_preferences: ^2.5.5
```

**Version verification (performed 2026-07-08):** all five packages confirmed current via crates.io / pub.dev registry APIs. Note: if the beacon broadcaster lives in `server-core` (recommended), `if-addrs` goes in **server-core** — it is cross-platform (that is its point) and keeps the Linux-CI zero-Windows-deps invariant intact.

## Package Legitimacy Audit

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| tauri-winrt-notification | crates.io | since 2022 | 146,320/wk | github.com/tauri-apps/winrt-notification | OK | Approved |
| if-addrs | crates.io | since 2020 | 340,850/wk | github.com/messense/if-addrs | OK | Approved |
| winreg | crates.io | since 2015 | 2,593,700/wk | github.com/gentoo90/winreg-rs | OK | Approved |
| flutter_secure_storage | pub.dev | mature, v10.3.1 | Flutter Favorite, extremely high adoption | github.com/juliansteenbakker/flutter_secure_storage | OK (manual — seam lacks pub.dev ecosystem) | Approved |
| shared_preferences | pub.dev | flutter.dev first-party | ubiquitous | github.com/flutter/packages | OK (manual) | Approved |
| flutter_multicast_lock | pub.dev | 1.2.1 (2026-06) | low adoption, not evaluated for provenance | unverified | SUS | **Not used** — hand-written MethodChannel instead |
| multicast_lock | pub.dev | 0.0.5 (2018) | dead | — | SLOP-adjacent (abandoned) | REMOVED from consideration |

**Packages removed due to [SLOP] verdict:** none installed; `multicast_lock` rejected pre-emptively (abandoned 2018).
**Packages flagged as suspicious [SUS]:** `flutter_multicast_lock` — avoided entirely by writing the MethodChannel by hand, so no checkpoint needed.

*The three crates were verified via the `gsd-tools query package-legitimacy check --ecosystem crates` seam (all OK). The two pub.dev packages were verified manually against pub.dev (first-party/Flutter-Favorite status) because the seam does not support the pub ecosystem.*

## Architecture Patterns

### System Architecture Diagram

```
WINDOWS SERVER                                ANDROID CLIENT
┌──────────────────────────────┐              ┌─────────────────────────────────────────┐
│ server-windows main.rs       │              │ BeaconListener (RawDatagramSocket       │
│  ├─ BeaconIdentity           │   UDP :17778 │   0.0.0.0:17778, MulticastLock held      │
│  │   name = %COMPUTERNAME%   │  broadcast   │   while device list visible)             │
│  │   guid = winreg MachineGuid│  every 2s   │        │ validated BeaconMsg              │
│  ├─ notify_pin(pin):         │ ────────────▶│        ▼                                 │
│  │   toast + console fallback│  (per-iface  │ DeviceListStore (Riverpod Notifier)      │
│  └─ server_core::run(...)    │   directed   │   guid → {name, ip, port, lastSeen,      │
│                              │   broadcast) │           paired?}  ← DeviceStore merge  │
│ server-core                  │              │        │ tap / auto-reconnect / beacon-   │
│  ├─ transport::beacon (NEW)  │              │        ▼   sighting short-circuit        │
│  │   tokio interval 2s       │              │ ConnectionService                        │
│  │   if-addrs enumerate      │              │  ├─ ReconnectFsm (PURE, IO-free)         │
│  │   send JSON to each       │              │  │   idle→connecting→handshaking→authed  │
│  │   subnet bcast addr       │              │  │   ↘ backoff(1..10s) ↘ authRejected    │
│  ├─ transport::listener      │   ws://      │  ├─ Driver: connectNoDelay →             │
│  │   (existing, unchanged)   │◀────────────▶│  │   HandshakeDriver (existing)          │
│  └─ auth (existing,unchanged)│  :17777      │  │   single stream listener routes:       │
│                              │              │  │   handshake→driver, pong→probe         │
└──────────────────────────────┘              │  ├─ SendPolicy: volatile drop-if-!authed │
                                              │  │   reliable queue≤10                    │
                                              │  └─ LatencyProbe + idle-ping timer        │
                                              │        │ status + p50 latency (throttled) │
                                              │        ▼                                  │
                                              │ Header status chip / Reconnecting banner │
                                              │ DeviceListScreen · PIN dialog ·          │
                                              │ Connect-by-IP sheet · Trackpad(consumer) │
                                              │                                          │
                                              │ DeviceStore:                              │
                                              │  flutter_secure_storage: token.<guid>     │
                                              │  shared_preferences: devices JSON map,    │
                                              │    lastDeviceGuid                         │
                                              └─────────────────────────────────────────┘
```

Primary use case trace (silent reconnect after IP change): beacon arrives on :17778 → validated → DeviceListStore updates guid's ip:port → ConnectionService sees target-guid sighting → FSM short-circuits backoff → driver dials new ip via connectNoDelay → HandshakeDriver auth path (token from secure storage) → authed → header chip green, latency resumes.

### Recommended Project Structure

```
app/remote_control/lib/
├── net/
│   ├── connection_service.dart   # grows: reconnect driver + send policy (keeps connectNoDelay)
│   ├── reconnect_fsm.dart        # NEW pure FSM (states/inputs/policy — no IO, no Flutter)
│   ├── handshake_fsm.dart        # unchanged
│   ├── handshake.dart            # unchanged
│   ├── beacon_listener.dart      # NEW RawDatagramSocket wrapper → Stream<Beacon>
│   └── beacon.dart               # NEW beacon decode + validation (fixture-tested)
├── store/
│   ├── device_store.dart         # NEW secure-storage tokens + prefs metadata (GUID-keyed)
├── screens/
│   ├── device_list_screen.dart   # NEW home: live list + grayed remembered + Connect-by-IP
│   ├── pairing_dialog.dart       # NEW PIN entry with authFail-reason error copy
├── widgets/
│   └── connection_header.dart    # NEW status chip + latency (replaces debug HUD)
├── hud/latency_probe.dart        # engine survives; latency_hud.dart DELETED
└── trackpad/trackpad_screen.dart # slimmed: consumes ConnectionService, loses connect UI

server/server-core/src/transport/
└── beacon.rs                     # NEW broadcaster task: identity in, 2s tick, per-iface send

server/server-windows/src/
├── main.rs                       # + beacon identity, spawn beacon task, notify_pin hook
└── notify.rs                     # NEW toast + console fallback
```

### Pattern 1: Per-interface subnet-directed beacon broadcast (Rust)

**What:** One `UdpSocket` bound `0.0.0.0:0` with `set_broadcast(true)`; every 2s, enumerate up non-loopback IPv4 interfaces and send the beacon JSON to each interface's directed broadcast address at the beacon port.
**When to use:** Always — a single `255.255.255.255` send exits ONE interface chosen by the Windows routing table; VPN/WSL/Hyper-V adapters silently eat it (PITFALLS.md #6) [CITED: .planning/research/PITFALLS.md].
**Example:**

```rust
// server-core/src/transport/beacon.rs  [ASSUMED field names — verify if_addrs API at implementation]
use std::net::{Ipv4Addr, SocketAddrV4};

pub struct BeaconIdentity { pub name: String, pub guid: String, pub ws_port: u16 }

pub async fn run_beacon(identity: BeaconIdentity, beacon_port: u16) {
    let sock = tokio::net::UdpSocket::bind(("0.0.0.0", 0)).await.expect("bind beacon socket");
    sock.set_broadcast(true).expect("SO_BROADCAST");
    let payload = serde_json::json!({
        "v": 1, "app": "remote-control",
        "name": identity.name, "guid": identity.guid,
        "port": identity.ws_port, "proto": "1.0",
    }).to_string();

    let mut tick = tokio::time::interval(std::time::Duration::from_secs(2));
    loop {
        tick.tick().await;
        // Re-enumerate EVERY tick group (cheap; adapters change under VPN/WSL churn).
        for iface in if_addrs::get_if_addrs().unwrap_or_default() {
            if iface.is_loopback() { continue; }
            if let if_addrs::IfAddr::V4(v4) = iface.addr {
                // if-addrs exposes the broadcast addr; fall back to ip | !netmask.
                let bcast: Ipv4Addr = v4.broadcast.unwrap_or_else(|| {
                    Ipv4Addr::from(u32::from(v4.ip) | !u32::from(v4.netmask))
                });
                let _ = sock.send_to(payload.as_bytes(), SocketAddrV4::new(bcast, beacon_port)).await;
            }
        }
    }
}
```

### Pattern 2: PIN toast from the unpackaged exe (Rust)

**What:** WinRT toast using the PowerShell AUMID (no registration needed); console print remains the guaranteed fallback.
**When to use:** D-09 — every `begin_pairing()` call (initial + WR-01 refresh loop) routes through one `notify_pin(pin)` helper.
**Example:**

```rust
// server-windows/src/notify.rs
// Source: docs.rs/tauri-winrt-notification (Toast::POWERSHELL_APP_ID documented for
// programs "not installed"; toast reports origin as PowerShell — accepted v1 quirk)
use tauri_winrt_notification::{Duration, Toast};

pub fn notify_pin(pin: &str) {
    // Console fallback FIRST — Focus Assist / notification settings can suppress toasts.
    println!("Pairing PIN: {pin}");
    let result = Toast::new(Toast::POWERSHELL_APP_ID)
        .title("Remote Control — pairing PIN")
        .text1(pin)
        .duration(Duration::Long)  // ~25s of the 60s PIN window
        .show();
    if result.is_err() {
        tracing::warn!("toast notification failed; PIN available on console");
    }
    // SECURITY: the PIN goes to stdout + toast ONLY — never through tracing (T-02-ID).
}
```

### Pattern 3: Beacon listener (Dart, no packages)

**What:** `RawDatagramSocket.bind(anyIPv4, beaconPort, reuseAddress: true)`, read datagrams, validate strictly, surface a typed stream.
**When to use:** While the device list screen is visible AND while reconnecting (beacon re-listen is a locked D-06 trigger).
**Example:**

```dart
// lib/net/beacon_listener.dart
// Source: api.dart.dev RawDatagramSocket (SDK built-in; stack doc forbids the stale `udp` pkg)
import 'dart:convert';
import 'dart:io';

const int kBeaconPort = 17778;
const int kMaxBeaconBytes = 512; // validation cap — beacon is UNTRUSTED input

Stream<Beacon> listenForBeacons() async* {
  final socket = await RawDatagramSocket.bind(
    InternetAddress.anyIPv4, kBeaconPort, reuseAddress: true);
  await for (final event in socket) {
    if (event != RawSocketEvent.read) continue;
    final dg = socket.receive();
    if (dg == null || dg.data.length > kMaxBeaconBytes) continue;
    final beacon = Beacon.tryParse(dg.data, dg.address); // strict: v==1, app match,
    if (beacon != null) yield beacon;                    // typed fields, else silent drop
  }
}
```

### Pattern 4: MulticastLock via hand-written MethodChannel (Kotlin + Dart)

**What:** ~15 lines in `MainActivity.kt` exposing `acquire`/`release` of `WifiManager.MulticastLock`; held only while the device list is visible.
**When to use:** Cheap insurance for OEM chipsets that filter broadcast frames (Broadcom-class filters block non-unicast; some OEMs filter even foreground) [CITED: developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock; community reports MEDIUM].
**Example:**

```kotlin
// android/app/src/main/kotlin/.../MainActivity.kt
class MainActivity : FlutterActivity() {
  private var lock: WifiManager.MulticastLock? = null
  override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
    super.configureFlutterEngine(flutterEngine)
    MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "remote_control/multicast")
      .setMethodCallHandler { call, result ->
        val wifi = applicationContext.getSystemService(Context.WIFI_SERVICE) as WifiManager
        when (call.method) {
          "acquire" -> {
            lock = lock ?: wifi.createMulticastLock("rc-discovery").also { it.setReferenceCounted(false) }
            lock?.acquire(); result.success(null)
          }
          "release" -> { lock?.takeIf { it.isHeld }?.release(); result.success(null) }
          else -> result.notImplemented()
        }
      }
  }
}
```

Manifest additions: `<uses-permission android:name="android.permission.CHANGE_WIFI_MULTICAST_STATE"/>` (INTERNET already present).

### Pattern 5: Scoped-as-possible cleartext config (XML + code guard)

**What:** Replace `android:usesCleartextTraffic="true"` with `android:networkSecurityConfig="@xml/network_security_config"`; because domain-config **cannot express IP ranges/CIDR** [CITED: developer.android.com/privacy-and-security/security-config — only exact domains + includeSubdomains; loopback IPs are the sole special case], the XML keeps base-config cleartext=true and the *scoping* is enforced in code: ConnectionService refuses ws:// dials to non-private addresses.
**Example:**

```xml
<!-- android/app/src/main/res/xml/network_security_config.xml -->
<?xml version="1.0" encoding="utf-8"?>
<network-security-config>
    <!-- ws:// to LAN IPs: Android XML cannot scope cleartext by IP range (no CIDR
         support). Cleartext stays permitted at base level; the app enforces
         private-range-only dialing in ConnectionService (RFC1918 + link-local). -->
    <base-config cleartextTrafficPermitted="true" />
</network-security-config>
```

```dart
// ConnectionService guard — the real "LAN ranges only" enforcement:
bool isPrivateLanAddress(InternetAddress a) {
  if (a.type != InternetAddressType.IPv4) return false;
  final b = a.rawAddress;
  return b[0] == 10 ||
      (b[0] == 172 && b[1] >= 16 && b[1] <= 31) ||
      (b[0] == 192 && b[1] == 168) ||
      (b[0] == 169 && b[1] == 254); // link-local (phone hotspot cases)
}
```

**Verification note:** Phase 2 empirically proved Dart's HttpClient consults the platform cleartext policy (ws:// failed until `usesCleartextTraffic=true` was added — STATE decision log). The XML swap must therefore be smoke-tested on-device: connect over ws:// after removing the manifest attribute. [ASSUMED: base-config XML is honored identically to the manifest attribute by Dart's check — high likelihood, but the 2-minute device test is mandatory]

### Pattern 6: Reconnect FSM (pure Dart, wraps — never duplicates — the handshake)

**What:** Connection-lifecycle FSM following the Phase-2 pure-FSM + thin-driver pattern. `HandshakeFsm` keeps owning hello/challenge/pin/auth; the reconnect FSM owns socket lifecycle and retry policy.

**States:** `idle` · `connecting(device)` · `handshaking` · `authed` · `backoff(attempt, delay)` · `needPairing(deviceOrNull, explanation?)` (device list / PIN flow surface)

**Inputs → policy table (D-05/D-06):**

| Input | From state | Next state / action |
|-------|-----------|---------------------|
| `connectRequested(device)` | any non-authed | `connecting` — driver dials via `connectNoDelay` |
| socket connect failed / stream closed / pong timeout | `connecting`/`handshaking`/`authed` | `backoff(n+1)` — delays 1s, 2s, 4s, 8s, cap **10s** (+ ±20% jitter); design spec §8 says cap 10s and D-06's "around 30s" is discretionary — take the spec's 10s |
| backoff timer fired | `backoff` | `connecting` (same device, last-known ip:port) |
| `appResumed` | `backoff`/`connecting` | reset attempt counter → immediate `connecting` |
| `beaconSighted(guid==target)` | `backoff` | update device ip:port from beacon → immediate `connecting` (handles PC IP change) |
| `retryNowPressed` | `backoff` | reset → `connecting` |
| handshake → `authed` (pairOk/authOk) | `handshaking` | `authed`; reset attempt counter; persist token if newly paired |
| handshake → `authFail` **noPairing/badMac** | `handshaking` | **terminal**: clear stored token for GUID, `needPairing(device, "This PC no longer recognizes this phone — pair again")` — NO retry |
| handshake → `authFail` pinInvalid/pinExpired/lockedOut | `handshaking` (pairing path) | stay in pairing UI with reason + attemptsRemaining/retryAfterSecs — user-driven retry only |
| `err versionMismatch` | `handshaking` | terminal: "update server/app" state — no retry |

**Dead-connection detection:** when `authed` and idle, ConnectionService sends a `ping` every ~2s (reusing the probe's encode path); 3 consecutive missed pongs (~6s) ⇒ treat socket dead ⇒ close ⇒ transport-failure input. This doubles as the header latency source when no move traffic flows.

**Send policy (per-message-class, phase goal):**

| Class | Members (v1) | Policy |
|-------|-------------|--------|
| volatile | binary move/scroll frames | drop unless `authed` — NEVER queue (design spec §8: queued deltas teleport the cursor) |
| reliable | `click`,`drag`,`key`,`text`,`media`,`power`,`confirm`,`clip.*`,`browser`,`present` | queue ≤10 during blips, then drop with a toast (design spec §8) — Phase 3 ships the seam; later phases consume |
| internal | handshake family, `ping` | owned by driver/probe; not exposed |

### Pattern 7: GUID-keyed multi-PC storage (D-07)

```
flutter_secure_storage:            shared_preferences:
  "token.<machineGuid>" = 64-hex     "devices" = JSON: { "<guid>": {"name": "...",
                                        "host": "192.168.1.7", "port": 17777,
                                        "lastConnectedAt": 1720400000 } }
                                     "lastDeviceGuid" = "<guid>"
```

- Read path on launch (D-01): `lastDeviceGuid` → device meta → token → silent auth attempt (bounded, e.g. one 3s attempt) → on failure land on device list with background retry.
- Secure-storage reads can throw after OS updates/restore (keystore invalidation, issue #853): catch `PlatformException` → treat device as **unpaired** (grayed→pairs again), never crash [CITED: pub.dev flutter_secure_storage changelog + issue #853, via STACK.md].
- Secrets rule: token string never enters shared_preferences, logs, or state objects that get `toString()`d.

### Anti-Patterns to Avoid

- **Re-implementing handshake states inside the reconnect FSM** — the two FSMs compose; duplicating pin/auth states creates drift against `session.rs`.
- **Queueing volatile frames during blips** — cursor teleports on reconnect (design spec §8 explicitly drops them).
- **Second stream listener on the channel** — the single-listener routing pattern (handshake→driver, pong→probe) moves into ConnectionService intact; double-subscribe throws in Dart.
- **Silent retry after `authFail`** — D-05 locks transport-retry/auth-stop; retrying `badMac` hammers the server's global lockout counter.
- **Trusting beacon contents** — a beacon is unauthenticated UDP. It may update the device list and short-circuit backoff, but never triggers sending secrets; challenge-response makes a spoofed beacon harvest nothing (PITFALLS #9).
- **Putting `if-addrs`-style enumeration behind a one-shot at startup** — adapters change (VPN connect/disconnect); enumerate per beacon tick or on a slow refresh.
- **Showing every beacon packet as a device-list update** — debounce/merge by GUID; evict to "grayed" after ~3 missed beacon intervals (6–8s), not instantly.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| HMAC challenge-response | any client crypto | `authProof()` from `remote_protocol` | Fixture-anchored byte-identity (05-auth-proof.json); hand-rolling risks silent mismatch |
| Interface enumeration | Win32 `GetAdaptersAddresses` FFI | `if-addrs` 0.15 | Cross-platform (Linux server port), handles the buffer dance |
| Toast notifications | raw WinRT COM activation | `tauri-winrt-notification` 0.8 | AUMID/XML template handling is fiddly; crate is tauri-maintained |
| Android keystore crypto | custom AES-on-prefs | `flutter_secure_storage` 10.3.1 | Spec-locked; v10 cipher is current best practice |
| UDP datagram socket | `udp` pub package | `dart:io RawDatagramSocket` | SDK built-in; the package is 4 years stale (stack doc "What NOT to Use") |
| WS construction | new connect path | existing `connectNoDelay` | Gate-proven TCP_NODELAY plumbing (p95 10ms) |
| PIN/lockout/token logic | anything server-side | existing `server-core/auth` | Phase 1 complete + tested; CONTEXT locks "no server auth logic this phase" |

**Key insight:** almost everything hard in this phase already exists and is tested — the failure mode to guard against is *rewriting* proven parts, not missing libraries. The only genuinely new externally-facing artifact is the beacon format.

## Beacon Wire Format (decision input — design spec §4 owns it, no format locked)

**Recommendation: versioned JSON datagram**, UTF-8, one per send:

```json
{ "v": 1, "app": "remote-control", "name": "OMKAR-LAPTOP", "guid": "9f3c…", "port": 17777, "proto": "1.0" }
```

- **Size:** ~120–160 bytes — far below the 1472-byte MTU-safe bound and the 512-byte conservative cap; zero fragmentation risk. [VERIFIED: arithmetic]
- **Destination port:** propose `17778` (`RC_BEACON_PORT` env override, mirroring `RC_PORT`). The ws `port` field travels IN the beacon so ws-port changes need no client update.
- **Validation (client):** length ≤ 512 → JSON parse → `v == 1` && `app == "remote-control"` → field types (name:string≤64, guid:string≤64, port:1..65535, proto:string) → else drop silently. The beacon is untrusted input; parsing must be total (no throws escaping the listener).
- **Versioning:** `v` is the beacon format version (independent of `proto`); unknown fields ignored (same forward-compat rule as SPEC §1).
- **Documentation home:** `protocol/BEACON.md` + shared fixtures in `protocol/fixtures/beacon/` (valid + malformed cases), Rust encoder test + Dart decoder test — matches the project's fixture discipline. SPEC.md itself stays untouched (it explicitly excludes discovery).
- **Machine GUID:** `winreg` read of `HKLM\SOFTWARE\Microsoft\Cryptography\MachineGuid` (REG_SZ, readable unelevated). The x86_64 build sees the 64-bit view by default; `KEY_WOW64_64KEY` only matters if a 32-bit build ever exists. Fallback if the read fails (rare): derive a stable ID from `COMPUTERNAME` and log a warning — never crash the server over identity.

```rust
// server-windows: machine GUID read
use winreg::{enums::HKEY_LOCAL_MACHINE, RegKey};
fn machine_guid() -> Option<String> {
    RegKey::predef(HKEY_LOCAL_MACHINE)
        .open_subkey(r"SOFTWARE\Microsoft\Cryptography").ok()?
        .get_value::<String, _>("MachineGuid").ok()
}
```

## Runtime State Inventory

Phase 3 replaces spike scaffolding (mild refactor), so the inventory was checked explicitly:

| Category | Items Found | Action Required |
|----------|-------------|-----------------|
| Stored data | In-memory client token only (dies with the process — nothing persisted yet); server token hashes in-memory only | None — no migration; first secure-storage write happens at next pairing |
| Live service config | None — no external services hold project config (verified: no tray, no installer, no registered services yet) | None |
| OS-registered state | None — no autostart entry, no scheduled tasks (Phase 7 items) | None |
| Secrets/env vars | `RC_PORT` env override (unchanged); no secret stores | None |
| Build artifacts | `server/target/` — stale after Cargo.toml dep additions | Normal rebuild |

## Common Pitfalls

### Pitfall 1: Discovery fails four independent ways on real networks
**What goes wrong:** Beacons vanish (VPN/WSL adapter absorbs the single-interface broadcast), AP isolation drops client-to-client traffic, Windows Firewall blocks the *inbound ws connect* while beacons still flow (PC listed but connect hangs — the most confusing case), and some Android chipsets filter broadcast frames.
**Why it happens:** Broadcast assumptions hold only on a one-router home LAN with no virtual adapters.
**How to avoid:** Per-interface directed broadcast (Pattern 1); MulticastLock while list visible (Pattern 4); manual IP entry as first-class fallback (D-03); distinct error copy for the beacon-seen-but-connect-timeout case: "PC found but connection blocked — check Windows Firewall."
**Warning signs:** Discovery tested only on the dev LAN; connect timeout shows a generic error. [CITED: PITFALLS.md #6]

### Pitfall 2: Owner's Xiaomi/HyperOS device is in the aggressive-OEM cohort (carried STATE concern)
**What goes wrong:** Broadcast reception may be filtered even foregrounded, or sockets throttled on screen-dim; the MulticastLock is ignored by some wpa_supplicant builds.
**How to avoid:** Make the on-device beacon reception test the FIRST verification step of the discovery plan (a 20-line spike listener is enough); if reception fails, the mitigations are already designed in (manual IP + remembered devices still work — discovery is a convenience, not the only path).
**Warning signs:** All discovery tests on emulator (emulators don't receive LAN broadcast at all — NAT'd networking; test on hardware only).

### Pitfall 3: Backoff cap eaten on app resume
**What goes wrong:** User returns to the app mid-backoff and stares at "Reconnecting…" for the full remaining delay.
**How to avoid:** `AppLifecycleListener.onResume` → reset attempt counter → immediate attempt (D-06 locked trigger). One line of FSM input; test it in the pure FSM suite. [CITED: PITFALLS.md #5]

### Pitfall 4: Toast never appears (Focus Assist / notification settings / unregistered AUMID)
**What goes wrong:** Windows suppresses toasts under Focus Assist/DnD; unpackaged exes without AUMID registration can't toast at all under their own identity.
**How to avoid:** `Toast::POWERSHELL_APP_ID` (works unregistered, attributed to "Windows PowerShell" — accepted v1 quirk, proper AUMID lands with the Phase-7 tray); console `println!` stays as the always-works fallback and prints BEFORE the toast attempt; `.show()` failure logs a warning, never panics. [CITED: docs.rs/tauri-winrt-notification; PITFALLS.md UX table]

### Pitfall 5: Secure-storage reads fail after OS update/backup restore
**What goes wrong:** Android keystore key invalidation makes `read()` throw `PlatformException`; naive code crashes at launch — the worst possible first impression.
**How to avoid:** Wrap every secure-storage read; on failure treat the device as unpaired (falls into the normal pairing flow) and delete the dead entry. Also exclude the app from auto-backup of prefs if token-adjacent metadata matters (`android:allowBackup` review — metadata is non-secret so default is acceptable). [CITED: flutter_secure_storage issue #853 via STACK.md]

### Pitfall 6: Server restart forgets pairings (in-memory hashes until Phase 7)
**What goes wrong:** `AuthManager.paired_hashes` is a `Vec` in memory ("config persistence is Phase 7" — auth/mod.rs comment). Restarting the server yields `authFail noPairing` on the phone's silent reconnect.
**How to avoid:** This is **expected Phase-3 behavior** and D-05 already handles it correctly: noPairing is terminal → phone clears the token → pairing flow with explanation. The plan must NOT add server-side persistence (CONTEXT scopes server work to beacon + notification) but SHOULD note the behavior in verification docs so a re-pair after server restart isn't misread as a bug.
**Warning signs:** Reconnect tests that restart the server and expect silent success.

### Pitfall 7: Cleartext swap silently breaks ws://
**What goes wrong:** Removing `usesCleartextTraffic` and adding the XML config has a failure mode where the config file isn't referenced in the manifest (attribute `android:networkSecurityConfig`) — every connect then fails with "Insecure HTTP is not allowed by platform."
**How to avoid:** Single commit for attribute-swap + XML + manifest reference; on-device ws:// smoke test is a mandatory verification step (Phase 2 proved Dart enforces this policy).

### Pitfall 8: Beacon listener held open forever
**What goes wrong:** Socket + MulticastLock held while the app sits on the trackpad screen burns battery (the lock disables chipset packet filtering globally).
**How to avoid:** Listen while (a) device list visible, and (b) FSM is in `backoff` for a discovered device (beacon re-listen trigger). Release socket + lock when `authed` and not on the list screen.

### Pitfall 9: Hot-path regressions while extracting connect UI from the trackpad screen
**What goes wrong:** Moving the single-stream-listener + probe wiring into ConnectionService accidentally introduces a second subscribe, or header-chip updates rebuild on every pong.
**How to avoid:** Keep exactly one `channel.stream.listen` inside ConnectionService; header chip reads probe percentiles on the existing `kHudReadThrottle` (500ms) cadence via a throttled provider, preserving the Phase-2 no-rebuild-on-hot-path invariant.

## Code Examples

(Primary patterns are inline above: beacon broadcaster, toast, beacon listener, MulticastLock channel, network-security-config, FSM policy table, GUID storage, MachineGuid read.)

### App-resume trigger (Flutter built-in)

```dart
// Source: api.flutter.dev AppLifecycleListener (Flutter 3.13+; current in 3.44)
late final AppLifecycleListener _lifecycle;
_lifecycle = AppLifecycleListener(
  onResume: () => connectionService.onAppResumed(), // FSM input: reset backoff, retry now
);
```

### Secure token store (flutter_secure_storage 10.x)

```dart
// Source: pub.dev/packages/flutter_secure_storage (v10 default Android cipher — do NOT
// set encryptedSharedPreferences, deprecated in v10)
const _storage = FlutterSecureStorage();

Future<String?> tokenFor(String guid) async {
  try {
    return await _storage.read(key: 'token.$guid');
  } on PlatformException {
    // Keystore invalidation (OS update / restore, issue #853): treat as unpaired.
    await _storage.delete(key: 'token.$guid').catchError((_) {});
    return null;
  }
}

Future<void> saveToken(String guid, String rawTokenHex) =>
    _storage.write(key: 'token.$guid', value: rawTokenHex);
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `winrt-notification` (allenbenz) | `tauri-winrt-notification` 0.8 (tauri-apps fork) | ~2022, actively maintained since | Use the tauri fork; original is stale |
| `encryptedSharedPreferences: true` | v10 default cipher (RSA_ECB_OAEP+SHA-256) | flutter_secure_storage 10 (2025) | Do not set the deprecated flag (stack doc) |
| `WidgetsBindingObserver` mixin for lifecycle | `AppLifecycleListener` object | Flutter 3.13+ | Cleaner disposal; either satisfies D-06 |
| `usesCleartextTraffic` manifest attribute | `network_security_config.xml` | Android 7+, best practice since 9 | The config file supersedes the attribute when both present |
| `get_if_addrs` crate | `if-addrs` (maintained fork) | 2020 | Same API surface, active maintenance |

**Deprecated/outdated:**
- `udp` pub package: 4 years stale — `dart:io RawDatagramSocket` (stack doc).
- `multicast_lock` pub package (2018): abandoned — hand-written MethodChannel.
- Tray balloon (`Shell_NotifyIcon` NIF_INFO) for the PIN: requires a tray icon (Phase 7) and is the legacy notification path; toast is current.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `if_addrs::Ifv4Addr` exposes `netmask` and `broadcast` fields as sketched | Pattern 1 | LOW — compute broadcast as `ip \| !netmask` (one line); verify field names at first compile |
| A2 | Dart's cleartext check honors `network_security_config.xml` base-config identically to the manifest attribute | Pattern 5 | MEDIUM — mandatory on-device ws:// smoke test after the swap; rollback is re-adding one attribute |
| A3 | MulticastLock improves plain-broadcast (not just multicast) reception on filtering chipsets; foreground+screen-on reception usually works without it | Pattern 4 | LOW — it's insurance; manual IP + remembered devices are the guaranteed paths; early Xiaomi device test scheduled |
| A4 | `Toast::POWERSHELL_APP_ID` still works unregistered on current Windows 11 builds | Pattern 2 | LOW — console fallback always prints the PIN first; failure degrades to Phase-2 UX |
| A5 | `COMPUTERNAME` env var is a sufficient device-name source on Windows | Beacon format | TRIVIAL — fallback literal "Windows PC" |
| A6 | Beacon port 17778 is free of common conflicts | Beacon format | TRIVIAL — env-overridable like RC_PORT |
| A7 | `RawDatagramSocket.bind(reuseAddress: true)` behaves as expected on Android for a fixed port across hot-restarts | Pattern 3 | LOW — dispose-and-rebind on listener restart handles it |

## Open Questions

1. **Should `protocol/BEACON.md` + shared beacon fixtures be in scope?**
   - What we know: SPEC.md excludes discovery; design spec §4 names the fields; the project has strong fixture discipline.
   - What's unclear: whether the planner treats beacon fixtures as required or gold-plating.
   - Recommendation: include them — the beacon is the only new cross-language wire artifact this phase, the fixture cost is one JSON file + two small tests, and it prevents Rust/Dart drift exactly where the project has been burned before. Planner's call on placement.

2. **Server restart → forced re-pair (token hashes in-memory until Phase 7).**
   - What we know: CONTEXT locks "no server auth logic this phase"; D-05 handles `noPairing` gracefully.
   - What's unclear: whether the owner will perceive re-pairing after every server restart as broken during weeks of Phase 3–6 daily use.
   - Recommendation: keep scope as locked; explicitly document the behavior in VERIFICATION.md. If it proves painful in practice, hash persistence to config.toml is a small Phase-7 pull-forward decided then, not now.

3. **Exact latency-chip content (p50 vs p95 vs last-RTT).**
   - What we know: probe exposes p50/p95; header space is small.
   - Recommendation: show p50 with the status color; planner/UI discretion (explicitly delegated by CONTEXT).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Flutter SDK | client work | ✓ | 3.44.5 stable | — |
| cargo / Rust | server work | ✓ | 1.89.0 | — |
| crates.io / pub.dev access | dep installs | ✓ | verified this session | — |
| Physical Android device (Xiaomi/HyperOS, Android 16) | discovery + cleartext + secure-storage verification | owner-provided (proven in 02-04 gate) | — | none — emulators cannot receive LAN broadcast; device steps are checkpoints |
| Windows 11 host (this machine) | toast + beacon + GUID verification | ✓ | 10.0.26200 | — |

**Missing dependencies with no fallback:** none blocking. Device-dependent steps must be `checkpoint:human-verify` tasks (owner runs them), consistent with the 02-04 gate pattern.

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Frameworks | Rust: cargo test (tokio test-util, start_paused for timers); Dart: flutter_test |
| Config files | `server/Cargo.toml` workspace; `app/remote_control/pubspec.yaml` (both exist) |
| Quick run commands | `cargo test -p server-core <module>` · `flutter test test/<file>.dart` (run in `app/remote_control`) |
| Full suite commands | `cargo test --workspace` (in `server/`) · `flutter test` (in `app/remote_control`) |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| CONN-01 | Beacon encode (Rust) / decode+validate (Dart) round-trip, malformed-drop | unit + fixture | `cargo test -p server-core beacon` · `flutter test test/beacon_test.dart` | ❌ Wave 0 |
| CONN-01 | Device list merge/evict by GUID (dup names, gray-out) | unit | `flutter test test/device_list_store_test.dart` | ❌ Wave 0 |
| CONN-02 | PIN dialog maps every `authFail` reason to correct copy | widget/unit | `flutter test test/pairing_flow_test.dart` | ❌ Wave 0 |
| CONN-02 | Toast displays PIN on this machine | manual-only (visual) | — checkpoint:human-verify (justification: notification rendering is not CI-testable) | — |
| CONN-03 | Token persisted at pairOk; reconnect FSM takes auth branch from stored token; keystore-failure → unpaired | unit (fake storage) | `flutter test test/device_store_test.dart` | ❌ Wave 0 |
| CONN-04 | Backoff sequence/cap/jitter, resume reset, beacon short-circuit, authFail-terminal — all pure FSM transitions | unit (no IO) | `flutter test test/reconnect_fsm_test.dart` | ❌ Wave 0 |
| CONN-04 | Real WiFi-toggle + PC IP change recovery | manual-only | — checkpoint:human-verify (justification: real network churn not reproducible in CI) | — |
| CONN-05 | Private-range guard; manual entry reuses connect path; firewall error copy on beacon-seen-connect-timeout | unit | `flutter test test/reconnect_fsm_test.dart` (+ widget test) | ❌ Wave 0 |
| CONN-06 | Idle-ping cadence, missed-pong → dead-connection input, throttled chip reads | unit (injected clock — probe pattern exists) | `flutter test test/latency_probe_test.dart` (extend) | ✅ extend |
| all | Existing suites stay green (handshake, probe, codecs, server integration) | regression | full suite commands | ✅ |

### Sampling Rate
- **Per task commit:** the task's targeted quick command (e.g. `flutter test test/reconnect_fsm_test.dart`)
- **Per wave merge:** `flutter test` + `cargo test --workspace`
- **Phase gate:** full suites green + on-device human-verify checklist (beacon on Xiaomi, pair via toast PIN, WiFi-drop recovery, cleartext swap smoke)

### Wave 0 Gaps
- [ ] `app/remote_control/test/reconnect_fsm_test.dart` — CONN-04/05 (pure FSM — the highest-value suite)
- [ ] `app/remote_control/test/beacon_test.dart` — CONN-01 decode/validation (+ `protocol/fixtures/beacon/` if adopted)
- [ ] `app/remote_control/test/device_store_test.dart` — CONN-03 (fake secure storage seam)
- [ ] `app/remote_control/test/device_list_store_test.dart` — CONN-01 merge/evict
- [ ] `app/remote_control/test/pairing_flow_test.dart` — CONN-02 error copy
- [ ] `server/server-core/src/transport/beacon.rs` unit tests — CONN-01 encode + interval logic (paused-time)
- Framework installs: none — both test frameworks already configured and green

## Security Domain

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | yes | Existing challenge-response (HMAC-SHA256 over CSPRNG nonce, SPEC §4) — unchanged; PIN rules enforced server-side (Phase 1) |
| V3 Session Management | yes | Existing auth gating (SPEC §6: pre-auth traffic silently dropped); one active session client-side (D-07) |
| V4 Access Control | no (single-user LAN tool) | — |
| V5 Input Validation | yes | Beacon = untrusted UDP: 512-byte cap, total parse, strict field validation, silent drop; manual IP input parsed + private-range-guarded |
| V6 Cryptography | yes | `sha2`/`hmac`/`subtle` (existing, fixture-proven); flutter_secure_storage v10 default cipher for token at rest — never hand-roll |

### Known Threat Patterns for this stack

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Beacon spoofing (rogue server advertises paired GUID) | Spoofing | Challenge-response: phone's `auth` reply is useless to the rogue (SPEC §4 replay defense); beacon NEVER triggers sending secrets — only a connect attempt that must survive the handshake |
| Beacon flood (UDP garbage at :17778) | DoS | Datagram size cap, parse-fail silent drop, GUID-debounced list updates (no unbounded state growth) |
| Token theft at rest | Info disclosure | flutter_secure_storage (Android keystore); server stores SHA-256 hashes only (existing) |
| Token/PIN in logs | Info disclosure | Redaction discipline carried forward: PIN → stdout/toast only, never tracing; token never in prefs/logs/toString |
| Cleartext ws:// sniffing | Info disclosure | Accepted v1 residual risk (SPEC §12, CONTEXT deferred TLS); private-range dial guard keeps the surface LAN-only |
| Lockout bypass via IP rotation | Elevation | Existing global 20-attempt cap (SPEC §5) — client shows `retryAfterSecs` honestly |

## Project Constraints (from CLAUDE.md)

- **Stack versions are authoritative:** tokio 1.52, tokio-tungstenite 0.29, windows 0.62, winreg 0.56, sha2 0.11, rand 0.10, Flutter 3.44, flutter_riverpod 3.3.2, web_socket_channel 3.0.3, flutter_secure_storage 10.3.1, wakelock_plus 1.6.1 — do not pin different majors.
- **Forbidden:** `udp` pub package, original `wakelock`, Riverpod 2.x `StateNotifier` patterns, `encryptedSharedPreferences: true`, `rdev`, `trayicon` (Ciantic), sha2 0.10 pins, app settings in secure storage.
- **Required:** secrets only in flutter_secure_storage; shared_preferences for non-secrets; `dart:io RawDatagramSocket` for UDP; hand-written codecs contract-tested against shared fixtures; server-core keeps zero Windows deps (compiles on Linux CI) — beacon broadcaster with `if-addrs` is cross-platform and belongs in core; Windows-only identity (winreg, COMPUTERNAME) injected from server-windows.
- **Security (spec-locked):** PIN pairing 60s/5-attempt/lockout, SHA-256 hashed tokens, LAN-only binding, never log secrets.
- **Workflow:** GSD entry points only; conventions emerge from the codebase (pure FSM + driver, effect objects, single stream listener, Riverpod 3 Notifier, #0E0F12 theme).

## Sources

### Primary (HIGH confidence)
- Codebase direct reads: `handshake_fsm.dart`, `handshake.dart`, `connection_service.dart`, `latency_probe.dart`, `trackpad_screen.dart`, `server-windows/main.rs`, `server-core/auth/mod.rs`, Cargo.toml/pubspec/AndroidManifest — reuse surfaces, in-memory-hash limitation, WR-01 re-pair loop
- `protocol/SPEC.md` + design spec §4/§6/§8 — handshake contract, authFail enum, backoff 1→2→4 cap 10s, beacon field list
- crates.io + pub.dev registry APIs (2026-07-08) — all five package versions; `gsd-tools query package-legitimacy` (3 crates OK)
- `.planning/research/PITFALLS.md` #5/#6/#9 + STACK.md (embedded in CLAUDE.md) — discovery failure matrix, lifecycle reset, secure-storage caveats

### Secondary (MEDIUM confidence)
- [docs.rs/tauri-winrt-notification Toast](https://docs.rs/tauri-winrt-notification/latest/tauri_winrt_notification/struct.Toast.html) + [github.com/tauri-apps/winrt-notification](https://github.com/tauri-apps/winrt-notification) — POWERSHELL_APP_ID unpackaged-exe pattern, PowerShell-attribution quirk
- [developer.android.com/privacy-and-security/security-config](https://developer.android.com/privacy-and-security/security-config) — domain element syntax: no CIDR/IP-range support; base vs domain cleartext semantics
- [developer.android.com WifiManager.MulticastLock](https://developer.android.com/reference/android/net/wifi/WifiManager.MulticastLock) — lock semantics, battery note

### Tertiary (LOW confidence — flagged for on-device validation)
- Community reports on chipset broadcast filtering ([B4X forum UDP-broadcast thread](https://www.b4x.com/android/forum/threads/solved-android-blocking-receiving-udp-broadcast.99519/), [lknuth.dev UDP multicast on Android](https://lknuth.dev/writings/udp_multicast_on_android/)) — device-dependent; drives the "insurance + fallback" posture, not a hard dependency
- IP-literals-in-domain-config community pattern ([blog.plentytolearn.com](https://blog.plentytolearn.com/2019/12/solve-cleartext-communication-to-ip.html)) — irrelevant to final design (ranges impossible anyway) but confirms per-IP matching exists

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all versions registry-verified today; legitimacy seam OK on all crates
- Architecture: HIGH — composes gate-proven code following the project's own locked patterns; new surface (beacon) is small and fully specified here
- Pitfalls: HIGH for Windows/network behavior (official docs + prior project research); MEDIUM for Android OEM broadcast behavior (inherently device-dependent — early Xiaomi test is scheduled, and the design does not depend on discovery working)

**Research date:** 2026-07-08
**Valid until:** 2026-08-07 (stable domain; re-verify crate/package versions if planning slips past that)
