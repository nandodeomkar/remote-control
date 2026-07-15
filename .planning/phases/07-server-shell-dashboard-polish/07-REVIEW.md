---
phase: 07-server-shell-dashboard-polish
reviewed: 2026-07-15T12:00:00Z
depth: standard
files_reviewed: 63
files_reviewed_list:
  - app/packages/remote_protocol/lib/src/json_codec.dart
  - app/packages/remote_protocol/test/fixture_test.dart
  - app/remote_control/lib/apps/apps_screen.dart
  - app/remote_control/lib/browser/browser_screen.dart
  - app/remote_control/lib/clipboard/clipboard_screen.dart
  - app/remote_control/lib/dev/beacon_smoke_main.dart
  - app/remote_control/lib/hub/hub_screen.dart
  - app/remote_control/lib/keyboard/key_rows.dart
  - app/remote_control/lib/keyboard/keyboard_panel.dart
  - app/remote_control/lib/keyboard/keyboard_screen.dart
  - app/remote_control/lib/keyboard/modifier_chip.dart
  - app/remote_control/lib/main.dart
  - app/remote_control/lib/media/media_screen.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/lib/power/power_screen.dart
  - app/remote_control/lib/presenter/presenter_screen.dart
  - app/remote_control/lib/screens/device_list_screen.dart
  - app/remote_control/lib/screens/pairing_dialog.dart
  - app/remote_control/lib/settings/haptics.dart
  - app/remote_control/lib/settings/scroll_direction.dart
  - app/remote_control/lib/settings/settings_screen.dart
  - app/remote_control/lib/theme/tokens.dart
  - app/remote_control/lib/trackpad/mouse_buttons.dart
  - app/remote_control/lib/trackpad/trackpad_driver.dart
  - app/remote_control/lib/trackpad/trackpad_screen.dart
  - app/remote_control/lib/widgets/connection_header.dart
  - app/remote_control/lib/widgets/keep_awake.dart
  - app/remote_control/lib/widgets/quick_bar_scaffold.dart
  - app/remote_control/lib/widgets/uipi_banner.dart
  - app/remote_control/pubspec.yaml
  - app/remote_control/test/haptics_gate_test.dart
  - app/remote_control/test/hub_offline_test.dart
  - app/remote_control/test/hub_tiles_test.dart
  - app/remote_control/test/keep_awake_test.dart
  - app/remote_control/test/quick_bar_test.dart
  - app/remote_control/test/scroll_direction_test.dart
  - app/remote_control/test/settings_screen_test.dart
  - app/remote_control/test/theme_tokens_guard_test.dart
  - app/remote_control/test/uipi_banner_test.dart
  - app/remote_control/test/widget_test.dart
  - protocol/fixtures/beacon/01-valid.json
  - protocol/fixtures/input_blocked/01-input-blocked.json
  - server/rust-toolchain.toml
  - server/server-core/src/auth/mod.rs
  - server/server-core/src/codec/json.rs
  - server/server-core/src/dispatch/router.rs
  - server/server-core/src/transport/listener.rs
  - server/server-core/src/transport/mod.rs
  - server/server-core/src/transport/session.rs
  - server/server-core/tests/fixtures.rs
  - server/server-core/tests/integration.rs
  - server/server-windows/Cargo.toml
  - server/server-windows/src/autostart.rs
  - server/server-windows/src/clip_thread.rs
  - server/server-windows/src/config.rs
  - server/server-windows/src/firewall.rs
  - server/server-windows/src/input_thread.rs
  - server/server-windows/src/main.rs
  - server/server-windows/src/notify.rs
  - server/server-windows/src/shell/mod.rs
  - server/server-windows/src/shell/settings.rs
  - server/server-windows/src/shell/tray.rs
findings:
  critical: 1
  warning: 8
  info: 8
  total: 17
status: issues_found
---

# Phase 7: Code Review Report

**Reviewed:** 2026-07-15T12:00:00Z
**Depth:** standard
**Files Reviewed:** 63
**Status:** issues_found

## Summary

Reviewed the Phase 7 surface end to end: the Flutter dashboard rewire (hub grid, quick-bar scaffold, settings screen, UIPI banner, haptics/scroll-direction prefs), the connection service, the keyboard/trackpad input surfaces, the protocol codecs on both sides, and the Rust server (session/router/auth, config persistence, tray/settings shell, firewall self-test, input thread).

Overall discipline is high — the auth/pause gating, secrets handling (hash-only persistence, no PIN/token in tracing), fixture-driven codec parity, and fail-safe config loading are all consistent and well tested. However, the review found one critical held-input lifecycle gap on the client (stuck keys/buttons on the PC after navigating away mid-hold), plus a cluster of warnings: stale-toast bugs from missing seed-at-mount guards, a dial-episode race in the connection service, unguarded keystore operations that CLAUDE.md explicitly warns can throw, a non-atomic config save with two concurrent writers (pairing data-loss window), two panic paths in the Rust shell/input threads that contradict their own documented degrade-never-panic contracts, and a session write-queue backpressure shape that can defeat the CONN-07 liveness guarantee.

## Critical Issues

### CR-01: Held input is never released when the emitting widget is disposed while the session stays authed — stuck keys/buttons on the PC

**File:** `app/remote_control/lib/keyboard/keyboard_panel.dart:164-169`, `app/remote_control/lib/keyboard/key_rows.dart:350-392`, `app/remote_control/lib/trackpad/trackpad_screen.dart:159-168`, `app/remote_control/lib/trackpad/trackpad_driver.dart:158-173`

**Issue:** The D-12 reset path only fires on *disconnect* (CONN-07 `release_all` frees held input server-side). But if the user navigates away while the session stays **authed**, nothing sends the owed `up`/`end` frames, and the server holds the input indefinitely:

1. **Locked modifiers:** locking Ctrl (D-10 = real server-side hold via `key {action: down}`) and then popping the Keyboard screen (or the trackpad screen hosting the panel) disposes `KeyboardPanel` — `dispose()` (line 165) cancels the subscription but never emits `SendModifierUp` for locked chips. Ctrl stays held on the PC with no visible indicator and no recovery short of reconnecting.
2. **Held key caps:** `_KeyCapState` has no `dispose()` override. A cap disposed mid-hold (screen pop with a key held, or switching the Nav/Fn/Num group with a second finger while a key is down — the switch rebuilds `KeyRows` with different caps) never fires `onKeyUp`. The server key stays down and **Windows autorepeats it** (KEY-04) until disconnect.
3. **Drag-lock:** engaging drag-lock (server `drag {action: start}`) and pressing back disposes `TrackpadScreen`; `_driver.dispose()` deliberately sends nothing. The PC's left mouse button remains held with the session still live.

The keyboard panel's own `_onKeyUp` guard comment (key_rows.dart line 420-424, IN-04) shows the team already fixed the *mid-press enabled-flip* stuck-key case — the disposal case is the same defect class and is unhandled.

**Fix:**
```dart
// keyboard_panel.dart
@override
void dispose() {
  _changesSub?.cancel();
  // Session may still be live: flush owed releases before going away.
  if (!widget.isDisconnected()) {
    for (final code in _heldCodes) {
      widget.send(KeyMsg(code: code, action: 'up'));
    }
    _sendEffects(_fsm.releaseAll()); // new FSM API: ups for armed-locked holds
  }
  _heldCodes.clear();
  _imeResetTick.dispose();
  super.dispose();
}
```
```dart
// key_rows.dart _KeyCapState
@override
void dispose() {
  if (_live && !_deferred) widget.onKeyUp(widget.def.code);
  super.dispose();
}
```
```dart
// trackpad_screen.dart dispose(), before _driver.dispose():
if (_driver.dragLocked && _service.isAuthed) {
  _service.sendReliable(const DragMsg(action: 'end', button: 'left'));
}
```

## Warnings

### WR-01: Stale toast fires on screen open — Apps and Clipboard screens don't seed the "already seen" marker at mount

**File:** `app/remote_control/lib/apps/apps_screen.dart:57-84`, `app/remote_control/lib/clipboard/clipboard_screen.dart:63-101`

**Issue:** `ConnectionService.lastError` and the clip store's `lastFetchEvent` are never cleared. `_AppsScreenState._shownError` and `_ClipboardScreenState._shownFetch` both start `null`, so the FIRST `changes` ping after mount (guaranteed within moments — `primeList()` triggers an `apps.list` reply) surfaces whatever stale value is parked from a *previous* visit or an unrelated feature: e.g. re-opening the Apps screen toasts an old `launchFailed` message; re-opening Clipboard re-toasts "Copied to phone." for a fetch that happened minutes ago. `UipiBanner` handles this exact hazard correctly ("Seed the 'already seen' marker from whatever is parked at mount time WITHOUT showing it", uipi_banner.dart:69-75) — these two screens skipped the pattern.

**Fix:** In `initState`, seed the marker before subscribing:
```dart
_shownError = _service.lastError; // apps_screen.dart
// ...
_shownFetch = ref.read(clipStateProvider.notifier).lastFetchEvent; // clipboard_screen.dart
```

### WR-02: `_dial` has no per-episode guard — overlapping dials can install a stale channel, leak a socket, or connect to the wrong PC

**File:** `app/remote_control/lib/net/connection_service.dart:488-548`

**Issue:** The stale-dial check (line 520) is `if (_fsm.state != ReconnectState.connecting)`. That distinguishes "the world moved on" only by *state*, not by *dial episode*. Sequence: dial A (target A) is awaiting `_connect`; the user taps a different PC → `connectTo(targetB)` → dial B starts (its `_teardownChannel()` is a no-op — A hasn't installed yet) and awaits its own connect; the FSM is back in `connecting`. Dial A's connect now resolves, passes the state check, and installs channel A + a `HandshakeDriver` carrying **target A's token** while `_fsm.target` is B — the header shows B's name but input drives A's PC. When B's connect then resolves, state is `handshaking`, so B closes its socket — or in the reverse completion order, A's channel/`_sub` are silently overwritten and leak (subscription never cancelled, socket never closed). The service already solves this exact problem for backoff timers with `_backoffGen` (line 273-279) but not for dials.

**Fix:** Add a dial generation, captured before the awaits:
```dart
int _dialGen = 0;
Future<void> _dial(DeviceTarget target) async {
  final gen = ++_dialGen;
  ...
  channel = await _connect(...);
  if (gen != _dialGen || _fsm.state != ReconnectState.connecting) {
    unawaited(channel.sink.close());
    return;
  }
```

### WR-03: Unguarded flutter_secure_storage calls — a keystore failure becomes an unhandled async exception

**File:** `app/remote_control/lib/net/connection_service.dart:508`, `app/remote_control/lib/net/connection_service.dart:645-666`

**Issue:** CLAUDE.md's stack notes state explicitly that "Keystore ops are slow and can throw after OS updates." Two paths ignore that:
1. `_dial` line 508: `final token = await _store.tokenFor(target.key);` is not wrapped — a throw propagates out of `_applyStep` into whichever caller triggered the dial. For `retryNow()`/`onAppResumed()`/beacon sightings the call is `unawaited(_applyStep(...))`, so the error surfaces as an **uncaught zone exception** (crash in release-mode zones that rethrow), and the FSM is left stranded in `connecting` with no `transportFailed` input — the reconnect loop stalls permanently.
2. `_onAuthed` line 649: `unawaited(_persistNewPairing(target, token))` — `saveToken` is a keystore *write* with no catch; failure is an uncaught async error and the pairing silently isn't persisted.

Only `main.dart`'s `_launchKick` (line 90, T-03-26) got the try/catch treatment.

**Fix:** In `_dial`: `String? token; try { token = await _store.tokenFor(target.key); } catch (_) { token = null; }` (a lost token degrades to the PIN path — correct behavior). In `_onAuthed`, wrap `_persistNewPairing` in try/catch and record a non-fatal flag the UI can surface ("couldn't remember this PC").

### WR-04: config.toml persistence is non-atomic with two concurrent writers and a hard `process::exit` — a corrupt file silently drops every pairing

**File:** `server/server-windows/src/config.rs:151-166`, `server/server-windows/src/shell/settings.rs:534-548`, `server/server-windows/src/shell/mod.rs:272-274`

**Issue:** Three compounding problems:
1. `config::save` uses `std::fs::write` directly — truncate-then-write, not write-temp-then-rename. Any interruption mid-write (power loss, crash) leaves a truncated/partial file.
2. Two independent writers race: the tokio auth-change save task (main.rs step 5b) and the shell thread's `persist()` (settings.rs:534) both call `config::save` with no serialization between them. A Revoke click (fires the tokio save) concurrent with a settings toggle (fires `persist()`) can interleave two truncate+write sequences on the same path.
3. Tray Quit calls `std::process::exit(0)` (shell/mod.rs:274) immediately — an in-flight save on the tokio thread is killed mid-write.

The failure mode is severe *because the load path is fail-safe*: a corrupt file parses to `Config::default()` (config.rs:130-137) — zero paired devices — so a single torn write silently revokes every phone and the owner must re-pair, with only a `warn!` in a log nobody reads.

**Fix:** Make `save` atomic and single-writer:
```rust
pub fn save(cfg: &Config) {
    let text = to_toml(cfg);
    if text.is_empty() { ... return; }
    let path = config_path();
    if let Some(parent) = path.parent() { let _ = std::fs::create_dir_all(parent); }
    let tmp = path.with_extension("toml.tmp");
    if std::fs::write(&tmp, text).is_ok() {
        let _ = std::fs::rename(&tmp, &path); // atomic on same volume
    }
}
```
Route the shell's `persist()` through the same tokio save task (e.g. bump the auth change-signal, or a dedicated save-request channel) so there is exactly one writer; on Quit, use `event_loop.exit()` + a graceful shutdown signal instead of `std::process::exit(0)`, or at minimum flush pending saves first.

### WR-05: `configs.next().expect(...)` panics the shell thread — a broken GL stack takes the tray (and Pause/Quit/Settings) down, contradicting the module's own contract

**File:** `server/server-windows/src/shell/settings.rs:92-97`

**Issue:** `SettingsWindow::new`'s doc comment says "Every fallible step surfaces as `anyhow::Error` so the caller can log-and-continue — a failed settings window must never kill the tray." But the config-picker closure passed to `DisplayBuilder::build` calls `configs.next().expect("no OpenGL config available")`. A panic inside that closure unwinds through `event_loop.run_app` on the shell thread: the tray, the Pause toggle, and Quit all die while the server keeps running headless — the exact failure the contract forbids. Broken/remote-session GPU stacks (RDP, stale drivers, VMs) are precisely where "no GL config" happens.

**Fix:** Return the error instead of panicking — pick via `configs.next()` into an `Option`, and after `build` map `None` to `anyhow::bail!("no OpenGL config available")` so `open_settings` logs and continues (shell/mod.rs:196 already handles the Err arm).

### WR-06: `Enigo::new(...).expect(...)` panics only the input thread — the server keeps running with silent, total input failure

**File:** `server/server-windows/src/input_thread.rs:374`

**Issue:** `run_input_thread` starts with `Enigo::new(&Settings::default()).expect("enigo init on input thread")`. This runs on a spawned `std::thread`; a panic there does **not** crash the process and is never observed by `main`. Result: the tray shows Normal, the phone pairs and shows Connected, every `Cmd` send lands in a dead channel via the executors' `let _ =` discipline — and nothing moves the cursor, forever, with no toast, no tray Warning state, and (depending on panic hook) at best a stderr line nobody sees. Every other thread in this codebase (clip: `arboard::Clipboard::new().ok()`, firewall: `Unknown`, autostart: `false`) degrades instead of panicking.

**Fix:** Handle the failure explicitly:
```rust
let mut enigo = match Enigo::new(&Settings::default()) {
    Ok(e) => e,
    Err(e) => {
        tracing::error!(error = %e, "enigo init failed; input injection disabled");
        // Drain commands so senders never block, or signal main to surface
        // a tray Warning / toast before returning.
        while rx.recv().is_ok() {}
        return;
    }
};
```
Ideally also plumb the failure to the tray Warning state so the owner learns input is dead.

### WR-07: Connect-by-IP field uses `TextInputType.number` — many Android keyboards omit the '.' key, making IPv4 entry impossible

**File:** `app/remote_control/lib/screens/device_list_screen.dart:490-498`

**Issue:** The Server-IP `TextField` sets `keyboardType: TextInputType.number`. On Android that requests the digits-only numeric class; several OEM keyboards (including MIUI's default on the owner's target Xiaomi device) render a keypad without a period key, so "192.168.1.50" cannot be typed and the D-03 fallback affordance is dead on exactly the devices it exists to rescue.

**Fix:**
```dart
keyboardType: const TextInputType.numberWithOptions(decimal: true),
// or, most robust for IPs across OEM keyboards:
keyboardType: TextInputType.url,
```

### WR-08: Session write-queue backpressure inside `select!` arms can stall the read loop and defeat the CONN-07 liveness deadline

**File:** `server/server-core/src/transport/session.rs:100-109, 193-205, 214-248, 279-288`

**Issue:** Push branches (`vol`/`apps`/`clip`/`blocked`) and reply sends all `tx.send(frame).await` **inside** `select!` branch bodies. While a branch body awaits, no other branch is polled — including the liveness `sleep_until`. If an authed client stops *reading* while its TCP window fills (frozen app, suspended process — distinct from the half-open silent case), the write task blocks in `sink.send`, the 64-slot mpsc fills, and the next push blocks the whole session task indefinitely. The liveness deadline never fires, so held input (e.g. a mid-drag button) is preserved past the 10s contract that `half_open_silence_releases_held_input` pins — the guarantee holds only for the *silent* half-open shape, not the alive-but-not-reading one. It also needs a steady push source (volume changes, window-list churn) to fill the queue, which the apps thread supplies for free on a busy desktop.

**Fix:** Replace blocking sends with `tx.try_send(frame)`: for watch-based pushes, a full queue can safely drop the frame (watch delivers latest-value on the next fire); for replies, either treat a full queue as a dead session (`break 'read`) or wrap the send in a `tokio::time::timeout` and break on expiry so the CONN-07 cleanup always remains reachable.

## Info

### IN-01: Pre-auth watch epochs replay as stale events right after auth

**File:** `server/server-core/src/transport/session.rs:279-288`
**Issue:** The `blocked` (and apps/clip) branches are auth-gated by the `select!` condition, so an epoch advance that happened *pre-auth* fires the moment the session auths — the client shows a "can't control this window" banner for a UIPI transition that may be minutes stale (the integration test pins this as intended, but it contradicts the "transition event, not a state prime" contract for `input.blocked`).
**Fix:** At the Authed transition (session.rs:344-354), drain the transition-style receivers with `borrow_and_update()` the way the volume snapshot does, so only genuinely post-auth transitions push.

### IN-02: Fire-on-tapDown controls inside scrollables can misfire during scroll gestures

**File:** `app/remote_control/lib/apps/apps_screen.dart:289-290, 422-423`, `app/remote_control/lib/clipboard/clipboard_screen.dart:371-372, 483-484`
**Issue:** Rows/tiles fire their action on `onTapDown` inside `SingleChildScrollView`s. `TapGestureRecognizer` fires `onTapDown` after its deadline even when a drag later wins the arena — starting a scroll on a window row can send a spurious `apps.focus`/`clip.set`. The press-on-down pattern is a deliberate house rule for the trackpad bar (non-scrolling), but it has a real misfire cost in scrollable lists.
**Fix:** For list/tile contexts, fire on `onTap` (arena-resolved) instead of `onTapDown`, keeping the accent flash on down.

### IN-03: Browser grid pairing logic only inspects the LEFT item for the full-width case

**File:** `app/remote_control/lib/browser/browser_screen.dart:97-115`
**Issue:** `if (spec.action == 'refresh' || ...)` checks only the pair-leading item; if a future reorder places `refresh` at an odd index it silently becomes a half-width right cell instead of full-width. Latent fragility, correct with today's data.
**Fix:** Also break the pair when `kBrowserActions[i + 1].action == 'refresh'`, or key the layout on an explicit `fullWidth` flag in `BrowserActionSpec`.

### IN-04: `RC_BEACON_PORT` parse aborts the server while `RC_PORT` warns-and-falls-through

**File:** `server/server-windows/src/main.rs:313-318`
**Issue:** 07-07 deliberately made `RC_PORT` fail-safe (warn + fallthrough, T-07-27), but an unparseable `RC_BEACON_PORT` still `?`-propagates and exits the whole server. Inconsistent fail-safe discipline for two sibling env vars.
**Fix:** Mirror `resolve_port`: warn and fall back to `beacon::DEFAULT_BEACON_PORT`.

### IN-05: Stale doc comment — tray icon canvas says 16x16, constant is 32

**File:** `server/server-windows/src/shell/tray.rs:34-36`
**Issue:** The comment reads "16x16 canvas is plenty" directly above `const TRAY_ICON_SIZE: u32 = 32;`.
**Fix:** Update the comment to 32x32.

### IN-06: `_confirmRevoke` uses `ref` after `await showDialog` without a disposed guard

**File:** `app/remote_control/lib/settings/settings_screen.dart:251-294`
**Issue:** After the dialog await, `ref.read(...)` runs on a `ConsumerWidget` whose element may have been unmounted (settings screen popped beneath the dialog) — Riverpod throws "Cannot use ref after the widget was disposed." Narrow window, but the pattern is guarded everywhere else in this codebase with `mounted` checks.
**Fix:** Convert `_PairedPcRow` to a `ConsumerStatefulWidget` and check `mounted` (or `context.mounted`) after the await before touching `ref`.

### IN-07: UIPI probe only runs on Move/Click — pure keyboard input into an elevated window never triggers the banner

**File:** `server/server-windows/src/input_thread.rs:381-382, 410-412`
**Issue:** `maybe_check_uipi` fires only in the `Cmd::Move` and `Cmd::Click` arms. A user who opens the Keyboard screen and types into an elevated window (no cursor movement) gets silent drops with no `input.blocked` push. The throttle already bounds the cost, so adding the key arms is cheap.
**Fix:** Call `maybe_check_uipi` in the `KeyDown`/`KeyTap`/`Type` arms as well.

### IN-08: Slide track leaves FSM and thumb frozen mid-track if `enabled` flips false during a drag

**File:** `app/remote_control/lib/power/power_screen.dart:273-318`
**Issue:** `_onUpdate`/`_onEnd` early-return when `!widget.enabled`. A connection drop mid-slide leaves `_display` frozen at partial progress (thumb stuck mid-track, muted) and the FSM in its dragging state until the next `dragStart`. Visual-only — no send can occur — but looks broken.
**Fix:** In `didUpdateWidget`, on an `enabled` true→false transition reset `_display = 0` (with `_animate = true`) and drive the FSM's cancel path.

---

_Reviewed: 2026-07-15T12:00:00Z_
_Reviewer: Claude (gsd-code-reviewer)_
_Depth: standard_
