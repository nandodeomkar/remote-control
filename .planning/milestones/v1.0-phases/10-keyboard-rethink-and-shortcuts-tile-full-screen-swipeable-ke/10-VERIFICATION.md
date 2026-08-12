---
phase: 10-keyboard-rethink-and-shortcuts-tile-full-screen-swipeable-ke
verified: 2026-07-17T12:30:00Z
status: passed
score: 12/12 must-haves verified
overrides_applied: 0
---

# Phase 10: Keyboard rethink and Shortcuts tile Verification Report

**Phase Goal:** The Keyboard screen becomes four full-screen swipeable pads (Type with the system IME + a slim extras row, Arrows, Numpad, Fn) with persistent Ctrl/Alt/Shift/Win chips and a bottom tab bar replacing the cramped Nav/Fn/Num strip — every key dramatically larger, every sacred stuck-key invariant preserved — and a new Shortcuts hub tile (position 3) fires 25 one-tap Windows shortcuts over the existing `key {action:tap, mods}` path, with the `keymap.rs` CLIENT_KEY_CODES vocabulary + its Dart mirror extended in lockstep. No protocol version bump.
**Verified:** 2026-07-17
**Status:** passed
**Re-verification:** No — initial verification

## Goal Achievement

### Observable Truths

| # | Truth | Status | Evidence |
| --- | ----- | ------ | -------- |
| 1 | Vocabulary extended +18 codes both sides, byte-for-byte lockstep | ✓ VERIFIED | `server/server-windows/src/executors/keymap.rs:56-62` and `app/remote_control/lib/keyboard/key_rows.dart:56-57` list identical 18 codes (A C D E F I R S V X Y Z 0 PrintScreen T W Plus Minus); Dart lockstep test asserts each (`key_rows_test.dart` "byte-for-byte" block); Rust `keymap_covers_all_codes` passed (re-run 2026-07-17: 5/5 keymap tests ok) |
| 2 | Every catalog code maps to a real enigo Key — no silent drop | ✓ VERIFIED | `keymap.rs:153-176` — letters via `Key::Unicode(lowercase)`, `"0" => Key::Unicode('0')`, `"PrintScreen" => Key::PrintScr`, `Plus/Minus => Unicode('=')/('-')`; coverage test iterates full `CLIENT_KEY_CODES` (keymap.rs:210) — passed |
| 3 | No protocol version bump | ✓ VERIFIED | Phase diff `a42af37^..HEAD` touches only `keymap.rs` on the Rust side (+35 lines); `SERVER_PROTO_VERSION` still `"1.5"` (`server/server-core/src/transport/session.rs:60`, untouched); Dart `version.dart` untouched |
| 4 | Shortcuts tile sits at hub position 3 (after Keyboard, before Media) | ✓ VERIFIED | `app/remote_control/lib/hub/hub_screen.dart:98-106` — third `HubTileSpec` in `kHubTiles`, label 'Shortcuts', builder → `ShortcutsScreen`; `hub_tiles_test.dart` in green run |
| 5 | Catalog = 4 sections / 25 buttons; tap fires one `key {action:tap, mods}` on reliable path | ✓ VERIFIED | `shortcuts_screen.dart:85` `kShortcutCatalog` (25 `ShortcutSpec` + 4 `ShortcutSection` instances, excluding constructors); `shortcuts_screen.dart:414-415` `sendReliable(KeyMsg(code, action:'tap', mods))`; tests assert section counts 7/3/9/6 = 25, Win+D and Ctrl+C wire sends — passed 2026-07-17 |
| 6 | Offline buttons muted-not-red and inert; excluded combos never render | ✓ VERIFIED | Test "disconnected: pressing a button sends nothing (gated muted)" passed; test "no excluded combo renders (Alt+Tab, Win+L lock, Ctrl+Alt+Del)" passed (`shortcuts_screen_test.dart:120`) |
| 7 | Sacred emission model reusable as public KeyCap; four pads' caps all in vocabulary | ✓ VERIFIED | `key_rows.dart:474` `class KeyCap` (public); `key_pads_test.dart:20-35` asserts every `capsForPad` code ∈ `kClientKeyCodes` for all four `KeyboardPad` values — passed |
| 8 | Last-open pad persists under NEW `keyboard.pad` key; `keyboard.rowGroup` independent | ✓ VERIFIED | `key_rows.dart:285` `kKeyboardPadPrefsKey = 'keyboard.pad'`; `KeyboardPadStore` (:290-315) + `keyboardPadProvider` (:348); `kKeyRowGroupPrefsKey = 'keyboard.rowGroup'` unchanged; store test asserts distinctness + default/corrupt/roundtrip — passed |
| 9 | Four full-screen pads with Expanded-flex caps + bottom tab bar (accent underline, always interactive) | ✓ VERIFIED | `key_pads.dart` — `TypePad`:278 (hint + slim extras row, IME mounted at screen level), `ArrowsPad`:340, `NumpadPad`:434, `FnPad`:513, `KeyboardTabBar`:201 with `onSelect(pad)`; caps built as `KeyCap(` inside `Expanded` cells; `pad_widgets_test.dart` (411 lines) in green run |
| 10 | Keyboard screen = PageView of four pads, persistent chips, one ModifierFsm, IME raised only on Type pad, pad restored + persisted | ✓ VERIFIED | `keyboard_screen.dart:362-368` PageView with `allowImplicitScrolling: false` + `onPageChanged`; :370-394 four pads wired; :87 single `ModifierFsm`; :268-272 `_onPageChanged` persists via `keyboardPadProvider` + `requestFocus` on page 0; :134 restores from provider; `HiddenTextInput` mounted outside PageView (:30). No keep-alive anywhere (CR-01 hinge intact) |
| 11 | Every sacred stuck-key invariant survives at screen level (CR-01/CR-02/IN-04/D-12/dispose-flush) | ✓ VERIFIED | `keyboard_screen.dart:95` `_heldCodes` set, :191-212 dispose LIVE-only flush, :185/:250 idempotent release; `keyboard_screen_test.dart:159-254` named suites for CR-01 page-leave release, CR-02 rollover + disconnect wipe, IN-04 cancelled-press release, D-12 zero-wire chip reset — all in green run (109/109 targeted tests passed 2026-07-17) |
| 12 | `keyboard_panel.dart` (D-07 docked panel) byte-untouched across phase | ✓ VERIFIED | `git log a42af37^..HEAD -- keyboard_panel.dart` → zero commits; `git diff a42af37^..HEAD --stat` → file absent from diff |

**Score:** 12/12 truths verified

### Required Artifacts

| Artifact | Expected | Status | Details |
| -------- | -------- | ------ | ------- |
| `server/server-windows/src/executors/keymap.rs` | Extended CLIENT_KEY_CODES + map_key arms | ✓ VERIFIED | 18 new codes + arms (:56-62, :153-176); `T/W/Plus/Minus` removed from `ROUTER_MACRO_CODES` (now `["BrowserBack","BrowserForward","B"]`) keeping lists disjoint |
| `app/remote_control/lib/keyboard/key_rows.dart` | kClientKeyCodes mirror + public KeyCap + pad tables + KeyboardPad + capsForPad + keyboard.pad store | ✓ VERIFIED | All present (:38, :255, :272, :285, :290, :348, :474) |
| `app/remote_control/lib/shortcuts/shortcuts_screen.dart` | kShortcutCatalog + ShortcutSpec/Section/Button + ShortcutsScreen | ✓ VERIFIED | 551 lines; catalog :85, button :290, screen :394, wire send :414-415 |
| `app/remote_control/lib/hub/hub_screen.dart` | Shortcuts HubTileSpec at index 2 | ✓ VERIFIED | :98-106 |
| `app/remote_control/lib/keyboard/key_pads.dart` | 4 pads + KeyboardTabBar + kKeyboardHint | ✓ VERIFIED | 566 lines; all five widgets + hint (:40) |
| `app/remote_control/lib/keyboard/keyboard_screen.dart` | Rebuilt PageView owner with lifted sacred logic | ✓ VERIFIED | Contains `allowImplicitScrolling: false` (:367), `_heldCodes`, FSM, dispose flush |
| Test files (6) | key_rows, key_pads, key_pads_store, pad_widgets, keyboard_screen, shortcuts_screen | ✓ VERIFIED | All exist, substantive (97–437 lines), all green |
| `10-UAT.md` | On-device UAT record | ✓ VERIFIED | Suites recorded green; fresh APK 2026-07-17 09:20 IST; gate APPROVED |

### Key Link Verification

| From | To | Via | Status | Details |
| ---- | -- | --- | ------ | ------- |
| Dart `kClientKeyCodes` | Rust `CLIENT_KEY_CODES` | byte-for-byte mirror | ✓ WIRED | Identical 18-code blocks; lockstep tests both sides |
| `keymap.rs map_key` | enigo `Key` | `Key::Unicode` letters + `Key::PrintScr` | ✓ WIRED | :153-176; coverage test green |
| `ShortcutButton` press | `ConnectionService.sendReliable` | `KeyMsg(code, 'tap', mods)` | ✓ WIRED | :414-415; widget test asserts one Win+D send |
| Every `ShortcutSpec.code` | `kClientKeyCodes` | vocabulary-membership test | ✓ WIRED | `shortcuts_screen_test.dart:97` green |
| Hub tile | `ShortcutsScreen` | `HubTileSpec.builder` | ✓ WIRED | `hub_screen.dart:103` |
| `capsForPad(pad)` | `kClientKeyCodes` | coverage test all 4 pads | ✓ WIRED | `key_pads_test.dart:20` green |
| `KeyboardPadStore` | `PrefsKv('keyboard.pad')` | getString/setString | ✓ WIRED | `key_rows.dart:302,315` |
| PageView | 4 pads | children wired to `_onKeyDown/_onKeyUp/_onKeyTapWithMods` | ✓ WIRED | `keyboard_screen.dart:370-394` |
| `onPageChanged` | `keyboardPadProvider` + IME focus | persist + raise/lower on page 0 | ✓ WIRED | :268-272 |

### Behavioral Spot-Checks

| Behavior | Command | Result | Status |
| -------- | ------- | ------ | ------ |
| Phase-touched Flutter suites | `flutter test test/keyboard/ test/shortcuts/ test/hub_tiles_test.dart` | 109 passed, 0 failed (2026-07-17) | ✓ PASS |
| Rust keymap coverage | `cargo test -p server-windows keymap` | 5 passed, 0 failed (incl. `keymap_covers_all_codes`) | ✓ PASS |
| Full suites + analyzer | recorded in 10-UAT.md (same day) | analyze clean; flutter 539/539; cargo 38 passed, 2 ignored | ✓ PASS (trusted record, 2026-07-17) |

### Requirements Coverage

| Requirement | Source Plan | Description | Status | Evidence |
| ----------- | ----------- | ----------- | ------ | -------- |
| KEY-01 (extended) | 10-05, 10-06 | Typing with system IME | ✓ SATISFIED | IME raised only on Type pad; HiddenTextInput outside PageView; CR-01 atomic IME wipe test |
| KEY-02 (extended) | 10-01, 10-03, 10-04 | F1–F12, numpad, nav keys | ✓ SATISFIED | Arrows/Numpad/Fn pads render full cap sets; vocabulary coverage tests |
| KEY-03 (extended) | 10-01, 10-02, 10-05 | Sticky modifiers / combos | ✓ SATISFIED | Persistent chip row on every pad, one FSM; 25 shortcut chords over tap+mods |
| KEY-04 (extended) | 10-03, 10-04, 10-05 | Held-key autorepeat, no stuck keys | ✓ SATISFIED | KeyCap down/up hold model reused; CR-02/IN-04/D-12 screen-level suites green |

No orphaned requirements — phase declared "no new REQ-IDs" in ROADMAP.

### Anti-Patterns Found

| File | Line | Pattern | Severity | Impact |
| ---- | ---- | ------- | -------- | ------ |
| — | — | none (TBD/FIXME/XXX/TODO/HACK/placeholder scan clean across all 6 modified source files) | — | — |

### Human Verification Required

None outstanding. The phase's human gate was plan 10-06 itself: on-device UAT against fresh GitHub prerelease `v1.3.0-rc1` (APK + server exe, both built 2026-07-17). Owner approved all 10 checks — four pads/swipe/chips, IME raise/lower, key size, cross-pad combos, no stuck keys, pad persistence, Shortcuts tile placement, real chord firing on the PC (Win+D, Win+Shift+S, PrtScn, Ctrl+Shift+Esc, Ctrl+C/V, Ctrl+Plus/0), offline gating, overall feel. Gate result: APPROVED (10-UAT.md:41).

### Gaps Summary

No gaps. All 12 merged must-have truths verified against the codebase; both lockstep vocabularies are byte-identical; no protocol file changed in the phase range; the D-07 docked panel and `keyboard.rowGroup` are byte-untouched; targeted suites re-run green during verification. Owner's "not perfect but it works" impression was explicitly not tied to any numbered check and produced no itemized defects — future irritations enter the backlog as new items per the UAT record.

---

_Verified: 2026-07-17T12:30:00Z_
_Verifier: Claude (gsd-verifier)_
