---
phase: 07-server-shell-dashboard-polish
fixed_at: 2026-07-15T12:00:00Z
review_path: .planning/phases/07-server-shell-dashboard-polish/07-REVIEW.md
iteration: 1
findings_in_scope: 9
fixed: 9
skipped: 0
status: all_fixed
---

# Phase 7: Code Review Fix Report

**Fixed at:** 2026-07-15T12:00:00Z
**Source review:** .planning/phases/07-server-shell-dashboard-polish/07-REVIEW.md
**Iteration:** 1

**Summary:**
- Findings in scope: 9 (CR-01, WR-01..WR-08 — Info findings IN-01..IN-08 out of scope)
- Fixed: 9
- Skipped: 0

Each fix was committed atomically on an isolated worktree. Dart fixes were
verified with `flutter analyze lib` (clean) plus the relevant `flutter test`
suites; Rust fixes with `cargo build --workspace` (green) and
`cargo test --workspace` (all passing, including the CONN-07 integration
tests `half_open_silence_releases_held_input` and
`disconnect_mid_drag_releases_held_input`).

## Fixed Issues

### CR-01: Held input released on widget dispose while session authed

**Files modified:** `app/remote_control/lib/keyboard/modifier_fsm.dart`, `app/remote_control/lib/keyboard/keyboard_panel.dart`, `app/remote_control/lib/keyboard/key_rows.dart`, `app/remote_control/lib/trackpad/trackpad_screen.dart`
**Commit:** 98e2c8e
**Status:** fixed (requires human verification — held-input lifecycle logic)
**Applied fix:** Added `ModifierFsm.releaseAll()` (emits `SendModifierUp` for every locked modifier, resets to rest). `KeyboardPanel.dispose()` now flushes owed key ups + locked-modifier ups when `!isDisconnected()`. Added `_KeyCapState.dispose()` to release a non-deferred held cap (covers screen-pop and the Nav/Fn/Num group-switch rebuild). `TrackpadScreen.dispose()` now sends `DragMsg(action:'end')` before `_driver.dispose()` when `dragLocked && isAuthed`. All release paths are idempotent via `_onKeyUp`'s `remove()` guard and the live-socket gate, so they never leak a stale `up` into a new session (D-12 path unchanged). Existing keyboard/trackpad tests (incl. CR-02 rollover and D-12 disconnect-wipe) still pass.

### WR-01: Seed already-seen toast marker at mount (Apps + Clipboard)

**Files modified:** `app/remote_control/lib/apps/apps_screen.dart`, `app/remote_control/lib/clipboard/clipboard_screen.dart`
**Commit:** b91e6b6
**Status:** fixed
**Applied fix:** Seeded `_shownError = _service.lastError` and `_shownFetch = ...lastFetchEvent` in `initState` (before subscribing to `changes`) so the first post-mount ping no longer re-toasts a stale error/fetch from a previous visit — mirroring the UipiBanner mount-seed pattern.

### WR-02: Dial-episode generation guard in `_dial`

**Files modified:** `app/remote_control/lib/net/connection_service.dart`
**Commit:** 7aea910
**Status:** fixed (requires human verification — overlapping-dial ordering logic)
**Applied fix:** Added `_dialGen`, bumped at the top of every `_dial`. The stale check is now `gen != _dialGen || _fsm.state != connecting`, so a dial whose `_connect` resolves after a newer dial started closes its own socket and bails instead of installing a channel/HandshakeDriver bound to a superseded target (or leaking `_channel`/`_sub`). Mirrors the existing `_backoffGen` idiom. `connection_service_test` passes.

### WR-03: Guard keystore token read + pairing write

**Files modified:** `app/remote_control/lib/net/connection_service.dart`
**Commit:** 9e10779
**Status:** fixed
**Applied fix:** Wrapped the dial-time `_store.tokenFor` read in try/catch (degrades a lost token to `null` → PIN path) and guarded the fire-and-forget `_persistNewPairing` with `.catchError((_) {})` so a keystore throw after an OS update no longer strands the FSM in `connecting` or surfaces as an uncaught zone error. The optional "couldn't remember this PC" UI hint from the review was intentionally deferred (no existing surface for it) and is noted as a follow-up in the code comment.

### WR-04: Atomic config.toml save

**Files modified:** `server/server-windows/src/config.rs`
**Commit:** ae8a8f3
**Status:** fixed (partial — see note)
**Applied fix:** `config::save` now writes to a sibling `config.toml.tmp` and atomically renames it over the target (Windows `MoveFileEx` REPLACE_EXISTING), removing the torn-write corruption that the fail-safe load path would otherwise turn into a silent revoke-all. Config round-trip and corrupt-file tests pass.
**Note / deferred:** The review also called for (a) routing the shell's `persist()` through a single writer to serialize it against the tokio auth-change save, and (b) replacing the tray-Quit `std::process::exit(0)` with a graceful shutdown that flushes pending saves. These are larger cross-thread refactors with real behavior risk; they were deliberately NOT applied here. The atomic rename alone eliminates the *severe* failure mode (a truncated file that silently revokes every phone) even under the two-writer race and a killed-mid-write Quit — the worst case degrades to "last writer wins / one update lost," never corruption. The single-writer serialization and graceful-shutdown flush should be a follow-up.

### WR-05: Contain the GL-config-picker panic

**Files modified:** `server/server-windows/src/shell/settings.rs`
**Commit:** 0b6fe36
**Status:** fixed (requires human verification — degrade path, no automated test)
**Applied fix:** The `glutin_winit` picker closure must return a `Config`, so an empty iterator (broken/remote GPU stack) can only be signalled by panic. Wrapped the `DisplayBuilder::build` call in `std::panic::catch_unwind(AssertUnwindSafe(...))` and convert a caught unwind into `anyhow::anyhow!("no OpenGL config available")`, so `open_settings` (shell/mod.rs:196 Err arm) logs and continues with the tray alive instead of unwinding through `event_loop.run_app`. Note: this differs from the review's literal "capture into an Option and bail after build" suggestion, which is infeasible because the picker signature requires a `Config` return in the empty case; catch_unwind achieves the stated intent (return an error, keep the tray). Workspace builds; settings tests pass.

### WR-06: Degrade instead of panicking on enigo init failure

**Files modified:** `server/server-windows/src/input_thread.rs`
**Commit:** 47ad952
**Status:** fixed
**Applied fix:** Replaced `Enigo::new(...).expect(...)` with a `match`: on failure, log an error, drain the command channel (`while rx.recv().is_ok() {}`) so senders never block, and return with input injection disabled — matching the clip/firewall/autostart degrade-never-panic threads. input_thread tests pass.

### WR-07: Decimal number keyboard for connect-by-IP field

**Files modified:** `app/remote_control/lib/screens/device_list_screen.dart`
**Commit:** 7d0a535
**Status:** fixed
**Applied fix:** Changed the IP `TextField` from `TextInputType.number` to `const TextInputType.numberWithOptions(decimal: true)` so OEM keyboards (e.g. MIUI) that omit the '.' key on the digits-only class render a period, making IPv4 entry possible. The port field was left as `number` (no decimal needed).

### WR-08: Non-blocking sends in session `select!` arms

**Files modified:** `server/server-core/src/transport/session.rs`
**Commit:** 424d279
**Status:** fixed (requires human verification — liveness/backpressure logic)
**Applied fix:** Converted every `tx.send(frame).await` inside `select!` branch bodies to `tx.try_send`. The four watch-push branches (vol/apps/clip/blocked) drop on a full queue (`TrySendError::Full`) — watch is latest-value-only so the next fire re-delivers — and break `'read` on `Closed`. The reply sends (handshake replies, versionMismatch close, after-auth vol snapshot) treat a full queue as a dead session (`break 'read`) since a dropped reply would corrupt protocol state. This keeps the liveness `sleep_until` arm reachable so an alive-but-not-reading client's held input is released within the CONN-07 10s deadline. All 22 integration tests pass, including `half_open_silence_releases_held_input`.

## Skipped Issues

None — all in-scope findings were fixed.

---

_Fixed: 2026-07-15T12:00:00Z_
_Fixer: Claude (gsd-code-fixer)_
_Iteration: 1_
