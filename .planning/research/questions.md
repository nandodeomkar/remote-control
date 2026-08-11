# Open Research Questions

Questions raised outside a phase's own RESEARCH.md. Each carries an ID, the date it
was raised, and what raised it. Move to a phase's RESEARCH.md when that phase is
planned; strike through with the answer when settled.

---

## OQ-A1 — What is "quick" for summon and dismiss, in milliseconds?

**Raised:** 2026-08-11, by the `/gsd-explore` session that produced
`.planning/notes/summon-bar-trackpad-keyboard.md`.

**Why it matters:** the summon-bar design has exactly one hard requirement, and it
is a latency requirement rather than a layout one. The owner's words: *"it can be
sequential as long as the trackpad or keyboard shows up and dismisses quickly."*
Everything else in that design (overlay rather than resize, no content reflow, one
affordance) is justified by sequential use being cheap. **If summon/dismiss is not
cheap, the justification collapses** and the whole shape should be reconsidered
rather than shipped slow.

Right now "quickly" is unquantified, which makes it unverifiable — there is no
number a plan can write a success criterion against.

**What is already known:**

- Expand/collapse today rides a **200ms** `AnimationController`
  (`kBubbleExpandDuration` in `widgets/bubble_scaffold.dart:50`), and the docked
  panel's open/close is a **200ms ease** on the same budget. So 200ms is the
  incumbent, not a proposal.
- The docked panel seeds its landing pad from the persisted value with a **one-shot
  restore jump that covers the async prefs load** (`keyboard_panel.dart`, "Pad
  persistence"). That was written for a surface opened occasionally. Under a summon
  model it runs constantly.

**Sub-questions:**

1. Is 200ms actually the right budget for a gesture that now repeats dozens of times
   per session, or does the incumbent value simply inherit from a rarer interaction?
   Cheaper is not automatically better — an instant appear can read as a glitch.
2. **Does the async prefs pad-restore produce a visible jump on re-summon?** If the
   deck lands on the default pad and then hops to the restored one, that hop happens
   every single summon. This is the concrete failure mode to test first.
3. Should re-summon restore the surface's full prior state (pad, scroll, modifier
   chips) or reset? Restoring is what "quick" implies to a user, but it interacts
   directly with the locked-modifier todo dated 2026-08-11.
4. Is there a measurable first-summon-per-screen cost (mount + prefs read) distinct
   from subsequent summons on the same screen? If so, the first one is the one that
   will be judged.

**How to settle it:** measure on the owner's physical device, not in the simulator —
this is a felt-latency question and the app already has a hardware-UAT habit. The
answer should land as a number in the phase's success criteria, so the surface can
be verified rather than argued about.
