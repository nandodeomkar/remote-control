# Phase 4: Trackpad & Keyboard - Pattern Map

**Mapped:** 2026-07-09
**Files analyzed:** 14 (6 modified, 8 new)
**Analogs found:** 12 / 14

This phase is "fill the real executors + build client producers." ~70% of the hard
machinery (wire protocol, codecs, send paths, diff helper, dispatch/held-input) already
exists and is fixture-proven. Every new file has a strong in-repo analog to copy from;
only two new UI surfaces (keyboard panel widgets, key rows) have no direct predecessor
and lean on generic Flutter Material + the UI-SPEC contract.

## File Classification

| New/Modified File | Role | Data Flow | Closest Analog | Match Quality |
|-------------------|------|-----------|----------------|---------------|
| `server/server-windows/src/input_thread.rs` (MOD) | executor/input-thread | streaming (mpsc) | itself (extend `Cmd` enum + arms) | exact (self) |
| `server/server-windows/src/executors/mouse_keys.rs` (MOD) | executor | request-response | itself (fill stubs, mirror `move_rel`/`scroll`) | exact (self) |
| `server/server-windows/src/executors/keymap.rs` (NEW) | utility/mapping | transform | `dispatch/router.rs` macro-string tables (L315–329) | role-match |
| `server/server-windows/Cargo.toml` (MOD) | config | — | itself (feature-flag list L11) | exact (self) |
| `app/remote_control/lib/net/connection_service.dart` (MOD) | service | request-response + volatile | `sendMove` (L292–296) → new `sendScrollVolatile` | exact (self) |
| `app/remote_control/lib/trackpad/move_sender.dart` (exists) | utility | streaming (sink) | already has `sendScroll` (L35–37) — no change | exact (self) |
| `app/remote_control/lib/trackpad/gesture_classifier.dart` (NEW) | FSM/pure logic | event-driven | `net/reconnect_fsm.dart` / `handshake_fsm.dart` | role-match (house style) |
| `app/remote_control/lib/trackpad/trackpad_screen.dart` (MOD) | component (screen) | event-driven | itself (Listener hot path, L59–90) | exact (self) |
| `app/remote_control/lib/trackpad/mouse_buttons.dart` (NEW) | component | request-response | UI-SPEC contract + trackpad widget style | partial |
| `app/remote_control/lib/keyboard/diff_ops.dart` (NEW) | utility (thin wrapper) | transform | `remote_protocol/src/diff_ops.dart` `computeDiff` | role-match |
| `app/remote_control/lib/keyboard/hidden_text_input.dart` (NEW) | component | event-driven | none (generic Flutter `TextField`) | no analog |
| `app/remote_control/lib/keyboard/modifier_chip.dart` (NEW) | FSM + component | event-driven | `reconnect_fsm.dart` (FSM half) | role-match (FSM only) |
| `app/remote_control/lib/keyboard/keyboard_panel.dart` (NEW) | component | — | none (generic Flutter panel) | no analog |
| `app/remote_control/lib/keyboard/key_rows.dart` (NEW) | component | request-response | UI-SPEC contract | partial |

## Pattern Assignments

### `server/server-windows/src/input_thread.rs` (MOD — input-thread, streaming)

**Analog:** itself. Extend the existing `Cmd` enum (L14–20) and add match arms in
`run_input_thread` (L60–82). D-01/D-02: keep `SubPixelAccumulator` (L26–48) verbatim,
only swap the `Cmd::Move` injection from `enigo.move_mouse(Coordinate::Rel)` to raw
`SendInput(ABSOLUTE|VIRTUALDESK)` per RESEARCH Pattern 1.

**Existing enum + accumulator to extend** (L14–48): `Cmd::Move(f32,f32)`, `Cmd::Scroll(f32,f32)`,
`SubPixelAccumulator::step` returning `(i32,i32)` with carried fraction.

**Existing move arm to REPLACE** (L62–68):
```rust
Cmd::Move(dx, dy) => {
    let (ix, iy) = move_acc.step(dx, dy);
    if ix != 0 || iy != 0 {
        let _ = enigo.move_mouse(ix, iy, Coordinate::Rel);   // ← becomes GetCursorPos + inject_absolute(p.x+ix, p.y+iy)
    }
}
```

**Non-fatal-injection rule to preserve** (L65–67): failures are dropped (`let _ =`), never
panic — carry this to every new arm (click/key/text). Extract a pure `normalize_virtual(x,y,metrics)`
fn so the normalization math is unit-testable without a display (Wave 0 gap).

---

### `server/server-windows/src/executors/mouse_keys.rs` (MOD — executor, request-response)

**Analog:** itself. The stubbed methods (L36–59) each become ONE non-blocking `Cmd` send,
mirroring the shipped `move_rel`/`scroll` (L30–35). Never touch `Enigo` here — it is `!Sync`
and lives only on the input thread (RESEARCH Pattern 3, hard constraint).

**Shipped pattern to copy for every stub** (L30–35):
```rust
fn move_rel(&self, dx: f32, dy: f32) {
    let _ = self.tx.send(Cmd::Move(dx, dy));
}
fn scroll(&self, dx: f32, dy: f32) {
    let _ = self.tx.send(Cmd::Scroll(dx, dy));
}
```

**Stubs to fill** (L36–59) — `click`, `button_down`, `button_up`, `key_down`, `key_up`,
`key_tap(code, mods)`, `type_text(text)`, `backspace(n)`. Each is `let _ = self.tx.send(Cmd::…)`.
The corresponding new `Cmd` variants + input-thread arms are RESEARCH Pattern 3.

**Trait contract** (server-core `executors/mod.rs` L51–62): `MouseKeys` is `&self` sync;
signatures are fixed — `key_tap(&self, code: KeyCode, mods: &[Modifier])`, `backspace(&self, n: u32)`.
`Button`/`KeyCode`/`Modifier` are the core types (L16–36).

---

### `server/server-windows/src/executors/keymap.rs` (NEW — utility/mapping, transform)

**Analog:** the terse macro-string tables already in `dispatch/router.rs` (L315–329,
`"refresh" => ("F5", …)`, `"next" => "Right"`, `"start" => "F5"`, `"end" => "Esc"`).
Establish ONE `map_key(&KeyCode) -> Option<Key>` table here (KEY-02 / RESEARCH Pattern 4);
server-windows only, so server-core stays zero-Windows-deps.

**Vocabulary decision (Open Q3 — planner must lock ONE):** router.rs uses terse strings
("F5","Right","Left","Esc","Tab"); Phase-1 tests used DOM-ish "KeyA"/"ShiftLeft"/"KeyW"
(router.rs L464, L534, L559). Pick one, document it in keymap.rs, and make the Flutter key
rows emit exactly those strings. Add the `keymap_covers_all_codes` unit test (Wave 0 gap).

**enigo Key variants available** (RESEARCH Pattern 4, verified enigo 0.6.1): `F1..F12`,
`UpArrow/DownArrow/LeftArrow/RightArrow`, `Home/End/PageUp/PageDown/Delete/Escape/Tab`,
`Control/Alt/Shift/Meta` (Meta=Win), `Numpad0..9`, `Return`, `Unicode(char)`, `Other(u32)`.

**Unknown-code drop pattern** (router.rs L83, L106–118): the router already drops unknown
buttons/actions silently — keymap returning `None` must map to "drop", same convention.

---

### `server/server-windows/Cargo.toml` (MOD — config)

**Analog:** itself (L11). Current `windows` features: `["Win32_Foundation", "Win32_UI_HiDpi"]`.
Add `Win32_UI_Input_KeyboardAndMouse` (SendInput/INPUT/MOUSEINPUT/MOUSEEVENTF_*) and
`Win32_UI_WindowsAndMessaging` (GetCursorPos/GetSystemMetrics/SM_*). POINT is in
`Win32_Foundation` (already present). RESEARCH Pitfall 1.

---

### `app/remote_control/lib/net/connection_service.dart` (MOD — service, volatile path)

**Analog:** itself. Add `sendScrollVolatile(dx, dy)` mirroring `sendMove` exactly (Open Q4).
Scroll `0x02` frames are volatile like move — NOT reliable.

**Shipped volatile method to mirror** (L292–296):
```dart
void sendMove(double dx, double dy) {
  if (!_policy.shouldSendVolatile()) return;
  _sender?.sendMove(dx, dy);
  _probe?.onMove();
}
```
New method: same `_policy.shouldSendVolatile()` gate + `_sender?.sendScroll(dx, dy)` (the
sink method already exists in `move_sender.dart` L35) + probe tick.

**Reliable path for clicks/keys/text/drag** (L300–303) — already shipped, no change:
```dart
void sendReliable(RemoteMessage msg) {
  _policy.enqueueOrSendReliable(encodeMessage(msg), _addToSink);
}
```
Clicks (`ClickMsg`), drag (`DragMsg`), keys (`KeyMsg`), text (`TextMsg`) all go through this.

**Disconnect reset seam for D-12** (L524–540, `_teardownChannel`): the client-side modifier/
held-key reset should hook the same teardown that already flips `_policy.authed = false`;
UI (modifier chips) subscribes to `changes` (L252) and clears on the disconnected transition.

---

### `app/remote_control/lib/trackpad/gesture_classifier.dart` (NEW — pure FSM, event-driven)

**Analog:** `net/reconnect_fsm.dart` + `net/handshake_fsm.dart` — the pure IO-free,
injected-seam, unit-tested house style. Copy this structure exactly (D-04, D-06).

**House-style contract to mirror** (`reconnect_fsm.dart` L1–22): "no IO … imports nothing
from Flutter or the IO libraries … timers/sockets/storage are all driver effects."
The classifier consumes raw pointer events (down/move/up/cancel + pointer id) and EMITS
intents (move / tap→click-left / two-finger-tap→click-right / scroll / long-press-drag);
it must not call `sendMove`/`sendReliable` itself — the screen wires intents to the service
(same effect/driver split as the FSMs). Injectable clock seam (`nowMillis`) for the tap-window
and ~250ms long-press timing (like `ConnectionService`'s `_nowMillis`, service L206).

**Tunable constants in ONE place** (D-06): tap-vs-move tolerance, two-finger-tap window
(~200ms), long-press (~250ms), momentum decay (~0.92/16ms), acceleration coefficients.
Land as named constants (RESEARCH Pitfall 4). On-device feel-check is an execution checkpoint.

**Momentum loop** (RESEARCH Pattern 2): `Timer.periodic(16ms)` decaying velocity →
`sendScrollVolatile`; ANY `onPointerDown` cancels the timer first (instant touch-stop).

---

### `app/remote_control/lib/trackpad/trackpad_screen.dart` (MOD — screen, event-driven)

**Analog:** itself. Keep the Phase-2/3 hot-path invariant: `Listener.onPointerMove` →
`service.sendMove`, zero rebuild, zero allocation (L59–90). Grow it to mount the classifier,
L/M/R bar, drag-lock pill, and the keyboard-panel toggle.

**Hot-path route to preserve** (L59–61):
```dart
void _onPointerMove(PointerMoveEvent event) {
  _service.sendMove(event.delta.dx, event.delta.dy);
}
```
Now the raw pointer stream ALSO feeds the classifier — but clicks/scroll/drag/keys must NOT
trigger `setState` on this surface or the header chip (RESEARCH Anti-Pattern; Pitfall 6 for
panel animation not rebuilding the `Listener` subtree).

**Cached-service + transition-only-watch pattern** (L40–48, L67): `_service` read once in
`initState`; `ref.watch(connectionStatusProvider)` rebuilds only on lifecycle transitions.
New chrome (L/M/R, pill, toggle) subscribes the same way — never the move path.

**Gated-state treatment** (L84–88): muted `#6B7280` text when not authed; L/M/R + keys +
chips follow the same "muted, not red" rule (UI-SPEC Component States).

---

### `app/remote_control/lib/trackpad/mouse_buttons.dart` (NEW — component)

**Analog:** partial — no existing button-bar widget. Follow the trackpad screen's Material
style (dark `Container`, `Color(0xFF16181D)` fill / `0xFF2A2D34` border) and UI-SPEC
"L/M/R mouse button" contract (64px bar, L flex 2 / M flex 1 / R flex 2, ≥48px, accent
flash on press). On tap-down: `HapticFeedback` tick + `_service.sendReliable(ClickMsg(button: …))`.

**Message class to emit** (`json_codec.dart` L239–248): `ClickMsg({required this.button})`
with button `"left"|"middle"|"right"`.

---

### `app/remote_control/lib/keyboard/diff_ops.dart` (NEW — thin wrapper, transform)

**Analog:** `remote_protocol/src/diff_ops.dart` — do NOT reimplement. Wire the hidden field's
committed-text transitions through the shipped `computeDiff` and emit `TextMsg`.

**Shipped helper to reuse** (`diff_ops.dart` L32–49): `computeDiff(oldText, newText) → TextDiff(bs, ins)`,
grapheme-cluster-exact via `package:characters`. Fixture-proven against `protocol/fixtures/text/*`.

**Wiring pattern** (RESEARCH Code Examples): track `_committed`; on `onChanged(next)` compute
`computeDiff(_committed, next)`, if non-empty `sendReliable(TextMsg(bs, ins))`, store `next`.
`TextMsg({required bs, required ins})` is `json_codec.dart` L329–341. RESEARCH Pitfall 5:
diff on committed transitions, not composing-region churn (SPEC §12: never log `ins`).

---

### `app/remote_control/lib/keyboard/hidden_text_input.dart` (NEW — component)

**Analog:** none in-repo (generic Flutter `TextField` + `TextEditingController` + explicit
`FocusNode`). D-08 offscreen/zero-opacity field; no caret/selection/background. RESEARCH
Pitfall 6: keep focused while panel open; special-key buttons must not steal focus.

---

### `app/remote_control/lib/keyboard/modifier_chip.dart` (NEW — FSM + component, event-driven)

**Analog (FSM half):** `reconnect_fsm.dart` — pure arm/lock/chord/auto-reset state machine,
unit-tested seam (`test/keyboard/modifier_fsm_test.dart`, Wave 0 gap). The visual chip is
UI-SPEC "Modifier chip" (rest / armed-outline / locked-solid / disabled).

**FSM model to lock** (D-10 + RESEARCH Open Q2 / Pitfall 7): tap = arm (auto-reset after
next non-modifier key sends combo via `KeyMsg` `mods`); long-press = LOCK. LOCKED modifier →
send `KeyMsg(code: "ControlLeft"/…, action: "down"/"up")` as a physical hold (NOT the `mods`
array), so OS chording+repeat work and CONN-07/D-12 release it. ARMED (tap) → the `mods`
array on the next `KeyMsg(action:"tap")`.

**Message class to emit** (`json_codec.dart` L282–326): `KeyMsg({required code, required action,
mods=const []})`; `mods` are `"ctrl"|"alt"|"shift"|"win"`; `action` `"tap"|"down"|"up"`.

**Server routing already handles this** (router.rs L106–121): `tap`→`key_tap(code, mods)`,
`down`→`note_key_down + key_down`, `up`→`note_key_up + key_up`. No server change for the model.

**Reset-on-disconnect (D-12):** clear all chip state on the `ChipStatus.disconnected` transition
off `ConnectionService.changes` (service L252, L524–540).

---

### `app/remote_control/lib/keyboard/keyboard_panel.dart` (NEW — component)

**Analog:** none (generic Flutter expandable panel). D-07: docks bottom, shrinks (never hides)
the trackpad, focuses the hidden input. UI-SPEC "Keyboard panel" (200ms slide, `#0E0F12`
continuous bg, group switcher persisted via `shared_preferences`). RESEARCH Pitfall 6:
expand/collapse must not rebuild the `Listener` subtree that owns the move path.

---

### `app/remote_control/lib/keyboard/key_rows.dart` (NEW — component, request-response)

**Analog:** partial — UI-SPEC "Special-key rows" contract (Nav default / Fn / Num groups,
key caps ≥48px, `HapticFeedback` tick on press). Emits `KeyMsg` on the reliable path; the
`code` strings MUST match `keymap.rs` (Open Q3 vocabulary). KEY-04 hold: press sends
`KeyMsg(action:"down")`, release sends `KeyMsg(action:"up")` — never tap-spam (D-11).

## Shared Patterns

### New executor commands ride the input-thread channel (server)
**Source:** `input_thread.rs` (`Cmd` enum L14–20) + `mouse_keys.rs` (L30–35).
**Apply to:** every filled stub in `mouse_keys.rs`, keymap consumers.
Extend `Cmd`, forward with `let _ = self.tx.send(Cmd::…)`, handle on the `&mut Enigo` thread.
Never call `Enigo` from an `&self` executor method (it is `!Sync`). Injection failures drop,
never panic (`input_thread.rs` L65–67).

### Pure IO-free FSM with injected seams (client)
**Source:** `net/reconnect_fsm.dart` (L1–22 doc contract) + `net/handshake_fsm.dart`.
**Apply to:** `gesture_classifier.dart`, `modifier_chip.dart` FSM.
No Flutter/IO imports in the logic file; emit intents/effects, let the widget/service execute
them; inject the clock (`nowMillis`) for deterministic unit tests. Tunable constants in one place.

### Two send paths, correct class per message (client)
**Source:** `connection_service.dart` `sendMove` (L292–296, volatile) / `sendReliable` (L300–303).
`SendPolicy.shouldSendVolatile` (send_policy.dart L38) / `enqueueOrSendReliable` (L42–52).
**Apply to:** all Phase-4 producers. Binary move/scroll `0x01`/`0x02` → volatile (drop-if-not-authed,
never queued). `click`/`drag`/`key`/`text` → reliable (bounded FIFO, flushed on auth).

### Fixture-proven codecs — never re-implement (client)
**Source:** `move_sender.dart` L4–8 note; `remote_protocol` `encodeMove`/`encodeScroll`/`computeDiff`.
**Apply to:** `diff_ops.dart` (use `computeDiff`), scroll frames (use `sendScroll`→`encodeScroll`).
Re-encoding risks endianness/opcode/grapheme drift against the Rust decoder.

### Unknown input dropped silently (server)
**Source:** `router.rs` L83, L106–118 (`parse_button` None, unknown action `=> {}`).
**Apply to:** `keymap.rs` (`map_key` returning `None` = drop). V5 input-validation control.

### Secrets discipline — never log typed text
**Source:** SPEC §12 (redaction-mandatory); `connection_service.dart` L26–28 token discipline.
**Apply to:** `diff_ops.dart`, `hidden_text_input.dart`, server `type_text`/`backspace` arms.
Never log `ins`/typed content.

## No Analog Found

| File | Role | Data Flow | Reason |
|------|------|-----------|--------|
| `keyboard/hidden_text_input.dart` | component | event-driven | No existing offscreen-IME `TextField` in repo; generic Flutter + UI-SPEC |
| `keyboard/keyboard_panel.dart` | component | — | No existing expandable-panel widget; generic Flutter + UI-SPEC layout |

(`mouse_buttons.dart` and `key_rows.dart` are partial — no button/keycap-bar analog, but they
follow the trackpad screen's Material/token style and emit already-existing message classes.)

## Metadata

**Analog search scope:** `server/server-windows/src/{input_thread,executors}`,
`server/server-core/src/{executors,dispatch}`, `app/remote_control/lib/{net,trackpad,keyboard}`,
`app/packages/remote_protocol/lib/src`.
**Files scanned:** ~16 read this session.
**Pattern extraction date:** 2026-07-09
