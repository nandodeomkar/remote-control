---
phase: 04-trackpad-keyboard
reviewed: 2026-07-10T09:48:33Z
depth: standard
files_reviewed: 31
files_reviewed_list:
  - app/remote_control/lib/keyboard/diff_ops.dart
  - app/remote_control/lib/keyboard/hidden_text_input.dart
  - app/remote_control/lib/keyboard/key_rows.dart
  - app/remote_control/lib/keyboard/keyboard_panel.dart
  - app/remote_control/lib/keyboard/modifier_chip.dart
  - app/remote_control/lib/keyboard/modifier_fsm.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/lib/settings/sensitivity.dart
  - app/remote_control/lib/trackpad/accel.dart
  - app/remote_control/lib/trackpad/gesture_classifier.dart
  - app/remote_control/lib/trackpad/mouse_buttons.dart
  - app/remote_control/lib/trackpad/trackpad_driver.dart
  - app/remote_control/lib/trackpad/trackpad_screen.dart
  - app/remote_control/lib/trackpad/tuning.dart
  - app/remote_control/test/connection_service_test.dart
  - app/remote_control/test/keyboard/ime_diff_producer_test.dart
  - app/remote_control/test/keyboard/key_rows_test.dart
  - app/remote_control/test/keyboard/keyboard_panel_test.dart
  - app/remote_control/test/keyboard/modifier_fsm_test.dart
  - app/remote_control/test/trackpad/accel_test.dart
  - app/remote_control/test/trackpad/gesture_classifier_test.dart
  - app/remote_control/test/trackpad/mouse_buttons_test.dart
  - app/remote_control/test/trackpad/trackpad_driver_test.dart
  - server/server-core/src/auth/mod.rs
  - server/server-core/src/transport/session.rs
  - server/server-core/tests/integration.rs
  - server/server-windows/Cargo.toml
  - server/server-windows/src/executors/keymap.rs
  - server/server-windows/src/executors/mod.rs
  - server/server-windows/src/executors/mouse_keys.rs
  - server/server-windows/src/input_thread.rs
findings:
  critical: 0
  warning: 5
  info: 5
  total: 10
status: issues_found
resolved_in_phase:
  - "CR-01 (pre-auth liveness kill): fixed by commits e1c01d1 (RED test) + 213b8fd (fix) — see Resolution note in CR-01 section"
---

# Phase 04: Code Review Report (re-review after gap closure)

**Reviewed:** 2026-07-10T09:48:33Z
**Depth:** standard
**Files Reviewed:** 31
**Status:** issues_found

## Summary

Re-review of the Phase 4 trackpad + keyboard surface after gap-closure plans 04-07..04-10, plus a fresh review of the new session-liveness deadline in `session.rs`.

**All four targeted prior findings are verified closed:**

| Prior finding | Status | Evidence |
|---|---|---|
| CR-01 (IME sentinel replay on disconnect) | **CLOSED** | `KeyboardPanel._onDisconnected` fires `_imeResetTick` (keyboard_panel.dart:144-149); `HiddenTextInput._onExternalReset` reseeds producer AND controller in one synchronous callback (hidden_text_input.dart:87-94); covered by two regression tests (keyboard_panel_test.dart:260-336) including the delete-becomes-insert variant |
| CR-02 (held-cap rollover leak) | **CLOSED** | `_heldCodes` is now a `Set<String>` (keyboard_panel.dart:109); `_onKeyUp` gates on `remove()` (200-207); rollover + disconnect-mid-hold regression tests (keyboard_panel_test.dart:338-401) |
| WR-04 (post-lift scroll halving) | **CLOSED** | `_emitScroll` divides by live `_pointers.length` (gesture_classifier.dart:462-473); n >= 1 structurally guaranteed via the `onPointerMove` null-check; three regression tests incl. fling seed and tapPending2 (gesture_classifier_test.dart:302-372) |
| IN-04 (mid-press release wiring) | **CLOSED** | `onTapUp`/`onTapCancel` always wired; only `onTapDown` gated on `enabled`; the `_live` flag keeps disabled-started presses inert (key_rows.dart:361-397, 420-429); mid-press flip test (key_rows_test.dart:122-142) |

Also re-verified: the Dart `kClientKeyCodes` and Rust `CLIENT_KEY_CODES` remain byte-for-byte identical (39 entries each), and the half-open integration test correctly pins its 60s virtual-time bound above the server's 10s deadline.

**However, the new liveness code introduces one Critical defect:** the 10s `LIVENESS_TIMEOUT` applies uniformly to ALL session states, including `AwaitingAuth` during first-time pairing — where the client sends nothing while the human reads the PIN off the PC and types it, and the server's own `PIN_TTL_SECS` grants 60 seconds. Any PIN entry slower than 10s gets its session killed mid-entry. The code comment's core invariant ("a live client can never trip this") is false pre-auth.

Additionally, three Warnings and four Infos from the prior review were NOT addressed by the gap plans and remain open (carried forward below with fresh IDs), plus two new findings (reliable-queue phantom flush; liveness deadline starvation via the blocked reply path) and one new Info.

## Narrative Findings (AI reviewer)

## Critical Issues

### CR-01: 10s liveness deadline kills pairing sessions mid-PIN-entry — pre-auth, the client sends nothing and the server's own PIN window is 60s

**File:** `server/server-core/src/transport/session.rs:60, 113` (with `app/remote_control/lib/net/connection_service.dart:467, 511-522` and `server/server-core/src/auth/pin.rs:13`)

**Issue:** `LIVENESS_TIMEOUT = 10s` breaks the read loop after 10s of NO inbound frames, in **every** auth state. The rationale comment claims "the client emits protocol pings every ~250ms under move load and ~2s idle... a live client can never trip this" — but that cadence exists **only while authed**: `_startLiveness()` is called exclusively from `_onAuthed` (connection_service.dart:467), `probe.onMove()` only fires on authed volatile sends, `HandshakeDriver` sends no pings, and the Dart WebSocket's `pingInterval` is never set (no WS-level keepalive either). During first-time pairing the sequence is: connect → `hello` → `challenge` → **silence while the human walks to the PC, reads the PIN toast, and types 6 digits**. The server's own pairing window (`PIN_TTL_SECS = 60`) explicitly budgets 60 seconds for this — yet the liveness deadline tears the socket down at 10s. Every PIN entry slower than 10s is deterministically killed mid-entry: the client sees a transport failure, backs off, redials, gets a **new** challenge, and the pairing sheet state churns (a PIN submitted into the 1s backoff gap is silently swallowed by `_driver?.feedPin`). This is a regression of the primary pairing flow introduced by the liveness change; 04-UAT and the integration suite never exercise a >10s human pause pre-auth (the tests submit the PIN within milliseconds).

**Fix:** Scale the deadline by auth state — held-input hygiene (the reason the timeout exists) only matters once input can be held, i.e. post-auth:

```rust
const LIVENESS_TIMEOUT: Duration = Duration::from_secs(10);
// Pre-auth: cover PIN_TTL_SECS (60s) + margin. Still bounds socket
// squatters, without racing the human PIN entry the 60s TTL budgets for.
const PRE_AUTH_LIVENESS_TIMEOUT: Duration = Duration::from_secs(75);

// in the select! loop:
() = sleep_until(last_inbound + if ctx.auth_state == AuthState::Authed {
    LIVENESS_TIMEOUT
} else {
    PRE_AUTH_LIVENESS_TIMEOUT
}) => break 'read,
```

(Alternative: have the client send protocol `ping`s during the handshake — but the server-side fix is one expression and needs no protocol change. Add an integration test that holds a session in `AwaitingAuth` for >10s virtual time and asserts it survives to a late `pin` submit.)

**Resolution (2026-07-10, same session):** Fixed as recommended. `PRE_AUTH_LIVENESS_TIMEOUT` (90s = `PIN_TTL_SECS` 60s + margin) applies to all pre-auth states; `Authed` keeps the 10s deadline (UAT Test 5 held-input contract). RED regression test `pre_auth_silence_survives_pin_entry` reproduced the kill (`ConnectionAborted` at 10s, 30s into the PIN window), green after fix. Full workspace suite green (115 tests). Commits: `e1c01d1` (test), `213b8fd` (fix), `fead00a` (summary doc).

## Warnings

### WR-01: Reliable queue flushes stale input from a disconnected epoch into the next session — including a different device

**File:** `app/remote_control/lib/net/connection_service.dart:259-266, 310-312, 349-353, 547-550` (with `app/remote_control/lib/keyboard/hidden_text_input.dart:96-108`, `app/remote_control/lib/trackpad/trackpad_screen.dart:250-256`)

**Issue:** The reliable queue (≤10, flushed on auth) is scoped wider than the "blip" the design intends, creating a phantom-input channel that survives a drop — the exact invariant D-12/CR-01 declared ("no phantom input survives a drop"):

1. **Typing while fully disconnected queues and replays.** `HiddenTextInput` has no `enabled` gate (unlike chips, caps, and the L/M/R bar): with the panel expanded and chip = disconnected, the system IME stays up, `_onChanged` still emits diffs, and `sendReliable` queues them. On the next successful auth — minutes later — up to 10 `TextMsg`s type into whatever window is focused on the PC (T-04-03-adjacent).
2. **Trackpad taps while disconnected queue ClickMsg/DragMsg.** The `Listener` surface is never gated; taps route classifier → driver → `sendReliable`. Queued clicks fire at the cursor position on reconnect.
3. **Queue survives `disconnect()` and target switches.** Only `AuthStopEffect` calls `_policy.clear()`. A user-requested `disconnect()` (CloseEffect) and a `connectTo(differentTarget)` both keep the queue — stale messages destined for device A flush into device B's fresh session on auth.

The queue-during-blip behavior (chip = reconnecting) is spec'd (§8) and correct; the defect is that the same queue also accumulates during `idle`/`needPairing` and across explicit disconnect/target-switch boundaries.

**Fix:** Clear the reliable queue whenever the FSM lands in a terminal-disconnected state and on every fresh `connectTo`:

```dart
Future<void> connectTo(DeviceTarget target) async {
  _lastDialError = null;
  _lastAuthFailure = null;
  _policy.clear(); // a new episode never inherits another epoch's queue
  ...
}
```

and gate the IME emission path on connection state (e.g. the panel passes `enabled` into `HiddenTextInput`, or `_onChanged` no-ops when `isDisconnected()`), matching the gating every other input surface already has.

### WR-02: Liveness deadline can be starved — a blocked reply send wedges the read loop with no deadline

**File:** `server/server-core/src/transport/session.rs:154-160, 203-204`

**Issue:** `tx.send(frame).await` runs inside the `incoming` select arm, not under the select. If the mpsc channel (cap 64) fills because the write task is blocked in `sink.send` (peer sends but never reads — its TCP receive window closes), the read loop parks inside the arm body and the `sleep_until` liveness branch is **never polled again**: the session hangs indefinitely, and post-auth any held input stays held — the exact stuck-key class the deadline was added to eliminate, reachable through the write path instead of the read path. This also defeats the stated side-benefit ("a silent pre-hello socket squatter also dies in 10s"): a squatter that spams `pin` frames and never reads its `authFail` replies holds the session task and socket forever. Same shape at teardown: `write_task.await` (line 204) can block for the full OS TCP timeout on a half-open peer with queued replies (held input IS released first, so impact there is only a leaked task).

**Fix:** Bound the reply send and the write-task join:

```rust
// replies loop:
if tokio::time::timeout(LIVENESS_TIMEOUT, tx.send(frame)).await.is_err() {
    break 'read; // peer not draining replies -> treat as dead
}
// (the inner send Err already breaks)

// teardown:
drop(tx);
let _ = tokio::time::timeout(LIVENESS_TIMEOUT, write_task).await;
```

### WR-03: No dial generation — concurrent dials can bind the session to the wrong target (carried forward, unaddressed)

**File:** `app/remote_control/lib/net/connection_service.dart:360-420` (staleness check at 392-396)

**Issue:** Unchanged from the prior review (2026-07-10T03:43Z, WR-01 there). `_dial`'s post-await staleness check `_fsm.state != ReconnectState.connecting` cannot distinguish WHICH dial owns the `connecting` state. `connectTo(A)` awaiting `_connect`, then `connectTo(B)`: if A's connect resolves first it passes the check, installs `channelA`, and drives `socketConnected()` — the service handshakes against target A's socket while `_fsm.target` is B and `_hadStoredToken` reflects A's token read; a successful pairing persists under B's key with A's session. `_backoffGen` guards stale timers but nothing guards stale dial awaits.

**Fix:** Add a `_dialGen` counter (same idiom as `_backoffGen`): capture `final gen = ++_dialGen;` at dial entry and discard the channel when `gen != _dialGen` after the await.

### WR-04: `dispose()` does not invalidate pending backoff timers — post-dispose redial opens an unclosed socket (carried forward, unaddressed)

**File:** `app/remote_control/lib/net/connection_service.dart:327-332, 342-346`

**Issue:** Unchanged from the prior review (WR-02 there). `dispose()` tears down the channel and closes `_changes` but does not bump `_backoffGen`; a pending backoff timer fires afterward, passes its generation check, and `_dial` opens a real socket on the disposed service that is never torn down again. Low impact while the service is an app-lifetime singleton, but the "Releases everything" contract is violated.

**Fix:** `_backoffGen++;` (and `_dialGen++` with WR-03) at the top of `dispose()`.

### WR-05: Async prefs load can clobber a user `set()`; `state =` after dispose throws unhandled (carried forward, unaddressed)

**File:** `app/remote_control/lib/settings/sensitivity.dart:85-87`, `app/remote_control/lib/keyboard/key_rows.dart:112-114`

**Issue:** Unchanged from the prior review (WR-03 there), in both Notifiers sharing the pattern: `unawaited(_load(...))` assigns `state = await store.load()` unconditionally. (1) A user `set()` racing the slow platform-channel load gets overwritten by the stale persisted value; (2) `state =` after provider disposal throws `StateError` inside an unawaited future.

**Fix:** Set a `_userSet` flag in `set()` and have `_load` return early when it is true; wrap the assignment in `try { state = loaded; } on StateError {}`.

## Info

### IN-01: `AuthManager.active_nonce` is written but never read — dead security-relevant state (carried forward)

**File:** `server/server-core/src/auth/mod.rs:31, 84-88, 93-97`

**Issue:** Unchanged. `issue_challenge` stores the nonce; `verify_auth` takes the nonce as a parameter and never consults the field. Verified again: `session.rs:91, 316-320` binds verification to the per-session copy, so there is no replay hole — but the field's doc comment implies it is the enforcement point, and as a single cross-session slot it could never be one.

**Fix:** Delete the field, or document that nonce binding lives on the session.

### IN-02: No cross-language contract test for the locked key vocabulary (carried forward)

**File:** `app/remote_control/lib/keyboard/key_rows.dart:36-48` vs `server/server-windows/src/executors/keymap.rs:44-56`

**Issue:** Unchanged. The 39-entry lists match today (re-verified), but each suite only checks internal consistency; a mirrored typo passes both and produces a silently dead key (T-04-02).

**Fix:** Emit the vocabulary into `protocol/fixtures/` and assert equality from both suites.

### IN-03: `connectNoDelay` leaks one `HttpClient` per dial (carried forward)

**File:** `app/remote_control/lib/net/connection_service.dart:80-96`

**Issue:** Unchanged. A fresh `HttpClient` per connect attempt, never closed; unbounded accumulation across a long backoff episode.

**Fix:** One shared top-level client, or `client.close(force: false)` after `channel.ready`.

### IN-04: `KeyboardPanel`'s `changes` subscription is captured once and never re-subscribed (carried forward)

**File:** `app/remote_control/lib/keyboard/keyboard_panel.dart:132-137, 151-161`

**Issue:** Unchanged (IN-05 in the prior review). `didUpdateWidget` handles `expanded` but not a replaced `changes` stream or `isDisconnected` probe. Notably, `HiddenTextInput.didUpdateWidget` (hidden_text_input.dart:64-72) DID gain exactly this re-subscribe for `resetSignal` — citing "IN-05-class hazard" — while the panel one file up still has the hazard for its own seams.

**Fix:** Re-subscribe in `didUpdateWidget` when `widget.changes` is not identical to `oldWidget.changes`, or document that the seams must be State-lifetime-stable.

### IN-05: `_MouseButton` release handlers gated on `enabled` — mid-press disable leaves `_pressed` stuck true

**File:** `app/remote_control/lib/trackpad/mouse_buttons.dart:129-132`

**Issue:** The same conditional-null pattern the IN-04 key-cap fix removed: `onTapUp`/`onTapCancel` are `null` when `enabled` is false, so a mid-press auth drop swallows the release and `_pressed` stays `true`. No wire-state impact (the click fires on tap-down, nothing is held server-side), but on re-enable the button renders the accent pressed state without being touched, until the next interaction.

**Fix:** Mirror the key-cap pattern — always wire `onTapUp: (_) => _release()` and `onTapCancel: _release`; gate only `onTapDown` on `enabled`.

---

_Reviewed: 2026-07-10T09:48:33Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
