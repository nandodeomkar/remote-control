---
phase: 04-trackpad-keyboard
verified: 2026-07-10T07:53:15Z
status: human_needed
score: 5/5 roadmap success criteria verified
overrides_applied: 0
re_verification:
  previous_status: gaps_found
  previous_score: 3/5
  gaps_closed:
    - "Typing with the phone keyboard — including IME autocomplete revisions, emoji, and backspace — produces exactly the same text on the PC (SC2/KEY-01): CR-01 closed by 04-07 (commits 76ebb93, 43dcc3a) — atomic producer+controller IME reset on disconnect"
    - "Holding a key autorepeats via server-side key-down/hold and stops immediately on release (SC5/KEY-04): CR-02 closed by 04-08 (commits d5844aa, e8effa0) — Set<String> _heldCodes rollover-safe tracking; IN-04 closed in the same plan — always-wired release handlers with _live guard"
    - "Warning WR-04 (scroll rate halved after one-finger lift) closed by 04-09 (commits 941b40a, 7131c05) — scroll deltas scaled by live tracked-pointer count"
  gaps_remaining: []
  regressions: []
human_verification:
  - test: "On the Windows laptop with 'Enhance pointer precision' ON: slow, small phone drag moves the cursor 1:1 (no ballistics suppression). On a dual-monitor PC, cross the seam onto the secondary display and back"
    expected: "1:1 tracking regardless of the OS pointer-precision setting; no jump or clamp at the monitor seam"
    why_human: "Requires real display hardware and OS pointer settings; SendInput behavior cannot be verified by grep or unit tests (deferred end-of-phase gate, 04-01)"
  - test: "On device vs the Remote Mouse benchmark (D-05): move/tap/two-finger-tap/L-M-R buttons/scroll-momentum/drag-lock; drag-lock pill appears on long-press and a tap drops it; sensitivity slider changes feel live. Include the WR-04 path: lift one of two scrolling fingers and keep scrolling with the remaining finger"
    expected: "Full gesture set works and feels at least as good as Remote Mouse; pill lifecycle correct; slider applies live and persists; post-lift scroll continues at full rate (04-09 fix)"
    why_human: "Trackpad 'feel' (acceleration, momentum decay, thresholds) is subjective and device-dependent — the tuning.dart constants are explicitly on-device tuning starting points (deferred end-of-phase gate, 04-04; must run AFTER 04-09 so feel tuning happens against correct post-lift kinematics)"
  - test: "Open the keyboard panel, type with autocomplete, insert a multi-codepoint emoji, rapid-backspace across it; verify the trackpad still moves the cursor while the panel + system IME are up. Then kill WiFi mid-typing, reconnect, and type one character"
    expected: "PC text matches the phone exactly (autocomplete revisions, emoji as one grapheme, correct backspace counts); trackpad stays live while typing (D-07); after the reconnect the PC receives ONLY the new character — no replay of pre-disconnect text (CR-01 fix)"
    why_human: "Real Android IME composing/committed behavior varies by keyboard app (RESEARCH A2) — cannot be simulated in widget tests (deferred end-of-phase gate, 04-05; must run AFTER 04-07 so it exercises the corrected disconnect path)"
  - test: "Arm Win then tap D; lock Ctrl (long-press) then hold Right in a text editor; roll from held Right onto Down (press Down before releasing Right); kill the connection mid-lock"
    expected: "Win+D shows the desktop and the Win chip auto-resets; Ctrl+Right repeats word-by-word while held and stops instantly on release; the rollover releases BOTH arrows — no key keeps autorepeating (CR-02 fix); after the drop, chips reset and no key stays held on the PC (CONN-07 + D-12)"
    why_human: "OS-level combo execution, autorepeat cadence, and release_all behavior need a live Windows session (deferred end-of-phase gate, 04-02/04-06; must run AFTER 04-08 so it exercises the rollover-safe path)"
---

# Phase 4: Trackpad & Keyboard — Verification Report (Re-verification)

**Phase Goal:** The phone is a genuinely usable daily mouse and keyboard — trackpad feel (raw Listener classifier, acceleration, momentum, drag lock) and typing fidelity (IME diff-ops, special rows, sticky modifiers, server-side autorepeat) match a real laptop, not a toy
**Phase User Story (from all six PLANs, MVP mode):** As a laptop owner, I want to use my phone as a precise mouse and full keyboard for my Windows laptop, so that it replaces a real trackpad and keyboard — not a toy.
**Verified:** 2026-07-10T07:53:15Z
**Status:** human_needed — all 5 roadmap success criteria verify programmatically; the 4 deferred on-device gates remain
**Re-verification:** Yes — after gap closure (initial verification 2026-07-10: gaps_found, 3/5)

> **MVP-mode note (carried from initial verification):** ROADMAP.md marks this phase `Mode: mvp` but its Goal field is prose, not User Story format. All six PLANs consistently embed the User Story above (which passes the canonical format), so verification proceeded against it. Flagged for hygiene: the ROADMAP Goal field should carry the User Story for MVP phases.

## Re-verification Summary

Initial verification found two BLOCKER gaps (CR-01 breaking SC2, CR-02 breaking SC5) and one warning (WR-04). Three gap-closure plans (04-07, 04-08, 04-09) have since executed; all nine claimed commits verified in git history; working tree is clean (code on disk = HEAD). Every fix was independently confirmed in the code — not taken from SUMMARY claims — and each carries regression tests that are part of the now-238-test green suite.

| Gap | Fix plan | Commits | Independently confirmed in code | Regression tests |
|-----|----------|---------|--------------------------------|------------------|
| CR-01 (SC2): one-sided `_imeProducer.reset()` on disconnect → post-reconnect replay of stale text | 04-07 | 76ebb93 (RED), 43dcc3a (GREEN), 1f70729 (docs) | ✓ One-sided reset DELETED from trackpad_screen.dart disconnect listener (lines 135-142 now call only `_driver.reset()`); `KeyboardPanel._imeResetTick` ValueNotifier (keyboard_panel.dart:120) fired in `_onDisconnected` (line 147) and wired as `resetSignal` (line 273); `HiddenTextInput._onExternalReset` (hidden_text_input.dart:87-94) writes `producer.reseed()` back into the controller under the `_reseeding` guard in ONE synchronous callback; `reseed()` resets `_committed` to the sentinel AND returns the seed (diff_ops.dart:64-67) — the two sides can no longer desync. `didUpdateWidget` re-subscribes on signal identity change; listener removed before controller dispose | keyboard_panel_test.dart:261 (first post-reconnect keystroke emits ONLY the new char, controller wiped to exactly the sentinel, reset write-back emits nothing, `ins.contains('secret')` asserted false) + :302 (post-reconnect backspace emits bs:1 never an insert; boundary reseed still restores the full sentinel) |
| CR-02 (SC5): single `String? _heldCode` slot swallowed the first key's up on rollover → stuck autorepeating key | 04-08 | d5844aa (RED), e8effa0 (GREEN), 4bdde4c (docs) | ✓ `final Set<String> _heldCodes` (keyboard_panel.dart:109); `_onKeyDown` adds + sends down (195-198); `_onKeyUp` sends up only if `_heldCodes.remove(code)` returns true (200-207) — one guard covers the D-12 stale-up skip AND IN-04 no-down releases; `_onDisconnected` clears the whole set with zero sends (146) | keyboard_panel_test.dart:339 (two concurrent pointers, rollover Right→Down: exact sequence `down:Right, down:Down, up:Right, up:Down` asserted) + :373 (disconnect mid-hold wipes ALL held caps; later release sends NO stale up) |
| IN-04 (SC5-adjacent): `enabled` flip mid-press nulled the release handlers → same stuck-key class | 04-08 | same as CR-02 | ✓ `_KeyCap.onTapUp`/`onTapCancel` ALWAYS wired (key_rows.dart:428-429); only `onTapDown` gated on `widget.enabled` (422); `_live` press-lifecycle flag (366) set in `_onTapDown`, checked-and-cleared in both release paths — disabled-started presses stay inert, mid-press flips still release; a canceled non-deferred press still releases the held key (396) | key_rows_test.dart:122 (enabled flips false mid-press — release still fires `up:Right`); pre-existing gated-inert tests green unmodified |
| WR-04 (warning, PAD-03 feel): constant `/2` scroll averaging halved rate after one-finger lift | 04-09 | 941b40a (RED), 7131c05 (GREEN), 3f28e8c (docs) | ✓ `_emitScroll` divides by `final n = _pointers.length` (gesture_classifier.dart:463-465); n==2 both fingers down (byte-identical to shipped averaging), n==1 post-lift (full rate); velocity samples record correctly-scaled deltas so fling seeds are unhalved; n>=1 structurally guaranteed by the `_pointers[pointer]` null-check upstream; tuning.dart untouched | gesture_classifier_test.dart:302 group, 3 exact-value tests (post-lift full rate -24 not -12; unhalved fling seed -2.4 not -1.2; tapPending2 slop-crossing full delta -30 not -15) |

**Regression check on previously-passed items:** `git diff --name-only 8db3a3c..HEAD -- app server` shows the gap-closure commits touched ONLY the five expected lib files and their three test files — zero server files changed, so the initial verification's 10/10 cargo test result stands. The cross-language key vocabulary was re-diffed programmatically after the key_rows.dart edit: 39 = 39, identical content AND order. `flutter analyze`: no issues. Full suite: 238/238 (230 initial + 2 CR-01 + 3 CR-02/IN-04 + 3 WR-04).

## User Flow Coverage (MVP mode)

| Step | Expected | Evidence in codebase | Status |
|------|----------|---------------------|--------|
| Move a finger on the trackpad | PC cursor moves 1:1 with acceleration | Listener → GestureClassifier → TrackpadDriver.accelGain-scaled onSendMove → sendMove 0x01 → server absolute SendInput(VIRTUALDESK) | ✓ (feel needs human) |
| Tap / two-finger tap / L-M-R bar | Left, right, and explicit clicks on the PC | ClickLeftIntent/ClickRightIntent → ClickMsg → router → Cmd::Click → enigo.button | ✓ |
| Two-finger scroll, lift with velocity | Momentum scroll, new touch stops it instantly; post-lift single finger scrolls at full rate | ScrollIntent/FlingIntent + StopFlingIntent-first invariant; live-pointer-count divisor (04-09); generation-guarded momentum loop; sendScroll 0x02 volatile | ✓ |
| Long-press, lift, drag to edge, tap | Drag lock survives lift; pill shows; tap drops | DragStart/DragEnd intents → DragMsg start/end → Cmd::ButtonDown/Up; ValueNotifier pill | ✓ |
| Open panel, type with the phone IME | Exact same text on the PC — including across a disconnect | HiddenTextInput → ImeDiffProducer → computeDiff → TextMsg → Cmd::Type/Backspace; atomic producer+controller wipe on disconnect (04-07) | ✓ (device IME variance needs human) |
| Press special keys / hold a key | Nav/Fn/Num act; hold autorepeats, release stops — including on rollover | key_rows down/up emission → KeyMsg → Cmd::KeyDown/KeyUp; Set-based held tracking + always-wired releases (04-08) | ✓ (autorepeat cadence needs human) |
| Arm/lock modifiers, send combos | Win+D, Ctrl+Alt+Del; auto-reset; disconnect-safe | ModifierFsm armed/locked; KeyTap mods path; disconnected() zero-effect reset | ✓ |

## Goal Achievement

### Observable Truths (roadmap Success Criteria — the contract)

| # | Truth | Status | Evidence |
|---|-------|--------|----------|
| 1 | Full gesture set: accelerated move, tap=left, two-finger tap=right, L/M/R buttons, momentum scroll w/ instant touch-stop, long-press drag with drag lock | ✓ VERIFIED | GestureClassifier (21 tests incl. 3 WR-04), TrackpadDriver, MouseButtonsBar, drag-lock pill; wiring confirmed trackpad_screen.dart:162-180; WR-04 scroll-halving warning CLOSED (04-09). On-device feel deferred to human gate |
| 2 | IME typing (autocomplete, emoji, backspace) produces exactly the same text on the PC | ✓ VERIFIED | Base pipeline verified initially (computeDiff never re-implemented, sentinel model, fixture-mirroring tests, Cmd::Type via enigo.text()). CR-01 CLOSED: one-sided producer reset deleted; panel-fired `_imeResetTick` → `_onExternalReset` atomic reseed (producer `_committed` + controller text both return to the sentinel in one synchronous callback); no-replay + backspace-stays-bs regression tests green |
| 3 | F1–F12, numpad, nav cluster all work from toggleable key rows | ✓ VERIFIED | key_rows.dart 39-code kClientKeyCodes re-diffed post-04-08 against keymap.rs CLIENT_KEY_CODES: byte-identical content AND order; Nav/Fn/Num groups with persisted `keyboard.rowGroup`; server map_key covers all 39 + 7 router macro codes; coverage tests green both sides |
| 4 | Sticky modifiers show held state, send combos, auto-reset, reset safely on disconnect | ✓ VERIFIED | ModifierFsm armed/locked two-level model (7 tests, file untouched by gap closure); hold codes exact; locked = physical hold excluded from modsForTap; disconnected() zero-effect reset proven via fake changes stream; D-12 test (keyboard_panel_test.dart:239) green |
| 5 | Held keys autorepeat server-side and stop immediately on release | ✓ VERIFIED | Server halves unchanged (Cmd::KeyDown → enigo Press, KeyUp → Release). CR-02 CLOSED: `Set<String> _heldCodes` with remove()-guarded ups — rollover releases EVERY key (exact-sequence test); IN-04 CLOSED: always-wired onTapUp/onTapCancel with `_live` guard — mid-press enabled flip still releases; disconnect wipes all held caps with zero sends (D-12 preserved) |

**Score:** 5/5 roadmap success criteria verified (previous: 3/5)

### Plan-Level Must-Have Truths (supporting detail)

| Plan | Truth | Status | Evidence |
|------|-------|--------|----------|
| 04-01 | Slow drag 1:1 despite pointer-precision; multi-monitor correct; sub-pixel carried; injection never panics | ✓ VERIFIED (unchanged) | No server files touched since initial verification; 10/10 cargo tests stand |
| 04-02 | Click/drag/key/text executors real; every CLIENT_KEY_CODES maps Some; unknown drops | ✓ VERIFIED (unchanged) | No server files touched; vocabulary re-diffed: identical |
| 04-03 | Deterministic classifier; fling seed + stop-first; monotonic accel; volatile sendScroll; all constants in tuning.dart | ✓ VERIFIED | 04-09 divisor uses live FSM state, not a new tunable (tuning.dart untouched); classifier still 0 Flutter imports; 21 classifier tests green |
| 04-04 | Accelerated moves w/ persisted sensitivity; clicks; momentum w/ touch-stop; drag-lock pill; hot path setState-free | ✓ VERIFIED (unchanged) | trackpad_screen.dart edit was comment + deletion of the producer reset only; 0 non-comment setState on the hot path |
| 04-05 | IME typing exact; boundary backspace via sentinel; panel over live trackpad; no logging of typed text | ✓ VERIFIED | Was PARTIAL (CR-01); now closed — atomic reset also PURGES pre-disconnect plaintext from the controller buffer (stronger T-04-03 closure); redaction grep still clean |
| 04-06 | Rows work; armed/locked modifiers; hold autorepeat; D-12 reset; every emitted code in vocabulary | ✓ VERIFIED | Was PARTIAL (CR-02); now closed — set-based tracking + always-wired releases; D-12 semantics preserved for any number of held caps |
| 04-07 | Atomic producer+controller IME reset on the disconnected transition; no replay, backspace stays bs | ✓ VERIFIED | Code + tests confirmed above (gap-closure plan) |
| 04-08 | Rollover releases every key; disconnect wipes all held caps; mid-press enabled flip still releases; disabled-started press inert | ✓ VERIFIED | Code + tests confirmed above (gap-closure plan) |
| 04-09 | Post-lift scroll at full rate; unhalved fling seed; two-finger averaging byte-identical | ✓ VERIFIED | Code + tests confirmed above (gap-closure plan) |

### Required Artifacts

| Artifact | Expected | Status | Details |
|----------|----------|--------|---------|
| `server/server-windows/src/input_thread.rs` | normalize_virtual + absolute move arm + 8 new Cmd arms | ✓ VERIFIED | Unchanged since initial verification |
| `server/server-windows/Cargo.toml` | Win32 feature flags | ✓ VERIFIED | Unchanged |
| `server/server-windows/src/executors/keymap.rs` | Locked vocabulary + map_key/map_mod/map_button | ✓ VERIFIED | Unchanged; re-diffed against Dart side |
| `server/server-windows/src/executors/mouse_keys.rs` | All 8 stubs filled as Cmd sends | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/trackpad/gesture_classifier.dart` | Pure IO-free FSM | ✓ VERIFIED | Still 0 Flutter imports; `_emitScroll` now divides by live `_pointers.length` (463-465) |
| `app/remote_control/lib/trackpad/tuning.dart` | ONE constants file | ✓ VERIFIED | Untouched by 04-09 (verified: n is live FSM state, not a tunable) |
| `app/remote_control/lib/trackpad/accel.dart` | accelGain pure fn | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/net/connection_service.dart` | volatile sendScroll | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/trackpad/trackpad_driver.dart` | Intent executor | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/trackpad/mouse_buttons.dart` | L/M/R bar | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/settings/sensitivity.dart` | Store + provider | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/trackpad/trackpad_screen.dart` | Live surface + chrome | ✓ VERIFIED | Was HOLLOW at the CR-01 seam; the one-sided `_imeProducer.reset()` is GONE (disconnect listener 135-142 calls only `_driver.reset()`); comment redirects to the panel-owned atomic hygiene |
| `app/remote_control/lib/keyboard/diff_ops.dart` | ImeDiffProducer + sentinel | ✓ VERIFIED | `reseed()` resets `_committed` AND returns the seed (64-67) — the atomic-wipe contract |
| `app/remote_control/lib/keyboard/hidden_text_input.dart` | Zero-footprint IME field | ✓ VERIFIED | + `resetSignal` Listenable seam (35), `_onExternalReset` guarded write-back (87-94), `didUpdateWidget` re-subscription (64-72), listener removed before controller dispose (75-79); all original fidelity flags intact |
| `app/remote_control/lib/keyboard/keyboard_panel.dart` | Panel shell + rows wiring | ✓ VERIFIED | Was HOLLOW at the CR-02 seam; now `Set<String> _heldCodes` (109) + remove()-guarded `_onKeyUp` (200-207) + `_imeResetTick` (120) fired in `_onDisconnected` (144-149), disposed (166), wired as resetSignal (273) |
| `app/remote_control/lib/keyboard/modifier_fsm.dart` | Sticky-modifier FSM | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/keyboard/modifier_chip.dart` | Chip visuals | ✓ VERIFIED | Unchanged |
| `app/remote_control/lib/keyboard/key_rows.dart` | Rows + kClientKeyCodes | ✓ VERIFIED | Vocabulary untouched (re-diffed); `_KeyCap` now has `_live` guard (366) + always-wired onTapUp/onTapCancel (428-429), onTapDown still enabled-gated (422) |

### Key Link Verification

All 16 key links from the initial verification re-confirmed unchanged, plus two new links introduced by the gap closure:

| From | To | Via | Status | Details |
|------|----|-----|--------|---------|
| keyboard_panel `_onDisconnected` | hidden_text_input `_onExternalReset` | `_imeResetTick` ValueNotifier wired as `resetSignal` | ✓ WIRED | keyboard_panel.dart:147, 273 → hidden_text_input.dart:60, 87 |
| hidden_text_input `_onExternalReset` | diff_ops `reseed()` | atomic write-back under `_reseeding` guard | ✓ WIRED | hidden_text_input.dart:89-93 → diff_ops.dart:64-67; zero emissions asserted by test |
| key_rows `_KeyCap` releases | keyboard_panel `_onKeyUp` | always-wired onTapUp/onTapCancel → onKeyUp seam | ✓ WIRED | key_rows.dart:428-429, 386, 396 → keyboard_panel.dart:254, 200-207 |
| trackpad_screen Listener | trackpad_driver | `_driver.handle(_classifier.onPointer*)` | ✓ WIRED | trackpad_screen.dart:162-180 (unchanged) |
| All other initial links (input_thread, mouse_keys, keymap, tuning, sendScroll, accel, diff→reliable, vocabulary mirror, fsm→send, router) | — | — | ✓ WIRED | Files unchanged since initial verification; suite green |

### Data-Flow Trace (Level 4)

| Artifact | Data Variable | Source | Produces Real Data | Status |
|----------|--------------|--------|--------------------|--------|
| TrackpadDriver moves | dx,dy × accelGain | Raw Listener pointer events → classifier | Yes | ✓ FLOWING |
| ScrollIntent stream | dx/n, dy/n | Live `_pointers.length` divisor | Yes — full rate post-lift (was half) | ✓ FLOWING (WR-04 closed) |
| TextMsg stream | ImeDiffProducer._committed | HiddenTextInput controller ← system IME | Yes — INCLUDING across disconnects (atomic reseed keeps producer == controller) | ✓ FLOWING (CR-01 closed) |
| KeyMsg stream | _heldCodes / fsm state | key caps + modifier chips | Yes — INCLUDING rollover and mid-press gating flips | ✓ FLOWING (CR-02/IN-04 closed) |
| Server injection | Cmd channel | router → EnigoMouseKeys → input thread | Yes | ✓ FLOWING (unchanged) |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
|----------|---------|--------|--------|
| Full Flutter suite (238 = 230 initial + 8 regression) | `flutter test` (run once) | 238 passed, "All tests passed!" | ✓ PASS |
| Static analysis | `flutter analyze` | No issues found | ✓ PASS |
| Cross-language vocabulary diff (post-04-08 key_rows edit) | Python comparison of kClientKeyCodes vs CLIENT_KEY_CODES | 39 = 39, identical content AND order | ✓ PASS |
| Gap-fix commit hashes exist | git log inspection of all 9 claimed hashes (76ebb93, 43dcc3a, 1f70729, d5844aa, e8effa0, 4bdde4c, 941b40a, 7131c05, 3f28e8c) | All present at top of history; working tree clean | ✓ PASS |
| Gap-closure blast radius | `git diff --name-only 8db3a3c..HEAD -- app server` | Exactly the 5 lib + 3 test files expected; zero server files | ✓ PASS |
| Server suite | Not re-run — zero server files changed since the initial verification's `cargo test -p server-windows` (10 passed) | Result stands by immutability | ✓ PASS (carried) |

### Probe Execution

SKIPPED — no `scripts/*/tests/probe-*.sh` probes exist in this project and no plan declares any.

### Requirements Coverage

| Requirement | Source Plan(s) | Description | Status | Evidence |
|-------------|---------------|-------------|--------|----------|
| PAD-01 | 04-01, 04-03, 04-04 | One-finger move, velocity acceleration, server sub-pixel accumulation | ✓ SATISFIED | Unchanged since initial verification |
| PAD-02 | 04-02, 04-03, 04-04 | Tap = left, two-finger tap = right, L/M/R buttons | ✓ SATISFIED | Unchanged |
| PAD-03 | 04-02, 04-03, 04-04, 04-09 | Two-finger scroll, momentum, instant touch-stop | ✓ SATISFIED | WR-04 feel warning closed — post-lift full-rate scroll + unhalved fling seed, test-proven |
| PAD-04 | 04-02, 04-03, 04-04 | Long-press drag with drag lock | ✓ SATISFIED | Unchanged |
| KEY-01 | 04-02, 04-05, 04-07 | IME typing incl. autocomplete + backspace via diff-ops | ✓ SATISFIED | CR-01 closed: atomic reset — no replay, backspace stays a backspace, both test-locked |
| KEY-02 | 04-02, 04-06 | F1–F12, numpad, nav cluster from key rows | ✓ SATISFIED | Vocabulary re-diffed post-edit: identical |
| KEY-03 | 04-02, 04-06 | Sticky modifiers, combos (Ctrl+Alt+Del, Win+D) | ✓ SATISFIED | Unchanged |
| KEY-04 | 04-02, 04-06, 04-08 | Server-side autorepeat, stops on release | ✓ SATISFIED | CR-02 + IN-04 closed: rollover-safe set tracking, always-wired releases, both test-locked |

**Orphaned requirements:** None. REQUIREMENTS.md's `[x]` marks for KEY-01 and KEY-04 — flagged premature in the initial verification — are now accurate.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
|------|------|---------|----------|--------|
| — | — | Initial CR-01 (one-sided reset), CR-02 (single-slot held tracking), WR-04 (constant /2) blockers/warning | — | ALL CLOSED (04-07/08/09) |
| app/remote_control/lib/net/connection_service.dart | ~360-420 | No dial-generation guard on concurrent dials | ⚠️ Warning | WR-01, connection-layer — outside phase must-haves, untouched by design (carried) |
| app/remote_control/lib/net/connection_service.dart | ~327-346 | dispose() doesn't invalidate pending backoff timers | ⚠️ Warning | WR-02, latent (carried) |
| lib/settings/sensitivity.dart + lib/keyboard/key_rows.dart | — | Async prefs load can clobber a user set(); post-dispose state throw | ⚠️ Warning | WR-03, UI/storage disagreement until restart (carried) |
| — | — | TBD/FIXME/XXX/TODO/HACK/PLACEHOLDER debt markers across lib/ | — | None found (fresh grep, zero matches) |

No logging of typed text anywhere in lib/keyboard/ (SPEC §12 redaction upheld). Security threats T-04-03 (info disclosure via replay/buffer) and T-04-04 (stuck-key) are addressed by 04-07/04-08 per their summaries — the 04-SECURITY.md re-audit (`/gsd-secure-phase 4`) can now flip both to closed.

### Human Verification Required

The four deferred end-of-phase gates (human_verify_mode = end-of-phase) remain — see frontmatter `human_verification` for the structured list. They MUST now run against the corrected paths, and three have been extended to exercise the specific fixes:

1. **Ballistics bypass + multi-monitor** — slow 1:1 drag with Enhance pointer precision ON; dual-monitor seam crossing (04-01)
2. **Trackpad feel vs Remote Mouse** — full gesture set, drag-lock pill lifecycle, live sensitivity, AND post-lift scroll rate (04-04 + 04-09 fix)
3. **IME fidelity on device** — autocomplete revisions, emoji, rapid backspace, trackpad live while typing, AND WiFi-drop → reconnect → no replay (04-05 + 04-07 fix, RESEARCH A2)
4. **Combos, autorepeat, mid-combo disconnect** — Win+D, locked-Ctrl + held Right, arrow-key rollover releases both, connection kill mid-lock (04-02/04-06 + 04-08 fix)

### Gaps Summary

None remaining. Both initial BLOCKER gaps (CR-01/SC2, CR-02/SC5) and the IN-04 and WR-04 findings are closed, each independently confirmed in code (not from SUMMARY claims) and locked by regression tests within the 238/238-green suite. No regressions in previously-passed items: server code is untouched since the initial verification, the key vocabulary remains byte-identical across languages, the hot-path/redaction/purity invariants all hold, and static analysis is clean.

All five roadmap success criteria now verify programmatically (5/5, previously 3/5). Status is `human_needed` rather than `passed` solely because the four deferred on-device gates (trackpad feel, real-IME fidelity, OS-level autorepeat/combo behavior, display ballistics) can only be validated by a human on real hardware — automated verification is exhausted.

---

_Verified: 2026-07-10T07:53:15Z_
_Verifier: Claude (gsd-verifier)_
_Re-verification after gap-closure plans 04-07, 04-08, 04-09_
