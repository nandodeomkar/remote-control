# Phase 13: Summon Shell & Bar - Context

**Gathered:** 2026-08-14
**Status:** Ready for planning

<domain>
## Phase Boundary

The **host**, and only the host. A permanent two-icon bar rides every screen
including the hub, and tapping an icon raises a correctly-sized **empty** overlay
in place — settling the host shape, the inset arithmetic, the bar's scope, the
dismiss vocabulary and the motion constants while the overlay still contains
nothing that can confuse a failure.

Covers BAR-01..05, SUM-01..04, MOT-01.

**Not this phase:** trackpad content (Phase 14), keyboard content (Phase 15),
bubble deletion (Phase 16), hub tile order and "you are here" bar identity
(Phase 17), chip row and the measured motion trace (Phase 18).

</domain>

<decisions>
## Implementation Decisions

Decisions D-13-01..D-13-13 below are **new** to this discussion. Everything under
"Already Locked Upstream" was settled before this discussion and is repeated only
so a planner does not re-open it.

### Back handling & the D5 spike

- **D-13-01:** **Predictive back is measured, not enabled.** The D5 spike records
  what predictive back actually does on hardware today as an observed baseline, and
  the `SummonBackGuard` must not change it. **No `AndroidManifest.xml` edit and no
  `pageTransitionsTheme` edit in this phase.** SC3's "predictive back still animates"
  is therefore an assertion against the recorded baseline, not a task to make it
  animate. Grounding: the manifest never declares
  `android:enableOnBackInvokedCallback`, but `targetSdk` resolves to **36** through
  Flutter 3.44 (so Android's system predictive-back animations are default-on
  regardless of the flag), and the theme has no `PredictiveBackPageTransitionsBuilder`
  (so in-app route transitions have no predictive peek). The spike must record which
  of those two SC3 is measuring.

- **D-13-02:** **The guard is per-route AND per-owner:**
  `canPop: !(raised && owner == thisRoute)`. Only the route that *raised* the surface
  intercepts back. Back on a route pushed **after** the surface was raised pops that
  route normally and the surface rides along. So: raise on the hub → tap a hub tile →
  Media pushes underneath with the surface still up → back pops to the hub → back
  lowers the surface → back exits. This preserves SUM-04 ("back dismisses a raised
  surface before it pops the screen") on the owning screen while keeping the surface
  alive across navigation, which the anti-feature list requires. The shell must track
  route ownership of the raised surface — that is a **new obligation for the D5 spike**
  to prove alongside the intercept itself. — **Reversibility:** costly — the ownership
  token threads through the shell state, every `SummonBackGuard` instance and the
  Phase 17 `activeSurfaceProvider` stack; changing the rule later means re-deriving
  back behaviour on all 14 screens.

- **D-13-03:** **An orphaned surface stays raised and un-owned.** Tool screens have
  an AppBar back arrow, so the owning route can be popped without a back gesture. When
  that happens the surface stays up with no owner; from then on only the icon tap (and
  from Phase 14 the handle) dismisses it. **Accepted consequence, stated explicitly by
  the owner:** back from the hub with an orphaned surface raised will exit the app with
  the surface still raised. Ownership transfer was offered and declined — do not add
  transfer machinery. This is a deliberate trade for less state, not an oversight.

- **D-13-04:** **If the D5 spike fails, stop and check in with the owner.** If
  `SummonBackGuard` does not intercept back from a route below a `MaterialApp.builder`
  shell, the executor does **not** pick a fallback host shape. The per-route-shell
  fallback resurrects the exact defect the app-scope shell exists to prevent (N
  `KeyboardInputController`s → a Shift locked on the hub stays physically held on the
  PC with no chip anywhere to release it). Raise it as a checkpoint. — **Reversibility:**
  one-way — the host shape determines whether the hidden IME field can be a sibling of
  the animating chrome at all; recovering from the wrong choice is a host rewrite
  (research PITFALLS P4).

- **D-13-05:** **On the Browser screen, back resolves the surface first, then the
  bookmark folder, then the route.** Strict one-thing-per-gesture.
  **Implementation constraint:** `browser_screen.dart:576` already holds
  `PopScope(canPop: !inFolder)`, and multiple `PopScope`s in one subtree **AND**
  together — both callbacks fire when `canPop` is false. So `_onBookmarksBack` must
  become conditional on nothing being raised, or the two guards must resolve through a
  single decision point. This is PITFALLS P8's "audit before adding" with a concrete
  answer. It is the **only** other `PopScope` in `lib/` (`bubble_scaffold.dart`'s dies
  with the bubble in Phase 16).

### Overlay geometry

- **D-13-06:** **Each icon raises its real final height in Phase 13**, not a
  placeholder. The trackpad icon raises the trackpad fraction; the keyboard icon raises
  the keyboard's (~0.75). Both come from **one shared derivation** — deriving once and
  applying a per-surface fraction, never forking the arithmetic per surface. Phases 14
  and 15 then only fill a box that is already the right size. This is the reason the
  phase exists ahead of the surfaces: validating the formula against a number nothing
  ships would reproduce exactly the "invisibly wrong until a real device" failure the
  ordering was designed to prevent. — **Reversibility:** costly — the derivation is
  pinned by driven-viewport discriminator tests across five devices; changing its shape
  means re-deriving and re-pinning all of them.

- **D-13-07:** **The 48dp drag handle ships in Phase 13 as inert chrome.** SUM-05
  (the handle as a working dismiss route, a11y-drivable) stays mapped to Phase 14, but
  the handle is *rendered* in 13 so the geometry this phase pins is the geometry that
  ships. Phase 14 adds behaviour to a box that already reserves the space — no
  re-derivation, and no second round of five-device viewport tests in a phase whose
  research flag is "not needed".

- **D-13-08:** **The empty overlay contains nothing throwaway.** `kSurface` fill, the
  real top-edge treatment the surfaces will keep, and the 48dp handle. No placeholder
  label, no debug height readout. Every pixel of Phase 13's overlay is chrome that
  Phases 14 and 15 inherit.

- **D-13-09:** **The height fractions are tuned on hardware during Phase 13's UAT.**
  Ship research's proposals as starting values (keyboard ~0.75; trackpad sized so the
  raised pad beats the retiring bubble window's 234px on the reference device while
  staying clearly smaller than the full Trackpad screen), then adjust in the same UAT
  session that judges 200/150ms and closes OQ-A1 sub-question 1. Both are
  one-constant changes. `kSummonMaxHeightFraction` / `kSummonTrackpadFraction` are
  declared design choices, not derived values — name them as such in code so a later
  reader does not treat them as arithmetic.

### Summon / dismiss behaviour

- **D-13-10:** **Tapping the other icon swaps in place, in one animation.** The
  surface stays raised and crosses over, resizing to the other surface's height in a
  single motion — not a 150ms lower followed by a 200ms raise. **Consequence the
  planner must carry into Phases 14 and 15:** a swap is a dismiss for the outgoing
  surface, so the trackpad's dismiss-side cleanup (`TrackpadCoreState.dismissed()`
  drag-lock flush, keep-awake release) and the keyboard's `dismissed()` modifier
  release must fire on the **swap** edge too, not only on a full dismiss. A dismiss
  path that only triggers on "surface → nothing" leaves a held button or a locked
  modifier on the PC every time the owner swaps.

- **D-13-11:** **The raised surface's bar icon is accent-tinted (`kAccent`); the
  other stays `kMuted`.** This is what makes the tap-to-dismiss toggle legible rather
  than a guess, and it matters more given D-13-10 (with swap-in-place, nothing else on
  the bar says which surface is up). **Note for Phase 17:** this is a *different* state
  from RET-02's "you are here" (selected-and-inert for the screen you are currently on).
  Both eventually render on the same two icons — Phase 17 must compose with this
  treatment, not invent a conflicting one.

### The bar as chrome

- **D-13-12:** **`kBg` fill with a `kHairline` top edge.** The bar reads as the edge
  of the screen, not as a component sitting on it — consistent with how the app already
  separates regions, and it honours "ship the bar looking empty". Icons carry all the
  visual weight. **Two icons centered as a pair**, dead width split evenly left and
  right — deliberate emptiness rather than two orphaned buttons, both in one thumb's
  reach, and the composition survives a hypothetical third icon (explicitly v2+).

- **D-13-13:** **`kSummonBarHeight = 56`, sitting above the Android gesture-nav
  inset** — the inset is padded *below* the 56dp, so total reserved space is
  `56 + viewPadding.bottom` and the icons never sit in the system gesture zone where
  the trackpad icon would compete with swipe-up-to-home. **When disconnected, both
  icons render `kMuted` but stay tappable**, mirroring the hub's D-08 offline tiles
  (which mute yet still open their screens); the raised surface shows its own
  disconnected state. This must be driven by the value-equal `connectionStatusProvider`
  — **never** a `ConnectionService.changes` subscription (research P9: the bar is on
  every screen including the trackpad's hot path, and the bar needs no `Timer.periodic`).

### Already Locked Upstream — do not re-open

- Host shape: `SummonShell` at `MaterialApp.builder` + a thin per-route
  `SummonBackGuard` (research C1). The one-`KeyboardInputController`-per-process
  property is a **correctness** requirement, not tidiness.
- The phase **opens with the D5 spike** — prove the guard intercepts, plus one
  `find.byType` assertion that the builder sits above the Navigator.
- Bar scope: every screen including the hub; keyboard icon gated on local field focus
  (BAR-03, so a pairing PIN can never reach the PC); QR scan screen suppressed entirely
  (BAR-04).
- Motion: 200ms summon / 150ms dismiss (MOT-01), on-device UAT is the gate.
- Zero new dependencies. Exactly two icons. No scrim, no swipe-down-to-dismiss, no
  haptics on summon/dismiss, no hide-on-scroll, no auto-dismiss on
  inactivity/disconnect/screen-change, no nested `Navigator`, never a static
  `PopScope(canPop: false)`.
- **Not** an IME-style resize contract — nothing beneath a raised surface resizes,
  reflows or scrolls.
- Phase 13 writes the **test-migration checklist** that Phase 16 executes (~42 tests
  vanish, ~5 mutate, from a suite of 882).

### Claude's Discretion

- **A tap landing mid-animation reverses from the current animation value**
  (`AnimationController.reverse()`) — no queue, no input lockout. The owner expressed
  no preference; this is the default framework behaviour and therefore the least code.
- The exact composition of the test-migration checklist (format, per-suite contract
  capture) — the owner cares that it exists before anything is deleted, not what it
  looks like.
- Which five devices/viewports the inset discriminator tests drive, provided at least
  one is a 360dp-wide gesture-nav device with a raised IME (the case where a naive read
  yields an obviously wrong number).

</decisions>

<canonical_refs>
## Canonical References

**Downstream agents MUST read these before planning or implementing.**

### Design intent and its known drift
- `.planning/research/SUMMARY.md` §`Design-Note Drift` — **read this BEFORE the design
  note.** Four of the note's claims have drifted and two more are unverified (D1–D6).
- `.planning/notes/summon-bar-trackpad-keyboard.md` — the owner's original design
  decision, the two deliberate phase-08 reversals (D-10, D8-05, D8-06) and the five
  landmines. Read only after the drift section above.
- `.planning/research/SUMMARY.md` §`Reconciled Contradictions` (C1–C6) and
  §`The Animation Budget` — where the four researchers disagreed and which position won.

### Requirements and scope
- `.planning/REQUIREMENTS.md` — BAR-01..05, SUM-01..04, MOT-01 are this phase;
  §`Out of Scope` and §`Decisions Folded In` are binding.
- `.planning/ROADMAP.md` §`Phase 13: Summon Shell & Bar` — success criteria and the
  "Notes the plan must carry" block.
- `.planning/ROADMAP.md` §`Milestone-Wide Constraints` — zero new dependencies, no
  server/protocol change, not an IME resize contract, and the anti-feature list.

### Implementation detail
- `.planning/research/ARCHITECTURE.md` §4 — the derived inset arithmetic with five
  worked devices and the failure mode of each shortcut. §8 — the design-note audit.
- `.planning/research/PITFALLS.md` — P4 (hidden IME inside animating chrome), P8
  (`PopScope` interactions), P9 (jank is rebuild scope and `saveLayer`, not shaders),
  P12 (bar scope).
- `.planning/research/STACK.md` — the rejected-package list and why each fails on the
  same disqualifier.

### Code the phase touches or must not break
- `app/remote_control/lib/main.dart:112` — `MaterialApp` with **no `builder:`** today;
  the shell is a clean insertion point.
- `app/remote_control/lib/widgets/bubble_scaffold.dart:140-200` — the shape to
  re-payload: `Stack` + reactive `PopScope` via an outer `ValueListenableBuilder` whose
  cached `child` never rebuilds off the expand state, plus the top-anchored `UipiBanner`
  slot. Reuse the structure verbatim; the widget itself dies in Phase 16.
- `app/remote_control/lib/browser/browser_screen.dart:576` — the only other `PopScope`
  in `lib/`; see D-13-05.
- `app/remote_control/lib/hub/hub_screen.dart:286` — where `BubbleScaffold` wraps tool
  screens centrally today; `showBubble` lives at `:73/:80/:92`.
- `app/remote_control/android/app/src/main/AndroidManifest.xml` — no
  `enableOnBackInvokedCallback`; do not add one in this phase (D-13-01).
- `app/remote_control/test/theme_tokens_guard_test.dart` and
  `test/icons_guard_test.dart` — **these will fail the build** if new chrome uses
  anything but `kBg`/`kSurface`/`kHairline`/`kText`/`kMuted`/`kAccent`/`kError` and
  const `Symbols.*_rounded` icons. Never `Icons.`, never `Symbols.get()`.

</canonical_refs>

<code_context>
## Existing Code Insights

### Reusable Assets
- **`BubbleScaffold`'s reactive-`PopScope` pattern** (`bubble_scaffold.dart:152-172`):
  an outer `ValueListenableBuilder<bool>` whose `child` (the body) is built exactly once
  and never rebuilt by the notifier. This is the shape `SummonShell` should reuse
  verbatim — it already solves the "keep `canPop` reactive without rebuilding the body"
  problem that P9 warns about.
- **The `UipiBanner` slot** (`bubble_scaffold.dart:172-186`): top-anchored,
  `SafeArea(bottom: false)`, `IgnorePointer` inside the banner so it never steals a body
  touch. Phase 13 builds the slot in the shell; Phase 16 moves the only production mount
  into it (SAFE-03 — deleting `BubbleScaffold` without this silently removes the SRV-05
  advisory and no test catches it).
- **`connectionStatusProvider`** — already value-equal, already the pattern used by the
  header chip. The bar's disconnected treatment (D-13-13) rides this, not
  `ConnectionService.changes`.

### Established Patterns
- **Every screen already wraps its body in `SafeArea`** — verified across all 14
  screens. This is what makes the shell's "wrap the Navigator in a `MediaQuery` that
  adds `kSummonBarHeight` to bottom padding" trick reach every screen with **zero
  per-screen edits**. It is also why BAR-05 is provable without touching 14 files.
- **`kHubTiles` is an ordered registry** and IS the hub render order — Phase 17's
  concern, but the bar must not assume tile positions.
- Token and icon guards are enforced by tests, not convention (see canonical refs).

### Integration Points
- `main.dart:112` `MaterialApp` gains `builder:` → `SummonShell`. This is the single
  insertion point for the whole phase.
- `hub_screen.dart:286` `BubbleScaffold` wrap — stays for now (the bubble is retired in
  Phase 16, deliberately after Phase 14 so the owner never loses fast trackpad access).
  Phase 13 ships the bar and the bubble **side by side**; a temporary double affordance
  is the accepted cost.
- `browser_screen.dart:576` — the `PopScope` that must learn about the raised state.

</code_context>

<specifics>
## Specific Ideas

- The bar should read as **the edge of the screen**, not as a component sitting on it —
  hairline separation, background matching the page, icons carrying all the weight.
  "Ship the bar looking empty" taken literally.
- Deliberate emptiness is the point: two icons centered as a pair, with the dead width
  left visibly dead rather than filled.
- Simplicity was chosen over completeness on the orphan case (D-13-03): the owner
  preferred no ownership-transfer machinery even at the cost of the app exiting with a
  surface still raised. Read that as a general preference for less state in the host.

</specifics>

<deferred>
## Deferred Ideas

- **Enabling in-app predictive back properly** (declare
  `android:enableOnBackInvokedCallback="true"` and add
  `PredictiveBackPageTransitionsBuilder` to `buildAppTheme()`). Deliberately out of
  Phase 13 per D-13-01. If the spike's recorded baseline shows in-app route transitions
  have no predictive peek, that is a finding to file with the evidence attached — not
  work to absorb here.
- **Ownership transfer for an orphaned surface** — considered and declined (D-13-03).
  Revisit only if exiting the app with a surface raised proves annoying in dogfooding.
- **A third bar icon, user-reorderable icons, swipe-on-bar to switch surfaces** — v2+,
  per research's defer list.
- **Deleting either hub tile (HUBF-01)** — explicitly deferred beyond v1.1; must not be
  pulled forward.

</deferred>

---

*Phase: 13-Summon Shell & Bar*
*Context gathered: 2026-08-14*
