---
phase: 10-keyboard-rethink-and-shortcuts-tile
plan: 05
subsystem: client-keyboard
tags: [keyboard, screen, pageview, ime, stuck-keys, persistence]
requires:
  - TypePad / ArrowsPad / NumpadPad / FnPad + KeyboardTabBar (10-04)
  - KeyboardPad enum + keyboardPadProvider + KeyboardPadStore (10-03)
  - ModifierFsm / ModifierChip / HiddenTextInput / ImeDiffProducer (04-05/04-06)
  - ConnectionHeaderChip.forService + ReconnectingBannerSlot (house chrome)
provides:
  - keyboard_screen.dart rebuilt as the PageView screen owner (FSM + _heldCodes + _imeResetTick + D-12 changes-sub + LIVE-only dispose flush lifted from keyboard_panel.dart)
  - _onPageChanged / _onTabSelected (keyboard.pad persistence + IME raise/lower + 200ms page animate)
  - test/keyboard/keyboard_screen_test.dart — full sacred-invariant suite at screen level
affects:
  - 10-06 (phase verification — screen + panel suites both green)
tech-stack:
  added: []
  patterns:
    - "LIFT not rewrite: the donor panel's FSM/held-set/D-12/dispose-flush methods copied verbatim into the screen State; only widget.send -> _service.sendReliable and widget.isDisconnected() -> _isDisconnected changed"
    - "One-shot async-restore jump: ref.listenManual(keyboardPadProvider) fires at most once, and a user page change pre-empts it — a late prefs load can never yank a pad the user already navigated to"
key-files:
  created:
    - app/remote_control/test/keyboard/keyboard_screen_test.dart
  modified:
    - app/remote_control/lib/keyboard/keyboard_screen.dart
decisions:
  - "Persisted-pad seeding uses PageController(initialPage: ref.read(...).index) + a one-shot ref.listenManual restore jump (guarded by _padRestoreDone, which also flips on the first user page change) — the plan's 'jump once when the persisted value differs' option, robust to the async prefs load landing at any time"
  - "The restore jump routes through jumpToPage so _onPageChanged is the SINGLE page-arrival path: persistence write-back, IME raise/lower, and tab-bar state all converge there for swipe, tab tap, and restore alike"
  - "Test-harness lesson: a Flutter animation ticker's first pump is elapsed-0 — tab-driven page changes need pump() (start) + pump(250ms) (run) + pump() (settle/dispose); a single pump(250ms) never moves the page"
metrics:
  duration: ~17min
  tasks: 2
  files: 2
  completed: 2026-07-17
---

# Phase 10 Plan 05: Full-Screen Keyboard Screen Owner + Sacred-Invariant Suite Summary

Rebuilt `keyboard_screen.dart` as a PageView of the four 10-04 pads with persistent modifier chips, a bottom tab bar, IME-on-Type-only, and `keyboard.pad` persistence — the sacred FSM/held-set/D-12/dispose-flush logic lifted verbatim from the byte-untouched `keyboard_panel.dart` and every stuck-key invariant re-proven at screen level.

## What Shipped

**Task 1 — the PageView screen owner** (`9fe9eee`)
- `_KeyboardScreenState` now owns (lifted verbatim from the panel): the ONE `ModifierFsm`, the `_heldCodes` rollover set, the `_imeResetTick` CR-01 wipe trigger, the `changes`-stream D-12 transition detector, and the `dispose()` LIVE-only flush (owed cap ups + `releaseAll()`; zero sends when disconnected). `_sendEffects` / `_onChipTap` / `_onChipLongPress` / `_onKeyDown` / `_onKeyUp` (remove-guarded) / `_onKeyTapWithMods` copied intact.
- Build per UI-SPEC §Screen 1: `Scaffold(resizeToAvoidBottomInset: true)` + kBg AppBar with `ConnectionHeaderChip.forService` + `ReconnectingBannerSlot` + `Expanded(PageView(allowImplicitScrolling: false))` over `[TypePad, ArrowsPad, NumpadPad, FnPad]` + `HiddenTextInput` OUTSIDE the PageView + the persistent 4-chip row (md/sm padding, gated on auth) + `KeyboardTabBar`.
- `_onPageChanged`: persist via `keyboardPadProvider.notifier.set`, `requestFocus` on index 0 / `unfocus` elsewhere, setState the tab-bar page. `_onTabSelected`: `hapticTick()` + 200ms ease `animateToPage`.
- Landing pad seeded from the persisted `keyboard.pad`; a one-shot `listenManual` restore jump covers the async prefs load (see decisions).
- No `keyboard_panel.dart` import remains; no keep-alive token anywhere in the file; `keyboard_panel.dart` and `trackpad_screen.dart` byte-unchanged (`git diff --quiet` clean, trackpad still imports the panel).

**Task 2 — screen-level sacred-invariant suite** (`6a7be74`)
- `test/keyboard/keyboard_screen_test.dart`: 10 named tests driven by a recording `_FakeService extends ConnectionService` (controllable broadcast `changes` stream, mutable `chipStatus`, recorded `sendReliable`) + an in-memory `PrefsKv` behind `keyboardPadStoreProvider`.
- **CR-01** proven on an actual page change: hold an Arrows cap, tab to Numpad → the outgoing pad's dispose fires the up; the late pointer release sends nothing.
- **CR-02** rollover (`down:Right, down:Down, up:Right, up:Down`) and disconnect-mid-hold (held set wiped, later release sends ZERO frames).
- **IN-04**: a cancelled non-deferred press (the PageView-drag-claims-gesture path) still emits its up.
- **D-12**: locked chip resets on the disconnected transition with zero wire sends; the atomic IME wipe returns the hidden field's controller to exactly the sentinel; post-reconnect keystroke emits only the new char (no `secret` replay), asserted on the wire via the recorded `TextMsg`s.
- **Dispose flush**: LIVE socket → held cap up + `releaseAll()` modifier up, each exactly once (set + length assertion pins idempotence); DISCONNECTED socket → zero sends.
- **Persistence** round-trip (`keyboard.pad` = `numpad` written on page change; fresh mount lands on NumpadPad with the IME down) and **IME raise/lower** (Type focused → Arrows unfocused → Type refocused).
- Persistent-chrome test pins chips + tab bar on every pad and the SAME `HiddenTextInput` State across a page switch (input connection never detaches, Pitfall 6).

## Verification

- `flutter test test/keyboard/keyboard_screen_test.dart test/keyboard/keyboard_panel_test.dart` — **23 passed** (10 new + 13 panel, docked panel unaffected).
- `flutter test test/keyboard/` — **91 passed** (81 pre-existing + 10 new).
- `flutter test` (full app) — **539 passed** (529 pre-existing + 10 new).
- `flutter analyze lib/keyboard` — No issues found.
- `git diff --quiet app/remote_control/lib/keyboard/keyboard_panel.dart app/remote_control/lib/trackpad/trackpad_screen.dart` — clean; `keyboard.rowGroup` untouched (mentioned in the screen only as a doc-comment ownership note).
- `grep "allowImplicitScrolling: false"` matches; `grep -cE "AutomaticKeepAlive|wantKeepAlive|keepAlive"` → 0.

## Sacred-Surface Compliance

| Constraint | Evidence |
|---|---|
| `keyboard_panel.dart` byte-untouched | In no commit of this plan; `git diff --quiet` clean; its 13-test suite green unchanged |
| `trackpad_screen.dart` byte-untouched | Same; still imports `keyboard_panel.dart` (line 31) |
| `keyboard.rowGroup` untouched | `KeyRowGroupStore`/`keyRowGroupProvider` unreferenced by the rebuilt screen |
| Lift semantics preserved | `_onDisconnected`, `_onKeyUp` remove-guard, dispose flush order (`ups → releaseAll → clear → tick.dispose`) match the panel line-for-line |
| No keep-alive | Zero occurrences of any keep-alive token in `keyboard_screen.dart`; pad-level CR-01 trap (pad_widgets_test) still green |

## Deviations from Plan

None — plan executed exactly as written. Both declared files, no others; no bugs found in dependencies, no architectural questions, no auth gates.

## Known Stubs

None. The screen is fully wired to the live `ConnectionService` seams; every rendered control sends real wire frames.

## Threat Flags

None. No new network surface, auth path, or protocol change — the rebuilt screen reuses the exact `key {action: down/up/tap}` path. T-10-06 (stuck input) and T-10-07 (pre-disconnect text replay) mitigations are implemented and pinned by the Task-2 suite as the threat model requires.

## Self-Check: PASSED

- FOUND: `app/remote_control/lib/keyboard/keyboard_screen.dart` (contains `allowImplicitScrolling: false`)
- FOUND: `app/remote_control/test/keyboard/keyboard_screen_test.dart` (contains `CR-01`)
- FOUND: commit `9fe9eee` (Task 1)
- FOUND: commit `6a7be74` (Task 2)
