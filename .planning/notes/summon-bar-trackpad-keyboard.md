---
title: The summon bar — trackpad and keyboard raised in place, on every screen
date: 2026-08-11
context: >
  Design settled by /gsd-explore after the owner dogfooded v1.6.3 for several days
  in place of the Play Store app it replaces. Supersedes two phase-08 decisions.
  Not yet planned or scheduled — routed to a v1.1 milestone.
---

# The summon bar

## The idea, in the owner's words

> "Get rid of keyboard and trackpad tiles or put them last. Instead, trackpad and
> keyboard should come up when requested like keyboards do in android phones. That
> way a keyboard and trackpad is always available alongside other types of remote
> tiles."

## What was decided

**A permanent bottom bar on every screen, carrying two icons — trackpad and
keyboard — that raise those surfaces IN PLACE.** No navigation, no screen push.

1. **The bar replaces the bubble outright.** `TrackpadBubble`,
   `FloatingTrackpadWindow` and `windowPositionProvider` all retire. One
   affordance, not two doing the same job — the same call phase 08 made when it
   deleted the quick-bar rather than keep both.
2. **The raised surface OVERLAYS; it does not resize the content beneath.** See
   the rationale below — it is stronger than it first looks.
3. **Both hub tiles move to the END of `kHubTiles`.** Neither is deleted.
4. **The bar rides the hub too** — ASSUMED, not stated outright by the owner. The
   opening ask was that both be available "alongside other types of remote tiles",
   and the hub is where the tiles live. Flagged here rather than buried; if a
   planner finds a reason to exclude the hub, this is the assumption it is
   contradicting.

## Why overlay, and not the IME's resize

The Android IME resizes the app above it so the text field you are typing into
stays visible. **That rationale does not transfer.** Nothing on the phone screen is
the target of the input — every keystroke and every cursor delta goes to the PC. So
there is no field to keep visible and nothing that must stay on screen.

The owner confirmed the usage is sequential: *"I require other remotes when using
the trackpad or keyboard but it can be sequential as long as the trackpad or
keyboard shows up and dismisses quickly."*

**This converts the requirement from a layout contract into a latency-and-gesture
contract.** Nothing needs to shrink or scroll. What must hold instead:

- summon and dismiss are fast enough that bouncing between "mouse a bit" and "hit
  pause" does not feel like navigation;
- dismiss costs ONE gesture;
- re-summoning restores the surface where it was (which pad, what state) without a
  visible jump.

A planner that "improves" this into a resize/inset contract is solving a problem
this app does not have, at the cost of the tool screens it would have to make
scrollable.

## Two deliberate reversals — record them as such

Both are phase-08 decisions being revisited on the strength of real use. Neither is
an oversight being corrected, and a future reader should not "restore" either.

| Decision | What it said | What changes now |
|---|---|---|
| **D-10** (07-CONTEXT.md:79) | A persistent bottom quick-bar: a **single Trackpad shortcut button** that **pushes the full Trackpad screen**. Explicitly *not* a live mini-pad — "that richer 'peek pad' was explicitly deferred." | A persistent bottom bar returns, but with two icons that **raise surfaces in place** instead of one that navigates away. |
| **D8-06** (08-CONTEXT.md:86) | "**Quick-bar deleted outright** — no settings toggle to restore it." Tool screens "get the full height back." | The bar comes back and the 56-ish px is re-paid on every screen. The owner accepted that cost knowingly. |
| **D8-05** (08-CONTEXT.md:83) | Bubble scope: "tool screens only… **Not on hub**, not on the Trackpad screen." | The summon bar reaches the hub (see assumption 4 above). |

**The thing coming back is not the thing that left.** The old quick-bar's flaw was
that it *navigated away* from the screen you were on; the bubble's flaw is that it
*only ever carried the trackpad*. A two-icon bar that summons both, in place, is
neither. That distinction is the entire justification for reopening D8-06 and
should survive into the phase's context.

## Why the timing is right

Quick `260809-ipc` (2026-08-09) collapsed the docked `KeyboardPanel` and the
full-screen `KeyboardScreen` into ONE implementation with a single
`KeyboardInputController` owning the stuck-key model. **A third mount point is now
a layout problem rather than a correctness problem.** Before that commit this same
idea would have meant inventing a third keyboard vocabulary — the exact thing
`260809-ipc` existed to delete.

Phase 08 also wrote down two of these items as deferred, at 08-CONTEXT.md:173:
"Keyboard inside the window (keyboard stays on its own tile + the full Trackpad
screen)" and "Bubble on the hub". **Days of real use independently rediscovered
both.** That is corroboration, not coincidence, and it is the strongest argument
that this is worth building.

## Why the tiles survive

The owner chose "both tiles move last" over deleting either. The reasoning that
held up:

- The **full Trackpad screen is the precision surface** — full-screen area for
  large cursor throws, versus a raised surface that is necessarily partial.
- The **docked keyboard-over-live-trackpad mode is a genuinely different mode**:
  type while the cursor stays live above. `keyboard_panel.dart:7` calls this "a
  hard contract, not a nicety."
- The hub grid is the **D-08 offline surface** (tiles stay visible but muted when
  disconnected) and the discovery path.
- It is **fully reversible**. If the bar proves worse in a week, nothing was thrown
  away. Deleting the tiles is a one-line follow-up; un-deleting them is not.

A weaker option was considered and rejected: dropping the Keyboard tile alone, on
the grounds that the bar raises the same four-pad deck so a full Keyboard screen
only buys height. Worth revisiting AFTER the bar has been lived with — not before.

## Landmines the plan must carry

Ordered by how likely they are to bite.

1. **A LOCKED modifier survives a dismiss.** Collapsing unmounts the caps so *held*
   caps release, but the panel State survives — a locked modifier stays physically
   held on the PC with no visible chip to un-lock it. Deferred from `260809-ipc`
   (deferred-items.md #2) when collapse was a rare gesture. **The summon model makes
   dismiss the most frequent gesture in the app**, so this stops being minor. Has
   its own todo.
2. **The pad-height clamp reads RAW window metrics**, not the ancestor MediaQuery,
   because in the trackpad tree that MediaQuery has had the very insets the clamp
   depends on stripped out from under it (`keyboard_panel.dart:40`, flagged
   load-bearing at the call site). A bar-hosted overlay is a THIRD inset context.
   Re-derive the arithmetic; do not copy it.
3. **The hidden IME input must stay mounted in both states and OUTSIDE the
   animating chrome**, or Android tears down the input connection on every summon.
   Already true in the docked panel; it has to survive the port.
4. **The modifier chip row overflows 7.3px at 360dp** (`260809-ipc`
   deferred-items.md #1). Another narrow-width mount means another place it shows.
   It is currently pinned by a test that drains the overflow deliberately and
   asserts the drain count is non-zero — **that test failing is the signal the bug
   was fixed**, not a flake.
5. **`showBubble: false` exists so there is never a shortcut to the screen you are
   on.** With the bubble retired and both tiles moved last, that flag's meaning
   needs a deliberate re-read rather than a mechanical port.

## Scope

~4-6 plans. Touches: the bar itself, the summon surface, the keyboard's third mount
point, retiring `FloatingTrackpadWindow` + `windowPositionProvider`, the hub
reorder, and test migration across `bubble_scaffold_test.dart`,
`floating_trackpad_window_test.dart`, `hub_tiles_test.dart` and the keyboard suites.

## Status

Routed to a **new v1.1 milestone** — v1.0 stays closed and auditable at 12/12
phases / 108/108 plans. Not yet planned. The dogfood/refine hold and the pending
`/gsd-audit-milestone` on v1.0 both still apply.
