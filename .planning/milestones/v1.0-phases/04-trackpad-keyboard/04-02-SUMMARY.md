---
phase: 04-trackpad-keyboard
plan: 02
subsystem: input-injection
tags: [rust, enigo, sendinput, mpsc, keymap, windows]

# Dependency graph
requires:
  - phase: 02-transport-cursor
    provides: input-thread Cmd channel pattern, EnigoMouseKeys move/scroll, non-fatal-drop rule
  - phase: 04-trackpad-keyboard (plan 01)
    provides: absolute SendInput move arm on the input thread
provides:
  - All eight MouseKeys stubs filled as non-blocking Cmd sends (click/drag/key/text server halves of PAD-02/PAD-04/KEY-01..04)
  - Extended Cmd enum + input-thread arms on the &mut Enigo thread (click, held button, held key with OS autorepeat, mod-combo tap, Unicode text, n-backspace)
  - keymap.rs — THE locked key.code vocabulary (CLIENT_KEY_CODES) + map_key/map_mod/map_button, coverage-tested
affects: [04-04 trackpad client, 04-05 keyboard IME, 04-06 key rows kClientKeyCodes mirror, 05 control center macros]

# Tech tracking
tech-stack:
  added: []
  patterns: [executor commands ride the input-thread mpsc channel, unknown key.code -> None -> silent drop, contract consts shared cross-language by byte-identical mirror]

key-files:
  created:
    - server/server-windows/src/executors/keymap.rs
  modified:
    - server/server-windows/src/input_thread.rs
    - server/server-windows/src/executors/mouse_keys.rs
    - server/server-windows/src/executors/mod.rs

key-decisions:
  - "Open Q3 RESOLVED: terse key.code vocabulary locked in CLIENT_KEY_CODES — Esc/Tab/Home/End/PgUp/PgDn/Del, Up/Down/Left/Right, F1..F12, Num0..Num9 + NumEnter + NumDot, ControlLeft/AltLeft/ShiftLeft/WinLeft"
  - "Numpad enter/decimal named NumEnter/NumDot (numpad-prefixed over bare Enter/'.') so a future main-Enter cap cannot collide; NumEnter injects Key::Return (enigo 0.6.1 has no distinct numpad-enter), NumDot injects Key::Decimal"
  - "Router Phase-1 browser/present macro codes (BrowserBack/BrowserForward/T/W/B/Plus/Minus) added to map_key via Key::Unicode — they reach key_tap today and would otherwise silently no-op"
  - "KeyTap with an unknown code drops the WHOLE command — modifiers are never pressed around a key that won't fire"
  - "Cmd dropped Copy (kept Debug/Clone/PartialEq): KeyCode/String/Vec variants own heap data; the mpsc send is a move"

patterns-established:
  - "Contract-const pattern: CLIENT_KEY_CODES in keymap.rs is the single source of truth the Dart kClientKeyCodes (04-06) mirrors byte-for-byte; coverage test on each side"
  - "Whole-command drop on unmappable key: check map_key before any side effect in a multi-step arm"

requirements-completed: [PAD-02, PAD-04, KEY-01, KEY-02, KEY-03, KEY-04]

# Metrics
duration: 6min
completed: 2026-07-09
---

# Phase 4 Plan 02: Real Windows Input Executors Summary

**All eight MouseKeys stubs wired through the input-thread Cmd channel to real enigo injection (click/drag-hold/key-autorepeat/combos/Unicode typing), plus keymap.rs locking the one key.code vocabulary with coverage tests**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-09T19:22:05Z
- **Completed:** 2026-07-09T19:26:33Z
- **Tasks:** 2 (Task 2 executed TDD: RED → GREEN)
- **Files modified:** 4

## Accomplishments

- Extended `Cmd` with `Click/ButtonDown/ButtonUp/KeyDown/KeyUp/KeyTap/Type/Backspace`; every new arm runs on the dedicated `&mut Enigo` thread with the non-fatal-drop rule (`let _ =`, never panic — T-04-01)
- All eight stubbed `EnigoMouseKeys` methods are now one-line non-blocking `self.tx.send(Cmd::...)` calls — `Enigo` is never referenced off the input thread
- Held key down/up arms enable OS-native autorepeat (KEY-04, D-11): Windows generates the repeat stream while the key is held; release stops it
- `KeyTap` presses mapped modifiers, clicks the key, releases modifiers in reverse (KEY-03 combo path: Ctrl+Alt+Del, Win+D)
- `Type` uses `enigo.text()` for layout-independent Unicode incl. emoji; `Backspace(n)` clicks Backspace n times (KEY-01); typed text is never logged (SPEC §12, T-04-03)
- `keymap.rs` locks the `key.code` vocabulary (Open Q3 resolved) as `CLIENT_KEY_CODES` — 38 codes covering Nav/arrows/F1-F12/numpad/modifier-hold — with `keymap_covers_all_codes`, `unknown_code_maps_none`, and `modifier_and_button_tables` proving the tables

## Task Commits

Each task was committed atomically:

1. **Task 1: Extend Cmd + fill mouse_keys stubs + input-thread arms** - `a23ae2a` (feat)
2. **Task 2 (TDD RED): failing keymap coverage tests + locked vocabulary** - `83669dd` (test)
3. **Task 2 (TDD GREEN): map_key vocabulary table** - `722ab75` (feat)

## Files Created/Modified

- `server/server-windows/src/executors/keymap.rs` - Locked CLIENT_KEY_CODES contract + map_key/map_mod/map_button tables + coverage tests
- `server/server-windows/src/input_thread.rs` - Extended Cmd enum (Copy dropped) + eight new arms on the Enigo thread
- `server/server-windows/src/executors/mouse_keys.rs` - All eight stubs filled as non-blocking Cmd sends
- `server/server-windows/src/executors/mod.rs` - Registered `pub mod keymap;`

## Decisions Made

- **Open Q3 resolved:** terse vocabulary (matches existing router macro style) — see key-decisions frontmatter for the full list
- **NumEnter/NumDot** chosen over bare `Enter`/`.` — collision-proof against a future main-Enter cap; 04-06 must mirror these exact strings
- **Router macro codes covered:** `browser_macro`/`present_macro` (Phase 1) reach `map_key` via `key_tap` today; without mappings for BrowserBack/BrowserForward/T/W/B/Plus/Minus those actions would silently no-op. Added as `ROUTER_MACRO_CODES` with its own coverage test
- **Whole-command drop:** `KeyTap` with an unmappable code presses nothing (no orphaned modifier press/release around a dead key)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] Router browser/present macro codes added to map_key**
- **Found during:** Task 2 (keymap vocabulary)
- **Issue:** The Phase-1 router already routes `browser`/`present` messages through `key_tap` with codes ("BrowserBack", "T", "Plus", …) not in the client key-row vocabulary; unmapped they would silently no-op, regressing already-routed functionality
- **Fix:** Added `ROUTER_MACRO_CODES` const + `router_macro_codes_covered` test; letters/signs map via `Key::Unicode` (VkKeyScanW resolves the layout VK so Ctrl chords work)
- **Files modified:** server/server-windows/src/executors/keymap.rs
- **Verification:** `router_macro_codes_covered` passes
- **Committed in:** 83669dd (RED) / 722ab75 (GREEN)

**2. [Rule 3 - Blocking] clippy -D warnings dead_code on contract consts**
- **Found during:** Task 2 verify (clippy)
- **Issue:** `CLIENT_KEY_CODES`/`ROUTER_MACRO_CODES` are consumed only by tests and the cross-language contract; server-windows is a bin crate so pub items with no runtime reader trip `-D dead-code`
- **Fix:** `#[allow(dead_code)]` with a comment documenting they are contract artifacts by design
- **Files modified:** server/server-windows/src/executors/keymap.rs
- **Verification:** `cargo clippy -p server-windows -- -D warnings` clean
- **Committed in:** 722ab75

---

**Total deviations:** 2 auto-fixed (1 missing critical, 1 blocking)
**Impact on plan:** Deviation 1 protects existing routed features from silent regression; deviation 2 is lint hygiene. No scope creep.

## Issues Encountered

- Task ordering: the plan notes "the two tasks compile together." Executed Task 1 with the plan-sanctioned minimal keymap stub (`map_key` → None; `map_mod`/`map_button` landed as their trivial total matches so clicks could never panic at that commit, honoring T-04-01). Consequence: at TDD RED, `modifier_and_button_tables` already passed while both coverage tests genuinely failed — the vocabulary table (the substance of Task 2) followed proper RED → GREEN.

## TDD Gate Compliance

Task 2 (`tdd="true"`): RED commit `83669dd` (test) → GREEN commit `722ab75` (feat). No refactor commit needed. RED verified failing (`keymap_covers_all_codes` + `router_macro_codes_covered` failed against the None stub).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Server halves of PAD-02/PAD-04/KEY-01..04 complete: any client producer (04-04 trackpad clicks/drag, 04-05 IME text, 04-06 key rows/modifiers) now executes on Windows
- 04-06 MUST mirror `CLIENT_KEY_CODES` byte-for-byte in `kClientKeyCodes` (including `NumEnter`/`NumDot` and the four `*Left` modifier hold codes)
- End-of-phase on-device gate outstanding (Manual-Only per 04-VALIDATION): hold an arrow key in a text editor → repeating stream, release stops immediately (KEY-04)

---
*Phase: 04-trackpad-keyboard*
*Completed: 2026-07-09*

## Self-Check: PASSED

- All 4 files exist; commits a23ae2a / 83669dd / 722ab75 found; no unexpected deletions.
