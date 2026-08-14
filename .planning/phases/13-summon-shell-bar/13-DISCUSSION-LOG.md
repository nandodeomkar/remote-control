# Phase 13: Summon Shell & Bar - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-08-14
**Phase:** 13-Summon Shell & Bar
**Areas discussed:** Predictive back posture, Empty overlay geometry, Back & icon-swap order, The bar as chrome

**Area selection:** all four offered areas were selected.

---

## Predictive back posture

### Q1 — SC3 says "predictive back still animates." How much of that is Phase 13's job?

| Option | Description | Selected |
|--------|-------------|----------|
| Measure, then don't regress | The D5 spike records today's behaviour as an observed baseline; assert the guard doesn't change it. No manifest or theme edit. | ✓ |
| Turn it on properly and verify | Declare the manifest flag AND add `PredictiveBackPageTransitionsBuilder`, then verify on hardware. App-wide visual change to all 14 screens' transitions. | |
| Measure now, enable later | Same baseline, but file any gap as a backlog item with evidence attached. | |

**User's choice:** Measure, then don't regress
**Notes:** Scouting established the facts this rested on — `android:enableOnBackInvokedCallback` is absent from the manifest, `targetSdk` resolves to 36 via Flutter 3.44 (system predictive-back default-on regardless of the flag), and the theme has no predictive-back transitions builder. The roadmap's "two-minute manifest check" therefore resolves to "measure which of the two SC3 means."

### Q2 — If the D5 spike fails, what should the planner reach for first?

| Option | Description | Selected |
|--------|-------------|----------|
| Stop and bring it to me | The spike failing invalidates the host shape; the fallback resurrects the N-controllers bug. Checkpoint rather than executor improvisation. | ✓ |
| Keep the shell, find another back route | Hold the app-scope shell, try a NavigatorObserver-driven guard or route-aware wrapper. Zero new deps still applies. | |
| Fall back to a per-route shell | STACK's original position — shell inside the MaterialPageRoute where PopScope provably works. Costs the one-controller property. | |

**User's choice:** Stop and bring it to me

### Q3 — Raise on the hub, push a tool screen with it still raised, press back?

| Option | Description | Selected |
|--------|-------------|----------|
| Lower the surface, stay on the pushed screen | Back always resolves the raised surface first, on whatever route. One rule, no exceptions. | |
| Pop, surface stays raised | Back is navigation; the surface is orthogonal chrome that rides along. | ✓ |
| Lower AND pop | One gesture resolves both. | |

**User's choice:** Pop, surface stays raised
**Notes:** Flagged at the time as contradicting SUM-04 and SC3, both of which say back resolves the surface first. Raised as a conflict rather than recorded silently, and reconciled in Q4.

### Q4 — Back never touches the surface, or back only lowers it on the raising screen?

| Option | Description | Selected |
|--------|-------------|----------|
| Only the raising screen intercepts | Back on a route pushed after raising pops normally; back on the owning route lowers first. Satisfies SUM-04 and Q3 both. Costs route-ownership tracking. | ✓ |
| Back is always navigation | No PopScope at all; the D5 spike's premise dissolves. Requires rewriting SUM-04 and SC3. | |
| Actually, surface first everywhere | Revert to Q3's recommended option; SUM-04 and SC3 unchanged. | |

**User's choice:** Only the raising screen intercepts
**Notes:** Resolves the Q3 conflict without amending any requirement. Guard becomes `canPop: !(raised && owner == thisRoute)`, and route ownership becomes a new thing the D5 spike must prove.

### Q5 — The owning route can be popped by the AppBar arrow, orphaning a raised surface

| Option | Description | Selected |
|--------|-------------|----------|
| Ownership transfers to the new top route | No orphan state; needs the same last-writer-wins stack Phase 17 already plans. | |
| Surface lowers when its owner pops | Never orphaned — but that's auto-dismiss-on-screen-change, a banned anti-feature. | |
| Surface stays, nothing owns it | Least code; back from the hub then exits the app with a surface still raised. | ✓ |

**User's choice:** Surface stays, nothing owns it
**Notes:** The exit-with-surface-raised consequence was stated in the option text and chosen anyway. Recorded in CONTEXT.md as a deliberate trade for less host state, not an oversight.

---

## Empty overlay geometry

### Q1 — Same empty-overlay height for both icons, or each icon's real final height?

| Option | Description | Selected |
|--------|-------------|----------|
| Each icon, its real final height | Trackpad fraction and keyboard ~0.75 both derived now; Phases 14/15 only fill a correctly-sized box. | ✓ |
| One placeholder height for both | Less arithmetic in 13, but validates the formula against a number nothing ships. | |
| Real heights, one shared formula | Same outcome as option 1, stated as a constraint on how it's written. | |

**User's choice:** Each icon, its real final height
**Notes:** The "one shared derivation, per-surface fraction on top" constraint from option 3 was folded into the decision rather than discarded.

### Q2 — Does the 48dp handle ship in 13, given SUM-05 is mapped to Phase 14?

| Option | Description | Selected |
|--------|-------------|----------|
| Handle ships in 13, inert | Rendered as chrome so the pinned geometry is the real geometry; SUM-05's wiring and a11y contract stay in 14. | ✓ |
| Reserve the space, draw nothing | Number is right, nothing half-built — but a reserved empty strip invites a later "cleanup". | |
| No handle, no reservation | Cleanest requirement boundary; costs re-running five-device tests in a phase flagged research-not-needed. | |

**User's choice:** Handle ships in 13, inert

### Q3 — What fills the empty overlay?

| Option | Description | Selected |
|--------|-------------|----------|
| Bare surface + handle | kSurface fill, real top edge, 48dp handle, nothing else. Nothing to delete later. | ✓ |
| Add a temporary label | Centered "Trackpad"/"Keyboard" placeholder Text — one widget to delete in 14/15. | |
| Add a debug height readout | Makes the inset check visually verifiable on hardware; must be removed. | |

**User's choice:** Bare surface + handle

### Q4 — When are the height fractions set?

| Option | Description | Selected |
|--------|-------------|----------|
| Tune them in 13's UAT | Ship research's proposals, adjust on device in the same session that judges 200/150ms. | ✓ |
| Take proposed values, revisit in 14/15 | Judge when real content is in the box; defers RET-03 to Phase 14 where it's mapped. | |
| Owner supplies numbers now | Lock an owner-specified height instead of research's proposal. | |

**User's choice:** Tune them in 13's UAT

---

## Back & icon-swap order

### Q1 — Trackpad raised, tap the keyboard icon

| Option | Description | Selected |
|--------|-------------|----------|
| Swap in place, one animation | Surface stays up and resizes/crosses over. Obliges the outgoing surface's cleanup to fire on the swap edge. | ✓ |
| Lower, then raise (350ms) | Every dismiss path identical no matter the trigger; slower, visibly two motions. | |
| Ignore the tap while raised | Simplest state machine; a dead tap on an enabled icon reads as a bug. | |

**User's choice:** Swap in place, one animation
**Notes:** The cleanup consequence (drag-lock flush, keep-awake release, modifier release must all fire on swap) was carried into CONTEXT.md as a note for Phases 14 and 15.

### Q2 — Browser screen, inside a bookmark folder, with a surface raised — one back gesture

| Option | Description | Selected |
|--------|-------------|----------|
| Surface first, folder next | Strict one-thing-per-gesture; matches the ownership rule. Requires the two guards to coordinate. | ✓ |
| Folder first, surface next | Screen state unwinds before app-level chrome. | |
| Both at once | Fewest presses; most likely way to lose your place. | |

**User's choice:** Surface first, folder next
**Notes:** Both `PopScope` callbacks fire when `canPop` is false, so `_onBookmarksBack` must become conditional on nothing being raised. Recorded as an implementation constraint.

### Q3 — Should the raised surface's bar icon look different?

| Option | Description | Selected |
|--------|-------------|----------|
| Yes, accent-tinted while raised | kAccent for the raised surface, kMuted for the other. Distinct from Phase 17's "you are here". | ✓ |
| Yes, treatment decided in UI-SPEC | Lock that it's distinct, leave tint/fill/indicator to the design pass. | |
| No, keep both identical | Bar stays dead-simple chrome; nothing says which surface is up. | |

**User's choice:** Yes, accent-tinted while raised

### Q4 — A tap landing mid-animation

| Option | Description | Selected |
|--------|-------------|----------|
| Reverse from where it is | AnimationController.reverse() from the current value; no snap, no queue. | (discretion) |
| Ignore taps until the animation finishes | Deterministic; a swallowed tap reads as unresponsive at this tap frequency. | |
| Queue the tap and run it after | Nothing lost; a double-tap costs the full 350ms. | |

**User's choice:** No preference — deferred to Claude
**Notes:** Recorded as Claude's discretion, resolved to "reverse from where it is" (default framework behaviour, least code).

---

## The bar as chrome

### Q1 — How much visual weight?

| Option | Description | Selected |
|--------|-------------|----------|
| kBg fill + kHairline top edge | Bar reads as the edge of the screen; icons carry all the weight. | ✓ |
| kSurface fill, no hairline | Clearer control strip, matching edge for the raised surface; heavier on dense screens. | |
| kBg, no hairline at all | Lightest possible; scrolling content looks like it collides with the icons. | |

**User's choice:** kBg fill + kHairline top edge

### Q2 — Where do the two icons sit on a 360dp bar?

| Option | Description | Selected |
|--------|-------------|----------|
| Centered as a pair | Deliberate emptiness, both in one thumb's reach, survives a hypothetical third icon. | ✓ |
| Spread across the width | Standard NavigationBar distribution; with two destinations it looks like items are missing. | |
| Right-aligned pair | Best right-handed reachability; visibly lopsided, worse left-handed. | |

**User's choice:** Centered as a pair

### Q3 — What does the bar do with no PC connected?

| Option | Description | Selected |
|--------|-------------|----------|
| Mute both icons, keep them tappable | Mirrors the hub's D-08 offline tiles (muted but still open). Must ride connectionStatusProvider, never ConnectionService.changes. | ✓ |
| Always full-strength, never react | Zero rebuild risk; the only affordance that doesn't acknowledge being offline. | |
| Mute AND disable taps | Honest, but breaks the hub precedent and deadens the bar during reconnect blips. | |

**User's choice:** Mute both icons, keep them tappable

### Q4 — Bar height and position relative to the gesture-nav inset

| Option | Description | Selected |
|--------|-------------|----------|
| 56dp above the nav inset | Icons never sit in the system gesture zone; total reserved space is 56 + inset. | ✓ |
| 56dp total, inset absorbed | Cheapest in real estate; puts tap targets under swipe-up-to-home. | |
| Something smaller than 56 | Buys back height on already-tight screens; looks cramped vs Material conventions. | |

**User's choice:** 56dp above the nav inset

---

## Claude's Discretion

- Mid-animation tap handling — resolved to `AnimationController.reverse()` from the current value.
- The exact format of the test-migration checklist that Phase 16 executes.
- Which five viewports the inset discriminator tests drive (constrained to include one 360dp gesture-nav device with a raised IME).

## Deferred Ideas

- Enabling in-app predictive back properly (manifest flag + `PredictiveBackPageTransitionsBuilder`) — out of Phase 13 by decision; file as a finding if the spike's baseline shows a gap.
- Ownership transfer for an orphaned raised surface — considered and declined; revisit only if dogfooding proves it annoying.
- A third bar icon, user-reorderable icons, swipe-on-bar to switch surfaces — v2+.
- Deleting either hub tile (HUBF-01) — deferred beyond v1.1, must not be pulled forward.
