# Phase 4: Trackpad & Keyboard - Research

**Researched:** 2026-07-09
**Domain:** Windows input injection (enigo/SendInput), Flutter raw-pointer gesture classification, IME diff-ops
**Confidence:** HIGH (server injection paths verified from enigo 0.6.1 source; client gesture patterns MEDIUM)

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- **D-01:** Switch server from RELATIVE to ABSOLUTE injection (enigo `Coordinate::Abs` via GetCursorPos + accumulated delta → normalized absolute SendInput). Bypasses Windows "Enhance pointer precision" ballistics so slow/small drags track 1:1. Confirmed problem from 02-04-GATE-RESULT.md.
- **D-02:** KEEP the existing server sub-pixel accumulator — never at fault; absolute injection consumes the accumulated position.
- **D-03:** Multi-monitor / virtual-desktop normalization is a known edge case (absolute coords normalize to the VIRTUAL desktop, not the primary monitor). Researcher must specify normalization math + a multi-display verification before implementation.
- **D-04:** Gesture classification is CLIENT-side, off the raw `Listener` pointer stream. One classifier distinguishes: single-finger move, tap (→`click left`), two-finger tap (→`click right`), two-finger scroll (→`0x02` frames), long-press-then-move drag with drag-lock.
- **D-05:** Benchmark = the Remote Mouse app. Ship sensible defaults (velocity accel curve; ~250ms long-press for drag-lock; scroll momentum that halts instantly on new touch) + expose a **sensitivity** setting (shared_preferences, non-secret).
- **D-06:** Exact curve shapes/thresholds are ON-DEVICE TUNING — land tunable constants in ONE place; include a device feel-check as an execution checkpoint. Do not hardcode magic numbers as final.
- **D-07:** Keyboard is an EXPANDABLE PANEL over the trackpad, not a separate screen. Trackpad stays the home surface.
- **D-08:** Typing uses a hidden/offscreen system `TextField` to capture the device IME; client computes diff-ops (`bs`/`ins`, extended-grapheme-cluster counting per SPEC §8) and sends `text` messages. Do NOT reinvent an on-screen keyboard.
- **D-09:** Special keys are toggleable ROWS (F1–F12, numpad, nav-cluster). Default visible row = nav-cluster.
- **D-10:** Tapping a modifier shows a VISIBLE held state; next non-modifier key sends the combo (`key` with `mods`) then modifiers auto-reset. Multiple modifiers chord. LONG-PRESS a modifier = lock it held until tapped off.
- **D-11:** Autorepeat (KEY-04) is server-side key-down/hold, driven by `key` `action: down`/`up` from a held on-screen key — never client tap-spam.
- **D-12:** All modifier/held state resets on disconnect (client-side), layered on the shipped CONN-07 server-side release-all.

### Claude's Discretion
Owner delegated area selection ("no preference") and confirmed all four locked decisions. Exact constants, widget structure, and slice ordering are Claude/planner discretion within these decisions. MVP mode: expect SPIDR slicing (trackpad slice(s) before keyboard slice(s)).

### Deferred Ideas (OUT OF SCOPE)
- Gyro/air-mouse mode (FEAT-01) — backlog.
- UDP mouse-delta channel (TRAN-01) — NOT triggered (Phase-2 gate passed on ws://, p50 6ms).
- Server one-pairing-per-run todo — Phase-7 concern, deferred.
- Overloaded `noPairing` reason copy todo — server-protocol follow-up, deferred.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| PAD-01 | One-finger move, velocity acceleration, server sub-pixel accumulation | Absolute-injection fix (§ Standard Stack / Pitfall 1); client accel curve applied on a tunable multiplier before `sendMove`; existing `SubPixelAccumulator` kept (D-02) |
| PAD-02 | Tap=left / two-finger tap=right / on-screen L/M/R buttons | Client gesture classifier (Pattern 1) → `ClickMsg` on reliable path; real `click()` executor (Pattern 3); L/M/R buttons per UI-SPEC |
| PAD-03 | Two-finger scroll, momentum + instant touch-stop | Client momentum decay loop → `encodeScroll` `0x02` frames (Pattern 2); real `scroll()` executor already wired |
| PAD-04 | Long-press drag with drag-lock for screen-edge drags | Classifier long-press timer → `DragMsg {start/end}`; server `button_down/up` + HeldInput (already routed); real executor (Pattern 3) |
| KEY-01 | IME typing incl. autocomplete/emoji/backspace via diff-ops | Hidden `TextField` + `TextEditingController` → existing `computeDiff` (grapheme-correct) → `TextMsg`; real `type_text`/`backspace` executors |
| KEY-02 | F1–F12, numpad, nav-cluster keys | `KeyMsg {code, action:tap}` → server key mapping table → enigo `Key` (Pattern 4) |
| KEY-03 | Sticky modifiers Ctrl/Alt/Shift/Win → combos | Client modifier FSM → `KeyMsg {code, mods, action:tap}` → server `key_tap(code, mods)` (already routed); see Open Question 2 for the lock+hold interaction |
| KEY-04 | Held keys autorepeat (server-side down/hold) | Client sends `key {action:down}` on press, `{action:up}` on release; server holds via enigo `Direction::Press`/`Release`; Windows OS generates the repeat (Pattern 5) |
</phase_requirements>

## Summary

Phase 4 is a **"fill the real executors + build the client producers"** phase, not a greenfield build. The wire protocol, both codecs, the client send paths (`sendMove` volatile / `sendReliable` queued), the grapheme-correct diff helper (`computeDiff`), the binary/JSON message classes, and the entire server dispatch/routing/held-input machinery **already exist and are fixture-proven**. What is missing is (a) the real Windows input execution behind the `MouseKeys` trait (the `EnigoMouseKeys` methods for click/button/key/text/backspace are stubbed with `// Phase 4: fills this`), (b) the relative→absolute move conversion (D-01), and (c) all the client UI/gesture/keyboard surfaces.

The single most important technical finding: **enigo 0.6.1's absolute-move path normalizes against the PRIMARY monitor only (`GetSystemMetrics(SM_CXSCREEN/SM_CYSCREEN)`) and does NOT set `MOUSEEVENTF_VIRTUALDESK`** — there is a literal `// TODO: Check if we should use MOUSEEVENTF_VIRTUALDESK too` in its source. This means *both* enigo mechanisms for bypassing ballistics (explicit `Coordinate::Abs`, or the default `windows_subject_to_mouse_speed_and_acceleration_level: false` which auto-converts `Rel`→`Abs`) are **broken on multi-monitor setups**: a cursor on a secondary display or at a negative virtual coordinate normalizes wrong and jumps/clamps. To satisfy D-01 AND D-03 correctly, the move executor should drop to raw `SendInput` via the `windows` crate (already a dependency) with explicit virtual-desktop normalization. The exact math is given in Pattern 1.

A second cross-cutting finding: the `MouseKeys` trait is `&self` sync while enigo's methods are `&mut self` and `!Sync`. The existing code already solved this by routing move/scroll through an mpsc `Cmd` channel to a dedicated input thread that owns `&mut Enigo`. **Every new executor method (click/key/text/…) must extend the `Cmd` enum and be handled on that same thread — not call enigo directly.** This is a hard constraint that shapes how the server slice is built.

**Primary recommendation:** Slice the server executors first (move-absolute + click + key + text on the input thread), because neither the trackpad client slice nor the keyboard client slice is end-to-end testable on hardware without them. Then slice the client vertically: trackpad (gesture classifier + L/M/R + drag-lock + momentum) before keyboard (hidden IME + key rows + modifier FSM).

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Gesture classification (move/tap/2-finger/scroll/drag) | Flutter client (`Listener` stream) | — | D-04 locks classification client-side; raw pointer stream is where multi-touch arrives |
| Velocity acceleration curve + sensitivity | Flutter client | — | Curve applied to deltas before `sendMove`; sensitivity is a client shared_preferences value (D-05) |
| Sub-pixel accumulation | Rust server (input thread) | — | D-02: already lives in `SubPixelAccumulator`; only the OS gets integer pixels |
| Absolute pointer positioning + monitor normalization | Rust server-windows (raw SendInput) | — | D-01/D-03: OS-injection concern; requires Win32 virtual-desktop metrics |
| IME text capture + diff computation | Flutter client (hidden `TextField` + `computeDiff`) | — | D-08; grapheme counting must match SPEC §8, helper already exists |
| Sticky-modifier / autorepeat state machine | Flutter client (chip FSM) | Rust server (held-key tracking) | Client owns the visible held/locked state (D-10); server holds keys down + releases on session end (D-11/D-12/CONN-07) |
| Key-code → OS key mapping | Rust server-windows | — | KeyCode is opaque in server-core (zero-Windows-deps); enigo `Key` mapping is Windows-specific |
| Real input execution (SendInput / enigo) | Rust server-windows (input thread) | — | `!Sync` `Enigo` + `&mut` methods confined to one thread |

## Standard Stack

No new packages are introduced this phase. Every dependency is already locked in CLAUDE.md and present in the lockfiles. Versions below are the ones actually pinned.

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| enigo | 0.6.1 (verified in `server/Cargo.lock`) | Keyboard + click + scroll injection | Locked; cross-platform SendInput wrapper. `Key::Unicode`, `key(Key, Direction)`, `text(&str)` all present [VERIFIED: enigo v0.6.1 src/lib.rs + src/win/win_impl.rs] |
| windows | 0.62 | Raw `SendInput` for absolute move w/ virtual-desktop normalization | enigo's Abs path is primary-monitor-only; raw SendInput is the documented fallback (CLAUDE.md alternatives table) [VERIFIED: enigo source TODO] |
| flutter_riverpod | 3.3.2 | State (modifier FSM providers, panel toggle, sensitivity) | Locked; keep classifier/diff logic OUT of providers (pure seams, house style) |
| characters | 1.4.1 (in `remote_protocol/pubspec.yaml`) | Extended-grapheme-cluster counting for diff-ops | Already a dependency; `computeDiff` already uses it [VERIFIED: codebase] |
| shared_preferences | 2.5.5 | Sensitivity + row-visibility persistence (non-secret) | Locked; not secure storage (CLAUDE.md rule) |

### Supporting (all Flutter built-ins — no package)
| API | Purpose | When to Use |
|-----|---------|-------------|
| `Listener` (flutter/widgets) | Raw pointer stream, no gesture arena | The trackpad surface; already in use (`trackpad_screen.dart`) |
| `TextField` + `TextEditingController` (flutter/material) | Hidden IME capture (D-08) | Offscreen/zero-opacity field driving `computeDiff` |
| `HapticFeedback` (flutter/services) | Tick on clicks/keys/drag-lock | Per project stack; `HapticFeedback.selectionClick()` or `.lightImpact()` |
| `Ticker` / `Timer` (flutter/scheduler, dart:async) | Momentum-scroll decay loop, long-press timer, autorepeat is server-side | Momentum + long-press timing |

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Raw `SendInput` for move | enigo `Coordinate::Abs` | Simpler, but primary-monitor-only — fails D-03 multi-monitor. Acceptable ONLY if the planner explicitly descopes multi-monitor for MVP (see Open Question 1) |
| Raw `SendInput` for move | enigo default `Settings{...: false}` (auto Rel→Abs) | Same primary-monitor normalization bug; no benefit over explicit Abs |
| Hidden `TextField` | Custom `TextInputClient` / raw platform channel | More control over composing region, but far more code; the `TextField`+controller diff approach is simpler and the diff helper already exists |

**Installation:** none — no new packages. Server-windows must add `windows` crate features (see Pitfall 1).

**Version verification:**
```bash
# already pinned; confirmed against lockfiles this session
grep -A2 'name = "enigo"' server/Cargo.lock   # -> 0.6.1  [VERIFIED]
grep characters app/packages/remote_protocol/pubspec.yaml   # -> ^1.4.1  [VERIFIED]
```

## Package Legitimacy Audit

**Not applicable — no external packages are added this phase.** All dependencies (enigo 0.6.1, windows 0.62, flutter_riverpod 3.3.2, characters 1.4.1, shared_preferences 2.5.5) are already locked, vetted in CLAUDE.md, and present in the committed lockfiles. The only change is enabling additional *feature flags* on the already-present `windows` crate.

## Architecture Patterns

### System Architecture Diagram

```
TRACKPAD SLICE
  finger(s) on Listener surface
        │  onPointerDown/Move/Up/Cancel  (raw, no gesture arena)
        ▼
  GestureClassifier (pure FSM, lib/trackpad/gesture_classifier.dart)
        │ move intent ──► accel curve × sensitivity ──► service.sendMove(dx,dy) ──► 0x01 binary  (VOLATILE)
        │ tap ─────────► ClickMsg(left)   ──┐
        │ 2-finger tap ► ClickMsg(right)  ──┤
        │ 2-finger scroll ► momentum loop ─┼─► encodeScroll ──► 0x02 binary            (VOLATILE)
        │ long-press+move ► DragMsg(start) │  ...deltas... DragMsg(end)
        ▼                                  ▼
   L/M/R buttons ─────────────────────► service.sendReliable(ClickMsg/DragMsg)          (RELIABLE queue)

KEYBOARD SLICE
  system IME  ──► hidden TextField ──► TextEditingController.onChanged
        │              old vs new committed text
        ▼
  computeDiff(old,new)  (grapheme-correct, remote_protocol) ──► TextMsg{bs,ins} ──► sendReliable
  special key row  ──► KeyMsg{code, action:tap/down/up, mods} ──────────────────────► sendReliable
  modifier chips (FSM) ─ arm/lock/chord ─ contributes mods[] / held modifier keys

SERVER (unchanged transport + dispatch; NEW execution)
  ws frame ──► session read task ──► route()/route_binary()  [auth+pause gates, already built]
        │ Msg::Click/Drag/Key/Text ──► MouseKeys trait (&self)
        ▼
  EnigoMouseKeys  ── mpsc Cmd ──►  input thread (owns &mut Enigo, !Sync)
        move ──► SubPixelAccumulator ──► GetCursorPos + delta ──► raw SendInput(ABSOLUTE|VIRTUALDESK)
        click/key/text ──► enigo key()/text()/button
  HeldInput (dispatch) ── release_all on session end (CONN-07) ── already built
```

### Recommended Project Structure
```
app/remote_control/lib/
├── trackpad/
│   ├── trackpad_screen.dart       # grows: mounts classifier, L/M/R bar, panel toggle, drag-lock pill
│   ├── gesture_classifier.dart    # NEW pure FSM (move/tap/2-tap/scroll/drag) — test-seamed
│   ├── mouse_buttons.dart         # NEW L/M/R bar
│   └── move_sender.dart           # exists (sendMove/sendScroll)
├── keyboard/                      # NEW package
│   ├── keyboard_panel.dart        # expandable panel (D-07)
│   ├── hidden_text_input.dart     # offscreen TextField (D-08)
│   ├── diff_ops.dart              # thin wrapper wiring controller → computeDiff → TextMsg
│   ├── modifier_chip.dart         # sticky-modifier chip + FSM
│   └── key_rows.dart              # Nav/Fn/Num rows
└── settings/                      # sensitivity + row-visibility (shared_preferences)

server/server-windows/src/
├── input_thread.rs                # grows: Cmd enum + absolute move + click/key/text handling
└── executors/
    ├── mouse_keys.rs              # fill the stubbed methods (send new Cmd variants)
    └── keymap.rs                  # NEW: wire KeyCode string + Modifier → enigo Key
```

### Pattern 1: Absolute move via raw SendInput with virtual-desktop normalization (D-01/D-02/D-03)

**What:** Replace `enigo.move_mouse(ix, iy, Coordinate::Rel)` with an absolute inject that keeps the existing accumulator and works across all monitors.
**When to use:** The `Cmd::Move` arm of `run_input_thread`.

The existing `SubPixelAccumulator.step(dx,dy)` still runs first and yields an integer `(ix, iy)` delta (D-02 preserved). Then compute a target from the *current* cursor (robust to external cursor moves) and inject absolute:

```rust
// Source: MS docs mouse_event/MOUSEINPUT remarks [CITED: learn.microsoft.com
//   /windows/win32/api/winuser/ns-winuser-mouseinput] + enigo v0.6.1 gap.
// windows 0.62 imports: Win32::UI::Input::KeyboardAndMouse::{SendInput, INPUT,
//   INPUT_MOUSE, MOUSEINPUT, MOUSEEVENTF_MOVE, MOUSEEVENTF_ABSOLUTE,
//   MOUSEEVENTF_VIRTUALDESK}; Win32::UI::WindowsAndMessaging::{GetCursorPos,
//   GetSystemMetrics, SM_XVIRTUALSCREEN, SM_YVIRTUALSCREEN,
//   SM_CXVIRTUALSCREEN, SM_CYVIRTUALSCREEN}; Win32::Foundation::POINT.
fn inject_absolute(target_x: i32, target_y: i32) {
    unsafe {
        let vx = GetSystemMetrics(SM_XVIRTUALSCREEN);            // left edge (can be < 0)
        let vy = GetSystemMetrics(SM_YVIRTUALSCREEN);            // top edge  (can be < 0)
        let vw = GetSystemMetrics(SM_CXVIRTUALSCREEN);           // total width across all monitors
        let vh = GetSystemMetrics(SM_CYVIRTUALSCREEN);           // total height
        // Normalize the virtual-desktop pixel to the 0..65535 grid.
        // +(vw-1)/2 rounds to nearest, matching the MS-documented convention.
        let nx = (((target_x - vx) as i64 * 65535 + (vw as i64 - 1) / 2) / (vw as i64 - 1)) as i32;
        let ny = (((target_y - vy) as i64 * 65535 + (vh as i64 - 1) / 2) / (vh as i64 - 1)) as i32;
        let input = INPUT {
            r#type: INPUT_MOUSE,
            Anonymous: INPUT_0 { mi: MOUSEINPUT {
                dx: nx, dy: ny,
                mouseData: 0,
                dwFlags: MOUSEEVENTF_MOVE | MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK,
                time: 0, dwExtraInfo: 0,
            }},
        };
        let _ = SendInput(&[input], std::mem::size_of::<INPUT>() as i32);
    }
}

// In Cmd::Move(dx, dy):
let (ix, iy) = move_acc.step(dx, dy);         // D-02 accumulator unchanged
if ix != 0 || iy != 0 {
    let mut p = POINT::default();
    if GetCursorPos(&mut p).is_ok() {          // current pos is virtual-desktop coords
        inject_absolute(p.x + ix, p.y + iy);   // consume accumulated delta (D-01)
    }
}
```

**Why raw SendInput and not enigo Abs:** enigo v0.6.1 normalizes against `main_display()` = `SM_CXSCREEN`/`SM_CYSCREEN` (primary monitor) and omits `MOUSEEVENTF_VIRTUALDESK` [VERIFIED: enigo v0.6.1 src/win/win_impl.rs lines 162-176]. On any non-primary monitor the normalization overshoots 65535 and the cursor clamps/jumps. `MOUSEEVENTF_VIRTUALDESK` + `SM_*VIRTUALSCREEN` is the documented multi-monitor mapping [CITED: MS winuser docs].

**Keep enigo for scroll/click/keys** — only the move arm needs raw SendInput. Mixing is fine; the input thread already owns `&mut Enigo` on the same thread.

### Pattern 2: Momentum scroll with instant touch-stop (PAD-03)
**What:** On two-finger lift, continue emitting `0x02` scroll frames with a decaying velocity until it falls below a threshold; cancel immediately on any new pointer-down.
**When to use:** Classifier's scroll-end handler.
**Example (client, conceptual):**
```dart
// Fling: seed velocity from the last N pointer-move samples (px/frame).
// Decay ~0.92/tick @ ~60Hz is a sane DEFAULT (D-06 tunable, ONE constants file).
void _onScrollFling(double vy) {
  _momentumTimer?.cancel();
  double v = vy;
  _momentumTimer = Timer.periodic(const Duration(milliseconds: 16), (t) {
    v *= kMomentumDecay;                 // tunable
    if (v.abs() < kMomentumStop) { t.cancel(); return; }
    _service.sendScroll(0, v);   // 0x02 frame; volatile path, no rebuild
  });
}
// Instant touch-stop: ANY onPointerDown cancels the timer before classifying.
void _onPointerDown(PointerDownEvent e) { _momentumTimer?.cancel(); ... }
```
Note: `MoveSender.sendScroll` exists but `ConnectionService` currently exposes only `sendMove` on the volatile path — the planner must add a `sendScroll` volatile method mirroring `sendMove` (same `_policy.shouldSendVolatile()` gate + `_sender?.sendScroll` + probe tick). Scroll frames are `0x02` binary, so they are volatile like move, NOT reliable.

### Pattern 3: New executor commands ride the existing input-thread channel
**What:** The stubbed `EnigoMouseKeys` methods must not touch `Enigo` directly (it's `!Sync`, `&mut`, lives only on the input thread). Extend `Cmd` and forward.
**Example:**
```rust
// input_thread.rs — extend the enum:
pub enum Cmd {
    Move(f32, f32), Scroll(f32, f32),
    Click(Button), ButtonDown(Button), ButtonUp(Button),
    KeyDown(KeyCode), KeyUp(KeyCode), KeyTap(KeyCode, Vec<Modifier>),
    Type(String), Backspace(u32),
}
// mouse_keys.rs — each stubbed method becomes one non-blocking send:
fn click(&self, b: Button)      { let _ = self.tx.send(Cmd::Click(b)); }
fn key_tap(&self, c: KeyCode, m: &[Modifier]) { let _ = self.tx.send(Cmd::KeyTap(c, m.to_vec())); }
// run_input_thread — handle on the &mut Enigo thread:
Cmd::Click(b)   => { let _ = enigo.button(map_button(b), Direction::Click); }
Cmd::KeyTap(c,m)=> { for md in &m { let _ = enigo.key(map_mod(*md), Direction::Press); }
                     if let Some(k) = map_key(&c) { let _ = enigo.key(k, Direction::Click); }
                     for md in m.iter().rev() { let _ = enigo.key(map_mod(*md), Direction::Release); } }
Cmd::Type(s)    => { let _ = enigo.text(&s); }             // layout-independent Unicode
Cmd::Backspace(n)=>{ for _ in 0..n { let _ = enigo.key(Key::Backspace, Direction::Click); } }
```
enigo API confirmed: `Direction::{Press, Release, Click}`, `key(Key, Direction)`, `text(&str)`, `button(Button, Direction)` [VERIFIED: enigo v0.6.1 src/lib.rs lines 153-272, win_impl.rs]. Injection failures stay non-fatal (drop, never panic) — the established Phase-2 rule.

### Pattern 4: KeyCode string → enigo Key mapping table (KEY-02)
**What:** A single `map_key(&KeyCode) -> Option<Key>` table in `server-windows/src/executors/keymap.rs`.
**Where:** server-windows only (server-core keeps KeyCode opaque, zero-Windows-deps).
**enigo Key variants available** [VERIFIED: enigo v0.6.1 Key enum]:
- F1–F12: `Key::F1 .. Key::F12`
- Arrows: `Key::UpArrow / DownArrow / LeftArrow / RightArrow`
- Nav: `Key::Home / End / PageUp / PageDown / Delete / Escape / Tab`
- Modifiers: `Key::Control / Alt / Shift / Meta` (Meta = Windows key)
- Numpad: `Key::Numpad0 .. Numpad9`, `Key::Decimal / Add / Subtract / Multiply / Divide`, `Key::Return` for Enter
- Character: `Key::Unicode(char)`; unknown OS codes: `Key::Other(u32)`
See Open Question 3 — the wire `key.code` *string vocabulary* is not yet locked; the existing browser/present macro tables in `router.rs` already established terse strings ("F5","Right","Left","Esc","Plus","Minus"). The planner must pick ONE vocabulary and make the Flutter key rows emit exactly what `keymap.rs` maps.

### Pattern 5: Server-side autorepeat via held key-down (KEY-04, D-11)
**What:** Holding an app-drawn key sends `key {action:down}` on touch-down and `key {action:up}` on release. The server calls `enigo.key(k, Direction::Press)` and later `Direction::Release`. **Windows itself generates the key-repeat stream while the key is physically held down** — no client tap-spam, no server timer needed.
**Why it works:** SendInput of a KEYDOWN that is not followed by KEYUP puts the key in a held state; the OS keyboard-repeat logic then auto-repeats it into the focused app. `release_all` (HeldInput, CONN-07) + D-12 client reset guarantee no stuck key on disconnect.
**Verify on device:** hold an arrow key in a text editor → confirm a repeating stream, and confirm release stops it.

### Anti-Patterns to Avoid
- **GestureDetector for the trackpad.** It joins the gesture arena and introduces arbitration latency/ambiguity; D-04 + the Phase-2/3 hot-path invariant require the raw `Listener`. Classify manually off pointer ids.
- **Calling `setState`/rebuilding on the move/scroll hot path.** Phase-2/3 invariant — the classifier must route clicks/scroll/drag/keys without rebuilding the trackpad surface or header chip.
- **Counting backspace in UTF-16 or bytes.** SPEC §8 is extended grapheme clusters; use the existing `computeDiff` (already `characters`-based). Fixtures `03-emoji`/`04-rapid-backspace` fail any other unit.
- **Client tap-spamming for autorepeat.** Explicitly forbidden (D-11); use down/up hold.
- **Batching/queuing move or scroll deltas.** Queued deltas teleport the cursor on reconnect (existing `MoveSender` doc); keep fire-and-forget volatile.
- **Calling `Enigo` from the executor's `&self` methods.** It's `!Sync`; must go through the `Cmd` channel.

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Grapheme-cluster diff | Custom prefix/backspace counter | Existing `computeDiff` (`remote_protocol`) | Already fixture-proven byte-identical to the Rust decoder; emoji/skin-tone edge cases handled |
| Binary frame encoding | Hand-rolled byte packing | `encodeMove` / `encodeScroll` | Fixture-proven; re-implementing risks endianness/opcode drift |
| Layout-independent typing | VK-code table per keyboard layout | enigo `text(&str)` (KEYEVENTF_UNICODE) | Handles any Unicode incl. emoji regardless of active layout |
| Multi-monitor coord mapping | Guessing offsets per display | `SM_*VIRTUALSCREEN` + `MOUSEEVENTF_VIRTUALDESK` | The one documented correct mapping; enigo's built-in is primary-only |
| Held-input release on disconnect | New client bookkeeping | Server `HeldInput.release_all` (CONN-07) + client D-12 reset | Already built and tested; client only clears its own chip/held-key UI state |
| Key-repeat timing | Client or server repeat timer | OS-native repeat via held KEYDOWN | The OS already does correct accelerating repeat with user settings |

**Key insight:** ~70% of Phase 4's "hard" problems (protocol, diffing, framing, held-input safety, transport) are already solved and proven. The genuinely new work is OS injection fidelity (absolute move) and client interaction surfaces (gesture FSM, keyboard panel).

## Runtime State Inventory

Not a rename/refactor/migration phase — **section omitted** (no stored data, service config, OS-registered state, secrets, or build artifacts are renamed or migrated). The only persistent state added is two non-secret shared_preferences keys (sensitivity, active-key-row), which are new writes, not migrations.

## Common Pitfalls

### Pitfall 1: `windows` crate feature flags missing → won't compile
**What goes wrong:** `SendInput`, `GetCursorPos`, `GetSystemMetrics`, `SM_*VIRTUALSCREEN`, `MOUSEEVENTF_*` are behind features not currently enabled. Current `server-windows/Cargo.toml` has only `Win32_Foundation`, `Win32_UI_HiDpi`.
**How to avoid:** Add `Win32_UI_Input_KeyboardAndMouse` (SendInput, INPUT, MOUSEINPUT, MOUSEEVENTF_*) and `Win32_UI_WindowsAndMessaging` (GetCursorPos, GetSystemMetrics, SM_*, POINT is in `Win32_Foundation`).
**Warning signs:** `unresolved import windows::Win32::UI::Input`.

### Pitfall 2: enigo `Coordinate::Abs`/default settings silently primary-monitor-only
**What goes wrong:** Using enigo's absolute path "works" on a single-monitor dev machine, then jumps/clamps the cursor on the owner's multi-monitor setup. The bug is invisible until multi-display hardware is tested.
**Why:** `main_display()` → `SM_CXSCREEN` only; no `MOUSEEVENTF_VIRTUALDESK` [VERIFIED: enigo source].
**How to avoid:** Use Pattern 1 (raw SendInput) OR explicitly descope multi-monitor for MVP with a written note (Open Question 1). Do not rely on enigo Abs and assume it's correct.
**Warning signs:** cursor teleports to top-left region on a secondary monitor; drags off the primary monitor stop tracking.

### Pitfall 3: Sub-pixel accumulator drift with absolute injection
**What goes wrong:** If you track a *floating target position* internally (seed once, target += delta forever), any physical mouse touch or another app moving the cursor desyncs your target from reality, and the next inject snaps the cursor back.
**How to avoid:** Read `GetCursorPos` fresh each frame and add only the *integer delta from the accumulator* (Pattern 1). The accumulator carries the fraction; the OS carries the position.
**Warning signs:** cursor "fights" the physical mouse.

### Pitfall 4: Two-finger tap vs. scroll vs. two-finger-move ambiguity
**What goes wrong:** A two-finger tap (→ right click) and the start of a two-finger scroll both begin as two simultaneous pointer-downs. Classifying too early fires a right-click when the user meant to scroll, or vice-versa.
**How to avoid:** Track per-pointer down time + travel. Two-finger tap = both up within a short window (~200ms default, tunable) AND total travel below a small threshold. Otherwise it's a scroll. This is exactly the D-06 on-device tuning surface — land the thresholds in one constants file.
**Warning signs:** stray right-clicks while scrolling.

### Pitfall 5: Hidden `TextField` composing-region / autocomplete revisions
**What goes wrong:** IME autocomplete rewrites already-committed text (e.g. `"thw"`→`"the "`); if you diff on every keystroke including the *composing* region, you send churn or wrong `bs`. Emoji insert as multi-codepoint single graphemes.
**How to avoid:** Diff on committed-text transitions using `computeDiff(old, new)`. Track the previous committed value; on `onChanged`, compute the diff against it, send `TextMsg`, then store new as old. Fixtures `02-ime-revision` and `03-emoji` are the exact cases to reproduce. Consider whether to diff on the raw controller text or only on composing-region-collapse — verify against the device IME during execution (ASSUMED — needs on-device check).
**Warning signs:** doubled characters, wrong backspace counts, emoji arriving as `??`.

### Pitfall 6: Keyboard panel steals the trackpad, or the IME never rises
**What goes wrong:** Focusing the hidden `TextField` is what raises the system IME. If the field loses focus (e.g. tapping a special-key row button that requests focus), the IME drops. Also, resizing the trackpad for the panel can trigger rebuilds on the hot path.
**How to avoid:** Keep the hidden field focused while the panel is open; use `FocusNode` explicitly. Special-key buttons must not steal focus (wrap in a widget that doesn't request focus, or refocus the hidden field after). Ensure panel expand/collapse animation doesn't rebuild the `Listener` subtree that owns the move path.
**Warning signs:** IME flickers away when tapping F-keys; hot-path frame drops when the panel animates.

### Pitfall 7: Modifier `mods` dropped on the `down`/`up` (autorepeat) path
**What goes wrong:** The `MouseKeys` trait's `key_down`/`key_up` take only `KeyCode` — no `mods`. The router's `down`/`up` arms ignore `p.mods`. So a held key with an armed/locked modifier loses the modifier server-side.
**How to avoid:** See Open Question 2. Recommended: represent a LOCKED modifier as its own held `key {code:"ControlLeft"/…, action:down/up}` (physical hold via `code`, not the `mods` array), so OS-level chording + repeat work and CONN-07 releases it. Reserve the `mods` array for the armed-then-tap combo path only.
**Warning signs:** Ctrl+Right (locked Ctrl + held Right) repeats as bare Right.

## Code Examples

### Client: wiring the hidden field to the diff helper (KEY-01)
```dart
// Source: existing remote_protocol.computeDiff (grapheme-correct, SPEC §8)
String _committed = '';
void _onTextChanged(String next) {
  final diff = computeDiff(_committed, next);      // TextDiff(bs, ins)
  if (diff.bs != 0 || diff.ins.isNotEmpty) {
    _service.sendReliable(TextMsg(bs: diff.bs, ins: diff.ins));
  }
  _committed = next;
}
```

### Server: input-thread move arm (D-01/D-02, full)
See Pattern 1 — the `SubPixelAccumulator` call is unchanged; only the injection changes from `enigo.move_mouse(ix, iy, Coordinate::Rel)` to `GetCursorPos + inject_absolute(p.x+ix, p.y+iy)`.

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `enigo.move_mouse(_, _, Coordinate::Rel)` | Raw `SendInput(ABSOLUTE\|VIRTUALDESK)` | This phase (D-01) | Bypasses pointer ballistics; multi-monitor correct |
| enigo pre-0.6 `Settings` default `subject_to_...: true` | 0.6.1 default is `false` (auto Rel→Abs) | enigo 0.6.x | Relevant reconciliation: see Open Question 1 — the gate observed ballistics; verify what changed |
| `key_event`/VK tables | enigo `key(Key, Direction)` + `text()` | already adopted | Layout-independent Unicode typing |

**Deprecated/outdated:**
- enigo `Coordinate::Rel` for the move hot path — replaced by absolute inject this phase.

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Owner's target machine is/could be multi-monitor, so D-03 must be solved not descoped | Open Q1 | If single-monitor forever, raw SendInput is over-engineering; enigo Abs would suffice |
| A2 | Diffing on `TextEditingController.onChanged` (committed text) reproduces the fixtures across the device's actual IME | Pitfall 5 | Composing-region churn could send wrong `bs`/`ins`; needs on-device IME check |
| A3 | Windows generates native key-repeat from a held SendInput KEYDOWN (no server timer needed) | Pattern 5 | If not, KEY-04 needs a server-side repeat timer instead |
| A4 | The wire `key.code` vocabulary should be a single documented table; DOM-`KeyboardEvent.code`-style or the existing terse macro strings | Open Q3 | Client/server string mismatch → keys silently drop (router maps unknown → nothing) |
| A5 | Locked modifiers are best modeled as held `key down/up` via `code` (not the `mods` array) for hold+repeat combos | Open Q2 / Pitfall 7 | If modeled via `mods` only, held-combo autorepeat loses the modifier |
| A6 | Default momentum decay ~0.92/16ms, long-press ~250ms, two-finger-tap window ~200ms are reasonable starting points | Patterns 2/Pitfall 4 | Wrong feel; but D-06 makes these tunable on-device, so low risk |
| A7 | enigo `button(Button, Direction)` exists for click/button_down/up | Pattern 3 | If the method name differs, click/drag executors need the correct enigo mouse API (verify at impl time) |

**Note:** A7 — I verified enigo's *keyboard* `key()`/`text()` and the `Mouse::move_mouse`/`location`/`main_display` signatures from source, but did not open the exact `Mouse` button method name; confirm `button`/`Direction` vs a `MouseButton` helper when filling the click/drag executors.

## Open Questions (RESOLVED)

> All four questions were resolved by the plan set (04-01..04-06). Original analysis kept below; each carries its plan-locked resolution.

1. **Multi-monitor: solve (Pattern 1) or descope for MVP?**
   - What we know: enigo Abs is primary-monitor-only; raw SendInput with VIRTUALDESK is correct; the `windows` crate is already a dep.
   - What's unclear: whether the owner's laptop is ever docked to external displays.
   - Recommendation: implement Pattern 1 (raw SendInput) — it's ~30 lines, uses an existing dep, and permanently retires D-03. Verify on a two-monitor setup (drag cursor across the seam onto the secondary display and back; confirm no jump/clamp).
   - **RESOLVED (plan 04-01):** Pattern 1 implemented — raw `SendInput(MOUSEEVENTF_ABSOLUTE|VIRTUALDESK)` behind a pure `normalize_virtual(x, y, metrics)` fn (unit-tested without a display). Multi-monitor is solved, not descoped; the seam-crossing check is deferred to the end-of-phase on-device gate (04-VALIDATION Manual-Only).

2. **How do sticky modifiers interact with held-key autorepeat (KEY-03 × KEY-04)?**
   - What we know: `key_tap(code, mods)` carries mods (combo path); `key_down/up(code)` does NOT.
   - What's unclear: the exact client model for "hold a key while a modifier is locked."
   - Recommendation: LOCKED modifier → send `key {code, action:down}` for the modifier itself (mapped to enigo Control/Alt/Shift/Meta); release on unlock. ARMED (tap) modifier → included in the next `key {action:tap, mods:[…]}` then auto-reset. This keeps combos+repeat correct at the OS level and lets CONN-07/D-12 clean up. Planner should lock this model in the plan.
   - **RESOLVED (plan 04-06):** locked exactly as recommended — a LOCKED modifier is a physical hold via `key {code: ControlLeft/AltLeft/ShiftLeft/WinLeft, action: down/up}` (so held-key combos autorepeat with the modifier, Pitfall 7 closed); an ARMED modifier rides the `mods` array on the next `tap` only, then auto-resets (`ModifierFsm`, 04-06 Task 1).

3. **Lock the `key.code` string vocabulary.**
   - What we know: router.rs already uses terse strings ("F5","Right","Left","Esc","Tab","Plus","Minus","BrowserBack"); Phase-1 tests also used "KeyA"/"ShiftLeft"/"KeyW" (DOM-code-ish).
   - What's unclear: no single documented table exists; the two conventions conflict.
   - Recommendation: pick ONE (suggest terse, matching the existing macro tables, e.g. "F1".."F12","Home","End","PgUp","PgDn","Del","Esc","Tab","Up","Down","Left","Right","Num7"…,"Enter","."), document it once in `keymap.rs`, and make the Flutter key rows emit exactly those strings. Add a unit test asserting every emitted client code maps to `Some(Key)`.
   - **RESOLVED (plan 04-02, consumed by 04-06):** the terse vocabulary is locked ONCE in `keymap.rs` as `CLIENT_KEY_CODES` (coverage-tested: `keymap_covers_all_codes`); the Flutter key rows mirror it byte-for-byte as `kClientKeyCodes` with a widget test asserting every emitted code is in the list.

4. **Does `ConnectionService` need a volatile scroll method?** Yes — currently only `sendMove` is volatile-gated; scroll `0x02` frames need an identical volatile method. Trivial, but must be planned (touches the "one place" volatile gate).
   - **RESOLVED (plan 04-03):** added as `ConnectionService.sendScroll(dx, dy)` — named to mirror `sendMove`; this doc's earlier working name `sendScrollVolatile` is superseded. Same `shouldSendVolatile()` gate + `_sender?.sendScroll` + probe tick, with pre-auth-drop and 0x02-opcode tests (04-03 Task 3).

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| enigo | key/click/text/scroll injection | ✓ (locked) | 0.6.1 | — |
| windows crate | absolute move (SendInput/virtualdesk) | ✓ (locked; needs 2 more features) | 0.62 | enigo Abs (primary-monitor only) |
| characters | grapheme diff | ✓ | 1.4.1 | — |
| A second physical monitor | D-03 verification | ✗ (unknown on dev machine) | — | Verify via Windows "duplicate/extend" or a virtual display; else mark D-03 verification as a deferred device-check |

**Missing dependencies with no fallback:** none blocking. **With fallback:** multi-monitor *verification hardware* may be absent — flag the D-03 on-device check as a checkpoint.

## Validation Architecture

`.planning/config.json` was not read as blocking; nyquist_validation is treated as enabled (default). The house style is pure IO-free FSMs + injected seams with unit tests (handshake_fsm/reconnect_fsm), plus shared golden fixtures.

### Test Framework
| Property | Value |
|----------|-------|
| Framework (Dart) | `flutter_test` / `test` (per existing `remote_protocol/test/*`) |
| Framework (Rust) | built-in `#[cfg(test)]` + `#[tokio::test]` (per `router.rs` tests) |
| Quick run (Dart) | `cd app/remote_control && flutter test` |
| Quick run (Rust) | `cd server && cargo test` (or `cargo nextest run`) |
| Fixtures | `protocol/fixtures/text/*`, `protocol/fixtures/mouse-binary/*` (shared, both langs) |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| PAD-01 | accel curve maps deltas deterministically | unit | `flutter test test/trackpad/accel_test.dart` | ❌ Wave 0 |
| PAD-01 | sub-pixel accumulator carries fraction | unit (exists) | `cargo test sub_integer_deltas` | ✅ (input_thread.rs) |
| PAD-01/03 | absolute inject normalization math | unit | `cargo test keymap_or_normalize` (pure fn extracted) | ❌ Wave 0 |
| PAD-02/03/04 | classifier emits move/tap/2tap/scroll/drag intents | unit (FSM) | `flutter test test/trackpad/gesture_classifier_test.dart` | ❌ Wave 0 |
| KEY-01 | computeDiff reproduces fixtures | unit (exists) | `flutter test` (diff_ops_test) | ✅ |
| KEY-02 | every client key.code maps to Some(Key) | unit | `cargo test keymap_covers_all_codes` | ❌ Wave 0 |
| KEY-03 | modifier FSM arm/lock/chord/auto-reset | unit (FSM) | `flutter test test/keyboard/modifier_fsm_test.dart` | ❌ Wave 0 |
| KEY-04 | down/up hold semantics (server) | unit (exists routing) + manual | `cargo test key_down_up_updates_held` | ✅ (routing) / manual repeat |
| PAD-01 (feel) | ballistics bypass + multi-monitor | manual on-device | device feel-check checkpoint (D-06) | manual |

### Sampling Rate
- **Per task commit:** `cargo test` (server) / `flutter test` (client) for the touched crate/package.
- **Per wave merge:** full `cargo test` + `flutter test` + fixture suites.
- **Phase gate:** on-device feel-check (trackpad vs. Remote Mouse benchmark, D-05) + multi-monitor cursor-seam check + IME emoji/backspace check, before `/gsd-verify-work`.

### Wave 0 Gaps
- [ ] `test/trackpad/gesture_classifier_test.dart` — PAD-02/03/04 classifier FSM
- [ ] `test/trackpad/accel_test.dart` — PAD-01 curve/sensitivity
- [ ] `test/keyboard/modifier_fsm_test.dart` — KEY-03 sticky-modifier FSM
- [ ] `server-windows` unit test for the pure normalization fn (extract `normalize_virtual(x,y,metrics)` so it's testable without a display) — PAD-01/03
- [ ] `keymap.rs` coverage test — KEY-02
- [ ] Pure classifier/diff-producer seams must be IO-free so they unit-test without a device (house style)

## Security Domain

`security_enforcement` treated as enabled. Phase 4 adds **no new wire messages, no new network surface, no new auth path** — it implements executors + client producers against the already-locked, already-gated protocol. The existing auth gate (SPEC §6), pause gate (§11), bs-cap (§8), and CONN-07 release-all remain the controls.

### Applicable ASVS Categories
| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V5 Input Validation | yes | Server router already validates button/action/mods enums and drops unknowns; `text.bs` capped at 10000 (already enforced) — no new validation surface, but keymap must drop unknown `code` (already the router pattern) |
| V6 Cryptography | no | No crypto in this phase |
| V2/V3/V4 Auth/Session/Access | no (unchanged) | Auth gate + LAN-only binding already enforced upstream |

### Known Threat Patterns for this stack
| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Injected keystrokes to a privileged window | Elevation of Privilege | Out of scope for enigo/SendInput (injecting into elevated windows requires the server itself elevated — documented enigo/Windows limitation; not a Phase-4 bug). No mitigation change. |
| Stuck held key/button after mid-drag disconnect | Denial of Service (local) | CONN-07 `HeldInput.release_all` (built) + D-12 client reset + enigo `release_keys_when_dropped:true` default |
| Oversized `text.ins` memory | DoS | 64KB frame cap (SPEC §13) + `bs` cap (§8), both already enforced |
| Logging captured IME text | Information Disclosure | SPEC §12 redaction-mandatory: `text` payloads must never be logged — the new client diff producer and server executor must not log `ins`/typed content |

## Sources

### Primary (HIGH confidence)
- enigo v0.6.1 source — `src/lib.rs` (Direction/Key/Keyboard/Mouse traits, Settings defaults), `src/win/win_impl.rs` (move_mouse Abs normalization, MOUSEEVENTF flags, the VIRTUALDESK TODO) — fetched from raw.githubusercontent.com at tag `v0.6.1` this session [VERIFIED]
- Codebase: `input_thread.rs`, `executors/mod.rs`, `executors/mouse_keys.rs`, `dispatch/router.rs`, `dispatch/held.rs`, `remote_protocol/src/diff_ops.dart`, `binary_codec.dart`, `json_codec.dart`, `connection_service.dart`, `trackpad_screen.dart`, `move_sender.dart` [VERIFIED: read this session]
- Protocol: `SPEC.md` §7/§8/§9/§11, `messages.schema.json`, `mouse-binary.md`, `fixtures/text/*`, `fixtures/mouse-binary/*` [VERIFIED]

### Secondary (MEDIUM confidence)
- MS Learn — MOUSEINPUT / mouse_event remarks: MOUSEEVENTF_ABSOLUTE maps to primary monitor; MOUSEEVENTF_VIRTUALDESK maps to the virtual desktop; 0..65535 normalization [CITED: learn.microsoft.com/windows/win32/api/winuser/ns-winuser-mouseinput]
- docs.rs/enigo/0.6.1 — Coordinate, Key, Mouse trait signatures [CITED]

### Tertiary (LOW confidence / training)
- Flutter raw `Listener` multi-touch classification patterns, momentum decay, hidden-`TextField` IME behavior — training knowledge, marked ASSUMED (A2, A6); verify on device.

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — no new packages; versions confirmed against lockfiles.
- Server injection (absolute move, key/text/click executors): HIGH — verified against enigo v0.6.1 source; the multi-monitor gap is confirmed, not assumed.
- Client gesture/IME patterns: MEDIUM — architecture is clear, exact IME/composing behavior and feel constants need on-device verification (D-06 already mandates this).
- Pitfalls: HIGH for the server/compile/held-state items; MEDIUM for IME/gesture ambiguity.

**Research date:** 2026-07-09
**Valid until:** 2026-08-09 (stable stack; enigo/windows crates move slowly, but re-check enigo if it bumps past 0.6.x — the VIRTUALDESK TODO may get fixed, which would let you drop the raw-SendInput path)
