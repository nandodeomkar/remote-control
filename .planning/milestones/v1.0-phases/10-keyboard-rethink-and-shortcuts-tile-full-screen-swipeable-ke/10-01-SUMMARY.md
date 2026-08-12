---
phase: 10-keyboard-rethink-and-shortcuts-tile
plan: 01
subsystem: api
tags: [keymap, enigo, key-vocabulary, protocol, flutter, rust]

# Dependency graph
requires:
  - phase: 04-keyboard
    provides: "keymap.rs CLIENT_KEY_CODES single-source-of-truth + kClientKeyCodes Dart mirror + both coverage gates"
provides:
  - "18 new key.code entries in CLIENT_KEY_CODES (letters A C D E F I R S V X Y Z, main-row 0, PrintScreen, promoted T W Plus Minus)"
  - "map_key arms for the 18 codes (letters -> Key::Unicode lowercase, 0 -> Unicode('0'), PrintScreen -> Key::PrintScr / VK_SNAPSHOT)"
  - "kClientKeyCodes Dart mirror grown byte-for-byte + a lockstep vocabulary test"
  - "ROUTER_MACRO_CODES trimmed to BrowserBack/BrowserForward/B (disjoint from client vocab)"
affects: [10-02-shortcuts-catalog, 10-03-keyboard-pads]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Vocabulary-grows-not-protocol-bumps: new key.code strings extend the accepted set with NO SERVER_PROTO_VERSION bump; unknown codes still drop silently server-side (T-04-02)"
    - "Byte-for-byte Dart<->Rust vocabulary mirror guarded by coverage gates on both sides"

key-files:
  created: []
  modified:
    - server/server-windows/src/executors/keymap.rs
    - app/remote_control/lib/keyboard/key_rows.dart
    - app/remote_control/test/keyboard/key_rows_test.dart

key-decisions:
  - "Key::PrintScr confirmed as the enigo 0.6.1 VK_SNAPSHOT variant (verified against vendored enigo src keycodes.rs: variant at line 525, doc(alias=Snapshot), maps to VK_SNAPSHOT line 1010) — plan's PrintScr assumption held, no fallback needed"
  - "T/W/Plus/Minus promoted from ROUTER_MACRO_CODES into CLIENT_KEY_CODES; existing map_key arms left verbatim (no re-map). Lists kept disjoint and semantically honest — the client now emits these directly"
  - "B stays router-only in ROUTER_MACRO_CODES (present_macro blank code, router.rs:374 — no client cap emits it)"
  - "Plus->Key::Unicode('=') Pitfall-11 fix preserved verbatim; Equal never introduced; no SERVER_PROTO_VERSION change"

patterns-established:
  - "Pattern: extend the locked key.code vocabulary by adding to CLIENT_KEY_CODES + a matching map_key arm + the Dart mirror in the same wave; both coverage gates prove completeness"

requirements-completed: [KEY-02, KEY-03]

# Metrics
duration: 7min
completed: 2026-07-16
---

# Phase 10 Plan 01: Keyboard vocabulary extension Summary

**Extended the locked `key.code` vocabulary on both sides — 12 letters + main-row 0 + PrintScreen (VK_SNAPSHOT) + promoted T/W/Plus/Minus — so the 10-02 Shortcuts catalog can fire real Windows chords, with both coverage gates green and no protocol version bump.**

## Performance

- **Duration:** 7 min
- **Started:** 2026-07-16T20:26:00Z (approx)
- **Completed:** 2026-07-16T20:33:06Z
- **Tasks:** 2
- **Files modified:** 3

## Accomplishments
- `CLIENT_KEY_CODES` grew by 18 codes; `map_key` maps every one to a real enigo `Key` (letters via `Key::Unicode` lowercase, `0` via `Unicode('0')`, `PrintScreen` via `Key::PrintScr`).
- `ROUTER_MACRO_CODES` trimmed to `BrowserBack`/`BrowserForward`/`B` — T/W/Plus/Minus promoted to the client vocabulary, lists now disjoint.
- Dart `kClientKeyCodes` mirror grown byte-for-byte with keymap.rs; a new lockstep test asserts all 18 codes present.
- Both coverage gates green: Rust `keymap_covers_all_codes` (+ router_macro/media/unknown/modifier tables), Dart 11/11 key_rows tests.
- No `SERVER_PROTO_VERSION` bump; `Plus`->`'='` Pitfall-11 fix preserved; no `Equal` introduced.

## Task Commits

Each task was committed atomically (TDD RED was proven by re-running the existing/added coverage gates before the map arms / mirror landed, then GREEN):

1. **Task 1: Extend Rust keymap vocabulary + map_key arms** - `58d1ce8` (feat)
2. **Task 2: Mirror vocabulary in Dart kClientKeyCodes + lockstep test** - `dac585b` (feat)

_TDD note: Task 1's RED was confirmed by growing CLIENT_KEY_CODES first (the pre-existing `keymap_covers_all_codes` gate failed on "A"), then adding the map arms to reach GREEN — captured in the single feat commit since the gate lives in the same file. Task 2's RED was the new lockstep test failing ("does not contain 'A'") before the mirror grew._

## Files Created/Modified
- `server/server-windows/src/executors/keymap.rs` - Added 18 codes to `CLIENT_KEY_CODES`, trimmed `ROUTER_MACRO_CODES`, added 14 `map_key` arms (12 letters + `0` + `PrintScreen`).
- `app/remote_control/lib/keyboard/key_rows.dart` - Extended `kClientKeyCodes` with the 18 wire strings byte-for-byte.
- `app/remote_control/test/keyboard/key_rows_test.dart` - Added the "new shortcut vocabulary codes are mirrored from keymap.rs" lockstep test.

## Decisions Made
- `Key::PrintScr` verified against the vendored enigo 0.6.1 source (`keycodes.rs` line 525 variant / line 1010 `-> VK_SNAPSHOT`) rather than trusting the plan literal — confirmed correct, no fallback variant needed.
- Promoted T/W/Plus/Minus out of `ROUTER_MACRO_CODES` and left their existing `map_key` arms untouched, keeping the two lists disjoint and honest.
- Kept `B` in `ROUTER_MACRO_CODES` (router-only present_macro "blank" code, no client cap emits it).

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. The one point of uncertainty flagged in the plan (exact enigo variant for VK_SNAPSHOT) was resolved by reading the vendored enigo source — `Key::PrintScr` is correct.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The full shortcut vocabulary is complete and lockstepped on both sides. 10-02 can now build `kShortcutCatalog` naming any of these codes and every one will fire a real chord server-side.
- The registry-driven catalog coverage gate (`for section in kShortcutCatalog ... expect(kClientKeyCodes, contains(s.code))`) is deferred to 10-02 once `kShortcutCatalog` exists, per plan.
- No blockers.

## Self-Check: PASSED

- Commits `58d1ce8`, `dac585b` found in git log.
- All modified files + SUMMARY.md exist on disk.

---
*Phase: 10-keyboard-rethink-and-shortcuts-tile*
*Completed: 2026-07-16*
