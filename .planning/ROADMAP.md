# Roadmap: Remote Control

## Milestones

- ✅ **v1.0 MVP** — Phases 1-12 (shipped 2026-08-12, released as `v1.6.3`)
- 🔵 **v1.1 The Summon Bar** — Phases 13-18 (started 2026-08-12, roadmapped 2026-08-13)

## Overview

**v1.1** is pure Flutter client UI: no Rust server work, no protocol change, no
`protoVersion` bump, and **zero new dependencies** — if a plan proposes editing
`pubspec.yaml`, that is a signal the plan drifted.

The journey is **host first, surfaces second, retirement third, polish last**, and that
shape is load-bearing. Phase 13 builds the shell, the bar and an *empty* correctly-sized
overlay, because the two things that are expensive to change later — the host shape and
the inset arithmetic — are entirely independent of what the overlay contains, and both
are invisibly wrong until a real device with gesture nav and a raised IME. It opens with
a spike, because the back-dismiss mechanism the whole dismiss vocabulary rests on is
unproven in this tree. Phase 14 then lands the **trackpad**, deliberately before the
keyboard: it is the half with no prior art and all the gesture risk, and it exercises the
whole overlay lifecycle with no IME entanglement, so a failure there is unambiguous.
Phase 15 adds the keyboard as a third mount point on a proven host with a proven dismiss
vocabulary. Only then does Phase 16 delete the bubble — retiring it any earlier would
leave the owner with no fast trackpad access for the duration of the milestone. Phases 17
and 18 are trivial in code and are last on purpose: the hub order pin and the chip-row
overflow tripwire are the two places where a careless migration silently reverts a
requirement, so each wants a deliberate, unhurried commit rather than a line in a large one.

## Phases

**Phase Numbering:**

- Phase numbering **continues** from v1.0 — v1.1 starts at Phase 13, it does not reset.
- Integer phases (13, 14, 15): Planned milestone work
- Decimal phases (13.1, 13.2): Urgent insertions (marked with INSERTED)

Decimal phases appear between their surrounding integers in numeric order.

<details>
<summary>✅ v1.0 MVP (Phases 1-12) — SHIPPED 2026-08-12 · 108 plans · 244 tasks</summary>

- [x] Phase 1: Protocol Contract & Server Core (8/8 plans) — completed 2026-07-07
- [x] Phase 2: End-to-End Cursor Spike (4/4 plans) — completed 2026-07-08 — hard gate PASS: p50 6ms / p95 10ms on real WiFi
- [x] Phase 3: Discovery, Pairing & Connection (7/7 plans) — completed 2026-07-09 — on-device E2E PASS, all five success criteria
- [x] Phase 4: Trackpad & Keyboard (10/10 plans) — completed 2026-07-10
- [x] Phase 5: Media, Power, Presenter & Browser (7/7 plans) — completed 2026-07-11
- [x] Phase 6: Apps & Clipboard (7/7 plans) — completed 2026-07-12
- [x] Phase 7: Server Shell, Dashboard & Polish (13/13 plans) — completed 2026-07-15
- [x] Phase 8: Floating Trackpad Bubble (6/6 plans) — completed 2026-07-16 — on-device UAT PASS
- [x] Phase 9: UI Refinement to Design Prototype (9/9 plans) — completed 2026-07-16
- [x] Phase 10: Keyboard Rethink & Shortcuts Tile (6/6 plans) — completed 2026-07-17
- [x] Phase 11: Browser Bookmarks (13/13 plans) — completed 2026-07-31
- [x] Phase 12: In-App Updates (18/18 plans) — completed 2026-08-08 — SC5 and SC7 observed on hardware

Full phase detail: [`milestones/v1.0-ROADMAP.md`](./milestones/v1.0-ROADMAP.md)
Requirements: [`milestones/v1.0-REQUIREMENTS.md`](./milestones/v1.0-REQUIREMENTS.md)
Audit: [`milestones/v1.0-MILESTONE-AUDIT.md`](./milestones/v1.0-MILESTONE-AUDIT.md)
Phase directories: [`milestones/v1.0-phases/`](./milestones/v1.0-phases/)

</details>

### v1.1 The Summon Bar (Phases 13-18)

- [ ] **Phase 13: Summon Shell & Bar** - The bar rides every screen and raises a correctly-sized *empty* overlay in place; host shape, inset arithmetic and the whole dismiss vocabulary are settled before any surface content exists
- [ ] **Phase 14: Raised Trackpad** - The trackpad raises over any screen and drives the PC cursor exactly as the full screen does, with a dismiss that can never fire from the pad body and never leaves a button held on the PC
- [ ] **Phase 15: Raised Keyboard** - The keyboard becomes a third mount point of the same four pads: types on the first keystroke from any screen, lands on the pad it was left on with no hop, and releases every modifier on dismiss
- [ ] **Phase 16: Bubble Retirement** - The floating bubble and its window are deleted outright, and everything they silently carried — the elevated-window advisory above all — has a new home before the delete lands
- [ ] **Phase 17: Hub Tiles & Bar Identity** - Both tiles survive at the end of the hub grid, and the bar marks the screen you are on as inert rather than hiding its icon
- [ ] **Phase 18: Chip Row & Measured Motion** - The chip row is *verified* at a real 360dp with the shipped font before anything is "fixed", the inverted overflow tripwire is corrected, and the motion budget becomes a recorded number

## Phase Details

### Phase 13: Summon Shell & Bar

**Goal**: A permanent two-icon bar rides every screen including the hub, and tapping an icon raises a correctly-sized *empty* overlay in place with a complete dismiss vocabulary — settling the host shape, the inset arithmetic, the bar's scope and the motion constants while the overlay still contains nothing that can confuse a failure
**Depends on**: Nothing (first phase of v1.1; builds on shipped v1.0 code)
**Requirements**: BAR-01, BAR-02, BAR-03, BAR-04, BAR-05, SUM-01, SUM-02, SUM-03, SUM-04, MOT-01
**Success Criteria** (what must be TRUE):

  1. A bottom bar carrying a trackpad icon and a keyboard icon is visible and geometrically identical on the hub and on all nine tool screens, and no screen's content is clipped or stranded behind it — including the browser tab list and the bookmarks section at 640dp height, and the already-scrolling hub grid
  2. Tapping a bar icon raises an empty surface over the current screen in 200ms without navigating away: nothing beneath it resizes, reflows or scrolls, a tappable widget on the screen outside the surface still receives its tap, and the bar stays visible and tappable the whole time because the surface sits **on top of** it — tapping the same icon lowers it in 150ms
  3. The Android back gesture lowers a raised surface instead of leaving the screen; with nothing raised, back still exits the app from the hub and predictive back still animates
  4. On the pairing sheet and the device list, the keyboard icon is visibly disabled while the PIN field holds focus — a pairing PIN can never be typed into the PC — and the bar is absent entirely from the QR scan screen
  5. On the owner's device, summon and dismiss feel quick at the frequency a permanent bar invites (this is what closes OQ-A1 sub-question 1; 200/150 is a one-constant change each if it does not)

**Research**: recommended — run `--research-phase`. Highest concentration of unverified premises in the milestone
**Plans**: 6/10 plans executed

Plans:
**Wave 1**

- [x] 13-01-PLAN.md — TRACER: pre-flight baseline + test-migration checklist, the app-scope shell, the per-route back guard, the D5 spike, and the BAR-05 reservation audit

**Wave 2** *(blocked on Wave 1 completion)*

- [x] 13-02-PLAN.md — The one shared derivation, the two-icon bar, the empty surface and its inert handle, mounted and raising end to end

**Wave 3** *(blocked on Wave 2 completion)*

- [x] 13-03-PLAN.md — Motion: 200/150 pinned by falsifiable timing, swap-in-place as one motion, and the single dismiss seam
- [x] 13-05-PLAN.md — The back vocabulary: the ownership scenario, the orphan case, and the predictive-back baseline
- [x] 13-06-PLAN.md — Browser one-thing-per-gesture: the predicate-conditional bookmarks back handler
- [x] 13-07-PLAN.md — Push-site coverage: one guarded seam, seven call sites, and a source-scanning guard
- [ ] 13-08-PLAN.md — The overlay contracts (outside taps land, nothing reflows) and the three named 640dp reach cases

**Wave 4** *(blocked on Wave 3 completion)*

- [ ] 13-04-PLAN.md — Geometry pinned on five driven viewports with four invariants and the F1/F2/F3/F4/F5 discriminators
- [ ] 13-09-PLAN.md — Bar state: the corrected keyboard focus gate and depth-counted QR suppression

**Wave 5** *(blocked on Wave 4 completion)*

- [ ] 13-10-PLAN.md — Hardware UAT: felt latency, the two heights, the resting tint and the back baseline, recorded

**UI hint**: yes

**Notes the plan must carry:**

- **D5 — spike first, before anything else.** The back-dismiss mechanism (SUM-04) is
  **unproven**: `PopScope` registers with the enclosing `ModalRoute`, and above the
  Navigator there is no route, so a shell-level `PopScope` is a **silent no-op** — no
  error, no warning, no log. Prove the per-route `SummonBackGuard` actually intercepts
  back from a route below a `MaterialApp.builder` shell, plus one `find.byType`
  assertion that the builder sits above the Navigator where the docs say. Two widget
  assertions. **If it fails the host shape changes, and this phase is the cheapest
  place to find that out.**

- **Never a static `PopScope(canPop: false)`.** Exactly one reactive `canPop: !raised`.
  The hub is the root route — a `canPop` that is false with nothing raised makes back
  stop exiting the app and the phone appears frozen on the dashboard. Multiple
  `PopScope`s in one subtree AND together: grep for existing ones before adding.

- **Derive the inset arithmetic; do not copy it.** A third mount context with two
  *opposite* failure modes. Do not reuse `kPanelMaxHeightFraction = 0.55` (a contract
  reserving room for a live trackpad that does not exist here) or
  `kPanelColumnOverhead = 122`. Read from the **ancestor** MediaQuery using
  `viewPaddingOf`, not `paddingOf`. `MediaQuery.removePadding(removeBottom: true)`
  around the overlay is **mandatory** — `KeyboardTabBar` carries its own `SafeArea`
  that contributed 0 in the docked panel and would silently add 24-48px of dead space
  here. Delete the `didChangeMetrics` observer rather than porting it. Pin with
  driven-viewport discriminator tests across five devices, where the naive read yields
  an obviously wrong number.

- **Write the test-migration checklist here, before anything is deleted** (Phase 16
  executes it). ~42 tests vanish and ~5 mutate from a suite of 882; four affected
  suites are named nowhere in the design note.

- **Two guards will fail the build if ignored:** new chrome must use the tokens from
  `theme/tokens.dart` and const `Symbols.*_rounded` icons — never `Icons.`, never
  `Symbols.get()`.

- **`pumpAndSettle` is banned for every timing assertion** in the new summon suites: it
  advances until no frames are scheduled, so a 200ms summon and a 900ms summon are
  indistinguishable. At least one test must assert the overlay is **not yet** at final
  geometry at t=100ms and **is** at t=250ms.

- Two-minute manifest check before planning: does the app already declare
  `android:enableOnBackInvokedCallback="true"`? If not, "don't regress predictive back"
  becomes "turn it on and verify it" — a different, larger task.

### Phase 14: Raised Trackpad

**Goal**: The trackpad is raised over any other screen and drives the PC cursor exactly as the full Trackpad screen does — the novel half of the milestone, with the gesture risk retired and nothing left welded down on the PC when it is dismissed
**Depends on**: Phase 13
**Requirements**: SURF-01, SUM-05, SUM-06, SAFE-02, RET-03
**Success Criteria** (what must be TRUE):

  1. With the trackpad raised over another remote's screen, cursor move, tap-to-click, left/middle/right click, two-finger scroll, drag and drag-lock behave exactly as they do on the full Trackpad screen
  2. **With the trackpad surface raised, 30 consecutive full-height downward one-finger cursor throws produce zero dismissals, and 30 consecutive two-finger downward scrolls produce zero dismissals**
  3. Dismissing the raised trackpad leaves nothing welded on: with drag-lock engaged, the PC's left mouse button is released so the next tap anywhere is a tap and not a drag; and the phone's screen returns to sleeping normally, while a Presenter show running underneath keeps its own keep-awake hold
  4. A 48dp drag handle is visible on the raised surface and dismisses it, including when driven by an accessibility service — alongside the same-icon tap and the system back gesture
  5. On the owner's device the full Trackpad screen is still a noticeably larger, more precise cursor surface than the raised one — the reason its hub tile survives

**Research**: not needed — the gesture rule is already recorded and implemented in this codebase (`floating_trackpad_window.dart:6-8, 16-23`), and `TrackpadCoreState.dismissed()` mirrors an existing method shape
**Plans**: TBD
**UI hint**: yes

**Notes the plan must carry:**

- **SAFE-02 must be in the same plan as the dismiss path, not a follow-up.**
  `TrackpadCore` flushes `DragMsg(end,left)` only in `dispose()`. Drag-lock deliberately
  survives the finger lift, so "drag-lock engaged, then dismiss" is the *normal* way a
  long drag ends — and the summon model makes dismiss the most frequent gesture in the
  app. A held left button corrupts drag-select in other apps and recovery is
  re-summon-and-tap or disconnect. Add `TrackpadCoreState.dismissed()` sharing one
  **idempotent** private flush with `dispose()`; do not rely on
  `TrackpadDriver.dispose()`, which deliberately sends nothing.

- **The trackpad UNMOUNTS on dismiss** (deliberate split policy — the keyboard in Phase
  15 stays mounted). It holds a process-wide ref-counted keep-awake hold acquired in
  `initState`; mounted-but-hidden means the screen never sleeps, on every screen, for
  the whole session — a battery bug with no symptom until the phone is hot. There is
  nothing visual to restore: the surface is a dot grid and a hint `Text`. **Record the
  split as a deliberate decision so nobody unifies it later.** Note also that a "fix"
  which calls `release()` on dismiss while leaving `acquire()` in `initState` will drop
  the Presenter's concurrent hold — include that regression test.

- **The dismiss gesture must never live on the surface body.** The trackpad is a raw
  `Listener` that never enters the gesture arena, so an ancestor `GestureDetector` wins
  uncontested after ~18dp of slop while the cursor has been moving since 10dp: every
  dismiss would nudge the PC cursor, **invisibly**, because the user is looking at the
  laptop. The 48dp handle is a spatially-disjoint **sibling** of the `Listener`, never
  an ancestor.

- `kSummonMaxHeightFraction` / `kSummonTrackpadFraction` are declared **design choices**
  and are movable by the owner on hardware. The proposed geometry is already better
  than the affordance being retired (363px of pad vs the retiring window's 234px on the
  reference device).

### Phase 15: Raised Keyboard

**Goal**: The keyboard becomes a third mount point of the same four pads on a proven host — typing works from any screen on the first keystroke, the surface returns to the pad it was left on with no visible hop, and every held or locked modifier is released on dismiss
**Depends on**: Phase 13 (host), Phase 14 (proven dismiss vocabulary, inherited verbatim)
**Requirements**: SURF-02, SURF-03, SURF-04, SAFE-01
**Success Criteria** (what must be TRUE):

  1. From any screen, the raised keyboard offers the same four pads — Type, Arrows, Numpad, Fn — swipeable and tappable, with the chip row and tab bar fully reachable above the Android IME and never rendered behind it
  2. Typing reaches the PC on the **first** keystroke after a summon, on every screen — including the first summon after app launch and after pushing a new route — with no dead first key and no visible IME re-animation
  3. Paging to Numpad, dismissing, then re-summoning lands on Numpad **on the first painted frame** with no hop, including the first summon after a cold launch
  4. Locking Shift (or any modifier) and then dismissing releases it on the PC — nothing stays physically held with no chip left on screen to release it
  5. The docked keyboard-over-live-trackpad panel and the full Keyboard screen still behave exactly as before — the shared deck extraction is behaviour-neutral

**Research**: recommended — run `--research-phase`. The inset arithmetic must be re-derived for a third context with two opposite failure modes, and pad restore across dismiss/re-summon is uncovered by any existing test
**Plans**: TBD
**UI hint**: yes

**Notes the plan must carry:**

- **D1 — SAFE-01 is NOT already satisfied. Do not scope it as "already done".** Quick
  `260812-tsw` shipped `KeyboardInputController.dismissed()`, but it has exactly **one**
  call site in all of `lib/` (`keyboard_panel.dart:244-249`, on the `expanded`
  true→false edge), and **`KeyboardScreen` never calls it at all** — and `KeyboardScreen`
  is the closer template for a bar-hosted deck. Under stay-mounted, neither `dispose()`
  nor `didUpdateWidget(expanded)` fires, and Shift stays physically welded down on the
  PC. Call `dismissed()` from the **host's visibility transition**, not from a
  widget-parameter edge, and add a mount-agnostic controller test that runs the *bar's*
  dismiss path end to end. **Warning sign:** `grep -rn "dismissed()" lib` still returns
  only `keyboard_panel.dart` after this phase ships.

- **D6 — pad restore is unverified and depends on framework behaviour, not on code.**
  `PageController(initialPage:)` is built once in `initState`; on remount the `PageView`
  attaches a fresh `ScrollPosition` and whether it lands on `_currentPage` depends on
  `PageStorage`/`keepScrollOffset`. No test covers "page to Numpad → collapse →
  expand". Today that path runs rarely; under a summon model it runs dozens of times per
  session. Make the restore **explicit** (post-frame `jumpToPage(_currentPage)` or a
  controller seeded to `_currentPage`) and pin it with a **first-frame** assertion.

- **The restore hop is a race, not a latency — measurement is the wrong tool.** The
  async prefs read is invisible when warm and visible when cold, so it will pass
  hardware UAT and fail in real use on the first summon after launch. **Hoist the prefs
  read to app start** into a synchronous in-memory value so the summon path reads memory
  and lays out correctly on frame one; `_pendingRestore` survives for cold start only.

- **Restore layout, reset input state.** Restore which surface was raised, which pad was
  showing, the geometry. Reset every held and locked modifier, released on the PC.
  Restoring a locked Ctrl would be restoring a hazard.

- The **keyboard host State stays MOUNTED** (its FSM, held-key set and hidden IME
  connection are load-bearing and cannot be rebuilt) — the deliberate opposite of Phase
  14's trackpad. Assert `HiddenTextInput` `State` **identity** across
  summon→dismiss→summon *and* across a route push, and that it is `findsOneWidget` while
  dismissed. `HiddenTextInput` must never sit inside `Offstage`/`Visibility` — add the
  source-scanning guard in the house style.

- Extract a shared `KeyboardDeck` (pads + chip row + tab bar, parameterised by a
  controller **and a height**) rather than making a third copy — a third copy is exactly
  what quick `260809-ipc` existed to delete. Introduce `summonPadHeight`; leave
  `panelPadHeight` untouched so the docked-panel guards at
  `trackpad_screen_test.dart:225-307` stay green as a regression net, and re-run
  `keyboard_panel_test.dart` unchanged to prove the extraction is behaviour-neutral.

- A **third** pad prefs key (`summonPadProvider`), not a shared one — the summon
  surface's usage profile (fast Type/Arrows bursts) differs from the full screen's
  (Numpad/Fn work), and sharing a key would make them yank each other's landing pad.

### Phase 16: Bubble Retirement

**Goal**: The floating trackpad bubble and its window are deleted outright — not toggled off — with every capability they silently carried rehomed **before** the delete lands, and every retiring test's contract accounted for rather than merely removed
**Depends on**: Phase 14 (the replacement must work first — deleting the bubble earlier leaves the owner with no fast trackpad access for the rest of the milestone)
**Requirements**: RET-01, SAFE-03
**Success Criteria** (what must be TRUE):

  1. No bubble appears on any screen and no floating trackpad window can be opened; the trackpad is reached only from the bar or from its hub tile, and no retired symbol survives anywhere in the tree
  2. The "input blocked — elevated window" advisory still reaches the user when the PC's foreground window is elevated — it now arrives from the shell rather than from the bubble scaffold
  3. A tappable widget on the screen underneath a raised surface still receives its tap — the single most valuable contract in the retiring suite, proved by its successor rather than deleted with it
  4. The full Flutter suite is green, with each deleted suite's header contract copied into its successor and ticked off, and the two orphaned prefs keys recorded as a knowing decision

**Research**: not needed — mechanical deletion against an explicit, enumerated reference list
**Plans**: TBD

**Notes the plan must carry:**

- **D3 — the retirement list under-counts, and one omission deletes a shipped feature.**
  `bubble_scaffold.dart:181` is the **only** production mount of `UipiBanner` in `lib/`.
  Deleting `BubbleScaffold` without rehoming the banner **silently deletes the SRV-05
  "input blocked — elevated window" advisory from the product, and no test catches it**
  (`uipi_banner_test.dart` builds the widget directly). **The rehoming must be in the
  same plan as the deletion — that is why SAFE-03 exists and why it lives in this phase.**

- Beyond `TrackpadBubble`, `FloatingTrackpadWindow` and `windowPositionProvider`, also
  delete `bubble_position.dart` / `bubblePositionProvider`, and `kBubbleSize` /
  `kBubbleEdgeInset` / `_bubbleAnchor` — **grep for these; the analyzer will not flag an
  unused public const.**

- **Execute Phase 13's migration checklist. Do not delete a file until its successor
  exists.** Copy each deleted suite's header contract block into its successor and tick
  every line. Four suites go (`trackpad_bubble_test.dart`, `window_position_test.dart`,
  `bubble_position_test.dart` and the bubble scaffold suite, ~42 tests) and
  `bubble_scaffold_test.dart` is rewritten into `summon_shell_test.dart`;
  `widget_test.dart` and `hub_offline_test.dart` must be re-run.

- Prefer a **recorded decision that the two orphaned prefs keys are knowingly orphaned**
  over migration machinery — but do record it: the app is sideloaded and updated in
  place, so "just reinstall" is not the delivery model.

- No `UI hint`: this phase deletes UI and rehomes one existing widget. It introduces no
  new visual design surface, so it needs no UI-SPEC.

### Phase 17: Hub Tiles & Bar Identity

**Goal**: Both hub tiles survive at the end of the grid, and the bar stops being shaped by which screen it is on — it marks the current screen's icon as inert instead of hiding it
**Depends on**: Phase 16
**Requirements**: RET-02
**Success Criteria** (what must be TRUE):

  1. On the hub, Trackpad and Keyboard are the **last two** tiles in the grid, and both still open their full screens — neither tile is deleted
  2. On the Trackpad screen the bar's trackpad icon reads as "you are here" — selected and inert — while the keyboard icon stays live, and vice versa on the Keyboard screen; the bar never changes shape from screen to screen
  3. The hub order guard asserts the **new** order with a rationale written for it — the stale "the trackpad is always first in the registry" pin is gone, not re-satisfied

**Research**: not needed — one enum, one provider, two test updates
**Plans**: TBD

**Notes the plan must carry:**

- **D4 — this is the phase where the requirement gets silently reverted.**
  `test/hub/hub_screen_test.dart:22-35` carries an *unlisted* order pin asserting "D-02:
  the trackpad is the full-width primary tile — always first in the registry", and its
  **rationale is already stale** (the primary row died in 07-13). It will fail for the
  right reason with a wrong explanation — which is exactly how a migration gets "fixed"
  by re-pinning Trackpad to index 0 and quietly reverting RET-02. Update it with a *new*
  rationale; do not re-pin.

- **A mechanical `showBubble` → `showBar` rename is wrong three ways** and produces a bar
  **absent from the Trackpad screen — the one screen where the *keyboard* icon is most
  valuable.** `showBubble` dies with the window; it is attached to the *tile that creates
  the route* rather than to the screen it describes; and hiding an icon changes the bar's
  shape from screen to screen, contradicting "permanent bottom bar". Replace it: the
  screen declares what it *is* (`SummonSurface` + `activeSurfaceProvider`) and the bar
  renders the matching icon **selected-and-inert**. The original intent survives verbatim
  — *never a shortcut to the screen you are on* — only the mechanism moves.

- Use a depth-counted / last-writer-wins stack for `activeSurfaceProvider`, not a naive
  set/clear: on push, the new route's `initState` runs while the old route is still
  mounted, and on pop, `dispose` runs *after* the transition.

- **RET-02's justification is RET-03, verified in Phase 14.** If the full Trackpad screen
  did not remain meaningfully more precise than the raised one, the tile-survival
  rationale evaporates — check that Phase 14 closed it before planning this.

- **HUBF-01 (deleting either tile) is explicitly deferred and must not be pulled
  forward.** Deleting a tile is a one-line follow-up; un-deleting one is not.

- No `UI hint`: registry ordering plus an icon state that already exists in the design
  language. No new visual surface.

### Phase 18: Chip Row & Measured Motion

**Goal**: The modifier chip row is *verified* on a real 360dp viewport with the shipped font before anything is changed, the inverted overflow tripwire is corrected so a future fix cannot read as a regression, and the animation budget stops being a spec value and becomes a recorded one
**Depends on**: Phase 15 (the fix must land on all three keyboard surfaces at once)
**Requirements**: CHIP-01, CHIP-02, MOT-02
**Success Criteria** (what must be TRUE):

  1. The chip row is checked on a real 360dp-wide viewport with the **shipped** font on all three keyboard surfaces — the raised surface, the docked panel and the full Keyboard screen — and shows no *user-visible* overflow. **"No fix was needed" is a legitimate outcome:** if the 7.3px turns out to be a widget-test-font artifact, the honest result is a recorded finding and a font-independent guard, not a `FittedBox` bolted onto three surfaces that shrinks labels the owner can currently read fine
  2. The overflow guard asserts that **no** overflow occurs rather than that a non-zero overflow drain exists, and `KeyboardScreen` — unguarded today — gains a 360dp guard too, so a correct layout can never make the suite red for being correct
  3. A 20-cycle summon/dismiss trace that **includes the first summon after app launch** is recorded in VERIFICATION with worst-frame UI and raster times — a number, not a "felt smooth" note — and on the owner's device the motion stays smooth across that run

**Research**: not needed — the fix is layout arithmetic and the instructions are already written verbatim
**Plans**: TBD
**UI hint**: yes

**Notes the plan must carry:**

- **C6 — this phase OPENS WITH VERIFICATION, not implementation.** The 7.3px is measured
  under the Flutter widget-test font, where every glyph advances a full em (`Shift` = 5 ×
  16px = 80dp against a 74dp cell). With the shipped Material face at 16/w600, `Shift`
  measures roughly half that. The suite's reference device is also 411×891, where even
  the *test* font fits. Verify first; scope the fix second, if at all.

- **D2 — the tripwire is in the WRONG FILE relative to the design note.** It is
  `test/trackpad/trackpad_screen_test.dart:291-304`, **not** a keyboard suite;
  `modifier_chip_test.dart` contains no overflow handling at all. A plan that greps the
  keyboard suites will conclude the tripwire does not exist.

- **The tripwire is INVERTED — "repairing" it back to green silently un-fixes the bug.**
  It asserts `expect(overflows, greaterThan(0))`. When the chip row is fixed, **that test
  fails with `Expected: a value greater than <0> / Actual: <0>`, and that failure is the
  PASS signal.** The correct response is to delete lines 291-304 and replace them with
  `expect(t.takeException(), isNull)`. **Explicitly forbidden:** changing it to
  `greaterThanOrEqualTo(0)`; wrapping it in a conditional; deleting the assertion but
  keeping the drain; marking it `skip:`. Each makes the suite green while leaving the
  overflow undetected forever. **The fix and the test replacement must be the same
  commit**, or the suite goes red for the right reason and looks like a regression. Also
  update the `expectColumnFits` comment block at `:178-186` and close item 1 in
  `260809-ipc/deferred-items.md`.

- Jank here is **not** shader compilation — Impeller has been default on Android API 29+
  since 3.27 and precompiles its set. The real causes are rebuild scope and `saveLayer`.
  Never subscribe the bar to `ConnectionService.changes`; watch the value-equal
  `connectionStatusProvider`. The bar needs no `Timer.periodic`.

- `pumpAndSettle` remains banned for timing assertions in the summon suites.

## Progress

| Phase | Plans Complete | Status | Completed |
|-------|----------------|--------|-----------|
| 13. Summon Shell & Bar | 6/10 | In Progress | - |
| 14. Raised Trackpad | 0/TBD | Not started | - |
| 15. Raised Keyboard | 0/TBD | Not started | - |
| 16. Bubble Retirement | 0/TBD | Not started | - |
| 17. Hub Tiles & Bar Identity | 0/TBD | Not started | - |
| 18. Chip Row & Measured Motion | 0/TBD | Not started | - |

## Requirement Coverage

**25 of 25 v1.1 requirements mapped. 0 unmapped. No requirement appears in two phases.**

| Phase | Requirements | Count |
|-------|--------------|-------|
| 13 | BAR-01, BAR-02, BAR-03, BAR-04, BAR-05, SUM-01, SUM-02, SUM-03, SUM-04, MOT-01 | 10 |
| 14 | SURF-01, SUM-05, SUM-06, SAFE-02, RET-03 | 5 |
| 15 | SURF-02, SURF-03, SURF-04, SAFE-01 | 4 |
| 16 | RET-01, SAFE-03 | 2 |
| 17 | RET-02 | 1 |
| 18 | CHIP-01, CHIP-02, MOT-02 | 3 |

Full traceability: [`REQUIREMENTS.md`](./REQUIREMENTS.md) `## Traceability`.

## Milestone-Wide Constraints

These apply to every phase and are cheap to state once:

- **Zero new dependencies.** `pubspec.yaml` is unchanged by this milestone. Every
  primitive needed already ships in the pinned Flutter 3.44.5 SDK. Every candidate
  package — and `OverlayPortal`, `showModalBottomSheet`, `DraggableScrollableSheet` and
  raw `OverlayEntry` too — fails on the *same* disqualifier: route- or portal-based, so
  it destroys its child's State on dismiss, breaking both the restore requirement and
  the Android IME connection. If a plan proposes editing `pubspec.yaml`, that is a
  signal the plan drifted; challenge it before merging.

- **No server, protocol or extension change.** Client-side Flutter only. No
  `protoVersion` bump, therefore no two-sided release coupling for this milestone.

- **Not an IME-style resize contract.** Nothing on the phone is the input target — every
  keystroke and cursor delta goes to the PC, so there is no field to keep visible.
  Converting "raise in place" into a resize/inset contract solves a problem this app does
  not have, at the cost of making every tool screen scrollable. A planner who "improves"
  this is regressing it.

- **Anti-features a planner must not re-derive:** a scrim; swipe-down-anywhere-to-dismiss;
  filling the bar's dead width with more actions (it becomes a second hub); keeping the
  bubble as a fallback toggle; multi-height peek/expanded surfaces; nested `Navigator`;
  auto-dismiss on inactivity, disconnect or screen change; long-press/double-tap
  alternates on the bar icons; hide-on-scroll for the bar; haptics on summon/dismiss
  (haptics in this app mean *something happened on the PC* — do not muddy that signal).
  **Ship the bar looking empty. Exactly two icons.**

## Next

Plan Phase 13 with `/gsd-plan-phase 13 --research-phase`. Its first plan must be the
back-dismiss spike (D5) — if `SummonBackGuard` does not intercept back from a route below
a `MaterialApp.builder` shell, the host shape changes, and Phase 13 is the cheapest place
in the milestone for that to happen.

Design and its landmines: [`notes/summon-bar-trackpad-keyboard.md`](./notes/summon-bar-trackpad-keyboard.md)
(read `research/SUMMARY.md` `## Design-Note Drift` first — four of the note's claims have
drifted). Research: [`research/SUMMARY.md`](./research/SUMMARY.md).
