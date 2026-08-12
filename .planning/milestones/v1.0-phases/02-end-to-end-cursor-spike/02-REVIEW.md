---
phase: 02-end-to-end-cursor-spike
reviewed: 2026-07-08T04:48:23Z
depth: standard
files_reviewed: 14
files_reviewed_list:
  - app/remote_control/lib/main.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/lib/trackpad/move_sender.dart
  - app/remote_control/pubspec.yaml
  - app/remote_control/test/move_sender_test.dart
  - app/remote_control/test/nodelay_factory_test.dart
  - app/remote_control/test/widget_test.dart
  - server/Cargo.toml
  - server/server-windows/Cargo.toml
  - server/server-windows/src/executors/mod.rs
  - server/server-windows/src/executors/mouse_keys.rs
  - server/server-windows/src/executors/stubs.rs
  - server/server-windows/src/input_thread.rs
  - server/server-windows/src/main.rs
findings:
  critical: 0
  warning: 7
  info: 4
  total: 11
status: issues_found
---

# Phase 02: Code Review Report

**Reviewed:** 2026-07-08T04:48:23Z
**Depth:** standard
**Files Reviewed:** 14
**Status:** issues_found

## Summary

Reviewed the Phase 02 cursor-spike vertical: the `server-windows` composition root (enigo input thread, sub-pixel accumulator, DPI awareness, executor stubs) and the Flutter client half (TCP_NODELAY connection factory, 9-byte move-frame sender, app shell). All builds and tests verified during review: `cargo check --workspace` clean, `cargo test -p server-windows` 3/3, `flutter analyze` clean, `flutter test` 9/9. The enigo 0.6.1 `set_dpi_awareness` crate-root re-export claimed in `main.rs` was verified against the vendored crate source (it exists, `#[cfg(target_os = "windows")]`-gated).

No critical findings. The core hot path (delta -> encode -> sink; decode -> mpsc -> accumulator -> SendInput) is correct, and the accumulator math is proven by tests. The warnings cluster around lifecycle and failure modes the spike leaves unhandled: a one-shot 60-second pairing window, an input thread whose init failure silently produces a cursor-dead-but-healthy-looking server, an unbounded command queue that contradicts the project's own "never queue deltas" anti-pattern, a `0.0.0.0` bind labeled LAN-only, and client-side sender/HttpClient lifecycle gaps that Phase 3's reconnect FSM must not inherit silently.

## Warnings

### WR-01: Pairing window is one-shot and expires 60 seconds after server start

**File:** `server/server-windows/src/main.rs:57-62`
**Issue:** `begin_pairing()` is called exactly once at startup. `PIN_TTL_SECS` is 60 (`server-core/src/auth/pin.rs:13`), and no code path in this binary — no timer, no message handler, no tray — ever calls `begin_pairing()` again (verified: the only production call site in the repo is this one). Sixty seconds after launch, pairing becomes permanently impossible until the process is restarted, and nothing on the console indicates the printed PIN is now dead. This will trip the Plan 04 manual gate the first time phone setup takes longer than a minute.
**Fix:** In the composition root, re-open the window and reprint while unpaired, e.g.:
```rust
let auth_for_repin = Arc::clone(&auth);
tokio::spawn(async move {
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(PIN_TTL_SECS)).await;
        let pin = auth_for_repin.lock().expect("auth mutex").begin_pairing();
        println!("Pairing PIN (refreshed): {pin}");
    }
});
```
(Stop refreshing once a device pairs, or gate on an `is_paired()` accessor. At minimum, print "PIN expires in 60s; restart to re-pair" so the operator is not debugging a silent expiry.)

### WR-02: A single non-finite delta permanently poisons the sub-pixel accumulator

**File:** `server/server-windows/src/input_thread.rs:39-47`
**Issue:** `SubPixelAccumulator::step` has no finiteness guard. If `dx` is ever `NaN`, `acc_x` becomes `NaN` forever: `NaN.trunc() as i32` saturates to `0`, so `acc_x -= 0.0` stays `NaN`, and every subsequent frame emits 0 on that axis — cursor movement silently dead until process restart. Today the only producer is the strict binary decoder, which rejects non-finite f32, but that invariant is enforced two crates away; `MouseKeys::move_rel(&self, dx: f32, dy: f32)` is a public trait any future dispatch path (or a Phase 4-6 addition) can call with unvalidated floats. Also note `±inf`/huge finite values saturate to `i32::MAX`, teleporting the cursor to the screen edge.
**Fix:** Guard at the accumulator boundary (defense-in-depth, one branch on the hot path):
```rust
pub fn step(&mut self, dx: f32, dy: f32) -> (i32, i32) {
    if !dx.is_finite() || !dy.is_finite() {
        return (0, 0); // never let NaN/inf enter the carried state
    }
    ...
}
```

### WR-03: enigo init failure yields a healthy-looking server that silently drops all input

**File:** `server/server-windows/src/input_thread.rs:57`, `server/server-windows/src/main.rs:43`
**Issue:** `Enigo::new(&Settings::default()).expect(...)` panics on the spawned thread, whose `JoinHandle` is discarded at `main.rs:43`. A panicked spawned thread does not propagate to `main`: the `Receiver` is dropped, every `tx.send()` in `EnigoMouseKeys` returns `Err` which is discarded by design (`let _ =`), and the server continues accepting connections, completing auth, and logging `server-windows listening` — while every move/scroll frame goes nowhere. The only diagnostic is a panic message on stderr before tracing formatting.
**Fix:** Fail fast by signalling init success back to the composition root:
```rust
let (ready_tx, ready_rx) = std::sync::mpsc::channel::<Result<(), String>>();
std::thread::spawn(move || input_thread::run_input_thread(rx, ready_tx));
ready_rx.recv()??; // main returns an error if Enigo::new failed
```
(In `run_input_thread`, send `Ok(())` after `Enigo::new` succeeds, `Err(msg)` and return otherwise.)

### WR-04: Unbounded mpsc queue between session and input thread can replay stale deltas (cursor teleport)

**File:** `server/server-windows/src/executors/mouse_keys.rs:30-35`, `server/server-windows/src/main.rs:42`
**Issue:** `std::sync::mpsc::channel()` is the infinitely-buffered variant. If the input thread stalls — `SendInput` blocked by the secure desktop/UAC prompt, an elevated foreground window, or any enigo hiccup — move frames queue without bound and then replay at full speed when the thread resumes, teleporting/rubber-banding the cursor. This is the exact anti-pattern the project's own client-side docs prohibit (`move_sender.dart:7-8`: "queued deltas teleport the cursor"); the server side reintroduces it one hop later. It also grows memory without bound under a sustained stall.
**Fix:** Use a small bounded channel and drop-on-full, consistent with the documented send-and-forget contract:
```rust
let (tx, rx) = std::sync::mpsc::sync_channel::<Cmd>(64);
// in EnigoMouseKeys:
fn move_rel(&self, dx: f32, dy: f32) {
    let _ = self.tx.try_send(Cmd::Move(dx, dy)); // drop when full, never block
}
```

### WR-05: `0.0.0.0` bind is not the spec's "LAN-only binding"

**File:** `server/server-windows/src/main.rs:80-82`
**Issue:** Binding `0.0.0.0` listens on every interface — VPN tunnels, mobile-hotspot adapters, and any publicly routable interface the laptop ever acquires — not only the LAN. The comment asserts "LAN-only by network design, never internet-exposed", which is an environmental assumption (NAT/firewall), not an enforced property; the security constraint in CLAUDE.md ("LAN-only binding — locked by spec") is a binding requirement. The pre-auth WebSocket endpoint (handshake + pairing) is therefore reachable from any network the machine joins. PIN lockout and challenge-response auth mitigate exploitation, so this is not critical, but the deviation from the locked constraint is unenforced and undocumented outside a code comment.
**Fix:** For the spike, at minimum add a peer-address guard in the accept path or bind the specific LAN interface; before Phase 7, enforce it properly (enumerate private-range interfaces, or reject peers whose IP is not RFC 1918/link-local at accept time). If deferring, record it as an accepted risk in the phase verification doc rather than a comment claiming the property holds.

### WR-06: `MoveSender` is not actually fire-and-forget across the sink's lifecycle

**File:** `app/remote_control/lib/trackpad/move_sender.dart:30-37`
**Issue:** `sink.add(...)` on a locally-closed `WebSocketSink` throws `StateError` synchronously — straight into the `PointerMove` handler that Plan 03 wires to `sendMove`. After a remote drop, adds are instead silently buffered into a dead controller. The class doc promises "fire-and-forget" but provides no guard, so the disconnect-mid-drag case (guaranteed to occur on real WiFi) either throws in the gesture callback or accumulates queued deltas — the same teleport-on-reconnect anti-pattern the header warns about — depending on who closed first.
**Fix:** Either make the sender lifecycle-safe:
```dart
void sendMove(double dx, double dy) {
  try {
    sink.add(encodeMove(dx, dy));
  } on StateError {
    // sink closed mid-gesture: drop the frame (fire-and-forget contract)
  }
}
```
or document explicitly that the trackpad/FSM must swap in a fresh `MoveSender` before any pointer event can fire post-disconnect, and enforce that in Plan 03.

### WR-07: `connectNoDelay` leaks its `HttpClient` (always, and especially on failed connects)

**File:** `app/remote_control/lib/net/connection_service.dart:60-68`
**Issue:** Every call builds a fresh `HttpClient` that is never closed. On the success path the upgraded socket detaches, but the client object and its idle-connection machinery linger until GC; on the failure path (`await channel.ready` throws) the client is simply abandoned. Phase 3's reconnect FSM will call this in a retry loop — under a flaky network that is one leaked client per retry attempt.
**Fix:** Close the client when the connect fails, and prefer a single reused client:
```dart
Future<IOWebSocketChannel> connectNoDelay(Uri wsUri) async {
  final client = buildNoDelayHttpClient();
  final channel = IOWebSocketChannel.connect(wsUri, customClient: client);
  try {
    await channel.ready;
  } catch (_) {
    client.close(force: true);
    rethrow;
  }
  return channel;
}
```

## Info

### IN-01: `windows` crate dependency is declared but never used

**File:** `server/server-windows/Cargo.toml:11`
**Issue:** No `use windows`/`windows::` reference exists anywhere in `server-windows/src` (verified by grep). The `main.rs` comment (lines 27-31) even records that the windows-crate DPI fallback "was not needed". Cargo emits no unused-dependency warning, so this silently costs compile time and dependency surface on every build.
**Fix:** Remove the dependency; re-add it in Phase 5/6 when `IAudioEndpointVolume`/`EnumWindows`/`ShellExecuteW` are actually implemented.

### IN-02: DPI-awareness failure is swallowed with no diagnostic path

**File:** `server/server-windows/src/main.rs:32`
**Issue:** `enigo::set_dpi_awareness().ok()` discards the result, and tracing is initialized after it, so the failure can never be logged. On a scaled display, a silent failure here reproduces exactly the wrong-distance cursor bug PAD-05 exists to prevent — with zero evidence in the logs. Tracing initialization is not DPI-dependent; the ordering constraint is only "before any Enigo op".
**Fix:** Initialize the tracing subscriber first, then:
```rust
if enigo::set_dpi_awareness().is_err() {
    tracing::warn!("SetProcessDpiAwareness failed; cursor deltas may be DPI-virtualized on scaled displays");
}
```

### IN-03: `RC_PORT=0` is accepted and the log then reports the wrong port

**File:** `server/server-windows/src/main.rs:74-83`
**Issue:** `"0".parse::<u16>()` succeeds, binds an ephemeral OS-assigned port, and `tracing::info!(port, ...)` then logs `0` rather than the actual bound port — a confusing state for the operator trying to point the phone at the server.
**Fix:** Either reject 0 in the parse validation, or log `listener.local_addr()?.port()` instead of the requested value (the latter is strictly more truthful for all inputs).

### IN-04: Pairing PIN printed to stdout can land in captured logs

**File:** `server/server-windows/src/main.rs:62`
**Issue:** The comment correctly keeps the PIN out of the tracing subscriber, but `println!` output is routinely captured when the binary is run under a service wrapper, task scheduler, or shell redirect — softening the T-02-ID "no secrets in logs" intent by a side door. Acceptable for the interactive spike; worth a note so Phase 7 (tray display) removes the stdout path rather than keeping both.
**Fix:** Track as a Phase 7 cleanup item: once the tray shows the PIN, delete the `println!`.

---

_Reviewed: 2026-07-08T04:48:23Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
