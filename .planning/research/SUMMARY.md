# Project Research Summary

**Project:** Remote Control — milestone **v1.1 "The Summon Bar"**
**Domain:** Flutter (Android) client UI restructuring — a persistent bottom bar that raises the trackpad and keyboard as in-place overlays. **Pure client-side. No Rust server work, no protocol change, no `protoVersion` bump.**
**Researched:** 2026-08-12
**Confidence:** HIGH on codebase facts, MEDIUM on two load-bearing framework behaviours, MEDIUM on competitor/UX claims

---

## Executive Summary

This milestone replaces a floating trackpad bubble with a permanent two-icon bottom bar that raises the trackpad or the keyboard **as an overlay over whatever screen is already showing** — nothing beneath resizes, reflows or scrolls, and dismissal is not a navigation event.

Research converged hard on three things. First, **no new dependencies are needed or wanted**: every primitive required (`Stack`/`Positioned`, `AnimationController`, `Offstage`/`Visibility(maintainState:true)`, `PopScope`, raw `Listener`) already ships in the pinned Flutter 3.44.5 SDK, and every candidate package — `smooth_sheets`, `sheet`, `modal_bottom_sheet`, `DraggableScrollableSheet`, `showModalBottomSheet`, `OverlayPortal` — is disqualified by the *same* mechanism: it is route-based or portal-based and therefore **destroys its child's State on dismiss**, which breaks both "restore where it was" and the Android IME input connection. Second, the keyboard half is heavily precedented (8 of 9 surveyed remote apps raise a keyboard in place from a persistent toggle icon), while the **trackpad-raised-as-an-overlay has essentially zero prior art** — that is the novel, risky half and should be built and dogfooded first. Third, **the dismiss gesture must never live on the surface body.** The trackpad is a raw `Listener` that never enters the gesture arena, so any ancestor `GestureDetector` wins uncontested after ~18dp of slop while the cursor has already been moving since 10dp: every dismiss would nudge the PC cursor. Worse, the user is looking at the laptop, so a false dismiss fires *invisibly*. Dismiss = tap the same bar icon (primary) + system back (secondary) + a 48dp drag handle (discoverability/a11y). Never the body, on either surface.

The dominant correctness risk is **physical state left welded down on the PC.** Two symmetric bugs: a LOCKED modifier surviving a dismiss (fixed for the docked panel by quick `260812-tsw` via `KeyboardInputController.dismissed()`, but that method has exactly **one** call site in `lib/`, and `KeyboardScreen` never calls it), and its untouched twin — an engaged **drag-lock leaving the PC's left mouse button held**, because `TrackpadCore` flushes `DragMsg(end,left)` only in `dispose()`. Both are safe today only because *every* dismiss is currently an unmount; the summon bar breaks that equivalence. The resolution is a **split mount policy**: the keyboard host State stays mounted (its FSM, held-key set and hidden IME connection are load-bearing and cannot be rebuilt) with an explicit `dismissed()` call on the hide edge; the trackpad **unmounts** (it has nothing visual to restore and holds a process-wide keep-awake ref-count that would otherwise pin the screen awake for the whole session, on every screen).

The single highest-risk, highest-value unknown is the **inset arithmetic for a third mount context**. The docked panel reads raw window metrics (`MediaQueryData.fromView(View.of(context))`) because its ancestor `MediaQuery` was stripped twice by `Scaffold(resizeToAvoidBottomInset)` and `SafeArea`. A shell mounted above the Navigator sits in the *opposite* situation — unstripped insets, automatic rebuilds — so copying the formula is wrong architecturally even where it is right numerically, and reusing the panel's `0.55` fraction and `kPanelColumnOverhead = 122` is wrong numerically too. Research produced a full derivation with five worked devices; it must be pinned by driven-viewport discriminator tests **before** any surface content exists. That, plus the host-shape decision, is why phase 1 is "shell + bar + empty, correctly-sized overlay".

---

## Design-Note Drift — READ THIS BEFORE PLANNING ANY PHASE

`ARCHITECTURE.md §8` audited `.planning/notes/summon-bar-trackpad-keyboard.md` against the working tree at `master @ 7c9ecf8`. **Four of its claims have drifted or are under-counted, and two more are unverified.** Planning a phase against the note as written will plan against a wrong premise.

**D1 — Landmine #1 is ALREADY FIXED; the note has drifted.**
The note says a LOCKED modifier surviving a dismiss is open with "its own todo". In fact quick `260812-tsw` shipped `KeyboardInputController.dismissed()` (`keyboard_input_controller.dart:143-146`), its call site (`keyboard_panel.dart:244-249`) and two tests; the todo is in `.planning/todos/done/`, and `260809-ipc/deferred-items.md#2` is now **stale**.
*Consequence:* it is **not zero work for v1.1.** The third mount point must *call* `dismissed()` on its own hide edge — and `dismissed()` has exactly **one** call site in all of `lib/`; `KeyboardScreen` never calls it at all. Do not scope this as "already done".

**D2 — Landmine #4's overflow tripwire is in the WRONG FILE.**
The note implies a keyboard suite (`modifier_chip_test.dart`). It is actually `test/trackpad/trackpad_screen_test.dart:291-304`; `modifier_chip_test.dart` contains no overflow handling.
*Consequence:* the chip-row phase must edit the *trackpad* suite. A plan that greps the keyboard suites will conclude the tripwire does not exist.

**D3 — The retirement list under-counts by 2 symbols, and one omission deletes a shipped feature.**
Beyond `TrackpadBubble`, `FloatingTrackpadWindow` and `windowPositionProvider`: `bubble_position.dart` / `bubblePositionProvider` becomes fully dead, and **`UipiBanner` loses its only production mount** — `bubble_scaffold.dart:181` is the sole `UipiBanner.forService` call site in `lib/`.
*Consequence:* deleting `BubbleScaffold` without rehoming the banner **silently deletes the SRV-05 "input blocked — elevated window" advisory from the product.** No test catches it (`uipi_banner_test.dart` builds the widget directly). Rehoming must be in the same plan as the deletion. Also delete `kBubbleSize` / `kBubbleEdgeInset` / `_bubbleAnchor` — the analyzer will not flag an unused public const, so grep.

**D4 — The test scope under-counts by 4 files, one of which is where the requirement gets silently reverted.**
Also affected: `trackpad_bubble_test.dart`, `window_position_test.dart`, `bubble_position_test.dart` (13 tests, named nowhere in the note), and **`test/hub/hub_screen_test.dart:22-35`** — an *unlisted* order pin asserting "D-02: the trackpad is the full-width primary tile — always first in the registry", whose rationale is **already stale** (the primary row died in 07-13). Plus `widget_test.dart` and `hub_offline_test.dart` to re-run. Net: ~42 tests vanish and ~5 mutate, from a suite of 882.
*Consequence:* the migration checklist must be written in phase 1, **before** anything is deleted. `hub/hub_screen_test.dart` will fail for the right reason with a wrong explanation — which is exactly how a migration gets "fixed" by re-pinning Trackpad to index 0 and quietly reverting the requirement.

**D5 — The back-gesture mechanism is NOT verified in code.**
`PopScope` registers with the enclosing `ModalRoute`; above the Navigator there is no route, so it is a **silent no-op** — no error, no warning, no log. The thin per-route `SummonBackGuard` is the proposed answer but has not been proven.
*Consequence:* **spike it in phase 1.** One widget test settles it. This is the single item most likely to invalidate the chosen host shape.

**D6 — Pad restore across dismiss/re-summon is NOT verified.**
`PageController(initialPage:)` is built once in `initState`; on remount the `PageView` attaches a fresh `ScrollPosition`, and whether it lands on `_currentPage` depends on `PageStorage`/`keepScrollOffset`, not on explicit code. **No test covers "page to Numpad → collapse → expand".** Today that path runs rarely; under a summon model it runs dozens of times per session.
*Consequence:* treat as a real risk, not a theoretical one. Make the restore explicit (post-frame `jumpToPage(_currentPage)`, or a controller seeded to `_currentPage`) and pin it with a **first-frame** assertion.

**Two note claims that hold up:** "the bar rides the hub too" is cheap and safe under an app-scope shell and is contradicted by nothing in the tree (FEATURES offers weak evidence *against* — no surveyed competitor puts input access on its home surface — worth one deliberate on-device check, not a blocker); and "~4-6 plans" matches the 6 plans scoped below.

---

## Reconciled Contradictions

The four researchers could not see each other's work. These are the places they disagree, stated openly with a recommendation.

### C1 — Where the bar mounts (the biggest one)

| Position | Argument |
|---|---|
| **STACK:** a shared shell widget each screen composes, **inside** the `MaterialPageRoute` (the existing `BubbleScaffold` seam, re-payloaded). Explicitly **rejects** `MaterialApp.builder`. | `PopScope` is a *silent no-op* without a `ModalRoute` ancestor (`pop_scope.dart:196`), and back-to-dismiss (D8-08) is a locked contract. Above the Navigator the bar would also paint over the sensitivity sheet, the power confirm dialog and the pairing sheet. |
| **ARCHITECTURE:** `SummonShell` at **`MaterialApp.builder`** (above the Navigator) **plus** a ~20-line per-route `SummonBackGuard` carrying the `PopScope`. | One mount reaches every route including the hub. Decisively: it yields **exactly one `KeyboardInputController` for the process.** A per-route shell means N controllers — lock Shift on the hub, tap a tile, and Shift stays physically held on the PC with no chip anywhere to release it. That is the `260812-tsw` bug resurrected at a scope no test covers. |
| **FEATURES:** "root-level `Overlay`/`OverlayPortal` above the root Navigator". | Makes "nothing beneath resizes" free and avoids nested-`Navigator` predictive-back breakage (flutter/flutter#139903). |
| **PITFALLS (P8a/P12):** an app-level host is acceptable **only with** an explicit route allowlist and an app-shell back handler; otherwise prefer per-route wrapping. | An app-level host appears over the pairing dialog and QR scanner by default. |

**Recommendation: ARCHITECTURE's hybrid — app-scope `SummonShell` at `MaterialApp.builder`, with a thin per-route `SummonBackGuard` carrying the `PopScope`.** It is the only shape that satisfies STACK's objection (the guard *is* inside a `ModalRoute`) while capturing the one-controller-per-process property, which is a **correctness** requirement, not tidiness. Two costs the roadmapper must fund: (a) the guard is **unproven — spike it in phase 1** (D5); (b) route suppression is real work (C5).

**Do NOT use `OverlayPortal`** as FEATURES loosely suggests — its docs state verbatim that `hide()` removes the overlay child and *"stateful descendants… may lose states as a result."* FEATURES was reasoning about resize and predictive back, not state survival. STACK and ARCHITECTURE both rule it out; they win.

### C2 — Mount policy on dismiss

**PITFALLS (headline):** keep the subtree **MOUNTED** for both surfaces, and pay for it with an explicit `dismissed()` contract on every stateful owner plus visibility-driven `KeepAwake`. Rationale: the no-jump and IME requirements are non-negotiable.

**STACK + ARCHITECTURE (agreeing independently):** **split policy** — keyboard host State mounted, **trackpad unmounts**. Rationale: `TrackpadCore` acquires a process-wide ref-counted keep-awake hold in `initState` and releases it in `dispose`; mounted-but-hidden means **the screen never sleeps, on every screen, for the whole session** — a battery bug with no symptom until the phone is hot. And there is *nothing visual to restore*: the surface is a dot grid and a hint `Text`; the cursor lives on the PC. Rebuild cost is two plain object allocations, one `listenManual` seed, one subscription. No I/O, no async, no prefs read.

**Recommendation: the split policy.** Two researchers reached it independently from different evidence, and PITFALLS' own P10 documents the wakelock trap that makes a mounted trackpad wrong. PITFALLS' contribution survives intact and is essential: **P2 (`TrackpadCoreState.dismissed()` for the drag-lock flush) is still required** — because "unmount on dismiss" is a policy a future optimiser will quietly reverse, and because the flush must be idempotent between dismiss and teardown regardless. Record the split as a deliberate decision so nobody unifies it.

### C3 — Extract a shared keyboard deck?

**ARCHITECTURE:** mandatory (AP-6). `keyboard_panel.dart:332-375` and `keyboard_screen.dart:276-317` are already near-identical `PageView`s over the same four pads; a third copy is exactly what `260809-ipc` existed to delete, and `key_pads.dart:361-365` says so outright.
**PITFALLS:** reusing `KeyboardPanel` verbatim inherits the `dismissed()` wiring for free but drags the trackpad-specific raw-view read and the `0.55` column reservation into a context with no trackpad — acceptable *only* if the height function is replaced at the same time.
**STACK:** neutral.

**Recommendation: extract `KeyboardDeck`** (pads + chip row + tab bar, parameterised by a `KeyboardInputController` and a height) **and pass the height in.** That satisfies both: no third copy, and the overlay supplies its own `summonPadHeight` rather than inheriting `panelPadHeight`. Leave `panelPadHeight` untouched so the docked-panel guards at `trackpad_screen_test.dart:225-307` stay green as a regression net. Re-run `keyboard_panel_test.dart` (20 tests) unchanged to prove the extraction is behaviour-neutral.

### C4 — Dismiss vocabulary

All four agree on the core: **tap the same bar icon (primary) + system back (secondary), and NEVER a swipe on the surface body.** All agree the trackpad's raw `Listener` never enters the arena, so an ancestor `GestureDetector` wins uncontested. The divergence is minor: FEATURES makes a 48dp handle a required third route (M3 `BottomSheetDragHandleView` — a11y services can drive it, and it is the visual signal that the surface is dismissable rather than navigated-to); PITFALLS ranks it second-preference; STACK permits it strictly as a spatially-disjoint **sibling** of the `Listener`, never an ancestor.

**Recommendation: ship all three routes, handle included, as a sibling.** The extra cost is one widget; the discoverability and a11y payoff is real, and without it a raised trackpad reads as navigation — undoing the milestone's premise. **The bar must stay pinned and visible while a surface is raised, with the surface's bottom edge sitting on top of the bar, never under it** — otherwise the primary dismiss is occluded.

Carry FEATURES' falsifiable acceptance test verbatim into phase 2's success criteria:
> With the trackpad surface raised, 30 consecutive full-height downward one-finger cursor throws starting at the top of the pad produce **zero** dismissals, and 30 consecutive two-finger downward scrolls produce zero dismissals.

### C5 — What "every screen" means

**ARCHITECTURE:** the arithmetic handles the two local-`TextField` screens correctly with no special-casing (the bar floats above the local IME; the field-bearing screen resizes above the bar), so keep the bar there and suppress only `QrScanScreen` — suppression logic is more risk than the noise it removes.
**PITFALLS (P12):** define an explicit **allowlist** (hub + 9 tool screens). `pairing_dialog.dart` and `device_list_screen.dart` are the only two files in `lib/` with a real `TextField`; `HiddenTextInput`'s focus request would steal focus from the PIN field and **the user's 6-digit PIN gets typed into the PC**, into whatever window has focus on the laptop. That is a pairing failure with a security smell.

**Recommendation: the bar renders everywhere (ARCHITECTURE's geometry argument holds), but the *keyboard icon* is gated on `FocusManager.instance.primaryFocus` being null, and `QrScanScreen` is suppressed entirely.** This is PITFALLS' own fallback suggestion and it is strictly better than screen-identity allowlisting — it stays correct for any future screen that gains a `TextField`. **The gated/excluded set and its reasons must be written into phase 1's context**, not discovered during execution. This is a requirements decision the roadmapper should surface to the owner.

### C6 — The chip-row 7.3px overflow

**FEATURES + PROJECT.md** list "the 7.3px overflow fixed on both keyboard surfaces" as a P1 table-stakes requirement.
**PITFALLS (P5) contradicts the premise:** the 7.3px is measured **under the Flutter widget-test font**, where every glyph advances a full em (`Shift` = 5 × 16px = 80dp against a 74dp cell). With the shipped Material face at 16/w600, `Shift` measures roughly half that and fits with room to spare. The owner's device is also not 360dp wide — the suite's reference device is 411×891, where the cell is ~86.75dp and even the *test* font fits.

**Recommendation: verify before fixing.** Phase 6 opens with a check on a real 360dp-wide viewport with the shipped font. If no user-visible overflow exists, the honest outcome is to make the guard font-independent (or close the deferred item as "test-font artifact") — **not** to bolt a `FittedBox` onto three surfaces and shrink labels the owner can currently read fine. Either way the inverted tripwire must be resolved (Pitfall 5).

---

## The Animation Budget — one number, with its source

| Motion | Budget | Source / rationale |
|---|---|---|
| **Summon** | **200 ms** | Incumbent, not a proposal: `kBubbleExpandDuration` (`bubble_scaffold.dart:50`), `KeyboardPanel`'s `AnimatedSize` (`keyboard_panel.dart:425-427`) and the pad-tab page animation all already run 200 ms. It sits inside the ~230 ms Model-Human-Processor visual-perception band, so it reads as *movement* rather than a cut; below ~150 ms it starts reading as a pop or a glitch. Reuse the constant — do not introduce a second one. |
| **Dismiss** | **150 ms** | FEATURES' recommendation: dismissals should feel like *getting out of the way*, not like a transition. The one deliberate departure from the incumbent, and a one-constant change. |
| **Restore ("no visible jump")** | **ZERO FRAMES** — ~16.7 ms at 60 Hz, ~8 ms at 120 Hz | A **different problem**, and conflating it with the 100 ms response limit is the mistake to avoid. NN/g's 100 ms governs *response to input*; "no visible jump" is **change detection on already-painted content**, perceptible far below 100 ms. The budget is zero frames: the surface must lay out correctly on frame one. |
| **Worst-frame raster / UI** | recorded from a 20-cycle profile trace | PITFALLS P9 requires a number in VERIFICATION, not a "felt smooth" note. |

**Dissent and constraints to honour.** PITFALLS offers no competing number but adds *teeth*, and its proposed test shape assumes 200 ms symmetric — adjust it: at least one test must assert the overlay is **not yet** at final geometry at t=100 ms and **is** at t=250 ms for summon, with the dismiss window tightened to the 150 ms budget. **`pumpAndSettle` is banned for every timing assertion** in the new summon suites: it advances until no frames are scheduled, so a 200 ms summon and a 900 ms summon are indistinguishable (the suite already uses it 95 times, 45 of those in `keyboard_panel_test.dart` alone). Use explicit `pump(Duration(...))` steps — the shape already at `trackpad_screen_test.dart:217-222`.

**The structural half matters more than the number.** FEATURES' key insight: *do not measure whether the async-prefs restore hop is visible.* It is visible when the read is cold and invisible when it is warm — so it will pass hardware UAT (warm) and fail in real use (first summon after launch). **Measurement is the wrong tool for a race.** Hoist the prefs read out of the summon path: read pad state once at app start into an in-memory value, so the summon path reads memory and lays out correctly on frame one. `_pendingRestore` stays, but *only* for cold start.

**On-device UAT is the gate, not the numbers.** The owner asked for a pinned budget with hardware judgement closing the phase. 200/150 is the spec value; if it feels slow at dozens-of-summons-per-session frequency, it is a one-constant change.

---

## OQ-A1 Status — "What is 'quick' for summon and dismiss, in ms?"

*(Reported only — `questions.md` was not edited.)*

| Sub-question | Status | Answer / disposition |
|---|---|---|
| **1.** Is 200 ms right for a gesture repeating dozens of times per session? | **OPEN — narrowed** | Proposed **200 ms summon / 150 ms dismiss**, grounded in the ~230 ms perception band and the existing house vocabulary. Cannot be closed by research — it is a felt-latency judgement. **Close it in phase 1's UAT on the owner's device.** |
| **2.** Does the async prefs pad-restore produce a visible jump on re-summon? | **SETTLED — structurally** | Yes, intermittently (cold read) — and it is a **race, not a latency**. Resolution: hoist the prefs read to app start into a synchronous in-memory value, plus an explicit `jumpToPage(_currentPage)` on the summon edge. Pin with a **first-frame** test: page to Numpad → dismiss → summon → `find.byType(NumpadPad)` findsOneWidget on frame one. Related risk **D6** (whether `PageStorage` restores the offset at all) is unverified — treat as real. |
| **3.** Restore full prior state, or reset? | **SETTLED** | **Restore layout; reset input state.** Restore: which surface was raised, which pad was showing, surface geometry. Reset: all held/locked modifiers, released on the PC. *Layout* is what "quick" means to the user; *input state* is what "safe" means. Nobody expects a modifier to survive a dismiss they performed deliberately, and restoring a locked Ctrl would be restoring a hazard. This settles landmine #1's interaction in one rule. |
| **4.** Is there a first-summon-per-screen cost distinct from later summons? | **SETTLED — by construction** | Once the prefs read is hoisted (sub-q 2) there is no distinct first-summon cost: the expensive part happened before either. With an app-scope shell the controller and hidden IME field are also constructed once per process, not per screen. Verify by including the *first* summon after launch in the 20-cycle profile trace. |

---

## Key Findings

### Recommended Stack

**Zero new dependencies. `pubspec.yaml` is unchanged by this milestone — if a plan proposes editing it, that is a signal the plan drifted; challenge it before merging.** Every candidate package fails on the *same* disqualifier: route-based and portal-based sheets destroy their child's State on dismiss, breaking both the no-jump requirement and the Android input connection. Verified against the pinned SDK source on disk: `ModalBottomSheetRoute extends PopupRoute`; `Scaffold.didUpdateWidget` calls `_closeCurrentBottomSheet()` the moment `bottomSheet` goes null; `OverlayPortal`'s own docs state stateful descendants may lose state on hide.

**Core (all already present):**
- **Flutter 3.44.5 / Dart 3.12.2** (pinned, confirmed on disk) — no language or SDK feature needed beyond what is in use
- **`Stack` + `Positioned`** — the only primitive that overlays without touching the body's constraints, keeps the child mounted, and stays where `PopScope` can work
- **`AnimationController` + `SlideTransition`** — prefer transform-based transitions over `AnimatedOpacity`/`AnimatedPositioned`; `Opacity` on a half-screen surface forces a `saveLayer` every frame, and `AnimatedPositioned` re-lays-out every frame
- **`Offstage` / `Visibility(maintainState: true)`** — keyboard only. Offstage children *"can receive focus and have keyboard input directed to them"* — exactly the property landmine #3 depends on. `Visibility` composes `TickerMode + Offstage`, giving ticker suppression for free
- **`PopScope` with `canPop: !raised`** — never a static `false` (Pitfall 4)
- **raw `Listener`** (trackpad hot path, unchanged) and **`GestureDetector`** (handle only, always a sibling)
- **`flutter_riverpod` 3.3.2** (locked; 3.4.2 exists — bump only as a separate quick task, never inside a UI-restructuring phase)

**Explicitly rejected:** `smooth_sheets`, `sheet`, `modal_bottom_sheet`, `sliding_up_panel`, `flutter_animate`, `go_router`/`ShellRoute`, `persistent_bottom_nav_bar`, `OverlayPortal`, raw `OverlayEntry`, `showModalBottomSheet`, `DraggableScrollableSheet`, `Dismissible`, `auto_size_text`, `flutter_keyboard_visibility`, `keyboard_actions`, `provider`/`get_it`.

**Two guards will fail the build if ignored:** new bar/overlay chrome must use `kBg`/`kSurface`/`kHairline`/`kText`/`kMuted`/`kAccent`/`kError` from `theme/tokens.dart` (`test/theme_tokens_guard_test.dart`) and const `Symbols.*_rounded` icons — never `Icons.`, never `Symbols.get()` (`test/icons_guard_test.dart`). Tell the implementer up front so it is not discovered as a mystery failure.

### Expected Features

**Must have (table stakes):**
- Keyboard raises in place from a persistent toggle icon — 8 of 9 surveyed apps do exactly this; users arrive trained
- Tap the same icon again to dismiss — *the* toggle vocabulary in this category (Microsoft's connection bar, Roku, Steam Link)
- Bar stays visible and tappable while a surface is raised; the surface sits **on top of** the bar, never under
- Back / back gesture dismisses the raised surface **before** popping the route — Android already does this for the IME; not doing it reads as a bug
- Predictive back still works when nothing is raised — default-on from Android 14; regressing it is a whole-app downgrade
- 48dp drag handle on the raised surface (M3 minimum; a11y-drivable; the signal that this is a surface, not a screen)
- Restore which keyboard pad was showing, **on frame one** — the wrong pad means a **wrong keystroke into a PC app**. Destructive, not cosmetic
- Release all held/locked modifiers on dismiss
- `ModifierChip` row fits at 360dp — *subject to C6's verify-before-fix*
- Nothing beneath resizes, scrolls or is pushed
- A stated, measured animation budget

**Should have (differentiators):**
- **Trackpad raised as an overlay over another remote's screen** — no surveyed app does this; the actual novel claim of v1.1, and it carries all the gesture risk
- One bar summoning **both** surfaces with an identical dismiss vocabulary
- Zero-frame synchronous state restore
- Active-state icon showing which surface is raised (what makes tap-to-dismiss legible rather than a guess)
- Bar reaches the hub too

**Defer (v1.2+):** delete the Keyboard hub tile (explicitly deferred by the design note — do not pull forward); remember the last-raised surface across launches; landscape-specific geometry. **v2+:** a third bar icon; user-reorderable icons; swipe-on-bar to switch surfaces.

**Anti-features — a planner must not re-derive these:** a resize/inset contract (nothing on the phone is the input target); swipe-down-anywhere-to-dismiss; a scrim; filling the bar's dead width with more actions (it becomes a second hub); keeping the bubble as a fallback toggle; multi-height peek/expanded surfaces; static `PopScope(canPop: false)`; nested `Navigator`; auto-dismiss on inactivity/disconnect/screen-change (the user is looking at the laptop — on reconnect they want the surface exactly where it was); long-press/double-tap alternates on the bar icons; hide-on-scroll for the bar; haptics on summon/dismiss (haptics in this app mean *something happened on the PC* — do not muddy that signal). **Ship the bar looking empty. Exactly two icons.**

### Architecture Approach

An app-scope `SummonShell` mounted at `MaterialApp.builder` owns a `Stack` containing: the Navigator (wrapped in a `MediaQuery` that adds `kSummonBarHeight = 56` to bottom padding — which reserves the bar for **all 14 screens with zero per-screen edits**, because every screen already wraps its body in `SafeArea`); the rehomed `UipiBanner` slot; an unconditional 1x1 `Positioned` `HiddenTextInput`; the raised surface; and the bar. A thin per-route `SummonBackGuard` carries the `PopScope`. This is a **deliberate, documented amendment to D-95** ("ownership IS lifecycle"): the `KeyboardInputController` moves up from the surface to the shell, because under a summon model the *surface* is no longer the thing whose lifetime matches the model's. Record it as such so a future reader does not "restore" the old rule.

**Major components:**
1. **`lib/shell/summon_shell.dart` (NEW)** — the bar, the overlay slot, the inset arithmetic, the hidden IME field, the `KeyboardInputController`, the banner slot, the `ValueNotifier<SummonSurface?>`
2. **`lib/shell/summon_bar.dart` (NEW)** — two const-icon actions, geometrically identical on every screen
3. **`lib/shell/summon_back_guard.dart` (NEW, ~20 lines)** — the per-route `PopScope`, `canPop: !raised`
4. **`lib/keyboard/keyboard_deck.dart` (NEW, extracted)** — pads + chip row + tab bar, taking a controller and a height; mounted by all three surfaces
5. **`summonPadProvider` + `kSummonPadPrefsKey`** (~12 lines in `key_rows.dart`) — a **third** pad key, following D-94's reasoning ("one model, three mount-point keys"): the summon surface's usage profile (fast Type/Arrows bursts) differs from the full screen's (Numpad/Fn work), so sharing a key would make them yank each other's landing pad
6. **`SummonSurface` enum + `activeSurfaceProvider`** — the replacement for `showBubble`; use a depth-counted / last-writer-wins stack, not a naive set/clear, because on push the new route's `initState` runs while the old route is still mounted, and on pop `dispose` runs after the transition

**The inset arithmetic, derived (not copied):**

```
available       = S - viewPaddingOf.top - max(viewPaddingOf.bottom, viewInsetsOf.bottom) - kSummonBarHeight
barBottomOffset = max(Pbot, Ibot)      // never double-counts: the IME draws OVER the nav bar
```

Read from the **ancestor** MediaQuery (unstripped at `builder`), using `viewPaddingOf` not `paddingOf` (`padding.bottom` collapses to 0 while the IME is up). **Delete the `didChangeMetrics` observer** — at the shell the MediaQuery is not value-equal across the IME animation, so rebuilds are automatic; porting the observer gives two rebuilds per IME frame on the hottest surface in the app. Then, **mandatory**: `MediaQuery.removePadding(removeBottom: true)` around the overlay, because `KeyboardTabBar` carries its own `SafeArea` that contributed 0 in the docked panel (an ancestor had already stripped it) and would silently add 24-48px of dead space here — the single most likely way to get this subtly wrong. **Do not reuse `kPanelColumnOverhead = 122`** — its `+1` is the docked panel's in-Column IME sliver; the shell's field is a `Positioned` sibling costing zero layout. **Do not reuse `kPanelMaxHeightFraction = 0.55`** — that fraction is a contract reserving room for the *live trackpad beneath*, which does not exist here; `0.75` is proposed for the keyboard overlay as an explicit **design choice** (legibility: an overlay that fills the screen has become a screen), movable by the owner on hardware. Five worked devices and the failure mode of each shortcut are in `ARCHITECTURE.md` section 4.

**`showBubble: false` becomes `activeSurfaceProvider`.** A mechanical port fails three ways: its second call site dies with the window (leaving a `bool` field set once — a constant, not a parameter); it is attached to the *tile that creates the route* rather than to the screen, which is what the property actually describes; and hiding an icon changes the bar's shape from screen to screen, contradicting "permanent bottom bar". Replacement: the screen declares what it *is*, and the bar renders the matching icon **selected-and-inert** ("you are here") rather than hiding it. The intent survives verbatim — *never a shortcut to the screen you are on* — while the mechanism moves from "hide an affordance, decided by the tile" to "mark it inert, decided by the screen". **This matters concretely: a mechanical `showBubble` to `showBar` rename produces a bar absent from the Trackpad screen — the one screen where the *keyboard* icon is most valuable.**

### Critical Pitfalls

1. **A LOCKED modifier survives a summon dismiss.** The `2779ecf` fix put the release in the right place (`_flushHolds()`, shared by `dispose()` and `dismissed()`) but wired it to exactly one *trigger*: `keyboard_panel.dart:248`, on the `expanded` true-to-false edge. **`KeyboardScreen` never calls `dismissed()` at all** — and it is the closer template for a bar-hosted deck. Under Stay-Mounted, neither `dispose()` nor `didUpdateWidget(expanded)` fires, and Shift stays physically welded down on the PC with no chip on screen to release it. **Avoid:** call `dismissed()` from the *host's visibility transition*, not from a widget-parameter edge; add a mount-agnostic controller test that goes through the bar's dismiss path end-to-end. **Warning sign:** `grep -rn "dismissed()" lib` still returns only `keyboard_panel.dart:248` after the summon surface ships.

2. **The trackpad has the identical bug and it was NEVER fixed — a dismissed drag-lock leaves the PC's LEFT MOUSE BUTTON held.** `TrackpadCore` flushes `DragMsg(end,left)` only in `dispose()`. Drag-lock deliberately survives the finger lift (it exists for screen-edge drags), so "drag-lock engaged, then dismiss" is the *normal* way a long drag is performed — and the summon model makes dismiss the most frequent gesture in the app. Every subsequent tap anywhere becomes a drag; recovery is re-summon-and-tap or disconnect. **Strictly worse than #1** — a held left button corrupts drag-select in other apps. The code comment claiming the flush "fires on both window collapse AND screen pop" is true *only* because collapse is currently an unmount. **Avoid:** add `TrackpadCoreState.dismissed()` sharing one idempotent private flush with `dispose()`; do not rely on `TrackpadDriver.dispose()` (it deliberately sends nothing).

3. **The pad-height clamp is copied instead of re-derived** — a third inset context with two *opposite* failure modes. Copy the arithmetic into an unstripped host and the `0.55` ceiling makes the summoned Numpad visibly shorter than the same Numpad on the full Keyboard screen, with ~45% of the screen empty for no reason (nobody reports it; it just feels cramped). Use the ancestor MediaQuery inside a route `Scaffold` instead, and `viewInsets` returns **zero** for the IME, so the chip row and tab bar render *behind* the Android keyboard, untappable — and the resulting `MediaQueryData` is value-equal across the IME animation, so no rebuild is even scheduled. **Avoid:** document the host's inset context next to the height call; introduce `summonPadHeight` rather than reusing `panelPadHeight`; write discriminator tests where the naive read yields an obviously wrong number (model: `trackpad_screen_test.dart:256-274`).

4. **A static `PopScope(canPop: false)` on a bar that is on every screen disables predictive back app-wide.** Official docs: *"Android's predictive back feature will not animate when this boolean is false."* Also: the hub is the **root route** (`main.dart:116`) — a `canPop` that is false with nothing raised makes back stop exiting the app, and the phone appears frozen on the dashboard. And multiple `PopScope`s in one subtree **AND** together, so any pre-existing per-screen `PopScope` interacts with the bar's — audit before adding (a 5-minute grep). **Avoid:** exactly one reactive `canPop: !raised` driven by the live notifier, reusing the `bubble_scaffold.dart:152-165` shape verbatim (an outer `ValueListenableBuilder` whose cached `child` is the body).

5. **The 7.3px chip-row overflow test is INVERTED — "repairing" it back to green silently un-fixes the bug.** `trackpad_screen_test.dart:291-304` asserts `expect(overflows, greaterThan(0))`. When the chip row is fixed, **that test fails with `Expected: a value greater than <0> / Actual: <0>`, and that failure is the PASS signal.** The correct response is to **delete lines 291-304** and replace them with `expect(t.takeException(), isNull)`. **Explicitly forbidden:** changing to `greaterThanOrEqualTo(0)`; wrapping in a conditional; deleting the assertion but keeping the drain; marking `skip:`. Each makes the suite green while leaving the overflow undetected forever. The fix and the test replacement must be the **same commit**, or the suite goes red for the right reason and looks like a regression. Also update the `expectColumnFits` comment block at `:178-186` and close item 1 in `260809-ipc/deferred-items.md`. **Read C6 above before spending a plan on the fix at all.**

**Also carry:** P4 (hidden IME inside the animating chrome — presents as *no IME on first summon*, a visible IME re-animation, **and** a dropped/mis-diffed first keystroke via the ZWSP baseline; catchable in a widget test by asserting `HiddenTextInput` `State` identity across summon-dismiss-summon, plus a source-scanning guard in the house style banning `HiddenTextInput` inside `Offstage`/`Visibility`); P7 (gesture arena — C4); P9 (jank: **not** shader compilation — Impeller has been default on Android API 29+ since 3.27 and precompiles its set; the real causes are rebuild scope and `saveLayer`. Never subscribe the bar to `ConnectionService.changes`; watch the value-equal `connectionStatusProvider`. The bar needs no `Timer.periodic`); P10 (wakelock — and note the "fix" that calls `release()` on dismiss while leaving `acquire()` in `initState` will **drop the Presenter's concurrent hold**); P11 (coverage loss); P13 (orphaned prefs keys — the app is sideloaded and updated in place, so "just reinstall" is not the delivery model; prefer a recorded decision that the two keys are knowingly orphaned over migration machinery).

---

## Implications for Roadmap

Six phases. The shape — **host first, surfaces second, retirement third, polish last** — is the load-bearing part; P3, P4 and P7 are all cheap to prevent and expensive to retrofit once the host shape is chosen.

### Phase 1: Shell + bar, empty overlay
**Rationale:** the inset arithmetic is the highest-risk, highest-value unknown, it is entirely independent of what the overlay *contains*, and getting it wrong is invisible until a real device with gesture nav and a raised IME. An empty panel with a derived height, driven through five viewports, retires that risk before a single line of surface code exists. This phase also **decides** everything expensive to change later: host shape, dismiss vocabulary, `showBubble` semantics, bar scope, rebuild scoping, and the test-migration checklist.
**Delivers:** `SummonShell` at `MaterialApp.builder`; `SummonBar` (two const icons); `SummonBackGuard`; the derived inset arithmetic + `kSummonBarHeight = 56`; the rehomed `UipiBanner` slot; the unconditional hidden IME field; `test/shell/summon_shell_test.dart`.
**Addresses:** docked toolbar on every screen incl. hub; bar visible while raised; back dismisses before popping; predictive back preserved; nothing beneath resizes.
**Avoids:** P4 (host shape determines whether the IME field can be a sibling at all — P4 recovery is a host rewrite), P8 (reactive `canPop`), P9a/9b (rebuild scoping is structural), P12 (the scope decision determines the host shape), P6 (semantics), P11 (checklist written before anything is deleted).
**Must include a spike (D5):** prove `SummonBackGuard` actually intercepts back from a route below a `MaterialApp.builder` shell, and that the builder sits where the docs say. Two widget assertions. If it fails, the host shape changes — and phase 1 is the cheapest place to find out.
**Demo:** the bar is on the hub and all 9 tool screens; nothing beneath is clipped or reflowed; tapping an icon raises a correctly-sized empty panel in 200 ms; back dismisses it; back with nothing raised still exits from the hub.

### Phase 2: Trackpad surface
**Rationale:** the novel half — no prior art, all the gesture risk — and it exercises the full overlay lifecycle (mount, dismiss, unmount, keep-awake, drag flush) with **no IME involved**, so a failure is unambiguous. Doing the keyboard first would entangle overlay-lifecycle bugs with IME-connection bugs.
**Delivers:** the trackpad surface in the overlay slot (unmount-on-dismiss); `TrackpadCoreState.dismissed()`; the 48dp handle as a `Listener` sibling; visibility-driven keep-awake.
**Avoids:** P2 (drag-lock — in the *same plan* as the dismiss path, not after), P7 (gesture arena), P10 (wakelock; include the Presenter-concurrency regression test).
**Success criterion to carry verbatim:** the 30-throw / 30-scroll zero-dismissal test from C4.

### Phase 3: Keyboard third mount point
**Rationale:** depends on phase 1's host and inherits phase 2's proven dismiss vocabulary verbatim. Height must be settled before any pad content is wired.
**Delivers:** the extracted `KeyboardDeck`; `summonPadProvider`; the controller at shell scope; `summonPadHeight`; synchronous pad restore with an explicit first-frame landing.
**Avoids:** P1 (wire `dismissed()` through the *bar's* dismiss path end-to-end), P3 (two discriminator tests), P4 (`State` identity across summon/dismiss/**route push**; `findsOneWidget` while dismissed), D6 (`PageController` restore).
**Demo:** type on any screen; lock Shift, dismiss and the PC releases it; page to Numpad, dismiss, re-summon and it lands on Numpad with **no hop, on frame one**.

### Phase 4: Retire the bubble
**Rationale:** cannot precede phase 2 — deleting it first leaves the owner with no fast trackpad access on tool screens for the duration of the milestone. Keeping both briefly costs nothing but a temporary double affordance.
**Delivers:** deletion of `TrackpadBubble`, `FloatingTrackpadWindow`, `BubbleScaffold`, `window_position.dart`, **`bubble_position.dart`** (D3), `kBubbleSize`/`kBubbleEdgeInset`/`_bubbleAnchor`; deletion of 4 test suites; rewrite of `bubble_scaffold_test.dart` into `summon_shell_test.dart`; the recorded orphaned-prefs decision.
**Avoids:** P11 (execute the phase-1 checklist — copy each deleted suite's header contract block into its successor and tick every line; **do not delete a file until its successor exists**), P13 (grep each deleted symbol; the analyzer will not flag an unused public const).
**The single most valuable test in the milestone must survive in spirit:** `bubble_scaffold_test.dart:11-16, 155-185` — *a tappable widget in the body OUTSIDE the raised surface still receives a tap.* That is what proves "overlay, not screen".

### Phase 5: Hub tile reorder + `showBubble` re-read
**Rationale:** trivial and independent, but it touches the order pins a careless migration reverts. Do it late, deliberately.
**Delivers:** `SummonSurface` + `activeSurfaceProvider`; `HubTileSpec.showBubble` deleted; Trackpad and Keyboard moved to the **end** of `kHubTiles` (neither deleted); `hub_tiles_test.dart` and **`test/hub/hub_screen_test.dart:22-35`** updated with a *new* rationale, not re-pinned to Trackpad-first.
**Avoids:** P6, D4.

### Phase 6: Chip row at 360dp + measured budget
**Rationale:** must land on all three keyboard surfaces at once, so it depends on phase 3. **Opens with verification, not implementation** (C6).
**Delivers:** the verify-before-fix check on a real 360dp viewport with the shipped font; either a font-independent guard or the layout fix; deletion of the inverted drain and its replacement with `expect(takeException(), isNull)`; a 360dp guard added to `KeyboardScreen` (today unguarded); the recorded animation budget from a 20-cycle profile trace.
**Avoids:** P5 (the explicit forbidden-responses list belongs in the plan text, not just in research), P9 (measurement with teeth).

### Phase Ordering Rationale
- **Host before surfaces:** the host shape determines whether the hidden IME field can be a sibling of the animating chrome at all, and whether `PopScope` works (D5). Everything else is retrofit-cheap; these are not.
- **Trackpad before keyboard:** no prior art + all the gesture risk + no IME entanglement. If the summon vocabulary fails, it fails on one surface rather than two.
- **Retirement after replacement:** the owner keeps fast trackpad access throughout.
- **Tiles and chip row last:** both are trivial in code and both are where a migration silently reverts a requirement, so each wants a deliberate, unhurried commit.

### Research Flags

**Needs `--research-phase` during planning:**
- **Phase 1** — the highest concentration of unverified premises: the `MaterialApp.builder` ordering claim and the `PopScope`/`ModalRoute` registration claim are both seam-classified LOW (webfetch provider) despite being official API docs; `SummonBackGuard` is unproven; and the bar-scope decision (C5) is a requirements question with a security edge that should reach the owner.
- **Phase 3** — the inset arithmetic must be re-derived for a third context with two opposite failure modes, and `PageController` restore across dismiss/re-summon (D6) is uncovered by any existing test.

**Standard patterns — skip research:**
- **Phase 2** — the gesture rule is already recorded and implemented in this codebase (`floating_trackpad_window.dart:6-8, 16-23`, "RESEARCH Pitfall 2"); `TrackpadCoreState.dismissed()` mirrors an existing method shape.
- **Phase 4** — mechanical deletion against an explicit, enumerated reference list.
- **Phase 5** — one enum, one provider, two test updates.
- **Phase 6** — the fix is layout arithmetic; the instructions are already written verbatim.

---

## Confidence Assessment

| Area | Confidence | Notes |
|---|---|---|
| Stack | **HIGH** | Every behavioural claim cross-checked against the pinned Flutter 3.44.5 SDK source **on disk** (`material/scaffold.dart:1040-1155, 2418-2430, 2841`, `material/bottom_sheet.dart:870`, `widgets/pop_scope.dart:171-215`, `widgets/visibility.dart`) — the exact code that will compile. Package currency from the pub.dev registry API. |
| Features | **MEDIUM** | Vendor docs read directly for Microsoft, Roku, Apple, Flutter, Android and M3. **Nothing was checked against a running copy of any competitor app** — Remote Mouse and Steam Link claims are secondary/community. Where certainty about a competitor's exact behaviour matters, the cheap move is to install it, not to re-research it. The perceptual-threshold numbers are sound; the 200/150 recommendation is a judgement on top of them. |
| Architecture | **HIGH / MEDIUM split** | HIGH for everything cited to `file.dart:line` (read from the working tree at `master @ 7c9ecf8`). **MEDIUM for the two framework behaviours the whole host shape rests on** — `MaterialApp.builder`'s position above the Navigator, and `PopScope`'s `ModalRoute` registration. Both are official API docs; both are seam-classified LOW because the seam cannot see which URL was fetched. Both are provable with **one widget test each**. |
| Pitfalls | **HIGH** | Every codebase claim cites a file:line or a commit SHA and was read directly, including the `2779ecf` diff and the 882-test suite inventory. MEDIUM for the two external claims (Impeller defaults, predictive-back animation) — web-sourced, cross-checked, not verified on this hardware. |

**Overall confidence: HIGH**, with the caveat that the host shape rests on two MEDIUM-confidence framework claims. That is exactly why phase 1 opens with a spike.

### Gaps to Address

- **`SummonBackGuard` is unproven (D5).** *Handle:* one widget test in phase 1's first plan. If back does not intercept from a route below a `MaterialApp.builder` shell, the host shape changes — and phase 1 is the cheapest place for that to happen.
- **`MaterialApp.builder` ancestor ordering is doc-sourced, not tree-verified.** *Handle:* one `find.byType` assertion alongside the same spike.
- **`PageController` page restore across dismiss/re-summon (D6) is uncovered by any test.** *Handle:* make the restore explicit rather than relying on `PageStorage`; pin with a first-frame assertion in phase 3.
- **Whether the 7.3px chip overflow exists at all outside the widget-test font (C6).** *Handle:* verify on a real 360dp viewport with the shipped font as the first step of phase 6, before scoping the fix.
- **Does the app already declare `android:enableOnBackInvokedCallback="true"`?** If not, predictive back was never on, and "don't regress it" becomes "turn it on and verify it" — a different, larger task. *Handle:* a 2-minute manifest check before planning phase 1.
- **How many existing `PopScope`/`WillPopScope` usages are there?** They AND with the bar's. *Handle:* a 5-minute grep in phase 1.
- **Where exactly does the raised surface's top edge land?** The full-screen Trackpad screen must remain meaningfully *more* precise than the raised one, or the tile-survival rationale evaporates. The proposed geometry is already better than the affordance being deleted (363px of pad vs the retiring window's 234px on the reference device). *Handle:* owner judgement on hardware; `kSummonMaxHeightFraction` and `kSummonTrackpadFraction` are declared design choices, movable.
- **Bar scope over the pairing dialog / device list / QR scanner (C5).** *Handle:* a requirements decision in phase 1, with the security reasoning (PIN typed into the PC) surfaced to the owner.
- **The animation budget is a spec value, not yet a measured one.** *Handle:* on-device UAT closes OQ-A1 sub-question 1; the 20-cycle profile trace produces the recorded number. **A SUMMARY on disk is not an outcome.**
- **Tool screens that were tight before the bar's 56px.** `hub_screen.dart:376` already scrolls; `browser_screen`'s tab list and bookmarks section should be re-checked at 640dp height. *Handle:* add to phase 1's UAT.

---

## Sources

### Primary (HIGH confidence)
- **Pinned Flutter SDK source on disk, `/c/dev/flutter` @ 3.44.5** — scaffold body-vs-bottomSheet layout and persistent-sheet teardown, `ModalBottomSheetRoute extends PopupRoute`, `PopScope`'s `ModalRoute.of` registration, `Visibility` = `TickerMode + Offstage`
- **Working tree `app/remote_control/` at `master @ 7c9ecf8`** — every `file.dart:line` citation across ARCHITECTURE.md and PITFALLS.md, read directly
- **Git history** — `2779ecf` (quick `260812-tsw`, locked-modifier release, full diff read), `18346b3` (quick `260812-uq8`, 5s reliable-queue TTL)
- api.flutter.dev — `OverlayPortal` (hide removes the child; stateful descendants may lose state), `Offstage`, `TickerMode`, `PopScope.canPop`
- pub.dev JSON API (2026-08-12) — currency of all seven evaluated packages
- Microsoft Learn (Remote Desktop Android client features), Roku Support, Apple Support (tvOS keyboard), Unified Remote Quick Switch, Google Chrome Remote Desktop help
- developer.android.com — Back dismisses the IME before navigating; `BottomSheetDragHandleView` (48dp, a11y, tap/double-tap)
- m3.material.io — bottom sheets; navigation bar (3-5 destinations)
- NN/g — Response Time Limits (the 0.1 s instantaneous limit)
- `.planning/notes/summon-bar-trackpad-keyboard.md`, `.planning/PROJECT.md`, `.planning/STATE.md`, `.planning/MILESTONES.md`, `.planning/research/questions.md`, `260809-ipc/deferred-items.md`

### Secondary (MEDIUM confidence)
- docs.flutter.dev — predictive back requirements and breaking changes (Android 13 + `enableOnBackInvokedCallback`; 14 default-on)
- Val Head, "How fast should your UI animations be?" — Model Human Processor ~230 ms; the 200 ms / 500 ms bounds
- flutter/flutter#161687 (cannot switch drag priority mid-gesture), #139903 (nested Navigator breaks predictive back)
- Impeller default on Android API 29+ since Flutter 3.27; precompiled shader set
- 9to5Google — M3 Expressive docked toolbar replaces the deprecated bottom app bar
- TechPP / Google Play listing (Remote Mouse), MakeUseOf + KDE UserBase (KDE Connect), XDA (Google TV app)

### Tertiary (LOW confidence — needs validation)
- Steam Community touch-controller guide (keyboard-button placement advice) — community, unverified against the shipping app
- **Confidence-seam honesty note:** the `classify-confidence` seam returns LOW for the `webfetch` provider generically, because it cannot see which URL was fetched. Several claims graded HIGH/MEDIUM above are webfetch-sourced from *official* Flutter and Android documentation. The two that are **load-bearing** — `MaterialApp.builder` ordering and `PopScope`'s `ModalRoute` registration — are called out in Gaps with the cheap proof (one widget test each) rather than being quietly upgraded.

---
*Research completed: 2026-08-12*
*Ready for roadmap: yes*
