# Architecture Research

**Domain:** Phone-as-remote-input system (Flutter Android client + Rust Windows input-injection server over LAN WebSocket)
**Researched:** 2026-07-07
**Confidence:** HIGH (component structure — multiple comparable OSS systems converge on the same shape); MEDIUM (latency specifics — web-sourced, needs empirical validation in Phase spikes)

> **Note:** The approved design spec (`docs/superpowers/specs/2026-07-07-remote-control-design.md`) already locks the high-level architecture. This research **validates** those boundaries against how comparable systems are actually built, identifies where latency hides in the input pipeline, and derives the dependency-correct build order for the roadmap.

## Standard Architecture

### How comparable systems are structured

Every surveyed phone-remote-input system converges on the same five-part shape:

| System | Client | Transport | Server routing | Injection layer |
|--------|--------|-----------|----------------|-----------------|
| KDE Connect | Android (Kotlin) | TLS TCP + UDP discovery | **Plugin-per-feature** (mousepad, remotekeyboard, media, ...) | `AbstractRemoteInput` abstraction per windowing system |
| RustDesk | Flutter | Custom TCP/UDP | Message dispatcher | Forked **enigo** (`mouse_move_relative`, SendInput) |
| Axon | Android (Kotlin) | WebSocket | WS handler → dispatcher | Platform-specific input simulation (Go) |
| Mousedroid / Remote Mouse clones | Android | TCP/WS | Command switch | OS input API |
| **This project (spec)** | Flutter | WebSocket + UDP beacon | `dispatch` module | Executor traits → `enigo`/Win32 |

**Validation verdict:** the spec's boundaries are the industry-standard shape. Two features stand out as *better* than the median OSS project: (1) the versioned `protocol/` directory with shared fixtures as a cross-ecosystem contract (most projects informally duplicate the protocol in two languages and drift), and (2) executor **traits** in an OS-agnostic core (KDE Connect's `AbstractRemoteInput` and RustDesk's enigo fork prove this seam is exactly where portability lives).

### System Overview

```
┌──────────────────────── Android (Flutter) ─────────────────────────┐
│  Screens (Trackpad, Keyboard, Media, Apps, Clip, Power, ...)       │
│      │ intents (Riverpod providers per feature)                    │
│  Controller layer (feature controllers, gesture→delta math)        │
│      │ typed messages                                              │
│  Protocol layer (binary encoder 9B mouse frames, JSON codecs)      │
│      │ frames                                                      │
│  ConnectionService (singleton: WS lifecycle, reconnect FSM,        │
│      beacon listener, token store, send queue policy)              │
└──────────────┬────────────────────────────────┬────────────────────┘
               │ WebSocket (binary + JSON)      │ UDP 255.255.255.255
               │                                │ (beacon, listen-only)
┌──────────────┴────────────────────────────────┴────────────────────┐
│                        server-core (Rust, OS-agnostic)             │
│  transport: WS listener (tokio+tungstenite, TCP_NODELAY)           │
│             UDP beacon broadcaster · session/auth manager          │
│      │ raw frames                                                  │
│  dispatch: codec (parse/validate) → auth gate → pause gate →       │
│            route by message family                                 │
│      │ trait calls                                                 │
│  Executor traits: MouseKeys · Media · Power · Apps · Clipboard     │
├─────────────────────────────────────────────────────────────────────┤
│                        server-windows (binary)                     │
│  Trait impls: enigo/SendInput · IAudioEndpointVolume ·             │
│    shutdown.exe/LockWorkStation · EnumWindows/ShellExecute ·       │
│    arboard + poll                                                  │
│  Shell: tray-icon · settings window · autostart · config.toml      │
└─────────────────────────────────────────────────────────────────────┘
```

### Component Responsibilities

| Component | Responsibility | Typical Implementation | Talks To |
|-----------|----------------|------------------------|----------|
| `protocol/` spec + fixtures | Single source of truth: message schemas, binary layout, golden byte fixtures | Markdown + JSON Schema + fixture files | Consumed by Rust and Dart codec tests (build-time only, no runtime dep) |
| Flutter screens | Render state, capture gestures/taps | One widget tree per feature; persistent quick-bar shell | Feature controllers only — never the socket directly |
| Controller layer | Gesture → semantic events (touch deltas, sticky-modifier state, slide-to-confirm) | Riverpod notifiers per feature | Protocol layer via typed API |
| Dart protocol layer | Encode/decode: 9-byte binary mouse frames, JSON codecs | Pure functions, fixture-tested | ConnectionService |
| `ConnectionService` | WS lifecycle, reconnect FSM, beacon listener, token storage, per-message-class queue policy | Singleton provider; exposes state stream + send API | OS socket, secure storage |
| server `transport` | Accept WS, per-connection read/write tasks, UDP beacon every 2s, session registry | tokio + tungstenite; mpsc sender per session in shared map | dispatch |
| server `dispatch` | Parse, validate, **auth gate** (drop pre-`authOk` except handshake), **pause gate**, route by family | Match on message type; owns session state machine | Executor traits |
| Executor traits | OS action contracts | `trait MouseKeys { fn move_rel(dx,dy); ... }` etc. | Nothing (leaf) |
| `server-windows` impls | Actual injection + OS integration | enigo/SendInput, Core Audio, Win32, arboard | Windows APIs |
| Tray/settings shell | Pause toggle, paired-device revoke, autostart, port self-test | tray-icon + config.toml | server-core config/session manager |

**Boundary rules (enforce from day one):**
- `server-core` has **zero** Windows dependencies — it compiles and passes its full test suite on any OS with executors mocked. This is what makes `server-linux` a later drop-in.
- Flutter screens never touch the WebSocket; only `ConnectionService` owns it. Comparable projects that scatter socket handling per-screen (several small GitHub clones) end up with N reconnect loops fighting each other.
- `protocol/` is a contract, not a library — both sides implement it independently and prove equivalence via shared fixtures.

## Recommended Project Structure

```
remote-control/
├── protocol/
│   ├── SPEC.md                  # versioned prose spec
│   ├── schema/                  # JSON Schema per message family
│   └── fixtures/                # golden files: JSON msgs + binary frames + expected decode
├── server/                      # Cargo workspace
│   ├── server-core/
│   │   └── src/
│   │       ├── codec/           # binary + JSON parse/serialize (fixture-tested)
│   │       ├── transport/       # ws listener, udp beacon, session registry
│   │       ├── dispatch/        # auth gate, pause gate, routing
│   │       ├── auth/            # PIN flow, token hash, lockout
│   │       └── executors.rs     # the 5 traits + mock impls (test feature)
│   └── server-windows/
│       └── src/
│           ├── exec/            # trait impls: mousekeys, media, power, apps, clipboard
│           ├── tray.rs          # tray-icon menu
│           ├── settings/        # settings window
│           └── main.rs          # wiring: core + executors + shell
└── app/                         # Flutter
    └── lib/
        ├── protocol/            # codecs mirroring protocol/ (fixture-tested)
        ├── connection/          # ConnectionService, reconnect FSM, beacon listener, token store
        ├── features/            # one folder per screen: controller + widgets
        └── shell/               # dashboard, quick-bar, theme
```

### Structure Rationale

- **`codec/` separate from `dispatch/`:** codecs are pure and fixture-testable in isolation; dispatch has session state. Mixing them makes contract tests drag in auth machinery.
- **`executors.rs` traits live in core, impls in the binary crate:** the dependency arrow points OS → core, never core → OS. Integration tests run real dispatch against mock executors (spec §9), which requires this direction.
- **`features/` folders own controller + widgets together:** each feature family in the wire protocol maps 1:1 to a screen and a controller — keeping them adjacent keeps message-family changes local.

## Architectural Patterns

### Pattern 1: Two-plane wire protocol (hot path vs. reliable path)

**What:** Mouse deltas travel as fire-and-forget 9-byte binary frames at input rate; everything else is sequenced JSON.
**When to use:** Any real-time input system where one message class is high-frequency/loss-tolerant and the rest are low-frequency/must-arrive. Remote Mouse, RustDesk, and game netcode all split this way.
**Trade-offs:** Two codecs to test (mitigated by shared fixtures); in exchange the hot path avoids JSON parse cost (~µs but per-frame at 120Hz) and the reliable path stays debuggable.
**Key rule:** button clicks/drag state go on the *reliable* plane (spec already does this) — a lost `mouseup` on a lossy plane means a stuck drag.

### Pattern 2: Dispatcher with layered gates (per-connection tasks + mpsc)

**What:** The canonical tokio-tungstenite server shape: each connection gets a read task and a write task; a session registry maps session → `mpsc::Sender` for server-push. Dispatch applies gates in order: parse → auth gate → pause gate → route.
**When to use:** Always for multi-client WS servers; it isolates per-connection failure (client dies → its tasks end, registry entry removed) and gives server-push (`apps.changed`, `clip.changed`) a natural fan-out point (iterate registry, send on each session's channel).
**Trade-offs:** Slight ceremony vs. a single loop, but the spec's "two phones connected" requirement makes the registry mandatory anyway.

**Example (server-core shape):**

```rust
// session registry: SessionId -> (sender, AuthState)
enum AuthState { PreAuth, PinPending { attempts: u8 }, Authed { device_id: Uuid } }

async fn dispatch(frame: Frame, session: &mut Session, exec: &Executors) {
    let msg = codec::parse(frame)?;                     // gate 0: valid frame
    if !session.auth.allows(&msg) { return; }           // gate 1: pre-auth drop
    if paused() && msg.is_input() { return; }           // gate 2: tray pause
    match msg {
        Msg::MouseMove { dx, dy } => exec.mouse.move_rel(dx, dy),
        Msg::Power(action)        => session.pend_confirm(action),  // gate 3: double-confirm
        // ...
    }
}
```

### Pattern 3: Connection state machine owned by one service (client)

**What:** A single `ConnectionService` FSM; screens are pure subscribers. Consensus pattern across Flutter WS guidance: reconnect logic lives in the service/provider layer, never in widgets or notifiers.

```
                 ┌──────────────────────────────────────────────┐
                 ▼                                              │
 idle ──► discovering ──► connecting ──► authenticating ──► connected
              ▲   ▲            │               │                │
              │   │       (ws error)      (authFail)       (onDone/onError,
              │   │            ▼               ▼             ping timeout)
              │   │       reconnecting    tokenRejected          │
              │   │       (backoff 1→2→4s,     │                 │
              │   └────── cap 10s, beacon ◄────┼─────────────────┘
              │           re-listen in ∥)      ▼
              └──────────────────────── pairingRequired (PIN dialog)
```

**Critical transitions (from spec §8, validated against websocket.org reconnection guidance):**
- `reconnecting` runs backoff **and** beacon re-listen in parallel — the beacon carries the machine GUID, so a DHCP IP change is caught by GUID match, not IP retry. This dual-path reconnect is the piece naive implementations miss.
- `authFail` is **terminal** into `pairingRequired` (clear token, no silent retry loop) — distinguishes "network is flaky" from "server revoked me."
- Entering any disconnected state resets sticky modifiers and flushes nothing: mouse deltas are dropped, low-rate messages queue up to 10.
- Reset backoff counter on successful `authOk`, not on TCP connect (a connect that fails auth shouldn't reset backoff).

**Server-side session FSM** is smaller: `PreAuth → PinPending → Authed`, plus a per-source-IP lockout table (5 attempts / 5-min lockout) that lives in the auth manager, *not* in the session (it must survive the session dropping and reconnecting).

### Pattern 4: Per-message-class send policy (client)

**What:** The send API is not one queue. Each message class has a disposition when the socket is down:

| Class | Disconnected behavior | Why |
|-------|----------------------|-----|
| Binary mouse/scroll frames | **Drop immediately** | Queued deltas replay as cursor teleport on reconnect |
| `key`, `text`, `clip.*` | Queue ≤10, then drop + toast | User expects typed text to arrive; small bound prevents replay storms |
| `power`, `confirm` | Reject with UI error | Replaying a shutdown after reconnect is dangerous |
| `ping` | Suppress | Meaningless off-connection |

This policy lives in `ConnectionService`, keyed by message type — controllers stay ignorant of connection state.

## Data Flow

### Hot path: touch → cursor (the <30ms budget)

```
finger move (Android touch, 60–120Hz sampling)
  → Flutter PointerMoveEvent (delivered per frame; may coalesce samples)
  → controller: apply sensitivity × delta
  → 9-byte binary encode (no alloc, reuse buffer)
  → WebSocket send (TCP, TCP_NODELAY set)
  → LAN (~1–3ms RTT)
  → tungstenite read task → codec (fixed-size parse, no JSON)
  → dispatch (auth/pause gate = two branch checks)
  → MouseKeys::move_rel → enigo → SendInput
  → Windows compositor moves cursor
```

**Where latency hides (each is a real, documented sink):**

1. **Nagle's algorithm** — TCP batches small writes waiting for ACKs; up to ~40–200ms bursts on interactive traffic. **Must call `set_nodelay(true)`** on the TcpStream before the tungstenite handshake (server) and verify the Dart `WebSocket` path (Dart's `dart:io` WebSocket sets TCP_NODELAY by default via `HttpClient`, but verify empirically in the latency spike). This is the single biggest silent killer; RDP's canonical lag fix is exactly this.
2. **Flutter pointer-event coalescing** — Flutter delivers pointer moves aligned to frames; on a 60Hz display a 120Hz touch digitizer's samples arrive coalesced. Fine for deltas (sum them), but don't *also* add your own throttle timer on top — send on every `PointerMoveEvent`.
3. **permessage-deflate** — WebSocket compression adds per-frame CPU and buffering for zero benefit on 9-byte frames. Keep it off on both ends (it's off by default in tungstenite; don't enable it).
4. **Async ceremony on the hot path** — routing mouse frames through a locked shared state or an intermediate mpsc hop per frame adds scheduling latency. Dispatch mouse frames inline in the read task; only server-push traffic needs the channel hop. SendInput itself is synchronous and cheap.
5. **Phone WiFi power-save** — Android throttles the radio when idle; a keep-awake wake-lock during trackpad/presenter use (already in spec) also keeps the radio in low-latency state. If jitter persists, this is the first suspect before reaching for UDP.
6. **Queue-on-reconnect** — covered above; a correctness *and* latency issue.

### Reliable path (request/response + server push)

```
UI action → controller → JSON codec → ConnectionService.send(class-policied)
  → dispatch → executor → (result) → `err` on failure → client toast

Server push (no request):
  clipboard poll / EnumWindows diff → session registry fan-out
  → `clip.changed` / `apps.changed` → ConnectionService stream
  → feature controller updates → screen rebuild
```

**Clipboard echo-loop warning:** with auto-sync on, `clip.set` (phone→PC) changes the PC clipboard, which the change-poller detects, which pushes `clip.changed` back to the phone, which (if naively wired) re-sets the phone clipboard and re-sends. Suppress the poller's next tick after an inbound `clip.set` (mark last-written hash) — this is a boundary concern of the Clipboard executor impl.

### Discovery + pairing flow

```
server: UDP broadcast every 2s {name, guid, port, protoVersion}
phone:  beacon listener → dedupe by GUID → list
first connect:  ws open → hello (version check) → server shows PIN notification
                → phone sends pin → server verifies (60s/5-attempt/lockout)
                → 32B token issued → phone: secure storage; server: SHA-256 hash → config.toml
reconnect:      ws open → hello → auth{token} → authOk (silent)
```

Discovery is deliberately **one-directional and stateless** (server shouts, phone listens) — no mDNS dependency, no phone-side broadcast. Validated pattern: KDE Connect and Remote Mouse both use UDP identity broadcast for the same reason (works on consumer routers where mDNS is flaky).

## Recommended Build Order

The dependency graph dictates the order; each layer is testable against the previous with no forward references. This validates the spec's implied order with one important amendment: **pull a thin end-to-end slice forward** to retire the latency risk before building breadth.

```
protocol/ (spec + fixtures)
   │
   ├──► server-core codecs  ──► dispatch + auth/session FSM (mock executors)
   │         │                        │
   ├──► app/ protocol codecs          ▼
   │         │                server-windows: MouseKeys impl ONLY + headless run
   │         ▼                        │
   │    ConnectionService  ◄──────────┘
   │    (reconnect FSM,        ★ E2E SPIKE: bare trackpad → real cursor,
   │     beacon listener)        measure RTT + injection latency (<30ms gate)
   │                                  │
   │                                  ▼
   │                     remaining Windows executors        Flutter screens
   │                     (Media, Power, Apps, Clipboard)    (trackpad → keyboard →
   │                     + tray/settings/autostart           media → rest) + dashboard
   └────────────────────────────── fixtures keep both sides honest throughout
```

**Phase-shaped ordering with rationale:**

1. **Protocol contract** — spec doc, JSON schemas, binary layout, golden fixtures. *Everything depends on it; changing it later ripples through two languages.* Cheap to write, expensive to defer.
2. **Server core** — Rust codecs (fixture-tested) → dispatch → auth/PIN/token/session FSM, all against **mock executors**. *Fully CI-testable with zero OS dependencies; proves the auth gating and routing before any Windows code exists.* Integration test: real tokio server + fake WS client driving pair→auth→input (spec §9).
3. **Minimal Windows executor + E2E latency spike** — implement `MouseKeys` via enigo only, run server headless (no tray), and in parallel build the Dart binary codec + a throwaway trackpad page. **Gate: <30ms visually-instant cursor on real LAN.** *This is the project's only make-or-break unknown (WebSocket-only transport decision rests on it); everything else is known-buildable. If jitter appears here, the transport abstraction gets exercised while the code is small.*
4. **Flutter connection layer** — full `ConnectionService`: reconnect FSM, beacon listener, token secure storage, per-class send policy, PIN pairing flow. *Screens all sit on this; building screens first forces mock-churn. The FSM is widget-testable with a mocked socket.*
5. **Windows executors, breadth** — Media (enigo + Core Audio), Power (+confirm gate), Apps (EnumWindows/ShellExecute + `apps.changed` push), Clipboard (arboard + poll + echo suppression). *Each is an isolated trait impl; parallelizable; dispatch already routes them.*
6. **Flutter screens** — trackpad (real) → keyboard → media → power → apps → clipboard → presenter → browser → settings, plus dashboard + quick-bar shell. *Order matches daily-use value and executor availability.*
7. **Server shell + polish** — tray icon, settings window, autostart registry key, port self-test, file logging; app haptics/keep-awake/latency header. *Pure UX packaging; nothing depends on it.*

**Integration seams worth testing first (highest defect leverage):**

| Seam | Test | Why first |
|------|------|-----------|
| Rust codec ↔ Dart codec | Shared fixtures decode identically both sides | Cross-language drift is the classic two-codebase failure; fixtures make it impossible |
| Dispatch auth gate | Unit: pre-`authOk` input dropped; handshake family passes | Security boundary; a regression here is silent |
| PIN lockout table | Unit: 5 fails → 5-min lock per source IP, survives reconnect | State that must outlive sessions is easy to attach to the wrong lifetime |
| Reconnect FSM | Widget/unit: authFail→pairing (no retry loop); drop→backoff+beacon parallel; modifier reset | Most complex client state; all edge cases in spec §8 enumerate to test cases |
| Server + fake client | Integration: pair→auth→input→pause→revoke over real socket | Proves transport+dispatch+session wiring without OS injection |
| E2E latency | Manual + debug overlay: RTT + injection under load | Only risk that can invalidate a locked decision (WS-only transport) |

## Scaling Considerations

Traditional scale is irrelevant (1 server, 1–2 phones). The dimensions that actually matter:

| Dimension | v1 approach | Pressure point |
|-----------|-------------|----------------|
| Concurrent phones | Session registry + fan-out already handles N; both control (last-writer-wins on cursor, inherently fine for deltas) | None expected at N=2 |
| Message rate | ~120Hz × 9B ≈ 1KB/s hot path — negligible | Only if UDP channel added later |
| Platform expansion | New OS = new crate implementing 5 traits + new tray shell; core untouched | Traits must not leak Win32 types (e.g., `Apps` returns opaque window IDs, not HWNDs) |
| Feature expansion | New message family = schema + fixture + dispatch arm + trait method + screen | Keep families independent; no cross-family coupling in dispatch |

## Anti-Patterns

### Anti-Pattern 1: Queuing input deltas across disconnects

**What people do:** Buffer all outbound messages during a blip and flush on reconnect, treating the socket like a reliable pipe.
**Why it's wrong:** Replayed relative mouse deltas teleport the cursor; replayed key events type ghost text; a replayed power command shuts the machine down minutes later.
**Do this instead:** Per-message-class policy (spec §8 already mandates it): drop deltas, bound-queue text/clipboard, reject power.

### Anti-Pattern 2: Connection logic in the UI layer

**What people do:** Each screen opens/monitors the socket, or widgets call `reconnect()` in `build`/lifecycle hooks.
**Why it's wrong:** N screens → N competing reconnect loops, duplicate sockets, and FSM state smeared across widgets that unmount. This is the most-repeated failure in small Flutter WS apps.
**Do this instead:** One `ConnectionService` singleton owning the FSM; Riverpod providers expose read-only state streams; reconnect policy lives only in the service layer.

### Anti-Pattern 3: OS types leaking into server-core

**What people do:** "Just for now," pass an HWND or spawn `shutdown.exe` from dispatch, or `#[cfg(windows)]` blocks inside core.
**Why it's wrong:** Kills the mock-executor CI story immediately and turns the future `server-linux` crate into a rewrite instead of a drop-in.
**Do this instead:** Traits speak in protocol-level types only (window id = opaque string/u64, volume = 0–100). Core has zero conditional compilation on target OS.

### Anti-Pattern 4: Treating the hot path like the reliable path

**What people do:** JSON-encode mouse moves, enable WS compression, await an ack per frame, or route frames through the same request/response machinery as `apps.list`.
**Why it's wrong:** Each adds fixed per-frame cost at 60–120Hz; combined with Nagle this is where "cursor feels laggy" comes from despite a 2ms LAN.
**Do this instead:** Fixed binary frames, fire-and-forget, TCP_NODELAY, no compression, inline dispatch in the read task.

### Anti-Pattern 5: Clipboard sync without echo suppression

**What people do:** Wire `clip.set` and the change-poller independently.
**Why it's wrong:** Inbound set → poller fires → `clip.changed` pushed back → client re-sets → loop (or at minimum a spurious round-trip and history pollution).
**Do this instead:** Clipboard executor records the hash of the last value it wrote; poller skips a change matching that hash.

## Integration Points

### External Services

None — deliberately. LAN-only, no cloud relay, no internet exposure (security posture in spec §6).

### Internal Boundaries

| Boundary | Communication | Notes |
|----------|---------------|-------|
| Flutter screens ↔ ConnectionService | Riverpod state streams + typed send API | Screens never see frames or sockets |
| ConnectionService ↔ server transport | WebSocket (binary + JSON), UDP beacon (one-way) | The *only* cross-machine seam; fully defined by `protocol/` |
| dispatch ↔ executors | Rust trait calls, sync, protocol-level types | Mock impls swap in for CI |
| server-core ↔ server-windows | Executor traits + a small `Shell` surface (pause flag, session events → tray tooltip) | Tray needs read access to session count and a pause toggle; keep it a narrow interface, not shared mutable config |
| tray/settings ↔ config | `config.toml` at `%APPDATA%/RemoteControl/` | Token hashes, paired devices, port, autostart flag; settings writes, core reads (reload or restart-to-apply — decide in phase) |

## Sources

- [KDE Connect mousepad plugin (AbstractRemoteInput abstraction)](https://invent.kde.org/network/kdeconnect-kde/tree/master/plugins/mousepad) — plugin-per-feature + injection abstraction precedent (HIGH, official repo)
- [KDE Connect remotekeyboard plugin](https://github.com/KDE/kdeconnect-kde/tree/master/plugins/remotekeyboard) — key-event payload design precedent (HIGH, official repo)
- [RustDesk enigo fork](https://github.com/rustdesk/rustdesk/tree/master/libs/enigo) and [RustDesk input processing](https://deepwiki.com/rustdesk/rustdesk/5.2-input-processing-and-keyboard-handling) — production Rust `mouse_move_relative`/SendInput injection (MEDIUM-HIGH)
- [enigo docs](https://docs.rs/enigo/) / [enigo-rs GitHub](https://github.com/enigo-rs/enigo) — cross-platform injection API surface (HIGH, official docs)
- [Axon (Go server + Android client)](https://github.com/Kaia-Alenia/Axon), [Mousedroid](https://github.com/hypertensiune/Mousedroid), [remote-mouse topic](https://github.com/topics/remote-mouse) — architecture convergence sample (MEDIUM)
- [Rust WebSocket guide: tokio-tungstenite patterns (websocket.org)](https://websocket.org/guides/languages/rust/) and [tokio-tungstenite server example](https://github.com/snapview/tokio-tungstenite/blob/master/examples/server.rs) — per-connection tasks + mpsc registry pattern (HIGH, official example)
- [WebSocket reconnection: state sync and recovery (websocket.org)](https://websocket.org/guides/reconnection/) — backoff + jitter + reset-on-success guidance (HIGH)
- [WebSocket reconnection in Flutter](https://medium.com/@punithsuppar7795/websocket-reconnection-in-flutter-keep-your-real-time-app-alive-be289cff46b8) and [Riverpod AsyncNotifier for real-time APIs](https://vibe-studio.ai/insights/using-riverpod-asyncnotifier-for-real-time-apis) — service-owned FSM, reconnect in client layer not notifier (MEDIUM)
- [TCP_NODELAY / Nagle interactive-latency guidance](https://oneuptime.com/blog/post/2026-03-20-tcp-nodelay-nagle-algorithm/view) and [RDP Nagle lag fix](https://windowsforum.com/threads/fix-remote-desktop-lag-disable-nagle-and-delayed-ack-with-tcpnodelay.409016/) — hot-path latency sink #1 (MEDIUM, cross-confirmed)

---
*Architecture research for: phone-as-remote-input (Flutter + Rust LAN remote control)*
*Researched: 2026-07-07*
