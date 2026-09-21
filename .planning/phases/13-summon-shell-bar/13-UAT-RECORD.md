---
phase: 13-summon-shell-bar
plan: 10
kind: uat-record
status: partially-observed
build: RemoteControl-v1.7.0.apk — the RELEASE build (AOT), not the debug APK this
  plan originally specified. Motion judgements below are therefore against the
  build the owner actually runs, which is the stricter and more relevant surface.
device: <fill in: model + Android version>
observed_by: owner
observed_on: 2026-08-15
---

# Phase 13 — Hardware UAT Record

> **What this file is.** The five things in `13-VALIDATION.md` `## Manual-Only
> Verifications`, plus the two the UI review asked to be carried here (CR-1, CR-3),
> written down where Phases 14, 15 and 18 will read them.
>
> **Why it is a file and not a chat message.** Two of this phase's constants are
> *declared design choices tuned on hardware* (D-13-09, D-13-14) and one success
> criterion is a human judgement about felt latency. Threat T-13-17: a tuned constant
> that lives only in a transcript is unrecoverable. Phase 14's RET-03 verdict depends
> on the trackpad height recorded here being a **fact**, not an assumption.
>
> **How to use it.** Every item below has an `Observation:` slot that is deliberately
> **blank**. Fill each one in your own words while the build is in your hand. Do not
> pre-fill them from reasoning — the whole point is that no test can produce these
> answers.

## What is on the device

A permanent 56dp bar with a trackpad glyph and a keyboard glyph rides every screen
including the hub. Tapping an icon raises an **empty** surface in place over the
current screen; tapping it again lowers it; tapping the other icon swaps in one
motion. The Android back gesture lowers a raised surface before it pops the screen,
on the route that raised it. The keyboard icon is disabled while a phone text field
holds focus, and the bar is absent on the QR scan screen. **The surface is
deliberately empty — Phases 14 and 15 fill it.** Judge the *box*, not the contents.

---

## 1. Felt latency — does it feel quick? (SC5 / MOT-01)

**Numbers in front of you.** The raise budget is **200**ms
(`kSummonRaiseDuration`). The lower budget is **150**ms
(`kSummonLowerDuration`). The swap is one **200**ms motion, never a 150 lower
followed by a 200 raise. **Each is a one-constant change** in
`app/remote_control/lib/shell/summon_geometry.dart`.

**What to do.** Raise and lower both surfaces twenty or thirty times, at the
frequency a permanent bar invites — not once carefully, but the way you would in
real use. Also tap trackpad → keyboard → trackpad to feel the swap.

**What to answer.** Does it feel quick, or does either direction drag? If it drags,
say **which direction** — raise and lower are separate constants and can move
independently.

- Observation (raise, currently 200ms): Works on tap. Raises nicely.
- Observation (lower, currently 150ms): Lowers nicely.
- Observation (swap, currently 200ms): Swaps nicely.
- Tuning requested (new value, or "none"): **none** — all three budgets stand at
  200 / 150 / 200. Judged on the v1.7.0 RELEASE build, so this verdict is against
  AOT timings rather than debug-JIT ones.

**Also observed, unprompted — and it is the SPECIFIED behaviour, not a defect.**
Dragging a raised surface up or down does nothing. That is D-13-07: the 48dp handle
ships in Phase 13 as *inert chrome*, with no gesture recognizer at all
(`summon_handle.dart` states it in its library doc). SUM-05 — the handle as a working,
a11y-drivable dismiss route — is mapped to **Phase 14**. The band is rendered now only
so the geometry this phase pins is the geometry that ships.

**This is a positive signal for Phase 14, not a null result.** The owner reached for a
drag without being asked to, which is evidence the affordance reads as draggable. Phase
14 must attach its recognizer to the 48x48 target as a **sibling** of the surface
content, never an ancestor — the `floating_trackpad_window.dart:245-257` rule — or the
trackpad's raw pointer listener will lose the arena uncontested and every dismiss will
nudge the PC cursor invisibly.

**Status:** ✅ observed — no tuning

---

## 2. Trackpad surface height (D-13-14 / CR-3 — the number Phase 14 inherits)

**Numbers in front of you.** The trackpad surface ships at **280**dp
(`kSummonTrackpadHeight`). The 1px top rule and the 48dp handle band come out of it:

```
280 − 1 (hairline) − 48 (handle band) = 231dp of actual pad
```

against the **234**dp of pad in the `FloatingTrackpadWindow` (the floating bubble
window) that Phase 16 retires. **At the starting constant the raised trackpad is
therefore 3dp *behind* the affordance it replaces.** That is CR-3, stated as
arithmetic rather than left as a footnote.

**What to do.** Raise the trackpad surface. Use it as a pad — move the cursor, tap,
drag — even though it is empty chrome in this build, judge the *space*.

**What to answer — two separate questions, both required.**

1. Is the raised trackpad **better than the bubble window** it replaces, or does the
   3dp deficit read as a downgrade?
2. Is the full **Trackpad screen still clearly the larger, more precise** surface? —
   this answer is the justification for the full-screen Trackpad hub tile surviving,
   and **Phase 14 inherits this verdict** (RET-03).

- Observation (vs the bubble window's 234dp): "Looks good." The 3dp deficit does not
  read as a downgrade.
- Observation (still clearly smaller than the full Trackpad screen?): **OUTSTANDING.**
  The owner's "looks good" answered the height question; this is the separate second
  question and it has not been answered yet. It must not be inferred from the first.
- Tuning requested (new height in dp, or "none" — 280 stays): **none** — 280 stays.
- Resulting content box if tuned (`new height − 1 − 48` = ___ dp): unchanged at **231**dp.

**Status:** 🟡 half observed — the height verdict is in (280 stays, 231dp of pad).
Phase 14's RET-03 input is still open.

---

## 3. Keyboard surface height (D-13-14)

**Numbers in front of you.** The keyboard surface ships at **432**dp
(`kSummonKeyboardHeight`), giving `432 − 1 − 48 = 383`dp of content. It is taller
than the trackpad's **280** deliberately: Phase 15's four pads do not fit an
IME-height box. Phase 15's chip row (64) plus tab bar (56) take 120 of that 383,
leaving 263 of pad viewport against a Numpad crushed to 48dp key caps needing ~248.
**There is only ~15dp of headroom — 432 is near the floor, not the ceiling.** Shaving
it is not free.

**What to do.** Raise the keyboard surface. Compare it against the system IME height
you are used to.

**What to answer.** Does it look right on your screen, or too tall?

- Observation: "Looks good." Not too tall on the owner's screen.
- Tuning requested (new height in dp, or "none" — 432 stays): **none** — 432 stays,
  383dp of content.

**Status:** ✅ observed — no tuning. Phase 15 sizes its four pads inside a **confirmed**
432dp box with `Expanded` (D-13-15), against ~15dp of headroom.

---

## 4. Resting connected glyph tint (CR-1) — one yes/no

**Context.** D-13-11 said the non-raised icon "stays `kMuted`"; D-13-13 said "when
disconnected, both icons render `kMuted`" — a clause that is vacuous unless the
connected resting state is something else. CR-1 resolved it as: **resting-and-
connected is `kText`**, disconnected is `kMuted`, raised is `kAccent`. That is an
owner-confirmed *reinterpretation* of a locked decision, and it is a one-constant
change if it reads wrong on hardware.

**What to do.** Connect to the PC. With nothing raised, look at the two bar glyphs.

**What to answer.** Do they read as normal light text, or as dimmed/muted? Yes or no.

- Observation (yes = reads as light text / no = reads muted): **yes** — resting-and-
  connected reads as normal light text, not dimmed. Answered in two passes: the owner
  first confirmed against the disconnected A/B that the two states are **visibly
  different** on hardware, then confirmed the connected state *on its own* reads as
  normal light text. The second pass was asked rather than inferred from the first,
  deliberately — this record's item 2 shows what inferring costs.
- Tuning requested (revert to `kMuted`, or "none"): **none** — CR-1's reinterpretation
  stands: resting-and-connected is `kText`, disconnected is `kMuted`, raised is `kAccent`.

**Status:** ✅ observed — no tuning. Two things close here, not one: CR-1's
reinterpretation of D-13-11 is confirmed on hardware, **and** D-13-13's "when
disconnected, both icons render `kMuted`" clause is proven live rather than vacuous —
the states are distinguishable to the eye. Phase 17 builds its bar-identity styling on a
resting tone that has now been looked at.

---

## 5. System back baseline (SC3 / D-13-01) — a recording, not a pass/fail

**Context.** This phase deliberately enables nothing: no
`enableOnBackInvokedCallback` in the manifest, no `pageTransitionsTheme`. D-13-01
says predictive back is **measured, not enabled**, and `SummonBackGuard` must not
change it. The widget suite already recorded the framework's back claim (false on the
hub with nothing raised, true while a surface is up, false again after lowering) —
but only the OS compositor renders the peek, and no test can see it. **This slot is
the baseline that SC3 is later measured against. There is no wrong answer here.**

**What to do — two passes.**

1. From the hub with **nothing raised**, do a back gesture. Describe what the system
   does: does the app window peek away toward home? Does it scale? Is there any
   animation at all?
2. Now **raise a surface on the hub** and do the same gesture. The surface should
   lower and the app should stay. Describe what the **raised surface looks like
   during** the gesture, while the compositor is scaling the window.

Attach a screen recording if it is easier than describing it.

- Observation (nothing raised — the baseline): **OUTSTANDING.** The owner reported route
  behaviour — "back from a hub tile goes to the hub" — which confirms SUM-04's *logic*
  but is not this slot. This slot wants what the **system compositor** draws during a
  back gesture **from the hub root** with nothing raised: whether the app window peeks
  or scales away toward home, or whether there is no animation at all.
- Observation (surface raised — what the surface does during the gesture): **confirmed
  functionally** — a back gesture from a raised surface lowers the surface and the app
  stays (SUM-04 holds, and the guard fires on the route that raised it). What the raised
  surface *looks like* mid-gesture, while the compositor scales the window, is still open.
- Video / screen recording attached (path or "none"): none

**Status:** 🟡 half observed — the dismiss behaviour is confirmed; the compositor
baseline SC3 is measured against is not yet recorded. **Still a BASELINE, not a pass.**

---

## 6. Browser at real device height, and the power confirm dialog (BAR-05 / SC1 / BAR-01)

**Context.** Two eyeball items that need real content at a real device height with
the bar present. The power-dialog one is threat **T-13-03**: the bar renders over
modal routes including the spec-locked power double-confirm. The dialog is centred
and the bar is a bottom strip so they should not overlap — but a mis-tap on a
double-confirm is worth a human look rather than an assertion. **If the bar does
occlude an action, that is a real finding recorded here and fixed in a follow-up —
not with a second suppressor**, which would contradict the criterion requiring the
bar on the pairing sheet.

**What to do.**

1. Open **Browser**. Switch between the tabs segment and the bookmarks segment.
   Scroll each to its very end. Confirm the last row is fully visible and **tappable**
   above the bar — not clipped, not stranded behind it.
2. Open **Power** and trigger the restart (or shutdown) confirm. Confirm the bar does
   not cover the dialog's buttons.

- Observation (Browser — tabs segment, scrolled to the end):
- Observation (Browser — bookmarks segment, scrolled to the end):
- Observation (power confirm dialog vs the bar):

**Status:** ⬜ not yet observed

---

## Who consumes each answer — what an un-filled slot costs

| # | Item | Downstream consumer | What is lost if this slot stays blank |
|---|------|---------------------|----------------------------------------|
| 1 | Felt latency — the **200**ms raise / **150**ms lower | **Phase 13 close-out** applies any tuning; **Phases 14 and 15** inherit the tuned budgets unchanged — the raised trackpad and raised keyboard reuse this one controller, they never declare their own | Milestone SC5 ("summon and dismiss feel quick") stays open with no evidence, and OQ-A1 sub-question 1 never closes. Two more phases ship motion nobody has judged |
| 2 | Trackpad height — **280** → **231** vs the bubble's **234** | **Phase 14 (RET-03)** — the verdict on whether the full-screen Trackpad hub tile is still justified is *downstream of this number*; **Phase 17 (RET-02)** then moves the hub tiles on the strength of it | Phase 14 inherits an assumption where CONTEXT explicitly warns "do not let Phase 14 assume RET-03 passes". A 3dp regression against the retired affordance ships unexamined, and Phase 16 deletes the bubble that would have been the comparison |
| 3 | Keyboard height — **432** → 383 of content | **Phase 15** sizes the four pads *inside* this fixed box with `Expanded` (D-13-15). The ~15dp of headroom is the whole budget | Phase 15 builds against a box that may be visibly wrong on the owner's screen, and discovers it only after the pads are wired — when the height is no longer a one-constant change in practice |
| 4 | Resting glyph tint (CR-1) | **Phase 13 close-out** (one-constant revert); **Phase 17** — bar identity and the raised/resting state pair | An owner-confirmed reinterpretation of a locked decision ships unverified. Phase 17 then builds state styling on top of a resting tone nobody looked at |
| 5 | System back baseline (SC3 / D-13-01) | **Phase 13 verification** — SC3 is asserted *against this baseline*, not against an ideal; the deferred idea "enable in-app predictive back properly" is evaluated against it | SC3 becomes unmeasurable: there is nothing to compare to. The deferred predictive-back idea loses its evidence and gets re-litigated from scratch |
| 6 | Browser at device height · power confirm dialog | **Phase 13 verification** (BAR-05 / SC1); threat **T-13-03** disposition; **Phase 16** removes the bubble from the same screens | A clipped last row in Browser and an occluded confirm button are exactly the two failures no widget test at a synthetic viewport will find. T-13-03 stays `mitigate` with nothing behind it |

---

## Findings and tuning applied

> Filled in at plan close-out (Task 3), after the observations above.
> Anything the owner asks for that is **not** a one-constant change is recorded here
> as a finding with its reason and surfaced for the next planning pass — it is not
> absorbed into this plan.

- Constants changed:
- Findings deferred:
