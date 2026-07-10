---
phase: 04-trackpad-keyboard
verified: 2026-07-10T00:00:00Z
status: gaps_found
score: 3/5 roadmap success criteria verified
overrides_applied: 0
gaps:
  - truth: "Typing with the phone keyboard — including IME autocomplete revisions, emoji, and backspace — produces exactly the same text on the PC (roadmap SC2, KEY-01)"
    status: partial
    reason: "Base-case fidelity is real and test-proven, but the disconnect-hygiene path desyncs ImeDiffProducer from the hidden field's controller: `_imeProducer.reset()` on ChipStatus.disconnected (trackpad_screen.dart:136) resets committed text to the sentinel while the TextEditingController still holds the pre-disconnect text. The first keystroke after reconnect replays ALL previously typed text (possibly a password) into the new session, and a post-reconnect backspace becomes an insert. This is phantom input surviving a drop — the exact failure class D-12 exists to prevent. (Review CR-01, independently confirmed in code.)"
    artifacts:
      - path: "app/remote_control/lib/trackpad/trackpad_screen.dart"
        issue: "Line 136: `_imeProducer.reset()` fires on disconnect but nothing re-seeds the HiddenTextInput controller; producer._committed (sentinel) != controller.text (sentinel + typed text). needsReseed() never triggers because the text still starts with the sentinel."
    missing:
      - "Either remove `_imeProducer.reset()` from the disconnect path (committed already equals controller text, so subsequent diffs stay correct), OR reset BOTH sides atomically: expose a reseed hook from HiddenTextInput that writes producer.reseed() back into the controller under the existing _reseeding guard in the same frame as producer.reset()"
      - "Regression test: disconnect with committed text != sentinel, reconnect, type one char — assert the emitted TextMsg contains ONLY the new char (no replay), and a backspace emits bs:1 not an insert"
  - truth: "Holding a key autorepeats via server-side key-down/hold and stops immediately on release (roadmap SC5, KEY-04)"
    status: partial
    reason: "The down/up autorepeat model itself is correct (server Cmd::KeyDown/KeyUp arms verified; press-down/up emission verified in key_rows), but KeyboardPanel tracks at most ONE held cap: `_heldCode` is a single String? (keyboard_panel.dart:105). Ordinary key rollover (press Down before releasing Right — the normal arrow-key pattern) overwrites the slot, so the first key's `up` is swallowed at the `_heldCode != code` guard (line 188) and that key stays held and autorepeating on the PC indefinitely. (Review CR-02, independently confirmed in code.)"
    artifacts:
      - path: "app/remote_control/lib/keyboard/keyboard_panel.dart"
        issue: "Lines 105/180-191: single `String? _heldCode` slot; each _KeyCap has its own GestureDetector so two caps can be concurrently pressed; second press overwrites the slot and the first release sends no key-up"
    missing:
      - "Track held caps as a Set<String>: _onKeyDown adds + sends down; _onKeyUp sends up only if remove(code) returns true; _onDisconnected clears the set (preserving the D-12 skip-stale-ups semantics)"
      - "Regression test: press cap A, press cap B, release A, release B — assert up:A AND up:B are both sent"
human_verification:
  - test: "On the Windows laptop with 'Enhance pointer precision' ON: slow, small phone drag moves the cursor 1:1 (no ballistics suppression). On a dual-monitor PC, cross the seam onto the secondary display and back"
    expected: "1:1 tracking regardless of the OS pointer-precision setting; no jump or clamp at the monitor seam"
    why_human: "Requires real display hardware and OS pointer settings; SendInput behavior cannot be verified by grep or unit tests (deferred end-of-phase gate, 04-01)"
  - test: "On device vs the Remote Mouse benchmark (D-05): move/tap/two-finger-tap/L-M-R buttons/scroll-momentum/drag-lock; drag-lock pill appears on long-press and a tap drops it; sensitivity slider changes feel live"
    expected: "Full gesture set works and feels at least as good as Remote Mouse; pill lifecycle correct; slider applies live and persists"
    why_human: "Trackpad 'feel' (acceleration, momentum decay, thresholds) is subjective and device-dependent — the tuning.dart constants are explicitly on-device tuning starting points (deferred end-of-phase gate, 04-04)"
  - test: "Open the keyboard panel, type with autocomplete, insert a multi-codepoint emoji, rapid-backspace across it; verify the trackpad still moves the cursor while the panel + system IME are up"
    expected: "PC text matches the phone exactly (autocomplete revisions, emoji as one grapheme, correct backspace counts); trackpad stays live while typing (D-07)"
    why_human: "Real Android IME composing/committed behavior varies by keyboard app (RESEARCH A2) — cannot be simulated in widget tests (deferred end-of-phase gate, 04-05)"
  - test: "Arm Win then tap D; lock Ctrl (long-press) then hold Right in a text editor; kill the connection mid-lock"
    expected: "Win+D shows the desktop and the Win chip auto-resets; Ctrl+Right repeats word-by-word while held and stops instantly on release; after the drop, chips reset and no key stays held on the PC (CONN-07 + D-12)"
    why_human: "OS-level combo execution, autorepeat cadence, and release_all behavior need a live Windows session (deferred end-of-phase gate, 04-02/04-06)"
---

# Phase 4: Trackpad & Keyboard — Verification Report

**Phase Goal:** The phone is a genuinely usable daily mouse and keyboard — trackpad feel (raw Listener classifier, acceleration, momentum, drag lock) and typing fidelity (IME diff-ops, special rows, sticky modifiers, server-side autorepeat) match a real laptop, not a toy
**Phase User Story (from all six PLANs, MVP mode):** As a laptop owner, I want to use my phone as a precise mouse and full keyboard for my Windows laptop, so that it replaces a real trackpad and keyboard — not a toy.
**Verified:** 2026-07-10
**Status:** gaps_found
**Re-verification:** No — initial verification

> **MVP-mode note:** ROADMAP.md marks this phase `Mode: mvp` but its Goal field is prose, not User Story format. All six PLANs consistently embed the User Story above (which passes the canonical format), so verification proceeded against it rather than refusing. Flagged for hygiene: the ROADMAP Goal field should carry the User Story for MVP phases.

## User Flow Coverage (MVP mode)

| Step | Expected | Evidence in codebase | Status |
|------|----------|---------------------|--------|
| Move a finger on the trackpad | PC cursor moves 1:1 with acceleration | Listener → GestureClassifier → TrackpadDriver.accelGain-scaled onSendMove → sendMove 0x01 → server absolute SendInput(VIRTUALDESK) | ✓ (feel needs human) |
| Tap / two-finger tap / L-M-R bar | Left, right, and explicit clicks on the PC | ClickLeftIntent/ClickRightIntent → ClickMsg → router → Cmd::Click → enigo.button | ✓ |
| Two-finger scroll, lift with velocity | Momentum scroll, new touch stops it instantly | ScrollIntent/FlingIntent + StopFlingIntent-first invariant; generation-guarded momentum loop; sendScroll 0x02 volatile | ✓ |
| Long-press, lift, drag to edge, tap | Drag lock survives lift; pill shows; tap drops | DragStart/DragEnd intents → DragMsg start/end → Cmd::ButtonDown/Up; ValueNotifier pill | ✓ |
| Open panel, type with the phone IME | Exact same text on the PC | HiddenTextInput → ImeDiffProducer → computeDiff → TextMsg → Cmd::Type/Backspace | ✗ base case works; disconnect path replays stale text (CR-01) |
| Press special keys / hold a key | Nav/Fn/Num act; hold autorepeats, release stops | key_rows down/up emission → KeyMsg → Cmd::KeyDown/KeyUp | ✗ rollover swallows a key-up → stuck autorepeating key (CR-02) |
| Arm/lock modifiers, send combos | Win+D, Ctrl+Alt+Del; auto-reset; disconnect-safe | ModifierFsm armed/locked; KeyTap mods path; disconnected() zero-effect reset | ✓ |

## Goal Achievement

### Observable Truths (roadmap Success Criteria — the contract)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Full gesture set: accelerated move, tap=left, two-finger tap=right, L/M/R buttons, momentum scroll w/ instant touch-stop, long-press drag with drag lock | ✓ VERIFIED | GestureClassifier (490 lines, 18 tests), TrackpadDriver (193 lines, tests), MouseButtonsBar, drag-lock pill; wiring confirmed trackpad_screen.dart:160-181; 230/230 Flutter tests green. On-device feel deferred to human gate. Warning: WR-04 scroll halving after one-finger lift |
| 2 | IME typing (autocomplete, emoji, backspace) produces exactly the same text on the PC | ✗ FAILED (partial) | Base pipeline verified: computeDiff (never re-implemented), sentinel model, 9 fixture-mirroring tests, Cmd::Type via enigo.text(). BUT trackpad_screen.dart:136 `_imeProducer.reset()` desyncs producer from controller on disconnect → post-reconnect keystroke replays all prior typed text (CR-01) |
| 3 | F1–F12, numpad, nav cluster all work from toggleable key rows | ✓ VERIFIED | key_rows.dart 39-code kClientKeyCodes byte-identical to keymap.rs CLIENT_KEY_CODES (programmatically diffed: content AND order match); Nav/Fn/Num groups with persisted `keyboard.rowGroup`; server map_key covers all 39 + 7 router macro codes; coverage tests green both sides |
| 4 | Sticky modifiers show held state, send combos, auto-reset, reset safely on disconnect | ✓ VERIFIED | ModifierFsm armed/locked two-level model (7 tests); hold codes ControlLeft/AltLeft/ShiftLeft/WinLeft exact; locked = physical hold excluded from modsForTap (Pitfall 7); disconnected() zero-effect reset proven via fake changes stream in widget tests |
| 5 | Held keys autorepeat server-side and stop immediately on release | ✗ FAILED (partial) | Server halves verified: Cmd::KeyDown → enigo Press (Windows autorepeats), KeyUp → Release. Client down/up emission verified. BUT keyboard_panel.dart:105 single `_heldCode` slot swallows the first key's up on rollover → key stuck autorepeating on the host (CR-02) |

**Score:** 3/5 roadmap success criteria verified

### Plan-Level Must-Have Truths (supporting detail)

| Plan | Truth | Status | Evidence |
|------|-------|--------|----------|
| 04-01 | Slow drag 1:1 despite pointer-precision; multi-monitor correct; sub-pixel carried; injection never panics | ✓ VERIFIED | input_thread.rs: normalize_virtual (clamped, i64 math, 3 display-free tests incl. negative-origin + i32::MIN/MAX), inject_absolute with MOUSEEVENTF_VIRTUALDESK, fresh GetCursorPos, `let _ =` non-fatal; SubPixelAccumulator untouched, 3 tests; saturating_add. 10/10 cargo tests green |
| 04-02 | Click/drag/key/text executors real; every CLIENT_KEY_CODES maps Some; unknown drops | ✓ VERIFIED | All 8 MouseKeys methods are one-line tx.send (Enigo never off-thread); 8 new Cmd arms; KeyTap whole-command-drop on unknown code; keymap coverage tests pass; router.rs routes click/drag/key/text/scroll to the trait (lines 84-135, 358) |
| 04-03 | Deterministic classifier; fling seed + stop-first; monotonic accel; volatile sendScroll; all constants in tuning.dart | ✓ VERIFIED | 0 Flutter imports in classifier/tuning/accel; sendScroll mirrors sendMove with shouldSendVolatile gate (connection_service.dart:302-304); 17 k* constants in tuning.dart; 23 unit tests |
| 04-04 | Accelerated moves w/ persisted sensitivity; clicks; momentum w/ touch-stop; drag-lock pill; hot path setState-free | ✓ VERIFIED | accelGain applied in driver (line 103-104); sensitivityProvider (Riverpod 3 Notifier) + `pointer.sensitivity` key; 0 non-comment setState in trackpad_screen.dart; drag-lock ValueNotifier |
| 04-05 | IME typing exact; boundary backspace via sentinel; panel over live trackpad; no logging of typed text | ⚠️ PARTIAL | Sentinel model + computeDiff verified; HiddenTextInput has no Offstage, showCursor:false, multiline, smart-substitutions disabled, ExcludeSemantics; redaction grep clean. FAILED on the disconnect-desync (CR-01, above) |
| 04-06 | Rows work; armed/locked modifiers; hold autorepeat; D-12 reset; every emitted code in vocabulary | ⚠️ PARTIAL | All verified except the rollover stuck-key (CR-02, above). Vocabulary coverage widget-test-gated; D-12 modifier reset proven |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `server/server-windows/src/input_thread.rs` | normalize_virtual + absolute move arm + 8 new Cmd arms | ✓ VERIFIED | 365 lines; `fn normalize_virtual` present; Cmd::KeyTap present; wired via mouse_keys + main composition |
| `server/server-windows/Cargo.toml` | Win32 feature flags | ✓ VERIFIED | Win32_UI_Input_KeyboardAndMouse + Win32_UI_WindowsAndMessaging present |
| `server/server-windows/src/executors/keymap.rs` | Locked vocabulary + map_key/map_mod/map_button | ✓ VERIFIED | 200 lines; CLIENT_KEY_CODES (39) + ROUTER_MACRO_CODES (7); 4 tests |
| `server/server-windows/src/executors/mouse_keys.rs` | All 8 stubs filled as Cmd sends | ✓ VERIFIED | `Cmd::Click` present; zero Enigo references; all one-line sends |
| `app/remote_control/lib/trackpad/gesture_classifier.dart` | Pure IO-free FSM | ✓ VERIFIED | 490 lines, `class GestureClassifier`, 0 Flutter imports |
| `app/remote_control/lib/trackpad/tuning.dart` | ONE constants file | ✓ VERIFIED | 17 k* constants incl. kLongPressMs |
| `app/remote_control/lib/trackpad/accel.dart` | accelGain pure fn | ✓ VERIFIED | 29 lines, `accelGain`, dart:math + tuning only |
| `app/remote_control/lib/net/connection_service.dart` | volatile sendScroll | ✓ VERIFIED | `void sendScroll` behind shouldSendVolatile, no queueing |
| `app/remote_control/lib/trackpad/trackpad_driver.dart` | Intent executor | ✓ VERIFIED | 193 lines, `class TrackpadDriver`, all seams injected |
| `app/remote_control/lib/trackpad/mouse_buttons.dart` | L/M/R bar | ✓ VERIFIED | 154 lines, `class MouseButtonsBar`, widget test |
| `app/remote_control/lib/settings/sensitivity.dart` | Store + provider | ✓ VERIFIED | `sensitivityProvider` NotifierProvider; `pointer.sensitivity` literal |
| `app/remote_control/lib/trackpad/trackpad_screen.dart` | Live surface + chrome | ⚠️ HOLLOW at one seam | Classifier/driver wiring verified; contains the CR-01 defective disconnect reset |
| `app/remote_control/lib/keyboard/diff_ops.dart` | ImeDiffProducer + sentinel | ✓ VERIFIED | 74 lines; `class ImeDiffProducer`, `computeDiff(` present, no hand-rolled diff, no Flutter imports |
| `app/remote_control/lib/keyboard/hidden_text_input.dart` | Zero-footprint IME field | ✓ VERIFIED | `class HiddenTextInput`; no Offstage; all fidelity flags per plan |
| `app/remote_control/lib/keyboard/keyboard_panel.dart` | Panel shell + rows wiring | ⚠️ HOLLOW at one seam | `class KeyboardPanel`, ModifierChip + all three KeyMsg paths wired; contains the CR-02 single-slot _heldCode |
| `app/remote_control/lib/keyboard/modifier_fsm.dart` | Sticky-modifier FSM | ✓ VERIFIED | 170 lines, `class ModifierFsm`, exact hold-code table, zero-effect disconnected() |
| `app/remote_control/lib/keyboard/modifier_chip.dart` | Chip visuals | ✓ VERIFIED | 101 lines, `class ModifierChip` |
| `app/remote_control/lib/keyboard/key_rows.dart` | Rows + kClientKeyCodes | ✓ VERIFIED | 490 lines; `kClientKeyCodes` byte-identical to keymap.rs |

### Key Link Verification

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| input_thread Cmd::Move arm | normalize_virtual | GetCursorPos + delta → inject_absolute → SendInput(ABSOLUTE\|VIRTUALDESK) | ✓ WIRED | input_thread.rs:198-200, 148-174 |
| mouse_keys.rs | input_thread Cmd variants | `self.tx.send(Cmd::...)` | ✓ WIRED | All 10 methods |
| input_thread key arms | keymap map_key | `map_key(&c)` with None-drop | ✓ WIRED | KeyDown/KeyUp/KeyTap arms |
| gesture_classifier | tuning.dart | k* constants | ✓ WIRED | No inline thresholds |
| connection_service sendScroll | move_sender sendScroll | `_sender?.sendScroll` behind shouldSendVolatile | ✓ WIRED | connection_service.dart:302-304 |
| trackpad_screen Listener | trackpad_driver | `_driver.handle(_classifier.onPointer*)` | ✓ WIRED | trackpad_screen.dart:160-177 |
| trackpad_driver | connection_service | onSendMove/onSendScroll/onSendReliable(ClickMsg/DragMsg) | ✓ WIRED | Screen ctor at 108-116; driver at 103-130 |
| trackpad_driver | accel.dart | `accelGain(dx, dy, sensitivity())` before onSendMove | ✓ WIRED | trackpad_driver.dart:103-104 |
| hidden_text_input | diff_ops | controller onChanged → producer.onChanged | ✓ WIRED | hidden_text_input.dart:60-62, 89 |
| diff_ops | remote_protocol computeDiff | grapheme-exact diff, never re-implemented | ✓ WIRED | diff_ops.dart:50 |
| diff_ops | connection_service | TextMsg on sendReliable | ✓ WIRED | trackpad_screen.dart:123 `ImeDiffProducer(emit: _service.sendReliable)` |
| key_rows | keymap.rs | kClientKeyCodes mirrors CLIENT_KEY_CODES byte-for-byte | ✓ WIRED | Programmatic diff: 39 = 39, identical content and order |
| modifier_fsm | connection_service | SendModifierDown/Up → KeyMsg down/up | ✓ WIRED | keyboard_panel.dart:161-163 |
| keyboard_panel | connection_service | KeyMsg down/up, tap+mods, modifier hold on sendReliable | ✓ WIRED | keyboard_panel.dart:182-195; screen passes send: _service.sendReliable |
| router (server) | MouseKeys trait | click/drag/key/text/scroll dispatch | ✓ WIRED | router.rs:84-135, 358 (pre-existing, fixture-proven) |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| TrackpadDriver moves | dx,dy × accelGain | Raw Listener pointer events → classifier | Yes | ✓ FLOWING |
| Drag-lock pill | ValueNotifier<bool> | driver onDragLockChanged | Yes | ✓ FLOWING |
| Sensitivity gain | cached double | ref.listenManual on sensitivityProvider ← SharedPreferences | Yes | ✓ FLOWING |
| TextMsg stream | ImeDiffProducer._committed | HiddenTextInput controller ← system IME | Yes, EXCEPT post-disconnect (desync) | ⚠️ CR-01 |
| KeyMsg stream | _heldCode / fsm state | key caps + modifier chips | Yes, EXCEPT rollover (swallowed up) | ⚠️ CR-02 |
| Server injection | Cmd channel | router → EnigoMouseKeys → input thread | Yes | ✓ FLOWING |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Server suite (normalize_virtual, keymap, accumulator) | `cargo test -p server-windows` | 10 passed, 0 failed | ✓ PASS |
| Full Flutter suite (classifier, driver, FSM, panel, rows, service) | `flutter test` (run once) | 230 passed, "All tests passed!" | ✓ PASS |
| Static analysis | `flutter analyze` | No issues found | ✓ PASS |
| Cross-language vocabulary diff | Python set/order comparison of both lists | 39 = 39, identical content AND order | ✓ PASS |
| SUMMARY commit hashes exist | `git rev-parse --verify` on all 18 claimed hashes | All present | ✓ PASS |

### Probe Execution

SKIPPED — no `scripts/*/tests/probe-*.sh` probes exist in this project and no plan declares any.

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| PAD-01 | 04-01, 04-03, 04-04 | One-finger move, velocity acceleration, server sub-pixel accumulation | ✓ SATISFIED | Absolute injection + accelGain + accumulator, all tested |
| PAD-02 | 04-02, 04-03, 04-04 | Tap = left, two-finger tap = right, L/M/R buttons | ✓ SATISFIED | Classifier intents + ClickMsg + Cmd::Click executors |
| PAD-03 | 04-02, 04-03, 04-04 | Two-finger scroll, momentum, instant touch-stop | ✓ SATISFIED (⚠️ WR-04 feel warning) | sendScroll 0x02 + momentum loop + StopFling-first invariant |
| PAD-04 | 04-02, 04-03, 04-04 | Long-press drag with drag lock | ✓ SATISFIED | DragStart/End intents + ButtonDown/Up + pill + tap-to-drop |
| KEY-01 | 04-02, 04-05 | IME typing incl. autocomplete + backspace via diff-ops | ✗ BLOCKED by CR-01 | Pipeline correct in the steady state; disconnect path replays stale text |
| KEY-02 | 04-02, 04-06 | F1–F12, numpad, nav cluster from key rows | ✓ SATISFIED | 39-code mirrored vocabulary, coverage tests both sides |
| KEY-03 | 04-02, 04-06 | Sticky modifiers, combos (Ctrl+Alt+Del, Win+D) | ✓ SATISFIED | ModifierFsm + KeyTap mods path + auto-reset + D-12 |
| KEY-04 | 04-02, 04-06 | Server-side autorepeat, stops on release | ✗ BLOCKED by CR-02 | Down/up model correct; rollover swallows an up → stuck key |

**Orphaned requirements:** None — REQUIREMENTS.md maps exactly PAD-01..04 and KEY-01..04 to Phase 4, and every ID is claimed by at least one plan.

Note: REQUIREMENTS.md already marks all 8 as Complete `[x]` — premature for KEY-01 and KEY-04 given the gaps above.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| app/remote_control/lib/trackpad/trackpad_screen.dart | 136 | One-sided state reset (producer reset without controller reseed) | 🛑 Blocker | Post-reconnect text replay / delete-becomes-insert (CR-01) |
| app/remote_control/lib/keyboard/keyboard_panel.dart | 105, 188 | Single-slot held-state tracking under multi-pointer input | 🛑 Blocker | Stuck autorepeating key on rollover (CR-02) |
| app/remote_control/lib/trackpad/gesture_classifier.dart | ~391-403 | Constant `/2` scroll averaging regardless of live pointer count | ⚠️ Warning | Scroll rate halves when one of two fingers lifts (WR-04) |
| app/remote_control/lib/net/connection_service.dart | 360-420 | No dial-generation guard on concurrent dials | ⚠️ Warning | Session can bind to the wrong target (WR-01, connection-layer — outside phase must-haves) |
| app/remote_control/lib/net/connection_service.dart | 327-346 | dispose() doesn't invalidate pending backoff timers | ⚠️ Warning | Post-dispose redial leak (WR-02, latent) |
| lib/settings/sensitivity.dart + lib/keyboard/key_rows.dart | — | Async prefs load can clobber a user set(); post-dispose state throw | ⚠️ Warning | UI/storage disagreement until restart (WR-03) |
| — | — | TBD/FIXME/XXX/TODO debt markers in phase files | — | None found (grep hits were `toDouble()` false positives and doc comments) |

No logging of typed text anywhere in lib/keyboard/ (SPEC §12 redaction upheld).

### Human Verification Required

Harvested from the plans' deferred `<human-check>` blocks (human_verify_mode = end-of-phase) — see frontmatter `human_verification` for the structured list:

1. **Ballistics bypass + multi-monitor** — slow 1:1 drag with Enhance pointer precision ON; dual-monitor seam crossing (04-01)
2. **Trackpad feel vs Remote Mouse** — full gesture set, drag-lock pill lifecycle, live sensitivity (04-04)
3. **IME fidelity on device** — autocomplete revisions, 👋🏽 emoji, rapid backspace; trackpad live while typing (04-05, RESEARCH A2)
4. **Combos, autorepeat, mid-combo disconnect** — Win+D, locked-Ctrl + held Right, connection kill mid-lock (04-02/04-06)

These remain necessary even after the gaps are closed; the on-device gate should run AFTER the CR-01/CR-02 fixes so it exercises the corrected paths.

### Gaps Summary

The phase is substantially built and well-tested — all 18 planned artifacts exist, are substantive, and are wired end-to-end; both test suites are fully green (10 Rust + 230 Flutter); the cross-language key vocabulary is byte-identical; and the hot-path/redaction/never-panic invariants all hold under inspection.

However, two independently-confirmed Critical defects (found by the phase code review at commit 83bb31d, with **no fix commits since**) each break a roadmap success criterion in an ordinary usage scenario:

1. **CR-01 (breaks SC2/KEY-01):** the disconnect-hygiene `_imeProducer.reset()` desynchronizes committed text from the hidden field's controller. After any WiFi blip mid-typing, the next keystroke replays everything previously typed (potentially a password) into the new session, and backspaces become inserts. This is phantom input surviving a drop — the inverse of the D-12 guarantee the phase claims.
2. **CR-02 (breaks SC5/KEY-04):** `KeyboardPanel` tracks one held key cap in a single `String?`. Routine key rollover (arrow keys) swallows the first key's `up`, leaving it held and autorepeating on the PC indefinitely.

Both fixes are small and localized (remove/atomize one reset call; replace a `String?` with a `Set<String>`), each with an obvious regression test. Neither is addressed by any later phase (Phase 5–7 goals checked — no match), so both are actionable gaps, not deferrals. The four review warnings (WR-01..04) do not block roadmap criteria but WR-04 (scroll halving) touches PAD-03 feel and is worth folding into the same gap-closure plan.

---

_Verified: 2026-07-10_
_Verifier: Claude (gsd-verifier)_
