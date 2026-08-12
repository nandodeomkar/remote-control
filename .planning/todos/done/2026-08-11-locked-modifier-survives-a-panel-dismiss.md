---
created: 2026-08-11T00:00:00Z
title: A locked modifier survives a panel dismiss — held on the PC with no chip to release it
area: app
files:
  - app/remote_control/lib/keyboard/keyboard_input_controller.dart
  - app/remote_control/lib/keyboard/keyboard_panel.dart
  - app/remote_control/lib/keyboard/modifier_fsm.dart
  - app/remote_control/test/trackpad/trackpad_screen_test.dart
---

## Problem

Collapsing the docked keyboard panel unmounts the key caps, so any **held** cap
releases. But the panel's `State` survives the collapse, so a **LOCKED** modifier
stays **physically held down on the PC** — with no visible chip anywhere to un-lock
it until the panel is reopened.

From the user's side: lock `Shift`, dismiss the panel, and the PC behaves as though
Shift is welded down. Nothing on screen says why, and nothing on screen can undo it.
Reopening the panel is the only route back.

## Why it is filed now

Recorded as out-of-scope during quick `260809-ipc`
(`.planning/quick/260809-ipc-unify-the-trackpad-docked-keyboard-panel/deferred-items.md`
item 2) and deliberately preserved verbatim there — the plan's `<out_of_scope>`
named "changing what a panel COLLAPSE does to a locked modifier", and Task 1's new
collapse test pins **the cap half only**, on purpose.

That was the right call while collapse was a rare gesture. **The summon-bar design
changes the arithmetic**: dismissing becomes the most frequent interaction in the
app, so a stuck-key path that fires on dismiss goes from a minor edge case to the
single most likely bug in the feature. See
`.planning/notes/summon-bar-trackpad-keyboard.md`.

Fix it with the summon bar, or before it — not after.

## Constraints on the fix

- **The release must reach the PC, not just the UI.** Clearing the chip's visual
  state without emitting the key-up leaves the real defect in place and removes the
  only evidence of it.
- **`KeyboardInputController` is the single owner of the stuck-key model** (D-95,
  `260809-ipc`). The fix belongs there, so it lands on **both** keyboard surfaces by
  construction. A fix written into one surface's State is the drift this controller
  was extracted to prevent.
- **Do not disturb the LIVE-only dispose flush.** The existing dispose contract
  (CR-01) already flushes on a live socket; whatever handles dismiss must compose
  with it rather than duplicate it, or a dismiss-then-teardown emits twice.
- **Decide the semantic deliberately**, and write down which was chosen:
  release the lock on dismiss (simple, predictable, loses an arguably useful
  "lock Shift, dismiss, drag-select on the trackpad" flow), or keep the lock and
  surface it somewhere still visible while dismissed (preserves the flow, costs
  persistent chrome). The first is the safe default; the second is worth a moment's
  thought given the trackpad stays live under the panel by design.

## Test

The existing collapse test pins the cap half only. Extend it to the lock half —
assert the key-up actually reaches the send seam, not merely that the chip cleared.
