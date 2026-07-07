# Phase 2: End-to-End Cursor Spike - Research

**Researched:** 2026-07-08
**Domain:** Real-time relative-cursor input path — Flutter trackpad → WebSocket (TCP_NODELAY) → Rust `server-windows` enigo executor → Windows cursor, with move-frame E2E latency measurement gated at p95 < 30ms
**Confidence:** HIGH (transport, enigo API, echo mechanism verified against official docs + existing Phase-1 code; DPI physical-pixel behavior MEDIUM — device-verify in the spike)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** The spike runs the **real** Phase 1 handshake (hello → challenge → pin/pairOk → auth → authOk), NOT an auth-bypass dev path. Auth is a one-time handshake and does not affect steady-state cursor latency (measured post-auth on move frames).
- **D-02:** Pairing UX in the spike is **minimal**: the tray/console shows the PIN; the app has a bare text field to type it (or a dev-fixed PIN for the owner's own test loop). No polished pairing screens.
- **D-03:** **Raw 1:1 finger-delta passthrough** — phone sends move frames of raw dx/dy deltas; no sensitivity curve, no acceleration in the spike. Sensitivity/acceleration is deferred to the real trackpad phase.
- **D-04:** **Server-side sub-pixel accumulation stays** (criterion 4): the enigo executor accumulates the fractional-pixel remainder across frames so slow diagonal movement tracks smoothly without drift or stair-stepping. DPI awareness (per-monitor DPI, `SetProcessDpiAwarenessContext` or equivalent) is in scope so deltas map to the right physical pixels.
- **D-05:** Latency is surfaced **live on the phone (an on-device HUD)** so "visually instant" and the number are both verified on the real device over real WiFi. Server-side logging of the measurement is also kept for the record.
- **D-06:** Measured on **actual move-frame round-trips (echo), not ping RTT**. The phone stamps a send-time, the server echoes it, and the phone computes end-to-end. Exact echo mechanism left to research/planning; the decision is only that it measures move-frame E2E, displayed live.
- **D-07:** Report **p50 and p95**; treat the gate as **p95 < 30ms** on real WiFi. If p95 fails, trigger the roadmap's UDP-channel reconsideration before Phase 3.
- **D-08:** Build minimal, but the load-bearing parts are **kept as foundation**, not thrown away: the `server-windows` crate + enigo `MouseKeys` executor and the Flutter app scaffold + bare trackpad surface.
- **D-09:** Only the **latency HUD/measurement mode and any dev-pairing shortcut** are spike-only and removable once the gate passes. Everything else survives into the product.

### Claude's Discretion
All nine decisions above are Claude-discretion defaults (user had no preference). Planner may refine details (exact crate/file names, measurement mechanism, DPI API choice, whether a dev-fixed PIN or typed PIN) as long as the observable contract holds: real handshake reused, raw 1:1 cursor with server-side sub-pixel + DPI, live on-device move-frame latency readout gated at p95 < 30ms, and the server-windows executor + app scaffold kept as foundation.

### Deferred Ideas (OUT OF SCOPE)
- Sensitivity / acceleration curves for cursor movement — deferred to the real trackpad phase (Phase 3+); the spike uses raw 1:1.
- Polished pairing/discovery UX (beacon listener, PIN screens, reconnect FSM) — Phase 3.
- Trackpad gestures beyond move/scroll (tap-click, two-finger, drag, buttons, haptics) — later trackpad phase.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PAD-05 | Cursor response is visually instant on same LAN (<30ms end-to-end; TCP_NODELAY both ends, raw pointer events) | This entire document. Criterion 1 (visually instant) verified via on-device HUD; Criterion 2 (<30ms E2E) via move-frame echo measurement (§ Latency Measurement); Criterion 3 (no 40–200ms hitches) via TCP_NODELAY on BOTH ends — server side already done in Phase 1 (`set_nodelay(true)`), Dart side via the `HttpClient.connectionFactory` construction path (§ Standard Stack + § Code Examples); Criterion 4 (smooth diagonals) via server-side sub-pixel accumulation + enigo `set_dpi_awareness` (§ Sub-Pixel Accumulation + § enigo). |
</phase_requirements>

## Summary

This spike proves the WebSocket-only transport can move the real Windows cursor with p95 move-frame end-to-end latency under 30ms on real WiFi. Almost all the transport machinery already exists and is proven from Phase 1: `server-core::run(listener, deps)` accepts connections, applies `set_nodelay(true)` server-side, runs the real handshake FSM, and routes binary `0x01` move / `0x02` scroll frames to `Executors.mouse_keys.move_rel(dx, dy)` / `.scroll(dx, dy)`. The Dart 9-byte binary codec (`encodeMove`/`encodeScroll`) and the `ping`/`pong` JSON echo path (both carry a `ts: u64`, and the router already replies `Ping{ts} → Pong{ts}`) also already exist. The spike is therefore *thin*: three genuinely new pieces — (1) a `server-windows` crate that builds `ServerDeps` with a real enigo `MouseKeys` executor and calls `server_core::run`; (2) a Flutter app scaffold with a `Listener`-based trackpad that encodes raw pointer deltas into move frames; (3) a move-frame echo measurement + on-device HUD.

**The single highest-risk item is Dart-side TCP_NODELAY** (STATE.md Phase-2 blocker, PITFALLS #3). `web_socket_channel` 3.0.3's `WebSocketChannel.connect` and `IOWebSocketChannel.connect` do **not** expose a socket-option hook directly, and `dart:io` sockets default to Nagle enabled. The verified construction path is `IOWebSocketChannel.connect(url, customClient: HttpClient()..connectionFactory = <factory that sets SocketOption.tcpNoDelay>)`. The `connectionFactory` callback (added to `HttpClient` for exactly this kind of low-level socket control) receives `(Uri, String? proxyHost, int? proxyPort)`, returns `Future<ConnectionTask<Socket>>`, and is the seam where `socket.setOption(SocketOption.tcpNoDelay, true)` is applied before the WebSocket upgrade rides over it. This must be verified empirically in the spike (send a burst of slow 1px moves, confirm no 40–200ms hitches) — it is criterion 3's make-or-break.

The second-order risks are all well-understood: enigo is not `Sync` and must live on a dedicated OS input thread fed by an mpsc channel from tokio (so injection stays off the async runtime and the `MouseKeys` trait's sync `&self` contract is honored); Windows applies pointer acceleration to injected relative moves (accepted for the spike per D-03 raw 1:1, but the HUD/feel readout must interpret "smooth" against that reality); and `set_dpi_awareness()` must be called once at startup or coordinate mapping is DPI-virtualized on scaled displays.

**Primary recommendation:** Reuse Phase 1's transport untouched. Add `server-windows` with an enigo executor on a dedicated input thread (mpsc-fed, `set_dpi_awareness()` at startup, f32 sub-pixel accumulator flushing integer deltas to `move_mouse(.., Coordinate::Rel)`). Build the Flutter trackpad on `Listener` (never `GestureDetector`) with the `HttpClient.connectionFactory` TCP_NODELAY construction. Measure move-frame E2E by extending the existing `ping{ts}`/`pong{ts}` echo (or an interleaved stamped move-echo) and display p50/p95 live on the phone. Gate on p95 < 30ms; if it fails, the UDP-channel escape hatch behind the transport trait is the roadmap-sanctioned next step.

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Raw pointer capture (finger deltas) | Flutter client (trackpad screen) | — | `Listener` raw `PointerMove` is the only tier that sees touch input; deltas are logical pixels here (see DPI pitfall). |
| Binary move/scroll frame encoding | Flutter client (`remote_protocol` package) | — | Codec already exists and is fixture-proven; client imports via path dependency. No new codec work. |
| TCP_NODELAY on client socket | Flutter client (`ConnectionService`/connector) | — | Must be set on the `dart:io` Socket the WebSocket rides over — only the client owns that socket construction. |
| WebSocket accept + `set_nodelay` server-side | `server-core` transport | — | Already done in Phase 1; the spike does not touch it. |
| Handshake / auth gating | `server-core` transport (session FSM) | — | Reused verbatim (D-01). Zero new auth code. |
| Binary frame routing → executor | `server-core` dispatch (`route_binary`) | — | Already routes `Move`/`Scroll` to `mouse_keys`. Reused. |
| OS cursor injection (SendInput) | `server-windows` enigo executor | — | The whole reason enigo+windows deps live ONLY in `server-windows`; `server-core` stays zero-Windows-deps (Phase 1 invariant). |
| Sub-pixel accumulation + DPI mapping | `server-windows` enigo executor | — | enigo takes integer pixel deltas; fractional remainder + DPI awareness are OS-injection concerns, belong next to the injector. |
| Dedicated input thread + mpsc | `server-windows` composition root | — | `Enigo` is `!Sync`; must not run on the tokio runtime. Thread-owned, channel-fed. |
| Move-frame echo (server side) | `server-core` router (`ping`→`pong` echo) | `server-windows` (logging) | Echo already exists in core (`Ping{ts}→Pong{ts}`); keep the measurement wire path OS-agnostic. |
| Latency HUD (p50/p95 display) | Flutter client (trackpad overlay) | — | D-05: measured and shown on the real device over real WiFi. |

## Standard Stack

All packages are **locked by spec** (CLAUDE.md) and were **registry-verified on 2026-07-07** (crates.io / pub.dev, per `.planning/research/STACK.md`). This phase introduces **no new package selection** — it activates the already-chosen `server-windows` crate deps (enigo, windows) and the already-chosen Flutter client deps. Versions below are the locked/verified values; the planner should re-confirm with `cargo add`/`flutter pub add` at implementation and flag any API drift (Phase 1 hit `rand`/`hmac` renames — expect similar for enigo 0.5→0.6).

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| enigo | 0.6.1 | Relative cursor move + scroll injection (SendInput) on Windows | [CITED: docs.rs/enigo/0.6.1] Cross-platform input crate locked by spec; `Mouse::move_mouse(x, y, Coordinate::Rel)` and `scroll` cover the spike; `set_dpi_awareness()` handles Windows scaling. |
| windows | 0.62 | Raw Win32 fallback (only if enigo's relative-move behavior blocks a criterion) | [ASSUMED] Microsoft's official crate; not required for the move path if enigo works. Kept available per CLAUDE.md alternatives. |
| tokio | 1.52 | Async runtime hosting `server_core::run` + the mpsc bridge to the input thread | [VERIFIED: Cargo.lock] Already in `server-core`; `server-windows` inherits via workspace. |
| tokio-tungstenite | 0.29 | WebSocket server (via `server-core`) | [VERIFIED: Cargo.lock] Already wired in Phase 1; `server-windows` does not touch it directly. |
| Flutter SDK | 3.44 stable | Client framework | [CITED: CLAUDE.md] Locked. |
| web_socket_channel | 3.0.3 | WebSocket client — **specifically `IOWebSocketChannel.connect` with `customClient`** | [CITED: pub.dev/packages/web_socket_channel] `IOWebSocketChannel.connect` forwards a `customClient: HttpClient` to `WebSocket.connect`; that HttpClient's `connectionFactory` is where TCP_NODELAY is set. This is the criterion-3 construction path. |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| flutter_riverpod | 3.3.2 | State for `ConnectionService` + throttled HUD provider | Keep the hot path (pointer→encode→sink) OUT of the widget tree; only the throttled latency stats go through a provider (PITFALLS #4). |
| wakelock_plus | 1.6.1 | Keep screen awake on the trackpad screen | D-05/spec: trackpad screen must not dim mid-measurement; acquire on screen enter, release on exit. |
| `dart:io` `HttpClient` + `Socket` | built-in | The `connectionFactory` seam for TCP_NODELAY | Built-in; no package. `Socket.startConnect` → `ConnectionTask<Socket>`, set option on the resolved socket. |
| tracing + tracing-subscriber | 0.1 / 0.3 | Server-side latency logging (D-05 "kept for the record") | `server-windows` binary owns the subscriber; core stays log-silent (session.rs is deliberately log-free). |
| anyhow | 1.0 | Error handling in the `server-windows` binary | thiserror stays in core; anyhow in the binary (CLAUDE.md convention). |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| enigo `move_mouse(Coordinate::Rel)` | Raw `SendInput` via `windows` crate | Only if enigo's relative move is blocked by a criterion; loses the cross-platform trait story. Drop to it per-call behind `MouseKeys`, not wholesale. |
| `IOWebSocketChannel.connect(customClient:)` | `dart:io WebSocket.connect(customClient:)` directly, then wrap in `IOWebSocketChannel(ws)` | Equivalent; the `IOWebSocketChannel.connect` factory already forwards `customClient`, so the extra unwrap is unnecessary. Use the factory. |
| ping/pong echo for measurement | A dedicated stamped move-echo opcode | The wire protocol is FROZEN (Phase 1). `ping{ts}`/`pong{ts}` already exists and echoes `ts` — no new opcode needed. See Latency Measurement for the move-frame-vs-ping nuance. |
| Server-side sub-pixel accumulation | Client-side accumulation | D-04 locks it server-side (accuracy plumbing next to the injector; keeps client raw 1:1). |

**Installation:**
```toml
# server/Cargo.toml — add member
[workspace]
members = ["server-core", "server-windows"]

# server/server-windows/Cargo.toml (NEW)
[package]
name = "server-windows"
edition.workspace = true
rust-version.workspace = true

[dependencies]
server-core = { path = "../server-core" }
enigo = "0.6"
windows = { version = "0.62", features = ["Win32_Foundation", "Win32_UI_HiDpi"] }  # HiDpi only if calling SetProcessDpiAwarenessContext directly; omit if enigo::set_dpi_awareness suffices
tokio = { version = "1.52", features = ["rt-multi-thread", "net", "sync", "time", "macros"] }
tracing = "0.1"
tracing-subscriber = { version = "0.3", features = ["env-filter"] }
anyhow = "1"
```
```yaml
# app/<flutter_app>/pubspec.yaml (NEW Flutter app alongside packages/remote_protocol)
dependencies:
  flutter_riverpod: ^3.3.2
  web_socket_channel: ^3.0.3
  wakelock_plus: ^1.6.1
  remote_protocol:
    path: ../packages/remote_protocol
```

**Version verification (planner MUST run at implementation):**
```bash
cargo add enigo@0.6 --dry-run          # confirm 0.6.1 API: Mouse::move_mouse(x,y,Coordinate), set_dpi_awareness
cargo add windows@0.62 --dry-run
flutter pub add web_socket_channel     # confirm 3.0.3, IOWebSocketChannel.connect(customClient:)
flutter pub add wakelock_plus
```
enigo's crate release (0.6.1, Aug 2025) lags its active repo (pushed 2026-07-01) — a 0.7 with breaking API changes may land mid-project; pin `enigo = "=0.6.1"` if churn is a concern (STACK.md caveat).

## Package Legitimacy Audit

All packages are from the spec-locked stack, verified against their authoritative registries on 2026-07-07 (crates.io / pub.dev per STACK.md). This phase adds **no** newly-discovered or unvetted packages.

| Package | Registry | Age | Downloads | Source Repo | Verdict | Disposition |
|---------|----------|-----|-----------|-------------|---------|-------------|
| enigo | crates.io | 0.6.1 (Aug 2025); repo active 2026-07-01 | high (established input crate) | github.com/enigo-rs/enigo | OK | Approved (locked by spec) |
| windows | crates.io | Microsoft official, long-lived | very high | github.com/microsoft/windows-rs | OK | Approved (locked by spec) |
| tokio | crates.io | 1.52 (May 2026) | very high | github.com/tokio-rs/tokio | OK | Approved (already in tree) |
| web_socket_channel | pub.dev | Dart-team owned | very high | github.com/dart-lang/web_socket_channel | OK | Approved (locked by spec) |
| flutter_riverpod | pub.dev | 3.3.2 | very high | github.com/rrousselGit/riverpod | OK | Approved (locked by spec) |
| wakelock_plus | pub.dev | 1.6.1 | high | github.com/fluttercommunity/wakelock_plus | OK | Approved (locked by spec) |

**Packages removed due to [SLOP] verdict:** none
**Packages flagged as suspicious [SUS]:** none

## Architecture Patterns

### System Architecture Diagram

```
[Finger on phone] 
      │ raw PointerMove (logical px deltas)
      ▼
┌─ Flutter trackpad (Listener) ──────────────────────────────────┐
│  onPointerMove → controller (NO setState on hot path)          │
│     │ dx,dy                                                     │
│     ▼                                                           │
│  remote_protocol.encodeMove(dx,dy)  ──►  9-byte binary frame   │
│     │                                                           │
│     ▼                                                           │
│  ConnectionService.sink.add(frame)   (fire-and-forget)         │
│  latency: stamp send-time on echo probe (ping{ts} / stamped)   │
└──────────────────────┬──────────────────────────────────────────┘
                       │ WebSocket over Socket with TCP_NODELAY=true
                       │ (HttpClient.connectionFactory sets the option)
                       ▼
┌─ server-core transport (Phase 1, UNCHANGED) ────────────────────┐
│  accept_loop → set_nodelay(true) → run_session (handshake FSM)  │
│     post-auth Message::Binary → binary::decode → route_binary   │
│        Move{dx,dy} → executors.mouse_keys.move_rel(dx,dy)       │
│     Message::Text ping{ts} → router → pong{ts}  (echo)          │
└──────────────────────┬──────────────────────────────────────────┘
                       │ move_rel(dx,dy)  (sync trait call, hot path)
                       ▼
┌─ server-windows enigo executor (NEW) ───────────────────────────┐
│  MouseKeys::move_rel  → mpsc.send(Cmd::Move(dx,dy))  (non-block) │
│                                    │                             │
│   ┌── dedicated input thread ─────▼───────────────────────────┐ │
│   │  Enigo (!Sync) lives here                                 │ │
│   │  accumulate f32 remainder → integer (ix,iy)               │ │
│   │  enigo.move_mouse(ix, iy, Coordinate::Rel)  → SendInput   │ │
│   └───────────────────────────────────────────────────────────┘ │
└──────────────────────┬──────────────────────────────────────────┘
                       ▼
              [Real Windows cursor moves]
                       │ (pong / echo returns over same NODELAY socket)
                       ▼
              [Phone computes E2E, updates p50/p95 HUD]
```

### Recommended Project Structure
```
server/
├── Cargo.toml                    # add "server-windows" to members
├── server-core/                  # UNCHANGED (zero Windows deps invariant)
└── server-windows/               # NEW crate
    ├── Cargo.toml
    └── src/
        ├── main.rs               # composition root: subscriber, bind, build ServerDeps, run
        ├── input_thread.rs       # dedicated thread owning Enigo + mpsc receiver
        └── executors/
            └── mouse_keys.rs     # EnigoMouseKeys: impl MouseKeys, sends Cmd to input thread

app/
├── packages/
│   └── remote_protocol/          # UNCHANGED (codec reused via path dep)
└── remote_control/               # NEW Flutter app
    └── lib/
        ├── main.dart
        ├── net/
        │   ├── connection_service.dart   # IOWebSocketChannel + TCP_NODELAY connectionFactory
        │   └── handshake.dart            # real hello→challenge→pin/auth→authOk (reuses remote_protocol JSON)
        ├── trackpad/
        │   ├── trackpad_screen.dart      # Listener-based surface
        │   └── move_sender.dart          # pointer delta → encodeMove → sink
        └── hud/
            └── latency_hud.dart          # p50/p95 overlay (throttled provider)
```

### Pattern 1: Sync trait over async runtime via dedicated input thread
**What:** `MouseKeys` is a **sync** trait (`&self`, `Send + Sync`) but `Enigo` is `!Sync`. The executor's `move_rel` must return immediately (hot path, called inline in the read task per `executors/mod.rs` docs) and must not block the tokio runtime. Solution: `move_rel` sends a `Cmd` over an `mpsc::Sender` (a `std::sync::mpsc` or `crossbeam` channel — sync, non-async) to a dedicated OS thread that owns the `Enigo` and does the actual injection.
**When to use:** Always for enigo on Windows — it is the CLAUDE.md/STACK.md mandated pattern.
**Example:**
```rust
// server-windows/src/executors/mouse_keys.rs
// Source: STACK.md "enigo on Windows" caveat + executors/mod.rs sync-trait contract
use std::sync::mpsc::Sender;
use server_core::executors::MouseKeys;

pub enum Cmd { Move(f32, f32), Scroll(f32, f32) /* ...later: click/key */ }

pub struct EnigoMouseKeys { tx: Sender<Cmd> }

impl MouseKeys for EnigoMouseKeys {
    fn move_rel(&self, dx: f32, dy: f32) {
        // Non-blocking send; drop on full/closed (send-and-forget, hot path).
        let _ = self.tx.send(Cmd::Move(dx, dy));
    }
    fn scroll(&self, dx: f32, dy: f32) { let _ = self.tx.send(Cmd::Scroll(dx, dy)); }
    // Spike stubs the rest (click/button/key/text) — Phase 4 fills them.
    fn click(&self, _b: server_core::executors::Button) {}
    fn button_down(&self, _b: server_core::executors::Button) {}
    fn button_up(&self, _b: server_core::executors::Button) {}
    fn key_down(&self, _c: server_core::executors::KeyCode) {}
    fn key_up(&self, _c: server_core::executors::KeyCode) {}
    fn key_tap(&self, _c: server_core::executors::KeyCode, _m: &[server_core::executors::Modifier]) {}
    fn type_text(&self, _t: &str) {}
    fn backspace(&self, _n: u32) {}
}
```
> Note: `move_rel`/`scroll` in `MouseKeys` take `f32`; `route_binary` passes the frame's `f32` deltas straight through. The sub-pixel accumulation therefore happens on the **input thread** (which converts `f32` → integer for enigo), NOT in the trait method — keep `move_rel` a pure non-blocking send.

### Pattern 2: Sub-pixel accumulation on the input thread
**What:** enigo's `move_mouse` takes **integer** pixel deltas. Naively truncating each frame's `f32` delta to `i32` loses the fractional remainder, so slow diagonal drags (e.g. 0.4px/frame) stair-step or never move. Accumulate a running `f32` remainder per axis; each frame add the incoming delta, take the integer part, inject it, carry the fraction.
**When to use:** Always (D-04 locks it in for criterion 4).
**Example:**
```rust
// server-windows/src/input_thread.rs
// Source: PITFALLS #2 (delta scaling) + enigo integer-delta constraint
use enigo::{Enigo, Mouse, Coordinate, Settings};

pub fn run_input_thread(rx: std::sync::mpsc::Receiver<Cmd>) {
    // MUST be created on this thread (Enigo is !Sync). set_dpi_awareness at
    // process start (see Pattern 3) BEFORE any Enigo coordinate op.
    let mut enigo = Enigo::new(&Settings::default()).expect("enigo init");
    let (mut acc_x, mut acc_y) = (0.0f32, 0.0f32);
    let (mut sacc_x, mut sacc_y) = (0.0f32, 0.0f32);
    while let Ok(cmd) = rx.recv() {
        match cmd {
            Cmd::Move(dx, dy) => {
                acc_x += dx; acc_y += dy;
                let ix = acc_x.trunc() as i32;   // integer part
                let iy = acc_y.trunc() as i32;
                acc_x -= ix as f32;              // carry fraction
                acc_y -= iy as f32;
                if ix != 0 || iy != 0 {
                    let _ = enigo.move_mouse(ix, iy, Coordinate::Rel);
                }
            }
            Cmd::Scroll(dx, dy) => {
                // enigo scroll takes integer wheel units; accumulate too.
                sacc_x += dx; sacc_y += dy;
                let sx = sacc_x.trunc() as i32;
                let sy = sacc_y.trunc() as i32;
                sacc_x -= sx as f32; sacc_y -= sy as f32;
                if sy != 0 { let _ = enigo.scroll(sy, enigo::Axis::Vertical); }
                if sx != 0 { let _ = enigo.scroll(sx, enigo::Axis::Horizontal); }
            }
        }
    }
}
```
> `enigo::Axis` and the exact `scroll(length, axis)` signature must be confirmed against 0.6.1 at implementation (docs.rs shows `scroll` uses an `Axis` enum; sign convention for wheel direction is device/OS-dependent — verify in the smoke test).

### Pattern 3: DPI awareness at process startup
**What:** Without declaring DPI awareness, Windows virtualizes coordinate APIs on scaled (125%/150%) displays, so injected deltas map to the wrong physical pixels — drift and mismatch (PITFALLS #2). enigo added a `set_dpi_awareness()` helper (since 0.4.0) that calls the Win32 API for you.
**When to use:** Once, at the very start of `main` (before spawning the input thread / any Enigo op).
**Example:**
```rust
// server-windows/src/main.rs
// Source: docs.rs/enigo (set_dpi_awareness note) + PITFALLS #2
fn main() -> anyhow::Result<()> {
    // Prefer enigo's helper; if 0.6.1 signature differs, fall back to the
    // windows crate: SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2).
    enigo::set_dpi_awareness().ok();   // confirm exact name/return at impl
    // ... tracing subscriber, tokio runtime, bind, ServerDeps, run
    Ok(())
}
```
> [ASSUMED] exact symbol is `enigo::set_dpi_awareness` — WebSearch confirmed such a helper was added in 0.4.0 but its 0.6.1 module path/signature must be confirmed (`cargo doc --open` or docs.rs). Fallback: `windows` crate `SetProcessDpiAwarenessContext(DPI_AWARENESS_CONTEXT_PER_MONITOR_AWARE_V2)` (needs `Win32_UI_HiDpi` feature).

### Pattern 4: TCP_NODELAY on the Dart client socket (the criterion-3 unlock)
**What:** `web_socket_channel` gives no direct socket-option API. `dart:io` sockets default to Nagle **on**. The verified path: build an `HttpClient`, set its `connectionFactory` to a callback that connects a `Socket` and calls `setOption(SocketOption.tcpNoDelay, true)`, then pass that client as `customClient` to `IOWebSocketChannel.connect`. See § Code Examples for the full, corrected snippet.
**When to use:** For every WebSocket the client opens (the spike, and every later phase — this becomes the permanent `ConnectionService` construction).

### Pattern 5: Composition root wires ServerDeps and calls server_core::run
**What:** `server-windows/main.rs` is the composition root: bind the listener, build `Executors { mouse_keys: Arc::new(EnigoMouseKeys{tx}), .. }` (mock/stub the other four executors for the spike), build the `AuthManager` and `pause` watch, assemble `ServerDeps`, and `server_core::run(listener, deps).await`.
**When to use:** This is the `server-windows` `main`. Keep it thin — all protocol logic stays in core.
**Example:**
```rust
// server-windows/src/main.rs (sketch)
// Source: server-core transport/mod.rs ServerDeps + run() signature
let (tx, rx) = std::sync::mpsc::channel::<Cmd>();
std::thread::spawn(move || input_thread::run_input_thread(rx));
let executors = server_core::executors::Executors {
    mouse_keys: std::sync::Arc::new(EnigoMouseKeys { tx }),
    media: /* stub */, power: /* stub */, apps: /* stub */, clipboard: /* stub */,
};
let auth = std::sync::Arc::new(std::sync::Mutex::new(AuthManager::new(/* spike PIN cfg */)));
let (_pause_tx, pause_rx) = tokio::sync::watch::channel(false);
let listener = tokio::net::TcpListener::bind(("0.0.0.0", PORT)).await?;
server_core::run(listener, ServerDeps { executors, auth, pause: pause_rx }).await;
```
> The four non-mouse executors need *some* impl to build `Executors`. For the spike, provide trivial no-op stubs in `server-windows` (NOT the core mocks — those live under `#[cfg(test)]`/`mock` and shouldn't be a runtime dep). Keep them as the seed for Phases 4–6.

### Anti-Patterns to Avoid
- **`GestureDetector.onPanUpdate` for the trackpad:** swallows the first ~8–18px (touch slop) and adds arena delay — cursor feels "sticky," ignores tiny nudges (PITFALLS #4). Use `Listener` + raw `PointerMove` from the start.
- **`setState`/provider notify per pointer event:** rebuild storms at 60–120Hz. Hot path = pointer → controller → encoder → sink, zero widget rebuilds. HUD updates via a throttled (~4Hz) provider with Riverpod `select`.
- **Running `Enigo` on the tokio runtime / behind an async lock:** it's `!Sync`; blocks the runtime and violates the sync-trait hot-path rule. Dedicated thread + mpsc.
- **Truncating each frame's delta to int without carrying the remainder:** stair-steps slow diagonals (criterion 4 failure).
- **App-level batching/queuing on the move path:** adds latency and defeats fire-and-forget; also queued deltas teleport the cursor on reconnect (spec §8). Send-and-drop.
- **Default `WebSocketChannel.connect` (no customClient):** leaves Nagle on — the exact bug that produces 40–200ms hitches on real WiFi.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| WebSocket accept + handshake + auth gating | A new spike-only server loop | `server_core::run` (Phase 1) | Fully tested; D-01 mandates the real handshake; re-implementing invites drift from the frozen protocol. |
| Binary move/scroll encoding | New Dart encoder in the app | `remote_protocol.encodeMove/encodeScroll` | Fixture-proven byte-identical to Rust decoder; path-dependency import. |
| Move-frame echo timestamp field | A new stamped opcode (protocol change) | Existing `ping{ts}`/`pong{ts}` JSON echo (router already replies) | Wire protocol is FROZEN; `ts:u64` echo already round-trips. |
| Nagle disable on Dart | A raw socket + hand-rolled WS framing | `IOWebSocketChannel.connect(customClient: HttpClient()..connectionFactory=...)` | Keeps the standard channel Stream/Sink interface while getting socket control. |
| DPI awareness Win32 call | Hand-written `SetProcessDpiAwarenessContext` FFI | `enigo::set_dpi_awareness()` (confirm symbol) | enigo already wraps it; fall back to `windows` crate only if the helper is missing/renamed. |
| Windows relative move / SendInput | Direct `SendInput` FFI | `enigo.move_mouse(dx, dy, Coordinate::Rel)` | Cross-platform trait story is why enigo was locked; drop to raw only per-call if blocked. |

**Key insight:** This spike is ~90% wiring of proven Phase-1 parts. The only genuinely new *logic* is (a) the input-thread + sub-pixel accumulator, (b) the DPI call, and (c) the Dart TCP_NODELAY construction. Everything else is composition. Resist re-solving transport.

## Common Pitfalls

### Pitfall 1: Dart Nagle left on → 40–200ms cursor hitches (criterion 3 killer)
**What goes wrong:** Cursor is smooth in bursts but rubber-bands / hitches during slow precise movement on real WiFi, even though ping RTT looks like 1–3ms. Small 9-byte frames at 60–120Hz interact with Nagle + delayed ACKs.
**Why it happens:** `dart:io` sockets default Nagle **on**, and `WebSocketChannel.connect` gives no option to disable it. Server side is already fixed (Phase 1 `set_nodelay(true)`); the client side is the untested half.
**How to avoid:** Use the `HttpClient.connectionFactory` construction (§ Code Examples) to set `SocketOption.tcpNoDelay, true` on the underlying socket. **Empirically verify** in the spike — do a slow-diagonal drag and watch the HUD tail (p95); no 40–200ms spikes means it's active. Consider logging on the server the inter-arrival gaps of move frames as a cross-check.
**Warning signs:** HUD shows low median but a fat p95 tail; smooth on emulator/localhost, janky on the real phone over WiFi.

### Pitfall 2: enigo `!Sync` on tokio → won't compile or blocks the runtime
**What goes wrong:** Trying to hold an `Enigo` inside the `Executors` struct (which is `Clone` and shared across async tasks) fails `Send + Sync` bounds, or, if forced behind a `Mutex`, serializes injection on the runtime.
**Why it happens:** `Enigo` is not `Sync`; the `MouseKeys` trait requires `Send + Sync`.
**How to avoid:** Own `Enigo` on a dedicated `std::thread`; the executor holds only an mpsc `Sender` (which is `Send + Sync`). `move_rel` = non-blocking `send`.
**Warning signs:** Compiler errors about `Enigo: !Sync`; or injection latency climbs under load.

### Pitfall 3: Missing DPI awareness → drift on scaled displays
**What goes wrong:** On a 150%-scaled monitor, injected deltas move the cursor the wrong distance; slow diagonals drift off-line. Passes on the dev machine at 100%.
**Why it happens:** Windows DPI-virtualizes coordinate APIs for non-DPI-aware processes.
**How to avoid:** Call `set_dpi_awareness()` (or `SetProcessDpiAwarenessContext(PER_MONITOR_AWARE_V2)`) once at startup, before any Enigo op. Test on a 150% display.
**Warning signs:** Cursor tracks fine at 100% scaling, drifts/mis-scales at 125%/150%.

### Pitfall 4: Measuring ping RTT, not move-frame E2E (criterion 2 explicitly forbids this)
**What goes wrong:** The HUD shows a flattering number that doesn't reflect what the cursor actually experiences — a bare `ping` may traverse a different (non-hot) code path than a binary move frame.
**Why it happens:** It's easier to time a JSON ping round-trip than to instrument the move path.
**How to avoid:** Time an echo that rides the **same socket under the same load as move frames**. Two viable mechanisms (see Latency Measurement): (a) interleave `ping{ts}` frames *within the move stream* while dragging, so the ping shares the NODELAY socket and queue with moves — measures the transport the moves use; (b) a spike-only stamped-move-echo if a spare binary opcode is acceptable (it changes the frozen protocol — prefer (a)). Report **round-trip** and derive one-way as RTT/2 (no clock sync needed — see clock-sync note).
**Warning signs:** Latency number is suspiciously stable and low while the cursor visibly stutters.

### Pitfall 5: Clock-sync trap in one-way latency
**What goes wrong:** Trying to compute true one-way latency by comparing a phone send-timestamp to a server receive-timestamp requires synchronized clocks (phone vs PC); without NTP-grade sync the number is garbage (can even be negative).
**Why it happens:** Two independent clocks; even a few ms of skew dominates a <30ms budget.
**How to avoid:** Use a **round-trip** measurement stamped and compared on the **same device** (phone stamps `ts` on send, server echoes `ts` verbatim, phone computes `now - ts`). No cross-device clock comparison. Report round-trip; if a one-way figure is wanted, use RTT/2 as the documented approximation. This is exactly what the existing `ping{ts}`/`pong{ts}` echo enables (server copies `ts` unchanged).
**Warning signs:** One-way latency occasionally negative or wildly variable; measurement code reads the server clock.

### Pitfall 6: Hot-path widget rebuilds on the phone
**What goes wrong:** Jank at 120Hz input, dropped frames, and inflated measured latency because the UI thread is busy rebuilding.
**Why it happens:** Updating a provider / calling `setState` per `PointerMove` (e.g. to show live coords or the HUD number).
**How to avoid:** Keep pointer→encode→sink out of the widget tree entirely. HUD/stats update through a throttled provider (~4Hz) with `select`-scoped rebuilds.
**Warning signs:** DevTools shows rebuild storms during trackpad use.

### Pitfall 7: WiFi power-save latency spikes off-charger
**What goes wrong:** 100–300ms spikes appear only on battery after the radio idles — invisible when USB-debugging (charging disables Doze and reduces power-save).
**Why it happens:** Android WiFi power-save idles the radio.
**How to avoid:** For the spike measurement, at minimum test **off-charger**. wakelock_plus keeps the screen on (helps). A `WIFI_MODE_FULL_LOW_LATENCY` lock is the full mitigation but is deferred to the real trackpad phase; note whether spikes appear and whether they're power-save-shaped (periodic) vs Nagle-shaped (traffic-pattern-dependent).
**Warning signs:** Clean p95 on charger, fat tail on battery.

## Code Examples

### TCP_NODELAY Dart client construction (criterion 3 — the key snippet)
```dart
// app/remote_control/lib/net/connection_service.dart
// Source: [CITED] api.dart.dev/dart-io/HttpClient/connectionFactory +
//         pub.dev IOWebSocketChannel.connect(customClient:) +
//         SocketOption.tcpNoDelay. VERIFY empirically in the spike.
import 'dart:io';
import 'package:web_socket_channel/io.dart';

Future<IOWebSocketChannel> connectNoDelay(Uri wsUri) async {
  final httpClient = HttpClient()
    ..connectionFactory = (Uri uri, String? proxyHost, int? proxyPort) {
      // startConnect returns Future<ConnectionTask<Socket>>. Attach the
      // socket option once the ConnectionTask's socket future resolves,
      // while still returning a ConnectionTask (so cancellation works).
      final taskFuture = Socket.startConnect(uri.host, uri.port);
      return taskFuture.then((task) {
        // Wrap: set TCP_NODELAY as soon as the socket connects.
        final wrapped = task.socket.then((socket) {
          socket.setOption(SocketOption.tcpNoDelay, true);
          return socket;
        });
        return ConnectionTask<Socket>.fromSocket(wrapped, task.cancel);
      });
    };

  return IOWebSocketChannel.connect(wsUri, customClient: httpClient);
}
```
> [ASSUMED] the exact `ConnectionTask.fromSocket` re-wrap shape — `ConnectionTask` exposes `.socket` (a `Future<Socket>`) and `.cancel`. If `ConnectionTask.fromSocket` is not public in the SDK version, the simpler correct form is to `await Socket.startConnect(...).then((t) => t.socket)`, set the option, and hand back a `ConnectionTask` — OR use the even simpler `Socket.connect(host, port).then((s){ s.setOption(...); ... })` inside a manual `ConnectionTask`. The planner MUST spike this exact construction against `web_socket_channel` 3.0.3 / current Dart SDK and confirm the option actually reaches the socket (empirical hitch test). This is the phase's #1 verify-in-code item.

### Existing echo path (server side — already implemented, reused as-is)
```rust
// server-core/src/dispatch/router.rs (EXISTING)
Msg::Ping(p) => vec![Msg::Pong(PongPayload { ts: p.ts })],  // echoes ts verbatim
```
```dart
// phone: stamp on send, compute on receive (round-trip, single-clock)
final sentAt = DateTime.now().microsecondsSinceEpoch; // ts
sink.add(encodePing(sentAt));                          // JSON ping{ts}
// on pong{ts}: rttMicros = DateTime.now().microsecondsSinceEpoch - ts
```

### enigo relative move (input thread)
```rust
// Source: [CITED] docs.rs/enigo/0.6.1 Mouse::move_mouse(x, y, Coordinate)
use enigo::{Enigo, Mouse, Coordinate, Settings};
let mut enigo = Enigo::new(&Settings::default())?;   // on the dedicated thread
enigo.move_mouse(dx_int, dy_int, Coordinate::Rel)?;  // relative delta
```

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| enigo `MouseControllable` trait, `mouse_move_relative(x,y)` | `Mouse` trait, `move_mouse(x, y, Coordinate::Rel)` returning `InputResult` | enigo 0.2→0.6 API overhaul | Old snippets won't compile; methods now return `Result<(), InputError>`. |
| `WebSocket.connect(url)` (no socket control) | `WebSocket.connect(url, customClient:)` / `IOWebSocketChannel.connect(customClient:)` | dart:io added `customClient` + `HttpClient.connectionFactory` | Enables TCP_NODELAY without leaving the channel abstraction. |
| Measuring latency via ping RTT only | Move-frame E2E echo on the same NODELAY socket | This phase (D-06) | Criterion 2 is explicit; ping-only measurement is disallowed. |

**Deprecated/outdated:**
- enigo `MouseControllable`/`mouse_move_relative` (pre-0.3) — replaced by the `Mouse` trait.
- `GestureDetector.onPanUpdate` for raw input streaming — use `Listener`.

## Runtime State Inventory

> Not a rename/refactor/migration phase — this section is N/A. The spike ADDS new crates/dirs (`server-windows`, Flutter app) and touches no stored data, live-service config, OS-registered state, secrets, or existing build artifacts. **Nothing to migrate — verified: this is greenfield scaffolding on top of Phase 1's frozen contract.**

## Validation Architecture

> Nyquist validation is enabled (config default). Note: this phase is a **latency-retirement spike** — its headline acceptance is a **manual on-device measurement**, not a CI-automatable one (input injection and real-WiFi latency are explicitly not CI-testable, spec §9). Automated tests cover the *plumbing correctness* around the manual gate.

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Rust) | `cargo test` (built-in) + existing `#[tokio::test]` harness in `server-core`; optional `cargo-nextest` |
| Framework (Dart) | `flutter test` (default with Flutter 3.44) |
| Config file | none custom — Cargo + Flutter defaults |
| Quick run command (Rust) | `cargo test -p server-windows` |
| Quick run command (Dart) | `flutter test` in the app dir |
| Full suite command | `cargo test --workspace && (cd app/remote_control && flutter test)` |
| Manual gate | On-device HUD read on real WiFi, off-charger: p50 + p95 over a sustained slow-diagonal drag; **gate = p95 < 30ms** |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PAD-05 (crit 1) | Cursor visually instant on real WiFi | manual-only | on-device observation + HUD | ❌ manual |
| PAD-05 (crit 2) | Move-frame E2E p95 < 30ms (echo, not ping RTT) | manual measurement | on-device HUD p50/p95 readout; server log cross-check | ❌ manual (Wave 0: build HUD) |
| PAD-05 (crit 3) | No 40–200ms hitches; TCP_NODELAY both ends | unit + manual | `cargo test -p server-core` asserts server `set_nodelay` path (existing); Dart: `flutter test` asserts `connectionFactory` sets `tcpNoDelay` on a fake socket; manual hitch test | ❌ Wave 0 (Dart nodelay unit test) |
| PAD-05 (crit 4) | Smooth diagonals — sub-pixel accumulation + DPI | unit + manual | `cargo test -p server-windows::input_thread` — feed 0.4px/frame stream, assert cumulative integer output matches (no lost fraction, no stair-step) | ❌ Wave 0 (accumulator unit test) |
| — | Real handshake reused (D-01) | integration | existing `server-core` integration suite still green with the real executor wired | ✅ (Phase 1 suite) |

### Sampling Rate
- **Per task commit:** `cargo test -p server-windows` (accumulator + wiring) / `flutter test` (nodelay factory + encoder use)
- **Per wave merge:** `cargo test --workspace && flutter test`
- **Phase gate:** Full suite green **AND** the manual on-device p95 < 30ms measurement passes on real WiFi off-charger. If p95 fails → invoke the UDP-channel reconsideration (roadmap gate) before Phase 3.

### Wave 0 Gaps
- [ ] `server-windows/src/input_thread.rs` sub-pixel accumulator — unit test: stream of sub-integer deltas sums to correct integer sequence with carried remainder (covers crit 4).
- [ ] `app/remote_control/test/nodelay_factory_test.dart` — assert the `connectionFactory` calls `setOption(SocketOption.tcpNoDelay, true)` (use a fake/mock socket or a loopback server that reports the option where testable; at minimum unit-test the factory logic).
- [ ] `app/remote_control/test/move_sender_test.dart` — assert `PointerMove` deltas produce correct `encodeMove` byte frames (reuses `remote_protocol`).
- [ ] Latency HUD widget + p50/p95 computation — unit test the percentile math on a fixed sample set.
- [ ] Manual smoke checklist entry: real phone + PC, off-charger, slow diagonal, HUD p95 read, 150%-scaled display DPI check.

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Rust toolchain (edition 2024) | server-windows build | ✓ (Phase 1 built) | 1.85+ | — |
| Windows target | enigo SendInject, DPI | ✓ (dev is Win11) | — | — |
| Flutter SDK | app build | assumed ✓ (locked 3.44) | 3.44 | planner: `flutter --version` |
| Android device (real) | on-device HUD, real WiFi latency | required for gate | — | **no fallback** — the gate is inherently on-device; emulator/localhost cannot validate WiFi latency |
| Real WiFi LAN (phone + PC same subnet) | criterion 2/3 measurement | required for gate | — | **no fallback** — localhost hides Nagle/WiFi behavior |

**Missing dependencies with no fallback:**
- A **real Android phone on real WiFi, off-charger**, on the same LAN as the PC — the entire gate depends on it. The planner must schedule the manual measurement as an explicit `checkpoint:human-verify` task; it cannot be automated or emulated.

**Missing dependencies with fallback:**
- 150%-scaled display for the DPI check — if unavailable, temporarily change Windows display scaling to 150% for one smoke pass.

## Security Domain

> `security_enforcement` default (enabled). This phase adds a network-facing binary and a client connector, but reuses Phase 1's already-hardened handshake/auth/gating verbatim (D-01). No new auth, crypto, or input-validation surface is introduced by the spike itself.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no (reused) | Phase 1 challenge-response HMAC handshake — unchanged; spike does not add an auth path (D-01 forbids a bypass). |
| V3 Session Management | no (reused) | Phase 1 session FSM + CONN-07 held-input cleanup — unchanged. |
| V4 Access Control | yes (inherited) | Auth gating: binary move frames are dropped pre-auth (`session.rs` drops pre-auth binary before decode). The spike's real handshake exercises this. |
| V5 Input Validation | yes (inherited) | Binary codec strict-decode (length/opcode/non-finite) already enforced in `server-core::binary::decode`; errored frames dropped+counted, never fatal. |
| V6 Cryptography | no | No new crypto; HMAC-SHA256 auth is Phase 1's. |

### Known Threat Patterns for {Rust WS server + Flutter client}
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Pre-auth flood of binary frames | DoS | Already mitigated: pre-auth binary dropped before decode; 64KB frame caps enforced (Phase 1). Spike inherits. |
| Logging of sensitive payloads | Information Disclosure | `server-core::session` is deliberately log-free; the NEW `server-windows` tracing subscriber must NOT log frame contents (only counts/latency). Enforce in the one logging chokepoint. |
| Dev-fixed PIN / spike shortcut leaking into product | Elevation of Privilege | D-09: dev-pairing shortcut and HUD are spike-only and removable; planner must tag them so they don't survive the gate. |
| Non-finite/oversized frames | Tampering | Strict decode rejects NaN/Inf and wrong-length frames (Phase 1). No change. |

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `IOWebSocketChannel.connect(customClient: HttpClient()..connectionFactory=...)` with `SocketOption.tcpNoDelay` actually disables Nagle on the WebSocket's underlying socket in web_socket_channel 3.0.3 / current Dart SDK | Stack, Code Examples, Pitfall 1 | **HIGH** — this is criterion 3. If the option doesn't reach the socket, the hitch test fails and the UDP-channel gate may trip. Mitigation: empirical hitch test is a mandatory spike task. |
| A2 | Exact `ConnectionTask.fromSocket` re-wrap shape in the connectionFactory | Code Examples | MEDIUM — the *concept* (set option on the connected socket, return a ConnectionTask) is correct; the exact SDK method names may differ. Spike compiles/runs it. |
| A3 | `enigo::set_dpi_awareness()` is the 0.6.1 symbol/path for DPI awareness | Pattern 3 | MEDIUM — helper confirmed added in 0.4.0 via WebSearch; 0.6.1 name/signature unconfirmed. Fallback: `windows` crate `SetProcessDpiAwarenessContext`. |
| A4 | `enigo::Axis` + `scroll(length, Axis)` signature and wheel-direction sign convention in 0.6.1 | Pattern 2 | LOW-MEDIUM — scroll is secondary for the spike (move is the headline). Confirm at impl. |
| A5 | enigo `move_mouse` relative-delta semantics feed cleanly through Windows pointer acceleration such that raw 1:1 still reads "visually instant" | Summary, Pitfall 3 | MEDIUM — acceleration applies to injected relative moves; for the spike's raw 1:1 this is accepted (D-03), but if it makes the feel misleading, note it and keep raw for the measurement. |
| A6 | The `windows = "0.62"` feature `Win32_UI_HiDpi` is only needed if calling the Win32 DPI API directly (not needed if `enigo::set_dpi_awareness` works) | Installation | LOW — cosmetic dependency scoping; confirm at impl. |

**If A1 fails, the phase's core risk materializes** — but that is exactly what the spike exists to discover, and the roadmap has the UDP-channel escape hatch ready.

## Open Questions

1. **Does the `connectionFactory` TCP_NODELAY reliably reach the socket in web_socket_channel 3.0.3?**
   - What we know: the API surface exists and is designed for exactly this (custom socket construction); server-side NODELAY is already proven.
   - What's unclear: whether `IOWebSocketChannel` honors the `customClient`'s `connectionFactory` end-to-end on the current SDK, and whether any intermediate layer re-wraps the socket.
   - Recommendation: make "verify Dart TCP_NODELAY empirically (slow-diagonal hitch test + optional server-side inter-arrival log)" the **first** implementation task of the phase.

2. **ping-interleaved echo vs a dedicated stamped-move echo for measurement?**
   - What we know: `ping{ts}`/`pong{ts}` exists and round-trips on the same socket; the protocol is frozen.
   - What's unclear: whether interleaving `ping` frames *while dragging* measures the move path faithfully enough, or whether a spike-only stamped-move variant is worth a temporary protocol extension (D-06 allows research to choose the mechanism).
   - Recommendation: default to ping-interleaved-during-drag (no protocol change, shares the NODELAY socket/queue with moves). Only add a stamped-move opcode if the interleaved number proves untrustworthy — and mark it spike-only (D-09).

3. **Stub executors location for the four non-mouse traits.**
   - What we know: `Executors` needs all five trait objects to construct; core mocks live under test/mock.
   - What's unclear: whether to expose a reusable no-op stub or seed real (empty) Phase-4/5/6 executors now.
   - Recommendation: seed empty `server-windows` executor files (mouse real, others no-op) — matches D-08 "kept as foundation" and gives later phases a home.

## Sources

### Primary (HIGH confidence)
- `server/server-core/src/transport/mod.rs`, `session.rs`, `executors/mod.rs`, `codec/binary.rs`, `codec/json.rs`, `dispatch/router.rs` (direct read) — `run()`/`ServerDeps`, `set_nodelay`, handshake FSM, `route_binary → move_rel`, `ping{ts}→pong{ts}` echo, `MouseKeys` sync-trait contract.
- `docs.rs/enigo/0.6.1` — `Mouse::move_mouse(x, y, Coordinate::Rel)`, `Coordinate` Abs/Rel, `scroll`+`Axis`, `Enigo::new(&Settings)`, `InputResult`/`InputError`, `set_dpi_awareness` existence.
- `api.dart.dev/dart-io/HttpClient/connectionFactory` — exact `connectionFactory` setter signature `(Uri, String?, int?) → Future<ConnectionTask<Socket>>`.
- CLAUDE.md / `.planning/research/STACK.md` — locked+registry-verified versions (crates.io/pub.dev 2026-07-07).
- `.planning/research/PITFALLS.md` — #2 (DPI/delta), #3 (Nagle/TCP_NODELAY), #4 (gesture/hot path), #5 (WiFi power-save), + enigo `!Sync` caveat.

### Secondary (MEDIUM confidence)
- pub.dev `web_socket_channel` / `IOWebSocketChannel.connect(customClient:)` docs + changelog (WebSearch, cross-checked against dart-lang SDK issue #47887/#55562 on `connectionFactory`).
- api.dart.dev `SocketOption.tcpNoDelay`, `Socket.startConnect`, `ConnectionTask`.

### Tertiary (LOW confidence)
- Exact `enigo::set_dpi_awareness` 0.6.1 symbol/signature and `Axis`/scroll sign convention — WebSearch-derived, confirm at implementation.
- Exact `ConnectionTask.fromSocket` re-wrap idiom — confirm against current SDK.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — all locked + registry-verified; API surfaces read from official docs and existing code.
- Architecture / wiring: HIGH — reads directly from Phase-1 code (`run`, `ServerDeps`, `route_binary`, echo).
- TCP_NODELAY construction: MEDIUM — path verified against official docs but the end-to-end effect in web_socket_channel 3.0.3 needs the empirical hitch test (A1, the phase's raison d'être).
- Sub-pixel/DPI: MEDIUM — pattern is standard; exact enigo 0.6.1 symbols confirm-at-impl.
- Pitfalls: HIGH — carried from project PITFALLS.md (official platform docs) + phase-specific reasoning.

**Research date:** 2026-07-08
**Valid until:** 2026-08-07 (30 days; enigo 0.7 or a web_socket_channel bump would warrant a re-check of the two MEDIUM items sooner).
