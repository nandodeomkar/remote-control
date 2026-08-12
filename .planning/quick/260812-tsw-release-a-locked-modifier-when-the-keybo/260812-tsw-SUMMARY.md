---
quick_id: 260812-tsw
phase: quick-260812-tsw
plan: 01
subsystem: app-client-keyboard
tags: [stuck-key, modifier-lock, keyboard-panel, dismiss, d-95, summon-bar-prep]
status: complete

requires:
  - "KeyboardInputController — the D-95 single stuck-key owner (260809-ipc)"
  - "ModifierFsm.releaseAll / .disconnected (04-05)"
provides:
  - "KeyboardInputController.dismissed() — the collapse that is not a teardown"
  - "_flushHolds() — the LIVE-only release shared by dispose and dismissed"
affects:
  - "KeyboardPanel.didUpdateWidget calls dismissed() on the collapse edge"

commits:
  - 2779ecf
---

# A locked modifier no longer survives a panel dismiss

Closes `.planning/todos/pending/2026-08-11-locked-modifier-survives-a-panel-dismiss.md`
and landmine #1 in `.planning/notes/summon-bar-trackpad-keyboard.md`.

## What was wrong

Collapsing the docked keyboard panel swaps the chrome for a zero-height box.
That unmounts the key caps, so a **held cap** frees itself through
`KeyCap.dispose` — a path `260809-ipc` proved with a test. The panel's `State`
survives the collapse, so `KeyboardInputController.dispose` — the only thing
that ever emitted the up for a **LOCKED modifier** — never ran.

Lock `Shift`, dismiss, and the PC behaved as though Shift was welded down.
Nothing on screen said why and nothing on screen could undo it; reopening the
panel was the only route back.

## The decision, recorded

**Release the lock on dismiss** — chosen by the owner 2026-08-12, the todo's
stated safe default.

Rejected: keep the lock and surface it on the collapsed chrome (an indicator on
the trackpad screen's "Show keys" toggle, tappable to release). It would
preserve "lock Shift → dismiss → drag-select on the still-live trackpad", which
is a real flow given the trackpad stays live under the panel by design, but it
costs persistent chrome, a second un-lock path to keep in sync with the chips,
and the same indicator again on the summon bar. **Revisit only if that flow is
missed in dogfooding** — the cost of reversing is one method call.

## What changed

`keyboard_input_controller.dart` — `dispose()`'s release body became
`_flushHolds()`, shared with a new public `dismissed()`. Composition, not
duplication (the todo's third constraint): a dismiss followed by a teardown
emits each owed up exactly ONCE, through the same `remove()` guard that already
makes cap-dispose and the owner's flush idempotent.

`keyboard_panel.dart` — `didUpdateWidget` already branched on the
`expanded` false edge to run `imeFocusNode.unfocus()`. `_controller.dismissed()`
joins it there. `onChanged` is `if (mounted) setState(() {})`, which is legal
inside `didUpdateWidget`: `StatefulElement.update` sets
`_debugAllowIgnoredCallsToMarkNeedsBuild` around that call for exactly this
case, and the rebuild is already happening.

The fix is in the controller **on purpose** (D-95). It lands on the full-screen
keyboard and on the summon bar's future third mount point by construction. The
full-screen surface needs no call site: it has no collapsed state, and a pop
runs the real `dispose()`.

## Things a later plan must not rediscover

- **`_flushHolds`'s dead-socket branch is deliberately inert for `dispose`.**
  It calls `ModifierFsm.disconnected()` — zero wire effects, state only. It
  exists for `dismissed()`, whose object LIVES ON and must not keep rendering a
  locked chip for a key nothing holds. Do not "simplify" it back to the old
  `if (!isDisconnected())` wrapper: that would leave a dismissed-while-dead
  panel showing a phantom lock.

- **`dismissed()` must never fire `imeResetTick`.** That tick is the CR-01
  security wipe for a dead socket (T-04-03). Hiding the keys does not earn it,
  and firing it would silently destroy the user's in-flight IME buffer on every
  dismiss — which the summon model makes the most frequent gesture in the app.
  Pinned by a test.

- **The todo's `files:` list named `test/trackpad/trackpad_screen_test.dart`
  as the home of the collapse test. It is not there** — `260809-ipc` put the
  collapse proofs in `test/keyboard/keyboard_panel_test.dart:537`. Extended
  there instead.

- **The "comes back at REST" test re-locks after reopening and asserts a
  SECOND `down:WinLeft`.** Asserting the chip's visual state alone would pass
  against the very bug this closes; only a fresh `down` proves the FSM really
  returned to rest.

## Verification

- 7 new tests, **all observed RED before GREEN**. The two widget tests failed
  behaviourally against the pre-fix tree (`down:WinLeft` with no `up` after a
  collapse); the five controller tests failed on the missing method.
- `flutter test` — **872 passed** (was 865).
- `flutter analyze` — clean, no issues.

## Not closed here

Nothing was deferred. The rejected "keep the lock and indicate it" option is
recorded above as a revisit-if-missed, not as debt.
