# Phase 2: End-to-End Cursor Spike - Pattern Map

**Mapped:** 2026-07-08
**Files analyzed:** 11 new (7 Rust, 4 Dart) + 2 modified (workspace + core Cargo.toml)
**Analogs found:** 11 / 11 (all new files have a close in-repo analog)

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `server/Cargo.toml` (MODIFY: add member) | config | — | `server/Cargo.toml` (self) | exact (edit) |
| `server/server-windows/Cargo.toml` (NEW) | config | — | `server/server-core/Cargo.toml` | role-match |
| `server/server-windows/src/main.rs` (NEW) | composition-root / binary | request-response (bootstrap) | `server-core/tests/integration.rs` `spawn_test_server` + bootstrap block (L40-78) | exact (build+run pattern) |
| `server/server-windows/src/executors/mouse_keys.rs` (NEW) | executor (service) | event-driven (mpsc producer) | `server-core/src/executors/mock.rs` `impl MouseKeys` (L119-150) | exact (same trait) |
| `server/server-windows/src/executors/{stubs}.rs` (NEW no-op Media/Power/Apps/Clipboard) | executor (service) | request-response | `server-core/src/executors/mock.rs` `impl Media/Power/Apps/Clipboard` (L152-221) | role-match (no-op vs recording) |
| `server/server-windows/src/input_thread.rs` (NEW) | service (OS thread) | event-driven / transform (sub-pixel accumulate) | RESEARCH Pattern 2 (no exact analog — see No Analog) | partial |
| `app/remote_control/pubspec.yaml` (NEW) | config | — | `app/packages/remote_protocol/pubspec.yaml` | role-match (path-dep shape) |
| `app/remote_control/lib/net/connection_service.dart` (NEW) | service (connector) | request-response / streaming | RESEARCH Code Example (Dart TCP_NODELAY — no in-repo analog) | partial |
| `app/remote_control/lib/net/handshake.dart` (NEW) | service | request-response | `remote_protocol` `encodeMessage` (json_codec.dart L783) + integration handshake sequence | role-match |
| `app/remote_control/lib/trackpad/move_sender.dart` (NEW) | utility | streaming (fire-and-forget) | `remote_protocol` `encodeMove/encodeScroll` (binary_codec.dart L44-47) | exact (codec import) |
| `app/remote_control/lib/trackpad/trackpad_screen.dart` (NEW) | component (widget) | event-driven (PointerMove) | no in-repo Flutter analog (first app screen) | none |
| `app/remote_control/lib/hud/latency_hud.dart` (NEW) | component (widget) | streaming (throttled provider) | no in-repo Flutter analog | none |

**Test files (Wave 0):**

| Test File | Role | Analog | Match |
|-----------|------|--------|-------|
| `server-windows/src/input_thread.rs` `#[cfg(test)] mod tests` | unit test (accumulator) | `mock.rs` `#[cfg(test)] mod tests` (L223-302) + `#[tokio::test]` harness | exact |
| `app/remote_control/test/move_sender_test.dart` | unit test | `remote_protocol` codec fixture tests | role-match |
| `app/remote_control/test/nodelay_factory_test.dart` | unit test | none (new construction) | none |

---

## Pattern Assignments

### `server/server-windows/Cargo.toml` (config)

**Analog:** `server/server-core/Cargo.toml` (L1-25)

Copy the `[package]` workspace-inheritance shape (edition/rust-version from workspace) and the `[dev-dependencies]` `test-util` pattern for the paused-time accumulator tests:

```toml
[package]
name = "server-core"
version = "0.1.0"
edition.workspace = true
rust-version.workspace = true

[dependencies]
tokio = { version = "1.52", features = ["rt-multi-thread", "net", "sync", "time", "macros"] }
...
[dev-dependencies]
# test-util enables #[tokio::test(start_paused = true)] + tokio::time::advance
tokio = { version = "1.52", features = ["test-util"] }
```

New crate uses `edition.workspace = true` / `rust-version.workspace = true`, adds `server-core = { path = "../server-core" }`, `enigo`, `windows`, `tracing`, `tracing-subscriber`, `anyhow` (deps enumerated in RESEARCH Installation L101-115). Keep the same `tokio` feature set as core.

### `server/Cargo.toml` (config, MODIFY)

**Analog:** self (L1-7). One-line change:

```toml
members = ["server-core", "server-windows"]
```

`[workspace.package]` (`edition = "2024"`, `rust-version = "1.85"`) and `resolver = "3"` stay unchanged — the new crate inherits them.

---

### `server/server-windows/src/executors/mouse_keys.rs` (executor, event-driven)

**Analog:** `server/server-core/src/executors/mock.rs` — the `impl MouseKeys for MockExecutors` block (L119-150).

**Trait contract to fulfill** (from `executors/mod.rs` L51-62, the frozen `MouseKeys` trait):

```rust
pub trait MouseKeys: Send + Sync {
    fn move_rel(&self, dx: f32, dy: f32);
    fn scroll(&self, dx: f32, dy: f32);
    fn click(&self, button: Button);
    fn button_down(&self, button: Button);
    fn button_up(&self, button: Button);
    fn key_down(&self, code: KeyCode);
    fn key_up(&self, code: KeyCode);
    fn key_tap(&self, code: KeyCode, mods: &[Modifier]);
    fn type_text(&self, text: &str);
    fn backspace(&self, n: u32);
}
```

**How the mock implements it** (L119-124) — copy this shape, but replace `self.log.record(...)` with a non-blocking mpsc `send`:

```rust
impl MouseKeys for MockExecutors {
    fn move_rel(&self, dx: f32, dy: f32) {
        self.log.record(Call::MoveRel(dx, dy));
    }
    fn scroll(&self, dx: f32, dy: f32) {
        self.log.record(Call::Scroll(dx, dy));
    }
    // ... all 10 methods implemented, none omitted
```

**Key adaptation** (RESEARCH Pattern 1, L239-254): the mock records into a `CallLog`; the enigo executor instead holds a `Sender<Cmd>` and does `let _ = self.tx.send(Cmd::Move(dx, dy))`. `move_rel`/`scroll` forward to the input thread; the other 8 methods are no-op stubs for the spike (Phase 4 fills them). `move_rel`/`scroll` receive `f32` — pass them straight through; accumulation happens on the input thread, NOT here.

**Critical:** ALL 10 trait methods must be present (the trait has no default impls). The mock proves the exact signatures including `key_tap(&self, code: KeyCode, mods: &[Modifier])` and `Button`/`KeyCode`/`Modifier` come from `server_core::executors`.

---

### `server/server-windows/src/executors/` no-op stubs (Media/Power/Apps/Clipboard)

**Analog:** `mock.rs` `impl Media` (L152-174), `impl Power` (L176-189), `impl Apps` (L191-210), `impl Clipboard` (L212-221).

The `Executors` struct (`mod.rs` L100-106) requires all five trait objects to construct:

```rust
#[derive(Clone)]
pub struct Executors {
    pub mouse_keys: Arc<dyn MouseKeys>,
    pub media: Arc<dyn Media>,
    pub power: Arc<dyn Power>,
    pub apps: Arc<dyn Apps>,
    pub clipboard: Arc<dyn Clipboard>,
}
```

The spike needs runtime no-op stubs for the four non-mouse traits (RESEARCH Open Question 3 / L339 — do NOT reuse `MockExecutors`, which is `pub` but semantically a test recorder). Note two methods have non-`()` returns that stubs must satisfy: `Apps::list(&self) -> Vec<WindowInfo>` (return `vec![]`) and `Clipboard::get(&self) -> String` (return `String::new()`). See mock L195-200 / L215-217 for the return shapes.

---

### `server/server-windows/src/main.rs` (composition root, bootstrap)

**Analog:** `server-core/tests/integration.rs` bootstrap block (L40-78) — this is the exact `ServerDeps` + `run()` wiring pattern.

**Server bootstrap** (integration.rs L40-46):

```rust
async fn spawn_test_server(deps: ServerDeps) -> (SocketAddr, tokio::task::JoinHandle<()>) {
    let listener = TcpListener::bind("127.0.0.1:0")
        .await
        .expect("bind ephemeral port on 127.0.0.1");
    let addr = listener.local_addr().expect("read bound address");
    let handle = tokio::spawn(server_core::run(listener, deps));
    (addr, handle)
}
```

**ServerDeps assembly** (integration.rs L70-78):

```rust
let auth = Arc::new(Mutex::new(AuthManager::new()));
let pin = auth.lock().unwrap().begin_pairing();
let (_pause_tx, pause_rx) = tokio::sync::watch::channel(false);
let deps = ServerDeps {
    executors,
    auth: Arc::clone(&auth),
    pause: pause_rx,
};
```

**`ServerDeps` shape** (transport/mod.rs L25-32) and **`run` signature** (L38-40):

```rust
pub struct ServerDeps {
    pub executors: Executors,
    pub auth: Arc<Mutex<AuthManager>>,
    pub pause: tokio::sync::watch::Receiver<bool>,
}
pub async fn run(listener: tokio::net::TcpListener, deps: ServerDeps) { ... }
```

**Composition-root adaptations for the binary** (RESEARCH Pattern 5, L328-338):
- `AuthManager::new()` takes no args (auth/mod.rs L36); call `begin_pairing()` to get the PIN, then display it (tray/console) per D-02.
- Build `Executors` with `mouse_keys: Arc::new(EnigoMouseKeys { tx })` + the four no-op stubs.
- Bind `("0.0.0.0", PORT)` for LAN (tests use `127.0.0.1:0`); the binary binds the real interface.
- `server_core::run(listener, deps).await` — the whole loop.
- Before anything: `enigo::set_dpi_awareness().ok()` (RESEARCH Pattern 3, L307-313 — confirm symbol at impl), spawn the input thread via `std::thread::spawn(move || input_thread::run_input_thread(rx))`, and install the `tracing_subscriber` (this binary owns logging; core is log-free).

---

### `server/server-windows/src/input_thread.rs` (service, transform)

**Analog:** none exact — this logic is genuinely new (see No Analog Found). Follow **RESEARCH Pattern 2** (L262-296) verbatim: `std::sync::mpsc::Receiver<Cmd>` loop, per-axis `f32` accumulator, `.trunc()` integer part, carry the fraction, `enigo.move_mouse(ix, iy, Coordinate::Rel)` only when non-zero. `Enigo` is created on THIS thread (it is `!Sync`).

**Test analog:** `mock.rs` `#[cfg(test)] mod tests` (L223-302) shows the `#[tokio::test]` unit-test structure and assertion style; the accumulator test is a plain sync `#[test]` feeding a sub-integer delta stream and asserting the emitted integer sequence carries the remainder (RESEARCH Validation L505). The `test-util` paused-time harness (core Cargo.toml L22-25) is available if a timed variant is needed.

---

### `app/remote_control/pubspec.yaml` (config)

**Analog:** `app/packages/remote_protocol/pubspec.yaml` (L1-11) — the sibling package's manifest shape. The new app adds a path-dependency BACK to that package:

```yaml
dependencies:
  flutter_riverpod: ^3.3.2
  web_socket_channel: ^3.0.3
  wakelock_plus: ^1.6.1
  remote_protocol:
    path: ../packages/remote_protocol
```

(RESEARCH Installation L117-124.) The app lives at `app/remote_control/` alongside `app/packages/`, so the relative path is `../packages/remote_protocol`.

---

### `app/remote_control/lib/trackpad/move_sender.dart` (utility, streaming)

**Analog:** `remote_protocol/lib/src/binary_codec.dart` `encodeMove`/`encodeScroll` (L44-47):

```dart
Uint8List encodeMove(double dx, double dy) => _encode(opMove, dx, dy);
Uint8List encodeScroll(double dx, double dy) => _encode(opScroll, dx, dy);
```

`move_sender` imports these from `package:remote_protocol/...` (NO new codec — RESEARCH Don't Hand-Roll L354). Hot path: `PointerMove.delta` → `encodeMove(dx, dy)` → `sink.add(frame)`, fire-and-forget, zero widget rebuilds (RESEARCH Pitfall 6). Frames are `Uint8List` — sent as binary WebSocket frames. `MouseFrame`/`decodeMouseFrame` are for tests only (client never decodes).

---

### `app/remote_control/lib/net/handshake.dart` (service, request-response)

**Analog:** `remote_protocol/lib/src/json_codec.dart` `encodeMessage` (L783-790) + the integration test's handshake sequence.

```dart
String encodeMessage(RemoteMessage msg, {int? seq}) {
  final envelope = <String, Object?>{
    't': msg.t,
    if (seq != null) 'seq': seq,
    'p': msg.toPayload(),
  };
  return jsonEncode(envelope);
}
```

Runs the REAL Phase-1 sequence (D-01): hello → challenge → pin/pairOk → auth → authOk, using `remote_protocol`'s `RemoteMessage` subtypes and `encodeMessage`. `PingMsg`/`PongMsg` already exist (json_codec.dart L614-645, `ts` field) — reused for the latency probe. No new message types; wire protocol is frozen.

---

### `app/remote_control/lib/net/connection_service.dart` (service, connector) — HIGHEST RISK

**Analog:** none in-repo. Follow **RESEARCH Code Example** (L414-435) exactly — the `HttpClient.connectionFactory` + `SocketOption.tcpNoDelay` + `IOWebSocketChannel.connect(customClient:)` construction. This is criterion-3 make-or-break (Pitfall 1, Assumption A1) and must be empirically verified in the spike. See `nodelay_factory_test.dart` gap (RESEARCH L506) for the unit-test seam.

---

## Shared Patterns

### Sync executor trait → non-blocking hot path
**Source:** `server-core/src/executors/mock.rs` (L119-150) + `executors/mod.rs` trait doc (L1-7, L46-62).
**Apply to:** `mouse_keys.rs` and all four stub executors.
The `MouseKeys` trait is SYNC (`&self`, `Send + Sync`) and called inline in the read task (hot-path rule). Executor methods must return immediately. The mock records; the enigo executor does a non-blocking `mpsc.send` and returns. Never block, never `.await`, never hold `Enigo` behind an async lock (RESEARCH Pitfall 2).

### ServerDeps + run() composition
**Source:** `server-core/tests/integration.rs` (L40-78) + `transport/mod.rs` (L25-40).
**Apply to:** `main.rs`.
`AuthManager::new()` (no args) → `Arc<Mutex<_>>`; `watch::channel(false)` for pause; assemble `ServerDeps { executors, auth, pause }`; `server_core::run(listener, deps).await`. Bind LAN (`0.0.0.0`) in the binary vs `127.0.0.1:0` in tests.

### Path-dependency on remote_protocol (Dart)
**Source:** `app/packages/remote_protocol/pubspec.yaml` (L1-11).
**Apply to:** `app/remote_control/pubspec.yaml`, `move_sender.dart`, `handshake.dart`.
Import codecs (`encodeMove`, `encodeScroll`, `encodeMessage`, `PingMsg`/`PongMsg`) from the pure-Dart package via `path: ../packages/remote_protocol`. Never re-implement a codec client-side.

### `#[tokio::test]` unit-test harness
**Source:** `mock.rs` tests (L223-302); paused-time via `test-util` (core Cargo.toml L22-25).
**Apply to:** `input_thread.rs` accumulator tests.
Plain `#[test]` for the sync accumulator; `#[tokio::test(start_paused = true)]` + `tokio::time::advance` available if timing is involved.

### Existing ping/pong echo (measurement wire path)
**Source:** `dispatch/router.rs` L235 (`Msg::Ping(p) => vec![Msg::Pong(PongPayload { ts: p.ts })]`) — echoes `ts` verbatim, works pre-pause-drop.
**Apply to:** `latency_hud.dart` / `connection_service.dart`.
Phone stamps `ts` on send, server echoes it, phone computes `now - ts` (single-clock round-trip — RESEARCH Pitfall 5). No new opcode, no server change.

## No Analog Found

Files with no close in-repo match (use RESEARCH patterns/examples instead):

| File | Role | Data Flow | Reason | Fallback Source |
|------|------|-----------|--------|-----------------|
| `input_thread.rs` | service | transform | No sub-pixel accumulator / dedicated-thread code exists yet | RESEARCH Pattern 2 (L262-296) |
| `connection_service.dart` | service | request-response | First Flutter WebSocket connector; TCP_NODELAY construction is new & unverified (A1) | RESEARCH Code Example (L414-435) |
| `trackpad_screen.dart` | component | event-driven | First Flutter widget in the repo; `Listener`/`PointerMove` pattern | RESEARCH Architecture + Anti-Patterns (L342-347) |
| `latency_hud.dart` | component | streaming | First Flutter widget; throttled Riverpod provider + percentile math | RESEARCH Pitfall 6 + Validation L508 |
| `nodelay_factory_test.dart` | test | — | Tests the new (analog-less) connectionFactory | RESEARCH Wave 0 L506 |

## Metadata

**Analog search scope:** `server/server-core/src/` (executors, transport, dispatch, auth), `server/server-core/tests/`, `server/Cargo.toml`, `app/packages/remote_protocol/`.
**Files scanned:** 12 (4 read in full, 8 targeted grep/read).
**Pattern extraction date:** 2026-07-08
</content>
</invoke>
