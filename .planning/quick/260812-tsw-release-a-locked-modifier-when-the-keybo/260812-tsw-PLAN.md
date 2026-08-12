---
quick_id: 260812-tsw
phase: quick-260812-tsw
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - app/remote_control/lib/keyboard/keyboard_input_controller.dart
  - app/remote_control/lib/keyboard/keyboard_panel.dart
  - app/remote_control/test/keyboard/keyboard_input_controller_test.dart
  - app/remote_control/test/keyboard/keyboard_panel_test.dart
---

# Release a LOCKED modifier when the keyboard panel is dismissed

Closes `.planning/todos/pending/2026-08-11-locked-modifier-survives-a-panel-dismiss.md`.

## The defect

Collapsing the docked keyboard panel swaps the chrome for a zero-height box,
which unmounts the key caps — so a **held cap** releases through its own
`KeyCap.dispose`. That half is real and pinned by
`keyboard_panel_test.dart:537` ("collapsing the panel mid-hold releases the
held key exactly once").

The panel's `State` survives the collapse, so `KeyboardInputController.dispose`
— the only thing that emits the up for a **LOCKED modifier** — never runs. Lock
`Shift`, dismiss, and the PC behaves as though Shift is welded down, with no
chip anywhere to release it. Reopening the panel is the only route back.

## The decision, recorded

**Release the lock on dismiss.** This is the todo's stated safe default and the
option chosen by the owner on 2026-08-12.

Rejected: keeping the lock and surfacing it on the collapsed chrome (an
indicator on the trackpad screen's "Show keys" toggle). It preserves the
"lock Shift → dismiss → drag-select on the live trackpad" flow, which is real
given the trackpad stays live under the panel by design, but it costs
persistent chrome, a second un-lock path to keep in sync with the chips, and
the same indicator again on the summon bar. Revisit only if the lost flow is
missed in dogfooding.

## Task 1 — the owner learns `dismissed()`

`app/remote_control/lib/keyboard/keyboard_input_controller.dart`

Extract the body of `dispose()`'s release into a private `_flushHolds()` and
call it from BOTH `dispose()` and a new public `dismissed()`. Composition, not
duplication (todo constraint 3): a dismiss-then-teardown must not emit twice,
and `keyUp`'s `remove()` guard plus the emptied `_heldCodes` already make the
pair idempotent the same way cap-dispose and the owner's flush are today.

```
void _flushHolds() {
  if (isDisconnected()) {
    _fsm.disconnected();          // zero effects by construction — state only
  } else {
    for (final code in _heldCodes.toList()) send(KeyMsg(code: code, action: 'up'));
    _sendEffects(_fsm.releaseAll());
  }
  _heldCodes.clear();
}
```

`dismissed()` is `_flushHolds()` + `onChanged()`. It does NOT fire
`imeResetTick` — that tick is the CR-01 security wipe for a dead socket, not
something a dismiss earns.

The dead-socket branch is new for `dispose()` and deliberately inert there
(the object is being discarded, `_fsm.disconnected()` sends nothing). It exists
for `dismissed()`, whose object LIVES ON: a dismiss on a dead socket must still
put the chips back to rest without touching the wire.

**Why the controller and not the panel:** D-95 — this file is the single owner
of the stuck-key model, so the fix reaches both keyboard surfaces, and the
summon bar's third mount point, by construction.

## Task 2 — the panel calls it on the collapse edge

`app/remote_control/lib/keyboard/keyboard_panel.dart`

`didUpdateWidget` already branches on `widget.expanded != oldWidget.expanded`
and runs `widget.imeFocusNode.unfocus()` on the false edge. The release belongs
beside it.

`onChanged` is `if (mounted) setState(() {})`, which is legal here —
`StatefulElement.update` sets `_debugAllowIgnoredCallsToMarkNeedsBuild` around
`didUpdateWidget` for exactly this, and the rebuild is already happening.

The full-screen `KeyboardScreen` needs no equivalent: it has no collapsed
state, and a pop runs the real `dispose()`.

## Task 3 — the tests, RED first

1. `keyboard_input_controller_test.dart` — unit, on the owner itself:
   - `dismissed()` on a LIVE socket emits the owed cap ups AND `up:WinLeft`
     for a locked Win, and leaves the chips at rest.
   - `dismissed()` on a DISCONNECTED socket sends NOTHING but still resets the
     chips to rest.
   - `dismissed()` then `dispose()` emits each up exactly ONCE.
2. `keyboard_panel_test.dart` — widget, beside the existing collapse test:
   lock Win, collapse, assert `up:WinLeft` reached the send seam (not merely
   that the chip cleared — todo constraint 1), and that a later dispose does
   not repeat it.

**Deviation from the todo's `files:` list:** it names
`test/trackpad/trackpad_screen_test.dart` as the home of the collapse test. It
is not there — the collapse proof added by `260809-ipc` lives in
`test/keyboard/keyboard_panel_test.dart:537`. Extended there instead.

## Gates

- `flutter test` — 865 passing today; every new test observed RED before GREEN.
- `flutter analyze` clean.
