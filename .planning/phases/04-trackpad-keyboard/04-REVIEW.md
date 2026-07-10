---
phase: 04-trackpad-keyboard
reviewed: 2026-07-10T03:43:01Z
depth: standard
files_reviewed: 29
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
  - server/server-windows/Cargo.toml
  - server/server-windows/src/executors/keymap.rs
  - server/server-windows/src/executors/mod.rs
  - server/server-windows/src/executors/mouse_keys.rs
  - server/server-windows/src/input_thread.rs
findings:
  critical: 2
  warning: 4
  info: 5
  total: 11
status: issues_found
---

# Phase 04: Code Review Report

**Reviewed:** 2026-07-10T03:43:01Z
**Depth:** standard
**Files Reviewed:** 29
**Status:** issues_found

## Summary

Reviewed the Phase 4 trackpad + keyboard surface: the pure gesture classifier and intent-executor driver, the acceleration/tuning constants, the hidden-IME diff pipeline, the modifier FSM and key rows, the connection service, and the Windows-side keymap/input thread. The pure-FSM/driver split is clean and well tested; the sub-pixel accumulator, virtual-desktop normalization, and modifier FSM all check out against their contracts, and the Dart `kClientKeyCodes` list is a byte-for-byte match of the Rust `CLIENT_KEY_CODES` (39 entries each).

Two Critical defects were found, both in the keyboard path and both producing phantom/stuck input on the host — exactly the failure class D-12 exists to prevent:

1. The disconnect-hygiene `_imeProducer.reset()` desynchronizes the producer's committed text from the hidden field's controller, so the first keystroke after a reconnect **replays all previously typed text** into the new session.
2. `KeyboardPanel` tracks at most ONE held key cap (`_heldCode` is a single `String?`), so ordinary key rollover (press cap B before releasing cap A) permanently swallows cap A's `up` — the key stays held and autorepeating on the PC.

Four warnings cover a dial-generation race in `ConnectionService`, a post-`dispose()` redial leak, a persisted-setting load race duplicated in two Notifiers, and a scroll-rate halving when one of two scrolling fingers lifts. Verified before flagging: `text.bs` is capped at 10,000 in `router.rs` before reaching `Cmd::Backspace` (not a DoS), and `session.rs` passes its own per-session copy of the server-issued nonce to `verify_auth` (no replay hole — but see IN-01 for the dead field).

## Critical Issues

### CR-01: IME reset on disconnect desyncs producer from controller — stale text replays into the next session

**File:** `app/remote_control/lib/trackpad/trackpad_screen.dart:137` (with `app/remote_control/lib/keyboard/diff_ops.dart:71-73`, `app/remote_control/lib/keyboard/hidden_text_input.dart:42-58`)

**Issue:** On the transition into disconnected, the screen calls `_imeProducer.reset()`, which sets the producer's `_committed` back to `kImeSentinel`. But the `HiddenTextInput`'s `TextEditingController` still holds the pre-disconnect text (e.g., `sentinel + "hello"`) — the panel stays mounted across disconnects (by design, Pitfall 6) and nothing re-seeds the controller. The producer and the field are now desynchronized:

- Next keystroke `'x'` → `onChanged(sentinel + "hellox")` → `computeDiff(sentinel, sentinel+"hellox")` → `TextMsg(bs: 0, ins: "hellox")`. The entire pre-disconnect committed text (possibly a password typed into the PC before the drop) is **retyped into whatever window is focused in the new session**.
- Worse, a backspace after reconnect → `onChanged(sentinel + "hell")` → `ins: "hell"` — a delete becomes an insert.

This is the inverse of the stated goal ("stale committed text must not skew the next diff"): *without* the reset, committed == controller text and the next diff is correct; the reset itself introduces the skew. Note the KEY-01 reliable path also queues during blips, so the corrupted `TextMsg` reliably flushes into the fresh session.

**Fix:** Keep the producer and controller atomically in sync. Simplest correct option — remove the reset from the disconnect path (committed text already equals the controller text, so subsequent diffs are correct):

```dart
// trackpad_screen.dart — disconnect hygiene listener
if (chip == ChipStatus.disconnected && _lastChip != ChipStatus.disconnected) {
  _driver.reset();
  // Do NOT reset _imeProducer alone: committed must stay equal to the
  // hidden field's controller text or the next diff replays stale input.
}
```

If a true wipe is wanted (privacy hygiene), reset BOTH sides: expose a reseed hook from `HiddenTextInput` (e.g., a `ValueNotifier`/callback the screen fires) that sets `_controller.value` back to `producer.reseed()` under the `_reseeding` guard, in the same frame as `producer.reset()`.

### CR-02: Single `_heldCode` slot — key rollover leaks a stuck, autorepeating key on the host

**File:** `app/remote_control/lib/keyboard/keyboard_panel.dart:105, 180-191`

**Issue:** `_heldCode` is a single `String?`. Each `_KeyCap` has its own `GestureDetector`, and Flutter tracks each pointer independently — two caps can be pressed concurrently (rollover is the *normal* pattern for arrow keys: press Down before releasing Right). Sequence:

1. Press cap `Right` → `down:Right` sent, `_heldCode = 'Right'`.
2. Press cap `Down` (finger 2, before releasing) → `down:Down` sent, `_heldCode = 'Down'` (overwritten).
3. Release `Right` → `_onKeyUp('Right')`: `_heldCode != 'Right'` → **return, no `up` sent**.
4. Release `Down` → `up:Down` sent.

`Right` is now held server-side indefinitely — Windows autorepeats it into the focused app until the user figures out they must press-and-release `Right` again, or the connection drops (CONN-07 `release_all`). Sustained unintended keystroke injection into the host from a routine gesture. The widget tests only ever press one cap at a time, so this path is untested.

**Fix:** Track held caps as a set:

```dart
final Set<String> _heldCodes = <String>{};

void _onKeyDown(String code) {
  _heldCodes.add(code);
  widget.send(KeyMsg(code: code, action: 'down'));
}

void _onKeyUp(String code) {
  // Only skip ups whose down did NOT survive (D-12 cleared it).
  if (!_heldCodes.remove(code)) return;
  widget.send(KeyMsg(code: code, action: 'up'));
}

void _onDisconnected() {
  _fsm.disconnected();
  _heldCodes.clear();
  if (mounted) setState(() {});
}
```

## Warnings

### WR-01: No dial generation — concurrent dials can bind the session to the wrong target

**File:** `app/remote_control/lib/net/connection_service.dart:360-420` (staleness check at 392-396)

**Issue:** `_dial`'s post-await staleness check is `if (_fsm.state != ReconnectState.connecting)`, which cannot distinguish *which* dial the `connecting` state belongs to. Sequence: `connectTo(A)` starts dial A (awaiting `_connect`); user calls `connectTo(B)` → FSM re-enters `connecting`, dial B starts (its `_teardownChannel()` runs before A has a channel, so it tears down nothing). If A's connect resolves first, it passes the check (`state == connecting`), assigns `_channel = channelA`, and drives `socketConnected()` → `handshaking`. B's connect then resolves, sees `handshaking`, and closes itself. Result: the service is handshaking against **target A's socket** while `_fsm.target` is **B** — `_hadStoredToken` reflects A's token read, and a successful pairing would persist under B's key with A's session. `_backoffGen` guards stale backoff timers but nothing guards stale dial awaits.

**Fix:** Add a dial generation counter (same idiom as `_backoffGen`):

```dart
int _dialGen = 0;

Future<void> _dial(DeviceTarget target) async {
  final gen = ++_dialGen;
  ...
  channel = await _connect(...);
  ...
  if (gen != _dialGen || _fsm.state != ReconnectState.connecting) {
    unawaited(channel.sink.close());
    return;
  }
```

### WR-02: `dispose()` does not invalidate pending backoff timers — post-dispose redial opens an unclosed socket

**File:** `app/remote_control/lib/net/connection_service.dart:327-332, 341-346`

**Issue:** `dispose()` cancels the beacon sub, tears down the channel, and closes `_changes`, but does not bump `_backoffGen` or set a disposed flag. A backoff timer scheduled before dispose fires afterward, passes its `gen == _backoffGen` check, feeds `backoffElapsed()` → `DialEffect` → `_dial` runs, `_connect` opens a **real socket** on the disposed service, and the handshake driver starts. `_notify()` is guarded against the closed controller, but the channel is never torn down again. Low impact today (the service is an app-lifetime singleton) but the API contract ("Releases everything") is violated and any future scoped use leaks a live connection.

**Fix:**

```dart
void dispose() {
  _backoffGen++;      // stale backoff timers no-op
  _dialGen++;         // (with WR-01) in-flight dials discard their channel
  _beaconSub?.cancel();
  _beaconSub = null;
  _teardownChannel();
  _changes.close();
}
```

### WR-03: Async prefs load can clobber a user `set()`; `state =` after dispose throws unhandled

**File:** `app/remote_control/lib/settings/sensitivity.dart:76-97`, `app/remote_control/lib/keyboard/key_rows.dart:103-122`

**Issue:** Both Notifiers fire `unawaited(_load(...))` from `build()` and assign `state = await store.load()` when it resolves, unconditionally. Two defects in the shared pattern:

1. **Clobber race:** if the user calls `set()` before the load future resolves (slow platform channel, first-frame slider drag), the resolving load overwrites the user's fresh value with the old persisted one — while the user's `save()` may have already persisted the new value, leaving UI and storage disagreeing until restart.
2. **Post-dispose throw:** `state =` after the provider container is disposed throws `StateError` inside an unawaited future — an unhandled async error at teardown.

**Fix:** Guard the load result against a subsequent user write (and swallow post-dispose):

```dart
bool _userSet = false;

Future<void> _load(SensitivityStore store) async {
  final loaded = await store.load();
  if (_userSet) return;          // a live set() wins over the stale load
  try { state = loaded; } on StateError { /* provider disposed */ }
}

void set(double value) {
  _userSet = true;
  ...
}
```

### WR-04: Scroll deltas halve when one of two scrolling fingers lifts

**File:** `app/remote_control/lib/trackpad/gesture_classifier.dart:391-392, 397-403, 457-467`

**Issue:** `_emitScroll` divides every delta by 2 on the stated assumption that "only one pointer moves per event, the other contributes zero" — valid while two fingers are down. But in `_Phase.scrolling`, when the first finger lifts (`onPointerUp` returns `const []` and stays in `scrolling` because `_pointers.isNotEmpty`), the remaining single finger keeps streaming through `_emitScroll`, still halved. The scroll rate abruptly drops to half the finger's travel mid-gesture, and the fling seed built from those samples is halved too. Same halving applies in `tapPending2` → `scrolling` when only one tracked finger remains.

**Fix:** Scale by the live tracked-pointer count instead of a constant 2:

```dart
ScrollIntent _emitScroll(double dx, double dy) {
  final n = _pointers.length;          // 2 while both down, 1 after a lift
  final sdx = dx / n;
  final sdy = dy / n;
  ...
}
```

## Info

### IN-01: `AuthManager.active_nonce` is written but never read — dead security-relevant state

**File:** `server/server-core/src/auth/mod.rs:31, 84-87, 93-97`

**Issue:** `issue_challenge` stores the nonce in `active_nonce`, but `verify_auth` takes the nonce as a caller parameter and never consults the field. Verified: `session.rs:218-219, 275-278` keeps its own per-session copy of the server-issued nonce and passes that — so there is no replay hole — but the field is dead state whose doc comment ("Most recently issued challenge nonce") implies it is the enforcement point. It also couldn't work as one: it is a single slot shared across concurrent sessions.

**Fix:** Delete the field (and its writes) or add a comment stating nonce binding lives on the session, so a future refactor doesn't "helpfully" start verifying against this cross-session slot.

### IN-02: No cross-language contract test for the locked key vocabulary

**File:** `app/remote_control/lib/keyboard/key_rows.dart:36-48` vs `server/server-windows/src/executors/keymap.rs:44-56`

**Issue:** The two 39-entry lists match today (verified), but each side's test only checks internal consistency (Dart: caps ⊆ `kClientKeyCodes`; Rust: `CLIENT_KEY_CODES` maps to `Some`). A typo'd addition mirrored on the Dart side would pass both suites and produce a silently dead key (the exact T-04-02 failure the comments warn about).

**Fix:** Emit the vocabulary into `protocol/fixtures/` (the existing shared-fixture mechanism) and have both suites assert equality against the fixture file.

### IN-03: `connectNoDelay` leaks one `HttpClient` per dial

**File:** `app/remote_control/lib/net/connection_service.dart:80-96`

**Issue:** `buildNoDelayHttpClient()` constructs a fresh `HttpClient` per connect attempt and never calls `client.close()`. Repeated backoff redials accumulate clients with idle-connection timers. Small, but unbounded across a long reconnect episode.

**Fix:** Hoist one shared `HttpClient` to a top-level `final`, or `close(force: false)` the client after `channel.ready` completes (the upgraded socket is already detached).

### IN-04: Mid-press `enabled` flip swallows a key-cap's `up` client-side

**File:** `app/remote_control/lib/keyboard/key_rows.dart:409-413`

**Issue:** `onTapUp`/`onTapCancel` are conditionally `null` when `enabled` is false. If auth drops while a cap is held, the rebuild nulls the handlers and the release produces no `up`. Today this is masked because losing `authed` coincides with socket loss → server CONN-07 `release_all`, and the D-12 reset clears held state — but the correctness depends on that coincidence, not on this widget. Also `_pressed` can be left stuck `true` visually.

**Fix:** Keep `onTapUp`/`onTapCancel` always wired and gate only `onTapDown` on `enabled`; the up path already no-ops when nothing is held (especially after CR-02's set-based fix).

### IN-05: `changes` stream on `KeyboardPanel` is captured once and never re-subscribed

**File:** `app/remote_control/lib/keyboard/keyboard_panel.dart:122-127, 138-147`

**Issue:** The `_changesSub` is created in `initState` from `widget.changes`; `didUpdateWidget` handles `expanded` but not a changed `changes` stream or `isDisconnected` probe. Safe with the current app-lifetime service singleton, but the injectable-seam design invites reconfiguration that would silently keep listening to the old stream.

**Fix:** In `didUpdateWidget`, if `widget.changes != oldWidget.changes`, cancel and re-subscribe (or document that the seams must be stable for the State's lifetime).

---

_Reviewed: 2026-07-10T03:43:01Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
