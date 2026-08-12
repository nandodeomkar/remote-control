---
phase: 10-keyboard-rethink-and-shortcuts-tile
plan: 03
subsystem: client-keyboard
tags: [keyboard, primitives, riverpod, prefs, key-vocabulary]
requires:
  - kClientKeyCodes (10-01 extended vocabulary)
  - PrefsKv / SharedPrefsKv seam (device_store)
  - _KeyCap sacred emission model (04-06)
provides:
  - KeyCap / KeyCapState (public shared key-cap widget)
  - kTypeExtrasCaps / kArrowsTopCaps / kFnEscCap (pad cap tables)
  - KeyboardPad enum + capsForPad (vocabulary-coverage seam)
  - kKeyboardPadPrefsKey / KeyboardPadStore / KeyboardPadNotifier / keyboardPadProvider
affects:
  - 10-04 (pad widgets — mount KeyCap, consume capsForPad)
  - 10-05 (keyboard screen — binds keyboardPadProvider to the PageView)
tech-stack:
  added: []
  patterns:
    - "KeyRowGroupStore pattern cloned under a NEW prefs key (never mutated)"
    - "Public-by-rename widget reuse: emission logic shared by reference, not duplicated"
key-files:
  created:
    - app/remote_control/test/keyboard/key_pads_test.dart
    - app/remote_control/test/keyboard/key_pads_store_test.dart
  modified:
    - app/remote_control/lib/keyboard/key_rows.dart
decisions:
  - "KeyCap gained a super.key param on going public (flutter_lints use_key_in_widget_constructors); the ValueKey('cap-<code>') on the inner GestureDetector is unchanged, so every existing cap finder still resolves"
  - "capsForPad returns kNumCaps by identity (not a copy) for the numpad, pinned by a same() test — no new numpad codes, per UI-SPEC"
  - "kTypeExtrasCaps re-declares its arrow defs rather than slicing kNavArrowCaps: the Type row's order is Esc|Tab|Left|Up|Down|Right|Del, which is NOT kNavArrowCaps' inverted-T order (Up|Left|Down|Right)"
  - "KeyboardPadStore.load() degrades on a THROWING read too (not just unknown strings) — proven with a dedicated _ThrowingPrefsKv, closing T-10-04 explicitly rather than by inspection"
metrics:
  duration: ~9min
  tasks: 2
  files: 3
  completed: 2026-07-17
---

# Phase 10 Plan 03: Keyboard Pad Primitives Summary

Exposed the sacred `_KeyCap` emission model as public `KeyCap` by rename (5 call-site lines changed, zero logic lines touched), declared the four pads' cap tables behind a `capsForPad` vocabulary seam, and added the `keyboard.pad` persistence store as an additions-only clone of the `KeyRowGroupStore` pattern.

## What Shipped

**Task 1 — public KeyCap + pad cap tables** (`5de4c55`)
- `_KeyCap`/`_KeyCapState` → `KeyCap`/`KeyCapState`. The press bodies (D-11 hold, D-10 deferred combo, IN-04 always-wired releases, CR-01 dispose release) carried through **verbatim** — the diff's only 5 removed lines are the rename sites themselves (`class`, ctor, `createState`, `State<>`, and `KeyRows._cap`'s constructor call).
- New tables: `kTypeExtrasCaps` (Esc, Tab, ←, ↑, ↓, →, Del), `kArrowsTopCaps` (Home, End, PgUp, PgDn), `kFnEscCap`. `kNavArrowCaps` / `kNumCaps` / `kFnCaps` reused as-is.
- `enum KeyboardPad { type, arrows, numpad, fn }` + `capsForPad(pad)`.
- `test/keyboard/key_pads_test.dart`: every pad's every code ∈ `kClientKeyCodes`, all four sets non-empty, per-pad layout pins, icon-caps-carry-tooltips, plus a guard that `capsForGroup` still returns the docked panel's original sets.

**Task 2 — keyboard.pad persistence (TDD)** (`e8a7c61` RED → `a7711f3` GREEN)
- `kKeyboardPadPrefsKey = 'keyboard.pad'`, `KeyboardPadStore` (PrefsKv seam, injectable), `keyboardPadStoreProvider`, `KeyboardPadNotifier`, `keyboardPadProvider`.
- `load()` degrades to `KeyboardPad.type` on unset / unknown / empty / throwing reads.
- Task 2's diff is **zero removed lines** — pure additions.

## Sacred-Surface Compliance

| Constraint | Evidence |
|---|---|
| Docked `KeyboardPanel` (D-07) untouched | `keyboard_panel.dart` not in any commit; its 33-test suite green unchanged |
| `keyboard.rowGroup` untouched | Task 2 diff removed 0 lines; `KeyRowGroupStore`/providers byte-identical; a store test asserts `save()` writes only `keyboard.pad` |
| `KeyCap` reused, not rewritten | 5 removed lines, all rename sites; no line inside `_onTapDown`/`_onTapUp`/`_onTapCancel`/`dispose` changed |
| No keyboard rebuild started | No pad widgets, no screen, no PageView — primitives only |

## Verification

- `flutter test test/keyboard/` — **65 passed** (11 new store, 8 new pad, 46 pre-existing).
- `flutter test` (full app) — **513 passed**.
- `flutter analyze` — **No issues found** (whole package, not just the touched file).
- `grep -n "class KeyCap" lib/keyboard/key_rows.dart` → matches (must_haves artifact `contains` check).

## Deviations from Plan

**1. [Rule 3 - Blocking] `KeyCap` needed a `super.key` parameter**
- **Found during:** Task 1
- **Issue:** `flutter_lints`' `use_key_in_widget_constructors` fires on public widget constructors with no `Key` param — the private `_KeyCap` was exempt, the public `KeyCap` is not. Without it, `flutter analyze` fails the plan's own clean-analyzer verification gate.
- **Fix:** Added `super.key` to the constructor (additive; no caller passes it, and the identity-bearing `ValueKey('cap-<code>')` stays on the inner `GestureDetector` as before, so existing finders are unaffected).
- **Files modified:** `app/remote_control/lib/keyboard/key_rows.dart`
- **Commit:** `5de4c55`

No other deviations — no bugs found, no architectural questions raised, no auth gates hit.

## Notes for 10-04 / 10-05

- `capsForPad(KeyboardPad.type)` is the **row order** (Esc|Tab|←|↑|↓|→|Del), directly renderable as 7 `Expanded` caps. `capsForPad(KeyboardPad.arrows)` is `[...top4, ...invertedT4]` — the consumer slices `.take(4)` / `.skip(4)`, since the two blocks have different layouts (row vs inverted-T).
- `KeyCap` sizes via `width` + a hard `minWidth: 48` / `minHeight: 48` floor. UI-SPEC's Type extras row wants 7 equal `Expanded` caps at 48px, which on a narrow phone (<392px content width) will fight that 48px `minWidth`. UI-SPEC §Spacing exceptions already anticipates this ("row-local minWidth relaxation") — 10-04 will need a way to relax it (e.g. a `minWidth` param on `KeyCap`). Flagged, not pre-built: no speculative parameter added here.
- `KeyCap`'s face styling is fixed at 14/400 labels and 20px icons. UI-SPEC's pads call for 16/600, 28/400 digits, and 28px arrows — 10-04 will need face-size seams on `KeyCap`. Deliberately deferred: the plan scoped this task to reuse-by-rename, and guessing the parameter shape before the pads exist risks a wrong API.

## Known Stubs

None — every symbol this plan ships is fully implemented and tested. `capsForPad` and `keyboardPadProvider` have no production caller yet **by design** (10-04/10-05 are their consumers); both are exercised by tests.

## Threat Flags

None. Client-only widget rename + a non-secret UI preference. No network surface, no protocol change, no new package. T-10-04 (corrupt pref DoS) mitigated and unit-proven.

## Self-Check: PASSED

- FOUND: `app/remote_control/lib/keyboard/key_rows.dart` (contains `class KeyCap`)
- FOUND: `app/remote_control/test/keyboard/key_pads_test.dart`
- FOUND: `app/remote_control/test/keyboard/key_pads_store_test.dart`
- FOUND: commit `5de4c55` (Task 1)
- FOUND: commit `e8a7c61` (Task 2 RED)
- FOUND: commit `a7711f3` (Task 2 GREEN)

## TDD Gate Compliance

Task 2 ran the full cycle: RED (`e8a7c61`, `test(10-03)` — 8 compile-level failures proving the store's absence) → GREEN (`a7711f3`, `feat(10-03)` — 11/11 pass). No REFACTOR commit: the store is a structural copy of an existing reviewed pattern with nothing to clean up.
