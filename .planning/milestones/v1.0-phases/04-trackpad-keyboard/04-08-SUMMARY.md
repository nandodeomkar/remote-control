---
phase: 04-trackpad-keyboard
plan: 08
subsystem: keyboard
tags: [flutter, keyboard, autorepeat, rollover, disconnect-hygiene, security, gap-closure]
requires:
  - phase: 04-06
    provides: KeyboardPanel key down/up plumbing + ModifierFsm disconnected() reset
  - phase: 04-07
    provides: D-12 disconnect transition wiring (changes stream + _onDisconnected)
provides:
  - "Set<String> _heldCodes multi-cap held tracking — key rollover releases EVERY key (CR-02 closed)"
  - "_KeyCap onTapUp/onTapCancel always-wired with _live press-lifecycle guard (IN-04 closed, T-04-04 closeable)"
  - "Regression tests: rollover both-ups, disconnect wipes all held caps, mid-press enabled-flip release"
affects: [04-VERIFICATION SC5 re-verification, 04-SECURITY T-04-04 sign-off]
tech-stack:
  added: []
  patterns:
    - "remove()-guarded key-up: up sent only when _heldCodes.remove(code) returns true — one guard covers D-12 stale-up skip AND IN-04 no-down releases"
key-files:
  created: []
  modified:
    - app/remote_control/lib/keyboard/keyboard_panel.dart
    - app/remote_control/lib/keyboard/key_rows.dart
    - app/remote_control/test/keyboard/keyboard_panel_test.dart
    - app/remote_control/test/keyboard/key_rows_test.dart
key-decisions:
  - "Held tracking is a Set, not a count or single slot: each _KeyCap owns its own GestureDetector so pointers are tracked independently; rollover (down:B before up:A) is the normal arrow-key pattern and both ups must fire."
  - "Release handlers permission-gate only the press ENTRY (onTapDown gated on enabled); onTapUp/onTapCancel always wired, with _live keeping presses that STARTED disabled inert — the existing gated-inert tests stay green unmodified."
  - "Disconnect clears the whole set with ZERO sends (D-12 preserved for any number of held caps): CONN-07 release_all already freed the real keys."
metrics:
  duration: split across sessions (token cut-off mid-execution)
  tasks: 2
  files: 4
completed: 2026-07-10
---

# Phase 04 Plan 08: CR-02 Rollover + IN-04 Release Hygiene Summary

Set-based held-cap tracking plus always-wired release handlers close CR-02 (rollover swallowed the first key's up → key stuck autorepeating on the PC) and IN-04 (enabled flip mid-press disposed the release handlers — same stuck-key class), letting T-04-04 in 04-SECURITY.md be signed off. Wire vocabulary untouched (D-11: autorepeat stays server-side down/hold/up).

## What Was Built

### keyboard_panel.dart

- `String? _heldCode` → `final Set<String> _heldCodes`. `_onKeyDown` adds + sends down; `_onKeyUp` sends up only if `_heldCodes.remove(code)` returns true — the single guard covers both the D-12 disconnect wipe (server already released) and releases forwarded by always-wired cap handlers when no down ever fired.
- `_onDisconnected` clears the whole set without ups (D-12 semantics preserved for any number of held caps).

### key_rows.dart

- `_KeyCap` release handlers (`onTapUp`, `onTapCancel`) wired unconditionally; only `onTapDown` remains gated on `widget.enabled`.
- New `_live` press-lifecycle flag: set in `_onTapDown`, checked-and-cleared in both release paths — a press that started disabled emits nothing (existing gated-inert contract unchanged), a press whose down fired always sends its up even if `enabled` flipped mid-press.

## TDD Cycle

- **RED** (`d5844aa`): CR-02 rollover both-ups test, CR-02/D-12 disconnect-wipes-all-held-caps test, IN-04 mid-press enabled-flip test.
- **GREEN** (`e8effa0`): set-based tracking + always-wired handlers; full Flutter suite 238/238 green with zero edits to pre-existing tests.

## Verification Results

- `flutter test`: 238/238 pass.
- Must-have truths: rollover sends up:A AND up:B (test-proven); disconnect clears ALL held caps with no sends; mid-press enabled flip still releases; disabled-started press stays inert (pre-existing tests green).
- Artifacts: `_heldCodes` in keyboard_panel.dart, `_live` in key_rows.dart, `CR-02` in keyboard_panel_test.dart, `IN-04` in key_rows_test.dart — all present.

## Follow-ups

- 04-SECURITY.md T-04-04 row can now be marked closed (04-07 closed T-04-03).
- Re-run phase verification: CR-01 (04-07), CR-02+IN-04 (04-08), WR-04 (04-09) all closed — SC2/SC5 should verify.
