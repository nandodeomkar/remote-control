# Pitfalls Research

**Domain:** Adding a persistent overlay-summon surface (trackpad + keyboard) to a shipped, well-tested Flutter/Riverpod app with a real-hardware side effect (a Windows PC that physically holds keys and mouse buttons)
**Researched:** 2026-08-12
**Confidence:** HIGH for every codebase claim (each cites `file.dart:line` or a commit SHA and was read directly). MEDIUM for the two external Flutter-platform claims (P9, P8b), which are web-sourced and cross-checked but not verified on this hardware.

---

## Read this first: one decision drives five of the pitfalls

Almost every correctness pitfall below collapses to a single architectural
choice the planner must make **explicitly, in the first phase**:

> **When the summon surface is dismissed, is its subtree UNMOUNTED, or kept
> mounted and hidden?**

The milestone's own requirements pull in opposite directions:

| Requirement | Pushes toward |
|---|---|
| "re-summoning restores the surface where it was… with no visible jump" (PROJECT.md:31) | **keep mounted** |
| "the hidden IME input must stay mounted… or Android tears down the input connection" (design note landmine 3) | **keep mounted** |
| a LOCKED modifier must be released on dismiss (`KeyboardInputController.dispose` is the release) | **unmount** |
| an engaged drag-lock must send `DragMsg(end,left)` on dismiss (`trackpad_core.dart:205`) | **unmount** |
| the wakelock must be released on dismiss (`trackpad_core.dart:209`) | **unmount** |

Today the codebase gets away with this because *every* dismiss is an unmount:
`BubbleScaffold`'s collapse swaps `FloatingTrackpadWindow` out of the tree
(`bubble_scaffold.dart:186-213`), which unmounts `TrackpadCore`, which is why
`trackpad_core.dart:204` can claim "This fires on both window collapse AND
screen pop". The summon bar breaks that equivalence.

**Recommended resolution (carry into the roadmap):** keep the subtree MOUNTED
(the jump and IME requirements are non-negotiable and untestable-on-CI
respectively), and pay for it with an **explicit dismiss contract** — a
`dismissed()`-style hook on every stateful owner, wired from the one place that
knows about visibility. `KeyboardInputController.dismissed()` already exists
(`keyboard_input_controller.dart:143`); `TrackpadCore` has **no equivalent and
needs one**; `KeepAwake` needs to be driven by visibility, not by mount.

---

## Critical Pitfalls

### P1: A LOCKED modifier survives a summon-bar dismiss — the `2779ecf` fix does NOT automatically cover the new path

**Verdict on the existing fix (the question's explicit ask):**

`2779ecf` (quick `260812-tsw`) put the release in the right *place* but wired it
to exactly one *trigger*.

- The release logic is `KeyboardInputController._flushHolds()`
  (`keyboard_input_controller.dart:165-175`), shared by `dispose()` (`:116`)
  and the new `dismissed()` (`:143`). Because it lives in the D-95 single owner,
  **both keyboard surfaces inherit it by construction** — the commit message
  says so ("reaches both keyboard surfaces and the future summon bar by
  construction").
- **But `dismissed()` has exactly one call site in the entire tree:**
  `keyboard_panel.dart:248`, inside `didUpdateWidget`, on the
  `widget.expanded` true→false edge (`:230-250`). Verified by grep: `lib/`
  contains the declaration and that one call, nothing else.
- **`KeyboardScreen` never calls `dismissed()` at all.** Its only teardown is
  `dispose()` (`keyboard_screen.dart:164-174`). And `KeyboardScreen` — four
  pads + chip row + tab bar + hidden IME outside the `PageView` — is the
  *closer template* for a bar-hosted deck than the docked panel is.

So the fix covers the new dismiss path **if and only if** one of these is true:

1. the summon overlay hosts `KeyboardPanel` and drives dismissal through its
   `expanded` flag (`didUpdateWidget` fires → `dismissed()`); **or**
2. the summon overlay fully unmounts the keyboard subtree on dismiss
   (`dispose()` fires → same `_flushHolds()`).

It does **not** cover the case the "no visible jump" requirement pushes an
implementer toward: a keyboard deck built on the `KeyboardScreen` shape, kept
mounted behind an `Offstage` / `Visibility` / zero-opacity / zero-height
wrapper. In that case neither `dispose()` nor `didUpdateWidget(expanded)` runs,
the `ModifierFsm` keeps its locked state, and `Shift` stays physically welded
down on the PC with no chip on screen to release it — **the exact bug
`2779ecf` fixed, fully restored, via a different door.**

**Why it happens:** the fix's trigger is a *widget-parameter edge*, not a
*visibility event*. Nothing in the type system or the test suite forces a new
mount point to declare "I was dismissed".

**How to avoid:**
- Make the summon host own a single `ValueNotifier<SummonTarget?>` (or
  equivalent) and **call `KeyboardInputController.dismissed()` from the host's
  hide transition**, not from a widget's `didUpdateWidget`. If the host reuses
  `KeyboardPanel`, forward the host's visibility into `expanded` so the
  existing edge still fires — and assert that with a test.
- Add a controller-level test that is **mount-agnostic**: construct the
  controller, `chipLongPress(Mod.win)`, call the surface's dismiss entry point,
  assert `up:WinLeft` on the send seam. The three existing tests
  (`test/keyboard/keyboard_input_controller_test.dart:240-310`) already do this
  for `dismissed()`; the new one must go through the **bar's** dismiss path,
  end-to-end, so a missing wire fails.
- Port the two behavioural widget tests added by `2779ecf`
  (`test/keyboard/keyboard_panel_test.dart`, the `down:WinLeft` / no-`up`
  assertions) to the summon surface **verbatim in shape**.

**Warning signs:**
- `grep -rn "dismissed()" lib` returns only `keyboard_panel.dart:248` after the
  summon surface ships — that means the new surface never wired it.
- On hardware: lock `Win`, dismiss, then use the trackpad — every click becomes
  a `Win`+click. Or lock `Shift` and watch the PC type in caps in another app.

**Phase to address:** Phase 1 (summon host & lifecycle contract) — the hook —
and Phase 3 (keyboard overlay) — the wiring and tests.

---

### P2: The trackpad has the *identical* bug and it was NEVER fixed — a dismissed drag-lock leaves the PC's LEFT MOUSE BUTTON held

**This is P1's twin and is strictly worse.** `260812-tsw` only touched the
keyboard.

`TrackpadCore` flushes an owed drag-end **only in `dispose()`**:

```
trackpad_core.dart:205-207
    if (_driver.dragLocked && _service.isAuthed) {
      _service.sendReliable(const DragMsg(action: 'end', button: 'left'));
    }
```

Drag-lock is a deliberate feature that **survives the finger lift** — see
`gesture_classifier.dart` library doc ("the lock survives the lift for
screen-edge drags; the next tap 'drops'") and the on-screen pill
(`trackpad_screen.dart:198-218`). So "drag-lock engaged, then dismiss" is not
an exotic sequence; it is the normal way a long screen-edge drag is performed,
and the summon model makes dismiss the most frequent gesture in the app.

If the trackpad overlay is kept mounted while hidden, `dispose()` never runs,
the flush never fires, and the PC is left with the left button DOWN and the
indicator pill hidden. Every subsequent tap on any surface becomes a drag. The
user's only recovery is to re-summon and tap to drop, or to disconnect
(CONN-07 `release_all`).

**Why it happens:** the comment at `trackpad_core.dart:204` says the flush
"fires on both window collapse AND screen pop" — which is true *today* only
because `BubbleScaffold` implements collapse as an unmount
(`bubble_scaffold.dart:186-213`). A reader trusts the comment and does not
re-check the premise.

**How to avoid:**
- Add `TrackpadCoreState.dismissed()` mirroring
  `KeyboardInputController.dismissed()`: live-socket-only `DragMsg(end,left)` +
  `_driver.reset()`, sharing one private flush with `dispose()`, idempotent so
  dismiss-then-teardown emits it exactly once. Call it from the same host
  transition that calls the keyboard's.
- Pin it with a widget test in the `T-08-03` shape: engage drag-lock via the
  injected driver seam (`trackpad_core.dart:90-91` already exposes
  `@visibleForTesting driver`), dismiss **without unmounting**, assert exactly
  one `DragMsg(action:'end')` on the recording service, then unmount and assert
  the count is still one.
- **Do not** rely on `TrackpadDriver.dispose()` — it deliberately sends
  nothing (`trackpad_core.dart:203` comment).

**Warning signs:** after a dismiss, a tap anywhere selects/drags on the PC
instead of clicking. Also: `grep -n "dragLocked" lib/trackpad/trackpad_core.dart`
shows the guard only inside `dispose()`.

**Phase to address:** Phase 2 (trackpad overlay). Do it in the same plan that
introduces the hidden-but-mounted state, not after.

---

### P3: The pad-height clamp is copied instead of re-derived — a THIRD inset context with two opposite failure modes

**What goes wrong:** `keyboard_panel.dart:405-408` computes

```dart
final view = MediaQueryData.fromView(View.of(context));
final columnHeight = view.size.height
    - view.viewPadding.top
    - math.max(view.viewPadding.bottom, view.viewInsets.bottom);
```

and feeds it to `panelPadHeight(pad, columnHeight)`
(`key_pads.dart:244-251`), which is
`min(padRequest, max(96, columnHeight * 0.55 − 122))`.

That formula encodes **two** things that are specific to the trackpad screen:

1. *Where the numbers come from.* The raw-view read exists because the trackpad
   screen's `Scaffold(resizeToAvoidBottomInset: true)` (`trackpad_screen.dart:150`)
   plus `SafeArea` (`:152`) have stripped `viewInsets.bottom` and both paddings
   out of the ancestor `MediaQuery` — documented at length in
   `keyboard_panel.dart:379-404`.
2. *What the number is for.* `kPanelMaxHeightFraction = 0.55`
   (`key_pads.dart:211`) exists to reserve 45% of the column **for the live
   trackpad above it**. A bar-hosted keyboard overlay has no trackpad above it.

Both halves break in the third context, in opposite directions:

**Failure A — the arithmetic is copied but the host has *unstripped* insets
(app-level overlay above the `Navigator`).** Nothing is stripped there, so a
plain `MediaQuery.of(context)` would already be correct and the raw read is
redundant-but-harmless. The *real* damage is the 0.55 ceiling: on a 360×640
device the Numpad's 312dp request clamps to `0.55×592 − 122 ≈ 203dp`. **Visible
symptom:** the summoned Numpad is visibly shorter than the same Numpad on the
full-screen Keyboard screen, caps flex below their 64dp target row height, and
~45% of the screen sits empty below the bar for no reason. Nobody reports it as
a bug; it just feels cramped.

**Failure B — the ancestor `MediaQuery` is used but the host IS inside a
route's `Scaffold` body (the `BubbleScaffold` `Stack`-child shape,
`bubble_scaffold.dart:166-215`).** Then `MediaQuery.viewInsetsOf(context)`
returns **zero** for the IME because `resizeToAvoidBottomInset` already removed
it. The overlay lays out against the full window height, so on the Type pad
with the system IME raised, the chip row and the tab bar render **behind the
Android keyboard** and are untappable. Worse, as `keyboard_panel.dart:394-397`
records, the resulting `MediaQueryData` is *value-equal across the whole IME
animation*, so no rebuild is even scheduled — the layout is silently stale, and
a stale-too-large reading racing a growing panel is a `RenderFlex` overflow.

**A third trap, easy to miss:** the raw-view read is **not reactive**. That is
why `keyboard_panel.dart:157` registers `WidgetsBindingObserver` and
`:196-199` implements `didChangeMetrics() => setState(...)`. Copy the formula
without the observer and the overlay never learns the IME rose or fell.

**How to avoid:**
- **Decide and document the host's inset context first**, in the phase's
  design section: app-level `Overlay`/`Stack` above the `Navigator` (raw
  insets, correct `MediaQuery`) vs. per-route `Stack` child inside the
  `Scaffold` body (stripped `MediaQuery`, raw read mandatory). Write the answer
  next to the height call, the way `keyboard_panel.dart:379-404` does.
- **Introduce a second height function** — e.g. `overlayPadHeight(pad, available)`
  — rather than reusing `panelPadHeight`. The docked panel's 0.55 reservation
  is a *contract with the live trackpad* and must not silently apply where no
  trackpad exists. Keep `panelPadHeight` untouched so the docked-panel guards
  in `test/trackpad/trackpad_screen_test.dart:225-307` stay green as a
  regression net.
- If the raw-view read is genuinely needed, port `didChangeMetrics` with it.
- Write the discriminator tests the way `260809-ipc` did: a viewport where the
  naive read yields an obviously wrong number and the test asserts the right one
  (`trackpad_screen_test.dart:256-274` is the model — "the naive read yields 80
  and fails").

**Warning signs:** the summoned keyboard's tab bar is under the system IME on
the Type pad; the Numpad in the overlay is shorter than the Numpad on the
Keyboard screen; rotating or raising the IME does not resize the overlay.

**Phase to address:** Phase 3 (keyboard overlay). Height is the first thing to
settle in that phase, before any pad content is wired.

---

### P4: The hidden IME field ends up inside the animating chrome — every summon tears down the Android input connection

**What goes wrong:** `HiddenTextInput` is the *only* thing that raises the
Android IME and the only source of free-text (`hidden_text_input.dart:1-16`).
Its contract is stated twice, in the widget and at both call sites:

- `hidden_text_input.dart:110-114`: "NEVER Offstage/Visibility(maintainState:false)
  — they detach the Android input connection".
- `keyboard_panel.dart:413-420`: mounted "ALWAYS… in both states, every pad… a
  1×1 invisible sliver **outside the animating chrome**" — it is a sibling of
  the `AnimatedSize` (`:425`), not a child.
- `keyboard_screen.dart:319-325`: mounted **outside** the `PageView`.

If the port puts the field inside the summon animation (inside an
`AnimatedSize`/`SizeTransition`/`AnimatedOpacity` that reaches zero, inside an
`Offstage`, or simply inside the `if (summoned) …` branch), the
`TextInputConnection` is closed and re-opened on every single summon.

**Symptoms, in order of how they will actually present** — the question asks
which, and the answer is all three, on different devices:

1. **The IME does not rise at all on the first summon** (most common). The
   focus request in `didUpdateWidget` (`keyboard_panel.dart:236`) runs against a
   field that is not yet attached; today that is defended by the post-frame
   callback at `:184-191`. A re-mounting field re-introduces the race on every
   summon, not just the first.
2. **A visible IME flicker / re-animation** on each summon as Android closes
   and re-opens the input view — directly against the milestone's "no visible
   jump" and animation-budget criteria.
3. **A dropped or mis-diffed first keystroke.** `ImeDiffProducer` works off a
   ZWSP sentinel baseline (STATE.md, phase 04-05: "hidden IME field rides a ZWSP
   sentinel (8 × U+200B)"). A remount reconstructs `TextEditingController` from
   `producer.seedText` (`hidden_text_input.dart:59`) while the producer's own
   committed-text baseline survives in the parent — if the two are reseeded at
   different moments the first diff after a summon is computed against the wrong
   baseline and emits a spurious backspace or drops a character.

**How to catch it in a test rather than on hardware** (the question's ask):
- Widget tests **can** observe the input connection. Use
  `tester.testTextInput.isRegistered` / `.setClientArgs`, and assert
  `TestTextInput` connection identity is **unchanged** across a summon→dismiss→
  summon cycle. Simpler and just as decisive: assert the `State` object survives —
  `final s = tester.state(find.byType(HiddenTextInput)); …summon/dismiss/summon…;
  expect(identical(tester.state(find.byType(HiddenTextInput)), s), isTrue)`.
  A remount fails it immediately.
- Assert `find.byType(HiddenTextInput)` is `findsOneWidget` **while dismissed**.
  That single assertion is the cheapest possible guard and belongs in the
  keyboard-overlay suite from the first RED test.
- Add a `flutter analyze`-adjacent grep guard in the style the repo already
  uses (`test/theme_tokens_guard_test.dart`, `test/icons_guard_test.dart`):
  fail if `HiddenTextInput` appears inside an `Offstage`/`Visibility` in `lib/`.
  Cheap, and this repo has the precedent for source-scanning guards.

**Warning signs:** the keyboard flickers on summon; the first character of a
typed word is missing or duplicated; `isRegistered` flips false during dismiss.

**Phase to address:** Phase 3 (keyboard overlay), as an explicit success
criterion, not a note.

---

### P5: The 7.3px chip-row overflow test is INVERTED — "repairing" it back to green silently un-fixes the bug

**Where it is:** `app/remote_control/test/trackpad/trackpad_screen_test.dart`,
in the test `'B2 DISCRIMINATOR: short 360x640 viewport with Numpad open…'`,
lines **291-304**. There is exactly one such drain in the suite (verified by
grepping `takeException` across `test/`).

```dart
// trackpad_screen_test.dart:295-304
var overflows = 0;
for (var e = t.takeException(); e != null; e = t.takeException()) {
  expect(e.toString(), contains('overflowed'), reason: '…the ONLY exception
      tolerated here is the 360dp chip-label overflow logged in
      deferred-items.md');
  overflows++;
}
expect(overflows, greaterThan(0),
    reason: 'if this ever reaches zero, the chip row was fixed — delete '
        'this drain and restore a plain takeException-is-null assertion');
```

A related, softer inversion sits at `trackpad_screen_test.dart:178-194`:
`expectColumnFits` deliberately proves "no vertical overflow" by summing child
heights **instead of** `expect(takeException(), isNull)`, precisely because the
horizontal chip overflow would poison the simpler assertion.

**EXPLICIT INSTRUCTIONS FOR THE IMPLEMENTER — do not paraphrase these:**

1. When you fix the chip row, `trackpad_screen_test.dart:302` **will fail with
   `Expected: a value greater than <0> / Actual: <0>`. That failure is the
   PASS signal.** It is not a flake, not a race, and not caused by your layout
   change being wrong.
2. **The correct response is to DELETE lines 291-304** (the whole drain block)
   and replace them with `expect(t.takeException(), isNull);`.
3. **The wrong response — explicitly forbidden — is any of:** changing
   `greaterThan(0)` to `greaterThanOrEqualTo(0)`; wrapping the assertion in a
   conditional; deleting only the `expect(overflows, …)` line and keeping the
   drain; or marking the test `skip:`. Each of those makes the suite green
   while leaving the overflow un-detected forever after.
4. Also update the comment block at `trackpad_screen_test.dart:178-186`
   (`expectColumnFits`), which explains the tolerance by pointing at
   `deferred-items.md`, and close item 1 in
   `.planning/quick/260809-ipc-…/deferred-items.md`.
5. Add the equivalent positive assertion on **both** new/changed surfaces:
   the summon keyboard overlay and `KeyboardScreen`. Today no test drives
   `KeyboardScreen` at 360dp at all — the overflow is unguarded there.

**CRITICAL CAVEAT the requirement writers must hear before scoping this:**
the 7.3px figure is measured **under the Flutter widget-test font**, where every
glyph advances a full em. `deferred-items.md` records the mechanism exactly:
inner `Row` (`modifier_chip.dart:76`) constrained to **74dp** (360 − 32 padding
− 24 gaps = 304, ÷4 = 76, − 2 for the chip's 1px borders), against a `Shift`
label measuring **~81.3dp**. Under the test font `Shift` is 5 glyphs × 16px =
80dp. With the shipped Material text face at 16/w600, `Shift` measures roughly
half that and **fits 74dp with room to spare**. The owner's device is also not
360dp wide (the suite's "reference device" is 411×891,
`trackpad_screen_test.dart:228`), where the cell is ~86.75dp and even the test
font fits.

**Consequence:** PROJECT.md:34/68 lists "the 7.3px overflow fixed on both
keyboard surfaces" as a milestone requirement. Before spending a plan on it,
**verify on a real 360dp-wide device or with a real font in the test** whether
any user-visible overflow exists. If it does not, the honest fix is to make the
guard font-independent (or accept the label geometry and delete the deferred
item as "test-font artifact"), **not** to bolt a `FittedBox` onto both surfaces
and shrink labels the owner can currently read fine.

**Phase to address:** Phase 5 (chip-row fit + verification). The
verify-before-fix step belongs in that phase's discussion, not its plan.

---

### P6: `showBubble: false` is ported mechanically and the summon bar becomes a shortcut to the screen you are already on

**What the flag means today:** `HubTileSpec.showBubble`
(`hub_screen.dart:73-81`) is false for exactly one tile — Trackpad
(`hub_screen.dart:87-93`) — and `BubbleScaffold` passes `showBubble: false`
when the `⤢` header button pushes the full trackpad
(`bubble_scaffold.dart:114-126`). The rule it encodes is *"never a shortcut to
the screen you are on"* (`hub_screen.dart:281`, `bubble_scaffold.dart:23-25`,
D8-05). It gates one thing: the `if (widget.showBubble)` branch at
`bubble_scaffold.dart:186`. The UIPI banner and the body are unaffected.

**The failure mode of a mechanical port** is that the flag is renamed
(`showBar`) and carried through with its old truth-value, producing a bar that
is **absent from the Trackpad screen** — the one screen where the *keyboard*
icon is now most valuable (a keyboard raised over the full precision trackpad
is a mode the owner explicitly kept, `keyboard_panel.dart:6-8`: "a hard
contract, not a nicety"). The result is a bar that is on "every screen except
the two it exists for."

**The flag's meaning has genuinely changed and needs a per-icon answer, not a
per-screen boolean:**

| Screen | Trackpad icon | Keyboard icon |
|---|---|---|
| Full Trackpad screen | redundant — the whole screen is a trackpad | **wanted** (this is the docked-panel mode) |
| Keyboard screen | **wanted** | redundant |
| Hub + 7 tool screens | wanted | wanted |

So `showBubble: bool` should become **two independent suppressions**, or —
cleaner — the bar renders both icons everywhere and the *redundant* one is
rendered in a distinct visual state rather than removed, so the bar's geometry
never changes between screens (a bar that loses an icon on two screens is a
layout jump on exactly the navigation the owner does most).

**A second, easily missed consequence:** with the tiles moved to the END of
`kHubTiles`, the trackpad tile is no longer index 0, and `showBubble` is
currently checked positionally-adjacent in two places. Both `hub_screen.dart:92`
and `bubble_scaffold.dart:120` must be revisited, and the `⤢` "open full"
button dies with `FloatingTrackpadWindow` — decide deliberately whether the
summon trackpad gets an equivalent "expand to full screen" affordance or
whether the hub tile is the only route to the precision surface.

**Warning signs:** the bar is missing on the Trackpad screen; the bar's icon
count differs between screens; a reviewer cannot say in one sentence what the
flag now means.

**Phase to address:** Phase 1 (bar shell — decide the semantics) and Phase 4
(bubble retirement + hub reorder — apply it).

---

### P7: A dismiss gesture on the trackpad surface cannot win the gesture arena — the surface is a raw `Listener`, which never enters the arena at all

**What goes wrong:** `TrackpadCore`'s surface is a bare
`Listener(onPointerDown/Move/Up/Cancel, behavior: HitTestBehavior.opaque)`
(`trackpad_core.dart:240-246`) — described in its own doc as a
"zero-gesture-arena Listener". A `Listener` receives raw pointer events during
hit-test dispatch and **never adds a recognizer to the gesture arena.**

Consequence: if a swipe-to-dismiss is implemented as a `GestureDetector`
(`onVerticalDragUpdate` / `onPanUpdate`) anywhere **above** the trackpad in the
widget tree, that recognizer is the *only* arena member for the pointer. It
faces no competition, so it wins by default once `kTouchSlop` (~18dp) is
crossed — while the `Listener` has already been feeding `MoveIntent`s to the
driver since `kTapSlopPx = 10.0` (`tuning.dart:17`).

**The visible symptom** is not "the dismiss doesn't work". It is: the PC cursor
jumps ~8-18dp downward and *then* the panel slides away — every single dismiss
nudges the mouse. Worse, the trackpad's own vocabulary is already saturated:
one-finger vertical drag = cursor move, two-finger vertical drag = scroll, and
two-finger separation vs. translation is already arbitrated once per contact
for pinch-zoom (`gesture_classifier.dart` library doc, protoVersion 1.7). There
is no unclaimed vertical gesture on that surface. A "swipe down on the pad to
dismiss" is ambiguous **by construction**, not by accident.

**Standard resolutions, in the order this codebase should prefer them:**

1. **Tap the bar icon again to dismiss (toggle).** This is the true
   one-gesture dismiss, costs zero arena risk, is symmetric with summon, and is
   how the Android IME's own affordances behave. Recommend this as the primary.
2. **A dedicated grab handle that is a spatially-disjoint SIBLING of the
   `Listener`, never an ancestor.** This is the house precedent and it is
   already documented as "RESEARCH Pitfall 2" —
   `floating_trackpad_window.dart:6-8` and `:16-23`: "a `⠿` drag handle (its
   OWN `GestureDetector`, a SIBLING of, never an ancestor of, the surface)…
   Touches on the gesture surface are ALWAYS mouse input and never move the
   window."
3. **System back** as a secondary dismiss (see P8).
4. **Never**: a full-surface `GestureDetector`, a `DismissDirection` wrapper, a
   `DraggableScrollableSheet`, or `showModalBottomSheet`. The last one is the
   most tempting and the most wrong: it pushes a route (violating "no
   navigation"), installs a barrier that eats trackpad pointers, and brings its
   own drag-to-dismiss that fights the surface.

**Prevention test:** pin the invariant the way 08-04 did — drive a long
vertical drag starting inside the trackpad surface and assert (a) the recording
service received `sendMove` calls, and (b) the overlay is **still visible**.
Then drive the same drag on the handle and assert the inverse.

**Warning signs:** the cursor twitches on dismiss; a drag that starts on the pad
and ends off it dismisses the overlay; `flutter test` shows moves recorded
during a dismiss gesture.

**Phase to address:** Phase 1 (choose the dismiss gesture — this is a design
decision, not an implementation detail) and Phase 2 (trackpad overlay).

---

### P8: Back-gesture handling on the ROOT route — `PopScope` breaks app exit and permanently kills predictive back

**What goes wrong:** the natural "one-gesture dismiss" on Android is system
back, and `BubbleScaffold` already does exactly that
(`bubble_scaffold.dart:157-165`: `PopScope(canPop: !expanded, …)`). Porting
that pattern to a bar present on **every screen including the hub** hits two
distinct problems:

**8a — the hub is the root route.** `main.dart:116` is `home: const HubScreen()`.
There is nothing under it to pop. A `PopScope(canPop: false)` on the hub while
the overlay is up is correct; but if the implementer wires `canPop` to anything
that is false when the overlay is *down*, the back gesture stops exiting the app
and the phone appears frozen on the dashboard. And if the summon host is placed
**above** the `Navigator` (an app-level overlay — the natural choice for
"every screen"), the route-scoped `PopScope` idiom does not apply at all;
back must be intercepted with `NavigatorObserver`/`WidgetsBindingObserver`-level
handling or by keeping one `PopScope` at the app shell.

**8b — predictive back dies while `canPop` is false.** [MEDIUM confidence,
web-sourced, cross-checked against the Flutter breaking-change doc] Android's
predictive back **does not animate at all** while a `PopScope` reports
`canPop: false`, by design: the OS must know ahead of time whether the gesture
will complete. So an always-mounted, always-`false` interceptor silently
disables the predictive-back preview on that route forever, including when no
overlay is showing. The fix is to keep `canPop` **reactive** — false only while
the overlay is actually raised — exactly what `bubble_scaffold.dart:159` does
today via the `ValueListenableBuilder` wrapper described at `:152-156`.

**How to avoid:**
- Keep exactly ONE `PopScope`, at the summon host, with `canPop` driven by the
  live overlay-visible notifier — reuse the `bubble_scaffold.dart:152-165`
  shape verbatim (outer `ValueListenableBuilder` whose cached `child` is the
  body, so the body never rebuilds off the flag).
- Add a test that the back gesture **pops the route** when no overlay is up,
  and **dismisses only the overlay** when one is — both on a pushed tool screen
  and on the hub.
- Confirm on hardware that the predictive-back preview still animates on tool
  screens with no overlay raised.

**Warning signs:** back does nothing on the hub; the predictive-back peek
animation disappears app-wide after the bar ships.

**Phase to address:** Phase 1 (summon host & lifecycle contract).

---

### P9: Jank under repeated summon — the real causes here are rebuild scope and `saveLayer`, NOT shader compilation

**Context correction first** [MEDIUM confidence, web-sourced]: Impeller has
been the default Android renderer since Flutter 3.27 on API 29+ with Vulkan,
and it precompiles a small fixed shader set at engine build time. On Flutter
3.44 targeting an Android 16 device, **runtime shader-compilation jank and the
Skia-era `--purge-persistent-cache` / SkSL warm-up workarounds are no longer
the relevant mitigation.** Do not spend a plan on them. (They would return only
on a pre-API-29 / no-Vulkan fallback device, which is not the owner's.)

The real risks, in order:

**9a — a rebuild storm from watching a provider too high.** The bar is on every
screen, so whatever it watches, every screen now watches. The safe reads exist
already: `connectionStatusProvider` is a **value-equal** snapshot, so the
Riverpod notifier suppresses no-op rebuilds (STATE.md, phase 03-05:
"ConnectionStatus snapshot is value-equal (== / hashCode) so the Riverpod
Notifier suppresses no-op rebuilds on changes pings"). The unsafe read is
`ConnectionService.changes` — a raw ping stream. **Never subscribe the bar to
`changes` directly**; watch the value-equal provider, following the house
pattern (`hub_screen.dart:308`, `trackpad_screen.dart:144`,
`bubble_scaffold.dart:148`). Also note `ConnectionHeaderChip` polls on its own
`Timer.periodic(500ms)` (STATE.md, 03-07) — if the bar copies that idiom it adds
a timer per screen; it should not need one.

**9b — the animating subtree must not include the host's body.** The house
answer is already written down twice: `bubble_scaffold.dart:10-12` and
`:152-156` ("the body Widget instance itself is built exactly once per
`BubbleScaffold` build"), and `trackpad_screen.dart:294-297` ("ONLY this slot
rides the notifier — the Expanded trackpad Stack above keeps its widget
identity so panel animation never rebuilds the hot path"). Reproduce this
exactly: a `ValueListenableBuilder` whose `child:` is the page body, with only
the overlay slot inside `builder:`.

**9c — `Opacity` and `ClipRect` are `saveLayer` costs.** Animating `Opacity`
over a large subtree forces an offscreen render target per frame. Prefer
`SlideTransition`/`FractionalTranslation` (transform-only, no layer) or
`AnimatedSize` over a `Container` (the panel's existing choice,
`keyboard_panel.dart:425-428`) to a fade over the whole surface. If a fade is
required, scope it to the smallest possible subtree — `bubble_scaffold.dart:206`
fades only the 56dp bubble, not the window, and `:190-205` deliberately renders
the window **unwrapped** (STATE.md 08-05 records the `Positioned`↔`Stack`
ParentData reason as well).

**9d — the hidden cost of "restore where it was".** Keeping four pads +
`PageView` + `TrackpadCore` mounted while hidden means their `build`s still run
on any ancestor rebuild. Wrap the hidden state in `TickerMode(enabled: false)`
and/or `IgnorePointer`, and make sure the hidden subtree is **not** rebuilt by
the visibility notifier (same `child:`-caching trick as 9b).

**How to verify** (the milestone has an explicit animation budget, so this
needs teeth):
- `flutter run --profile` + `--trace-skia`/DevTools timeline; capture 20
  consecutive summon/dismiss cycles and record worst-frame raster and UI times.
  Put the numbers in the phase's VERIFICATION, not a "felt smooth" note.
- In widget tests, assert rebuild counts, not timings: give the page body a
  `StatefulWidget` counter and assert it did **not** rebuild across a summon.
  This is the CI-visible half; the timeline is the hardware half.
- Beware `pumpAndSettle` in these tests — see P11.

**Warning signs:** first summon of a session is visibly slower than later ones
(if this persists on Impeller it is 9d/9b, not shaders); the header chip or
device name flickers on summon; DevTools shows the whole page rebuilding.

**Phase to address:** Phase 1 (rebuild scoping is structural, decide it with
the host) and Phase 5 (measured budget + verification).

---

### P10: Wakelock is acquired on mount and released on dispose — with an always-mountable overlay the screen never sleeps again

**What goes wrong:** `TrackpadCore` is the **sole owner** of the keep-awake hold
and takes it in `initState` (`trackpad_core.dart:194`), releasing it in
`dispose` (`:209`), through the ref-counted `KeepAwake` singleton
(`keep_awake.dart:29-71`). `PresenterScreen` is the only other holder
(`presenter_screen.dart:83`/`:91`).

Three failure modes appear once the trackpad is summonable from anywhere:

1. **Mounted-but-hidden = permanent wakelock.** If the overlay stays mounted
   after dismiss (the P1/P2 architecture), `dispose()` never runs, the count
   never returns to 0, and the phone's screen stays on for the rest of the app
   session — a battery drain the owner will notice as "the phone got hot in my
   pocket" long before he connects it to the summon bar.
2. **The bar makes the hold reachable from every screen.** Previously the hold
   was scoped to two destinations you deliberately navigated to. Now a stray tap
   on the bar from the Clipboard screen acquires it.
3. **Double-acquire on re-summon.** If the implementer "fixes" (1) by calling
   `release()` on dismiss but leaves `acquire()` in `initState`, a
   mounted-but-hidden core re-summoned N times releases N times and acquires
   once — `KeepAwake.release()` guards underflow (`keep_awake.dart:58-64`) so it
   will not go negative, but the Presenter's concurrent hold **will be dropped**
   by the extra releases. That is precisely the bug `keep_awake.dart:1-15` was
   written to prevent, reintroduced from the other side.

**How to avoid:**
- Move the hold from **mount lifecycle to visibility lifecycle**: acquire on
  the summon transition, release on the dismiss transition, both from the ONE
  host that owns visibility — and keep `TrackpadCore` as the sole owner by
  giving it `onShown()`/`onHidden()` seams rather than letting the host call
  `keepAwake` directly (preserving the "SOLE owner" invariant at
  `trackpad_core.dart:20-22`).
- Pair every acquire with exactly one release, and pin it with the existing
  spy seam: `TrackpadCore.keepAwake` is already `@visibleForTesting`
  (`trackpad_core.dart:74-75`). Assert `activeCount == 0` after a
  summon→dismiss cycle and `== 1` after summon→dismiss→summon.
- Add the specific regression test the old comment predicted: Presenter open
  → summon trackpad → dismiss → assert `activeCount == 1` (the Presenter's hold
  survives), not 0.
- Decide explicitly whether the **keyboard** overlay should hold a wakelock at
  all. Today it does not (only `TrackpadCore` and Presenter do). Typing on the
  PC with the phone idle is exactly the case where a screen timeout is
  annoying — but that is a new requirement, and it should be a decision, not a
  side effect of sharing a host.

**Warning signs:** the phone screen never dims while the app is foregrounded;
`keepAwake.activeCount` is non-zero with nothing raised; the Presenter screen
dims after a trackpad excursion.

**Phase to address:** Phase 2 (trackpad overlay).

---

### P11: Test migration silently reduces coverage — 44 tests die by deletion and two order pins are not on the scope list

**The numbers.** The suite is 882 tests as of `18346b3` (STATE.md quick-task
table). Deleting `TrackpadBubble`, `FloatingTrackpadWindow` and the position
providers removes:

| Suite | Tests | Fate |
|---|---:|---|
| `test/floating_trackpad_window_test.dart` | 6 | deleted with the widget |
| `test/trackpad_bubble_test.dart` | 6 | deleted with the widget |
| `test/window_position_test.dart` | 12 | deleted with `windowPositionProvider` |
| `test/bubble_position_test.dart` | 13 | **not named in the design note** — `bubblePositionProvider` has no consumer left once `TrackpadBubble` and `bubble_scaffold.dart:131-140` go |
| `test/bubble_scaffold_test.dart` | 5 | rewritten, not deleted (banner + body contracts survive) |

That is **~42 tests that vanish and ~5 that mutate**. The milestone will show a
lower test count than v1.0 and that is *correct* — but only if the invariants
those tests protected are re-pinned on the new surface. The ones that must
survive the migration, restated as new-surface requirements:

- overlay and bar are **never both** rendering the same affordance (was D8-01,
  `bubble_scaffold_test.dart:5-7`);
- a pointer on the gesture surface is **always** mouse input and never moves
  chrome (was `floating_trackpad_window_test.dart`, the header-drag isolation);
- the overlay is **fully on screen** at every viewport (was the window's clamp
  tests + `floating_trackpad_window_test.dart:282-303`, the 360×640
  no-overflow guard);
- the UIPI banner still rides every screen and still ignores pointers
  (`bubble_scaffold.dart:176-183`, `test/uipi_banner_test.dart`).

**Two order pins the design note's scope list misses.** The note names
`hub_tiles_test.dart`; there are **three** files coupled to `kHubTiles` order:

1. `test/hub_tiles_test.dart:15-25` — `kExpectedOrder`, the locked 9-label list;
   plus positional assertions at `:49-52` (`kHubTiles[1] == 'Keyboard'`,
   `kHubTiles[2] == 'Shortcuts'`) and a tail-tile assertion at `:112-118` that
   assumes index 8.
2. **`test/hub/hub_screen_test.dart:22-35`** — *not on the scope list*. It
   asserts `kHubTiles.first.label == 'Trackpad'` with the reason "D-02: the
   trackpad is the full-width primary tile — always first in the registry", and
   `:55-60` taps `'Trackpad'` expecting it first. **That rationale is already
   stale** (the full-width primary row was deleted in 07-13,
   `hub_screen.dart:6-10`) — so the test will fail for the right reason with a
   wrong explanation, which is exactly how a migration gets "fixed" by
   re-pinning Trackpad to index 0 and quietly reverting the requirement.
3. `test/hub_offline_test.dart:93` — iterates `kHubTiles` (order-agnostic, safe).

**The three classic silent-coverage-loss mechanisms, and this repo's answers:**

- **Deleted tests never re-added.** Prevention: before deleting any suite,
  copy its `//` header contract block (every suite here opens with a numbered
  list of what it proves — e.g. `floating_trackpad_window_test.dart:17-18`)
  into the new suite's header as a checklist, and tick each line. Do not delete
  a file until its successor exists.
- **`pumpAndSettle` hiding an animation regression.** The suite uses it 95
  times, 45 of them in `test/keyboard/keyboard_panel_test.dart` alone.
  `pumpAndSettle` advances until no frames are scheduled, so a summon that
  takes 200ms and one that takes 900ms are indistinguishable. Prevention: in the
  summon suites use **explicit `pump(Duration(...))` steps** — the shape already
  used at `trackpad_screen_test.dart:217-222` ("panel slide" / "pad-height
  ease") — and assert intermediate geometry at a named millisecond. At least one
  test must assert the overlay is **not yet** at final size at t=100ms and
  **is** at t=250ms; that is what turns the animation budget into a regression
  gate. Also: `pumpAndSettle` **times out** against a never-ending animation, so a
  looping shimmer/pulse on the bar would hang 95 call sites.
- **Golden tests not updated.** **Not applicable here** — verified: zero
  `matchesGoldenFile` in `test/`. The visual regression net in this repo is the
  two source-scanning guards instead: `test/theme_tokens_guard_test.dart` (bans
  the 7 locked palette hex literals anywhere in `lib/` outside `tokens.dart`)
  and `test/icons_guard_test.dart` (bans classic `Icons.` in `lib/`, allowlist
  intentionally empty). **New bar/overlay chrome must use `kBg`/`kSurface`/
  `kHairline`/`kText`/`kMuted`/`kAccent`/`kError` from `theme/tokens.dart` and
  `Symbols.*_rounded`, or these two tests fail the build.** That is a feature —
  tell the implementer up front so it is not discovered as a mystery failure.

**Warning signs:** the test count drops and no one can name what stopped being
proven; a PR touches `kExpectedOrder` and `hub_screen_test.dart` in the same
commit as a source change with no RED-first evidence; a summon test contains
`pumpAndSettle` and no explicit duration.

**Phase to address:** Phase 4 (bubble retirement + hub reorder + test
migration) — and the migration checklist should be written in Phase 1, before
anything is deleted.

---

### P12: "Every screen" is not defined — the bar over the pairing dialog, the QR scanner and Settings

**What goes wrong:** `BubbleScaffold` is applied **centrally at one push site**
(`hub_screen.dart:282-293`) — the 08-06 migration lesson (STATE.md: "swapping
the `_open` wrap in `hub_screen.dart` alone migrated all 7 tool screens"). That
seam reaches exactly the 9 tool screens. It does **not** reach:

- the **hub itself** (`main.dart:116`, `home: const HubScreen()` — unwrapped);
- **Settings** (`hub_screen.dart:296-302`, a separate unwrapped push);
- **device list / add-PC**, **pairing dialog**, **QR scanner**
  (`lib/screens/*`), and **Updates** (`lib/update/updates_screen.dart`).

"Every screen" as written in PROJECT.md:29 therefore has an undefined boundary,
and two of the excluded screens are actively hostile to it:

1. **`pairing_dialog.dart` and `device_list_screen.dart` are the only two files
   in `lib/` with a real `TextField`** (verified by grep). Raising the summon
   keyboard there creates **two competing IME clients**: `HiddenTextInput`'s
   focus request (`keyboard_panel.dart:236`) steals focus from the PIN / IP
   field. The user then types their 6-digit PIN **into the PC**. That is not a
   cosmetic bug — it is a pairing failure with a plausible security smell
   (the PIN is typed into whatever window has focus on the laptop).
2. **The QR scanner** is a live camera surface; a trackpad overlay over it is
   meaningless and a keyboard over it worse.
3. **A pairing dialog is a modal route** — the trackpad cannot control a PC
   that is not yet paired anyway, and the bar's icons would render disabled
   (`enabled: authed`) on every one of these screens.

**How to avoid:**
- Define the bar's scope as an explicit **allowlist** ("the hub + the 9 tool
  screens"), not "every screen", and write the excluded set into the phase
  context with the reason. This is a one-line requirements change that prevents
  a whole class of discovery-during-execution.
- If the bar is hosted app-level (above the `Navigator`), it will appear over
  those routes **by default** — so an app-level host needs an explicit
  suppression mechanism (a route-settings flag or a `NavigatorObserver`
  allowlist), which is real work. Weigh that against the per-route-wrap host,
  which gets exclusion for free but needs three additional wrap sites for the
  hub/Settings/Updates.
- If any excluded screen later needs the bar, gate the **keyboard** icon on
  "no `TextField` currently focused" via `FocusManager.instance.primaryFocus`
  rather than trusting screen identity.

**Warning signs:** the summon keyboard opens over the PIN field; the bar renders
over the camera preview; `Navigator` pushes from Settings show no bar and it is
unclear whether that is intended.

**Phase to address:** Phase 1 (host + scope) — this must be settled before the
host shape is chosen, because it *determines* the host shape.

---

### P13: Deleting the position providers leaves orphaned prefs keys and a live-device migration nobody planned

**What goes wrong:** `bubblePositionProvider` and `windowPositionProvider` each
persist a JSON string under their own `SharedPreferences` key
(`lib/settings/bubble_position.dart:96-113`, `lib/settings/window_position.dart`;
STATE.md 08-01: "bubble/window positions each serialize as a single JSON
string… a separate prefs key"). Deleting the providers leaves both keys on the
owner's **already-installed** device forever. Harmless in itself — but:

- there is no prefs-migration mechanism anywhere in the app, so this is the
  first orphan and sets the precedent;
- if a future feature reuses either key name it will read a stale value that
  degrades through the corruption-tolerant path rather than as a fresh default;
- the app is **sideloaded and updated in place** via the Phase-12 updater, so
  "just reinstall" is not the delivery model.

**How to avoid:** make it a one-line **decision**, not an oversight: either
delete the keys on first run after upgrade (a 3-line `SharedPreferencesAsync
.remove` in the app shell, guarded by a version marker), or record in the phase
SUMMARY that the two keys are knowingly orphaned and must never be reused.
Prefer the second — cheaper, and the repo already prefers recorded decisions to
machinery.

**Also delete, not just orphan:** `kBubbleSize` / `kBubbleEdgeInset`
(`trackpad_bubble.dart:28`/`:31`) are consumed by
`bubble_scaffold.dart:135-137`; that anchor helper (`_bubbleAnchor`,
`bubble_scaffold.dart:131-140`) becomes dead with the window's
`initialTopLeft`. `flutter analyze` will not flag an unused public const, so
grep for each deleted symbol before closing the phase.

**Warning signs:** `grep -rn "BubblePosition\|WindowPosition" lib` returns hits
after Phase 4; `dart analyze` is clean but dead files remain.

**Phase to address:** Phase 4 (bubble retirement).

---

## Technical Debt Patterns

| Shortcut | Immediate benefit | Long-term cost | When acceptable |
|---|---|---|---|
| Reuse `KeyboardPanel` verbatim as the summon surface | Inherits the `dismissed()` wiring (P1) and the four-pad deck for free | Inherits the trackpad-specific raw-view read and the 0.55 column reservation (P3) into a context with no trackpad; two mount points now disagree about what "column" means | Only if `panelPadHeight` is replaced by an overlay-specific height at the same time |
| Unmount the overlay on dismiss to get the releases for free | P1, P2 and P10 all solve themselves | Breaks "restore where it was, no visible jump" (PROJECT.md:31) and re-detaches the IME connection on every summon (P4) | Never for the keyboard. Arguably acceptable for the **trackpad** in a first slice, since it has less state to restore — but say so explicitly |
| Wrap `showBubble` → `showBar` and move on | Zero-thought migration, one rename | The bar disappears from exactly the two screens where the *other* icon matters most (P6) | Never — the flag's meaning genuinely changed |
| Change `expect(overflows, greaterThan(0))` to `>= 0` when it fails | Suite goes green immediately | The chip-row guard is dead forever and nobody notices (P5) | **Never.** Delete the drain instead |
| `pumpAndSettle` in the new summon tests | Fewer flaky waits | The animation budget becomes unmeasurable in CI; a 900ms summon passes (P11) | Acceptable for non-timing assertions only; every timing assertion needs explicit `pump(Duration)` |
| App-level overlay above the `Navigator` for "every screen" | One host, no per-route wrapping, correct un-stripped insets | Appears over the pairing dialog / QR scanner by default; route-scoped `PopScope` no longer applies (P8a, P12) | Acceptable **with** an explicit route allowlist and an app-shell back handler |
| Skip the trackpad's `dismissed()` because "the keyboard one was the reported bug" | Saves a plan | A stuck left mouse button on the PC — worse than a stuck Shift (P2) | Never |

---

## Integration Gotchas

The "external service" here is the PC, reached over the wire. Every item is a
phone-side mistake with a physical consequence on the laptop.

| Integration | Common mistake | Correct approach |
|---|---|---|
| Reliable key path (`sendReliable`) on dismiss | Sending owed `up` frames unconditionally | Live-socket-only. `_flushHolds()` (`keyboard_input_controller.dart:166-174`) resets the FSM with **zero effects** when disconnected, because CONN-07 `release_all` already freed the real keys and a queued stale `up` must never flush into a NEW session (D-12) |
| The 5s reliable-queue TTL (`260812-uq8`, `18346b3`) | Assuming a dismiss-time `up` is guaranteed delivery | A frame queued during a blip is dropped after 5s. A dismiss during a reconnect may therefore never release the modifier on the PC. The disconnect path (`_onDisconnected`, `:107-112`) is the actual safety net — do not weaken it |
| Idempotence between cap-dispose and surface flush | Emitting the `up` twice (once from `KeyCap.dispose` at `key_rows.dart:494-504`, once from the flush) | The `_heldCodes.remove()` guard in `keyboard_input_controller.dart:224` is what makes the pair idempotent. Any new release path must go through `keyUp()`/`_flushHolds()`, never `send(KeyMsg(...,'up'))` directly |
| Server version coupling | Assuming the bar is client-only and needs no server release | It is client-only — **no protocol change is needed for this milestone**, which is worth stating explicitly so nobody bumps `protoVersion`. (The standing ship-together rule from `260731-euq` still applies to any future keymap growth) |
| `changes` ping stream | Subscribing the bar to `service.changes` for its enabled state | Watch the value-equal `connectionStatusProvider` (`hub_screen.dart:308` pattern) — `changes` fires on volume/apps/clipboard/bookmark pings too |

---

## Performance Traps

Scale here is *gestures per session*, not users.

| Trap | Symptoms | Prevention | When it breaks |
|---|---|---|---|
| Overlay animation rebuilds the page body | Header chip / device name flicker on summon; DevTools shows whole-page rebuild | `ValueListenableBuilder` with the body as the cached `child:` (`bubble_scaffold.dart:152-171`) | Immediately — the first summon on any content-heavy screen (Browser tab list, Bookmarks) |
| Full-surface `Opacity`/`ClipRect` fade | Raster time spikes on summon frames | Transform-based transitions; scope any fade to the smallest subtree (`bubble_scaffold.dart:206` fades only the 56dp bubble) | ~dozens of summons/session — i.e. the target usage |
| Hidden-but-mounted subtree still building | UI thread time grows with every screen visited | `TickerMode(enabled:false)` + `IgnorePointer` on the hidden state, and keep it out of the visibility notifier's `builder:` | Gradual; worst on the four-pad deck |
| Per-screen `Timer.periodic` copied from the header chip | Battery drain; wakeups with nothing on screen | The bar needs no poll — the status provider is push-driven | 9+ screens |
| Provider lookup on the pointer hot path | Cursor latency regression against the locked <30ms budget (measured p50 6ms) | `TrackpadCore` caches the service in `initState` (`:139`) and the sensitivity in a `listenManual` double (`:145-149`) — the overlay must not reintroduce a `ref.watch` above the `Listener` | Immediately and visibly — this is the one number the owner would notice |
| Shader compilation jank | First-summon stutter | **Not the cause on this stack** — Impeller is default on Android API 29+ since 3.27 and precompiles its shader set. Investigate rebuild scope and raster layers instead | Only on a pre-API-29 / Vulkan-less fallback device |

---

## Security / Safety Mistakes

| Mistake | Risk | Prevention |
|---|---|---|
| Summon keyboard raised over the pairing dialog | The 6-digit PIN is typed **into the PC** instead of the field, landing in whatever window is focused on the laptop | Exclude pairing/device-list from the bar's scope (P12), or gate the keyboard icon on `FocusManager.instance.primaryFocus` being null |
| Dismiss does not fire the CR-01 IME wipe | Pre-disconnect typed text (possibly a password) replaying after reconnect | This is already correct and must stay: `dismissed()` **deliberately does not** fire `imeResetTick` (`keyboard_input_controller.dart:141-145`) — the wipe answers a dead socket, not a hidden surface. Do not "improve" it into a wipe-on-dismiss, and do not drop the disconnect-path wipe at `:110` |
| A locked modifier or drag-lock left held on the PC | The laptop is left with `Shift`/`Win` welded down or the left button held — affects every other app the owner is using, not just this one | P1 and P2 |
| Overlay renders over the UIPI banner | The "input blocked by an elevated window" warning is hidden exactly when the user is trying to type into an elevated window | Keep the banner slot above the overlay in the `Stack` (it is top-anchored and `IgnorePointer`-wrapped today, `bubble_scaffold.dart:176-183`); assert z-order in the migrated scaffold test |

---

## UX Pitfalls

| Pitfall | User impact | Better approach |
|---|---|---|
| The bar changes shape between screens (icon suppressed where redundant) | A layout jump on the most-used navigation | Keep both icons everywhere; distinguish the redundant one visually (P6) |
| Dismiss implemented as swipe-on-the-pad | Every dismiss nudges the PC cursor (P7) | Tap the bar icon to toggle; a disjoint grab handle as secondary |
| Re-summon lands on the default pad instead of the last one | The owner's muscle memory breaks; contradicts "restores the surface where it was" | Keep the surface mounted, or persist and restore the pad **synchronously** — note the async prefs load already needed a one-shot restore dance (`keyboard_panel.dart:132-146`, `:205-225`), and an unmount/remount cycle re-runs it on every summon, visibly |
| The bar eats ~56dp on every screen | Tool screens lose height they gained in 08-06 (D8-06 reversal) | Accepted knowingly (design note "Two deliberate reversals") — but check the tool screens that were tight before: `hub_screen.dart:376` already scrolls; `browser_screen`'s tab list and `bookmarks_section` should be re-checked at 640dp height |
| Overlay covers the very control the user is reaching for | e.g. the Media volume slider or the Presenter zones sit behind the raised trackpad | The owner accepted sequential use ("I require other remotes… but it can be sequential"), so this is in-contract — but the dismiss must be reachable **without** touching the covered surface, which is another argument for the bar-icon toggle |

---

## "Looks Done But Isn't" Checklist

- [ ] **Dismiss:** verify on hardware — lock `Win`, dismiss, then click. If the click is `Win`+click, P1 is live. `grep -rn "dismissed()" lib` must show a call from the summon host.
- [ ] **Dismiss (trackpad):** engage drag-lock, dismiss, tap elsewhere. If the tap drags, P2 is live and there is no test covering it.
- [ ] **IME:** `find.byType(HiddenTextInput)` is `findsOneWidget` **while dismissed**; the `State` identity survives summon→dismiss→summon.
- [ ] **Height:** summon the keyboard on the Type pad with the system IME up, on a 360dp-wide device. Chip row and tab bar must be above the IME and tappable.
- [ ] **Height parity:** the summoned Numpad is not shorter than the Keyboard screen's Numpad for no reason.
- [ ] **Wakelock:** open Presenter → summon trackpad → dismiss → Presenter still keeps the screen awake; and with nothing raised, `keepAwake.activeCount == 0`.
- [ ] **Back:** back exits the app from the hub with nothing raised; back dismisses only the overlay when raised; predictive-back preview still animates on tool screens.
- [ ] **Gesture:** a long vertical drag starting on the pad produces `sendMove` calls and does **not** dismiss.
- [ ] **Chip row:** before claiming the overflow fixed, confirm it is visible on a real 360dp device with the shipped font — not only under the test font (P5).
- [ ] **Overflow test:** `trackpad_screen_test.dart:291-304` has been **deleted and replaced** with `expect(takeException(), isNull)`, not loosened.
- [ ] **Order pins:** `test/hub/hub_screen_test.dart:22-35` updated with a *new* rationale, not re-pinned to Trackpad-first.
- [ ] **Dead code:** `grep -rn "TrackpadBubble\|FloatingTrackpadWindow\|windowPositionProvider\|bubblePositionProvider\|kBubbleSize" lib` returns nothing.
- [ ] **Guards:** `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` green — new chrome uses tokens and `Symbols.*_rounded`.
- [ ] **Budget:** the animation budget is a recorded number from a profile trace, not "felt smooth". *A SUMMARY on disk is not an outcome* (MILESTONES.md:74).

---

## Recovery Strategies

| Pitfall | Recovery cost | Recovery steps |
|---|---|---|
| P1 locked modifier stuck (shipped) | LOW | Ship a `dismissed()` wire + test; the user's immediate workaround is re-summon → tap the chip, or disconnect (CONN-07 `release_all` frees it) |
| P2 drag-lock stuck (shipped) | LOW-MEDIUM | Add `TrackpadCoreState.dismissed()`; user workaround is re-summon → tap to drop. Higher urgency than P1 because a held left button corrupts drag-select in other apps |
| P3 wrong height context | MEDIUM | Split the height function. Cheap in code, but it invalidates every layout test written against the wrong number — write the discriminator tests first |
| P4 IME remount | MEDIUM-HIGH | Requires restructuring the overlay tree so the field is a sibling of the animating chrome; if the host shape is wrong this is a host rewrite. **This is why the host shape is a Phase-1 decision** |
| P5 overflow test "repaired" | HIGH (silent) | Nothing fails; discovery is by code review of the diff. Prevention only — put the delete-the-drain instruction in the plan text, not just here |
| P7 gesture conflict | LOW if caught in the phase | Swap to icon-toggle dismiss; the surface code does not change |
| P10 wakelock leak | LOW | Move acquire/release to the visibility transitions; the ref-count guard prevents the worst outcome already |
| P11 coverage loss | HIGH once merged | Re-derive from the deleted suites' header contract blocks in git history (`git show <sha>^:app/remote_control/test/...`) — which is why the checklist must be extracted **before** deletion |

---

## Pitfall-to-Phase Mapping

Phase numbers are **suggestions** for the roadmapper; the shape (host first,
surfaces second, retirement third, polish last) is the load-bearing part —
P3, P4 and P7 are all cheap to prevent and expensive to retrofit once the host
shape is chosen.

| Pitfall | Prevention phase | Verification |
|---|---|---|
| P1 locked modifier survives dismiss | **Ph1** host contract, **Ph3** wiring | Controller test through the bar's dismiss path + ported widget test asserting `up:WinLeft`; hardware check |
| P2 drag-lock leaves left button held | **Ph2** trackpad overlay | Widget test: dismiss-without-unmount emits exactly one `DragMsg(end)`, unmount emits none more |
| P3 pad-height clamp copied | **Ph3** keyboard overlay | Two discriminator tests where the naive read gives an obviously wrong number (model: `trackpad_screen_test.dart:256-274`) |
| P4 hidden IME remounted | **Ph1** host shape, **Ph3** assertion | `HiddenTextInput` `State` identity stable across summon/dismiss/summon; `findsOneWidget` while dismissed |
| P5 inverted overflow test | **Ph5** chip-row fit | The drain block is deleted and replaced by `takeException(), isNull`; 360dp guard added to `KeyboardScreen` too |
| P6 `showBubble` mechanical port | **Ph1** semantics, **Ph4** application | Test that the bar renders on the Trackpad screen and the Keyboard screen with the expected per-icon state |
| P7 gesture-arena conflict | **Ph1** dismiss gesture choice, **Ph2** implementation | Long vertical drag on the pad → moves recorded AND overlay still visible |
| P8 back / predictive back | **Ph1** host contract | Back-behaviour tests on hub and on a pushed screen, both overlay states; hardware predictive-back check |
| P9 summon jank | **Ph1** rebuild scoping, **Ph5** measurement | Body-rebuild-count test in CI + a profile-mode trace of 20 cycles with recorded worst-frame times |
| P10 wakelock lifecycle | **Ph2** trackpad overlay | `KeepAwake` spy: `activeCount` 0 after dismiss, 1 with Presenter open behind |
| P11 test migration coverage loss | **Ph1** write the checklist, **Ph4** execute | Every deleted suite's header contract list ticked off against a successor test; explicit `pump(Duration)` in all timing assertions |
| P12 undefined "every screen" | **Ph1** scope decision | The excluded-route list is written into the phase context with reasons; a test that no bar renders over the pairing dialog |
| P13 orphaned prefs / dead symbols | **Ph4** bubble retirement | `grep` for each deleted symbol returns nothing; the orphan decision is recorded in the phase SUMMARY |

---

## Sources

**Codebase (HIGH — every file read directly at the cited line):**
- `app/remote_control/lib/keyboard/keyboard_input_controller.dart` — `dismissed()` :143, `_flushHolds()` :165-175, `dispose()` :116, `_onDisconnected()` :107-112, `keyUp` remove-guard :224
- `app/remote_control/lib/keyboard/keyboard_panel.dart` — sole `dismissed()` call site :248, `didUpdateWidget` :228-251, raw-view read + rationale :379-408, `didChangeMetrics` :196-199, `HiddenTextInput` outside `AnimatedSize` :413-428, `_chipRow` :306-326
- `app/remote_control/lib/keyboard/keyboard_screen.dart` — dispose-only teardown :164-174, `HiddenTextInput` outside `PageView` :319-325, `_chipRow` :213-233
- `app/remote_control/lib/keyboard/key_pads.dart` — `panelPadHeight` :244-251, `kPanelMaxHeightFraction` :211, `kPanelMinPadHeight` :215, per-pad heights :193-206
- `app/remote_control/lib/keyboard/hidden_text_input.dart` — never-Offstage contract :8-14, :110-114
- `app/remote_control/lib/keyboard/key_rows.dart` — `KeyCap.dispose` CR-01 release :494-504
- `app/remote_control/lib/keyboard/modifier_chip.dart` — inner `Row` :76, `minWidth: 48` :69
- `app/remote_control/lib/trackpad/trackpad_core.dart` — dispose drag-end flush :198-211, `keepAwake.acquire()` :194, raw `Listener` :240-246, test seams :74-91
- `app/remote_control/lib/trackpad/trackpad_screen.dart` — `resizeToAvoidBottomInset` :150, `SafeArea` :152, panel slot rebuild discipline :294-312
- `app/remote_control/lib/trackpad/floating_trackpad_window.dart` — header-drag-is-a-sibling precedent :6-8, :16-23
- `app/remote_control/lib/widgets/bubble_scaffold.dart` — `showBubble` :61-68/:186, `PopScope` :157-165, body-never-rebuilds :10-12/:152-171, `_openFullTrackpad` :114-126, UIPI slot :176-183
- `app/remote_control/lib/widgets/keep_awake.dart` — ref-count :29-71
- `app/remote_control/lib/hub/hub_screen.dart` — `kHubTiles` :86-144, `showBubble` :73-93, central wrap `_open` :282-293, unwrapped `_openSettings` :296-302
- `app/remote_control/lib/main.dart` — `home: const HubScreen()` :116
- `app/remote_control/lib/trackpad/tuning.dart` — `kTapSlopPx` :17
- `app/remote_control/test/trackpad/trackpad_screen_test.dart` — inverted overflow drain :291-304, `expectColumnFits` :178-194, discriminator model :256-274
- `app/remote_control/test/hub_tiles_test.dart` — `kExpectedOrder` :15-25, positional pins :49-52
- `app/remote_control/test/hub/hub_screen_test.dart` — unlisted Trackpad-first pin :22-35
- `app/remote_control/test/theme_tokens_guard_test.dart`, `test/icons_guard_test.dart` — source-scanning guards
- Verified absences: zero `matchesGoldenFile` in `test/`; `TextField` only in `lib/screens/pairing_dialog.dart` and `lib/screens/device_list_screen.dart`

**Git history (HIGH):**
- `2779ecf` — quick `260812-tsw`, "release a locked modifier on panel dismiss" (message + full diff read)
- `18346b3` — quick `260812-uq8`, 5s reliable-queue TTL
- `.planning/quick/260809-ipc-unify-the-trackpad-docked-keyboard-panel/deferred-items.md` — items 1 (7.3px overflow, exact geometry) and 2 (locked modifier survives collapse)

**Planning artifacts (HIGH):**
- `.planning/notes/summon-bar-trackpad-keyboard.md` — the five landmines, D8-05/D8-06/D-10 reversals, scope list
- `.planning/PROJECT.md` — v1.1 requirements and speed contract
- `.planning/STATE.md` — Accumulated Context (08-02/08-04/08-05/08-06, 07-09, 07-10, 03-05, 03-07, 04-05, 04-06), Deferred Items, quick-task table (882 tests)
- `.planning/MILESTONES.md:66-77` — "A SUMMARY on disk is not an outcome"

**External (MEDIUM — web-sourced, cross-checked across results, not verified on this hardware):**
- Impeller default on Android API 29+ since Flutter 3.27; precompiled shader set; Skia-era `--purge-persistent-cache` no longer the mitigation — [Shader compilation jank | Flutter](https://liudonghua123.github.io/flutter_website/perf/shader/), [Impeller wiki](https://github.com/flutter/flutter/wiki/Impeller/ffbc9fd551cf9913ebc1fc3a47ed2a8d9dad815e)
- Android predictive back does not animate while `PopScope.canPop` is false — [Android predictive back | Flutter docs](https://docs.flutter.dev/release/breaking-changes/android-predictive-back), [PopScope.canPop API](https://api.flutter.dev/flutter/widgets/PopScope/canPop.html)

---
*Pitfalls research for: v1.1 The Summon Bar — adding a persistent overlay-summon surface to a shipped Flutter + Rust remote-control app*
*Researched: 2026-08-12*
