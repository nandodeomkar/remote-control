---
quick_id: 260809-ipc
phase: quick-260809-ipc
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - app/remote_control/lib/keyboard/keyboard_input_controller.dart
  - app/remote_control/lib/keyboard/keyboard_panel.dart
  - app/remote_control/lib/keyboard/keyboard_screen.dart
  - app/remote_control/lib/keyboard/key_pads.dart
  - app/remote_control/lib/keyboard/key_rows.dart
  - app/remote_control/test/keyboard/keyboard_input_controller_test.dart
  - app/remote_control/test/keyboard/keyboard_panel_test.dart
  - app/remote_control/test/keyboard/key_pads_store_test.dart
  - app/remote_control/test/keyboard/key_pads_test.dart
  - app/remote_control/test/keyboard/key_rows_test.dart
  - app/remote_control/test/keyboard/pad_widgets_test.dart
  - app/remote_control/test/trackpad/trackpad_screen_test.dart
autonomous: true
requirements:
  - QUICK-260809-ipc-unify-docked-keyboard-panel
user_setup: []

must_haves:
  truths:
    - "Opening the keyboard from the trackpad shows the SAME four pads in the same order, with the same labels and icons, as the full-screen keyboard — swipeable, with the same bottom tab bar (D-92)"
    - "The trackpad stays LIVE at every pad height: with the tallest pad open, a drag on the shrunken surface still produces move frames on the service (D-93)"
    - "The height clamp BINDS where it matters — with the IME raised and on a short viewport the trackpad floor still holds, proven by two tests that FAIL against the naive MediaQuery formula (B2)"
    - "The panel is a slim strip on Type and grows for Arrows / Numpad / Fn, animating over the existing 200ms ease (D-93)"
    - "The system IME rises only on the panel's Type pad and lowers on the other three"
    - "The panel's last-open pad survives a restart, and an existing install's Fn / Num row-group choice arrives as Fn / Numpad (D-94)"
    - "There is exactly ONE implementation of the stuck-key model; a change to it is visible on both surfaces (D-95)"
    - "CR-01, CR-02, IN-04, D-10/D-11 and D-12 are each proven on the shared owner AND on both surfaces — including a panel-surface IN-04 cancelled-press test and a panel collapse-mid-hold test, neither of which exists today"
    - "The LIVE-only dispose flush stays LIVE-only on both surfaces: never into a dead socket, never into a new session"
    - "No second keyboard vocabulary remains in lib/ — the Nav/Fn/Num row-group surface is gone, key and all, comments included"
    - "trackpad_screen.dart is byte-unchanged, so the Pitfall-6 ValueListenableBuilder isolation cannot have regressed"
  artifacts:
    - path: "app/remote_control/lib/keyboard/keyboard_input_controller.dart"
      provides: "the ONE owner of ModifierFsm + held set + IME reset tick + D-12 transition + LIVE-only dispose flush, shared by both surfaces"
      contains: "class KeyboardInputController"
      min_lines: 120
    - path: "app/remote_control/test/keyboard/keyboard_input_controller_test.dart"
      provides: "the sacred invariants proven once, directly on the owner, with no widget"
      contains: "CR-02"
    - path: "app/remote_control/lib/keyboard/keyboard_panel.dart"
      provides: "the docked panel rebuilt as a swipeable four-pad deck with the shared tab bar and an inset-correct per-pad height"
      contains: "MediaQueryData.fromView"
    - path: "app/remote_control/lib/keyboard/key_pads.dart"
      provides: "the docked-panel sizing contract: chrome height, per-pad viewport heights, the fraction clamp, panelPadHeight()"
      contains: "kPanelPadHeights"
    - path: "app/remote_control/lib/keyboard/key_rows.dart"
      provides: "keyboard.panelPad persistence on the KeyboardPad model + the one-time read of the retired key; the row-group surface deleted"
      contains: "kPanelPadPrefsKey"
    - path: "app/remote_control/test/keyboard/keyboard_panel_test.dart"
      provides: "the panel surface's own dispose, IN-04, collapse-mid-hold, height, IME and persistence proofs"
      contains: "IN-04"
    - path: "app/remote_control/test/trackpad/trackpad_screen_test.dart"
      provides: "the trackpad is USABLE (not merely present) with the tallest pad open, under real safe-area and IME insets"
      contains: "TrackpadCore"
  key_links:
    - from: "app/remote_control/lib/keyboard/keyboard_panel.dart"
      to: "app/remote_control/lib/keyboard/keyboard_input_controller.dart"
      via: "the panel State constructs and disposes the one shared owner"
      pattern: "KeyboardInputController\\("
    - from: "app/remote_control/lib/keyboard/keyboard_screen.dart"
      to: "app/remote_control/lib/keyboard/keyboard_input_controller.dart"
      via: "the screen State constructs and disposes the SAME owner class"
      pattern: "KeyboardInputController\\("
    - from: "app/remote_control/lib/keyboard/keyboard_panel.dart"
      to: "app/remote_control/lib/keyboard/key_pads.dart"
      via: "the pad viewport height for the current pad"
      pattern: "panelPadHeight\\("
    - from: "app/remote_control/lib/keyboard/keyboard_panel.dart"
      to: "app/remote_control/lib/keyboard/key_rows.dart::panelPadProvider"
      via: "docked-panel pad persistence on the KeyboardPad model"
      pattern: "panelPadProvider"
    - from: "app/remote_control/lib/keyboard/keyboard_panel.dart"
      to: "dart:ui View.of(context) raw window metrics"
      via: "the real column height, which the ancestor MediaQuery cannot supply in this tree"
      pattern: "MediaQueryData\\.fromView"
---

<objective>
The app ships TWO keyboards. Hub → Keyboard opens `KeyboardScreen`: four
full-screen pads (Type | Arrows | Numpad | Fn), persistent modifier chips,
a bottom tab bar. Trackpad → keyboard button opens `KeyboardPanel`: a ~200px
strip with a Nav | Fn | Num segmented switcher and small caps.

This is not a bug. `10-CONTEXT.md` line 15 put the docked panel explicitly out
of scope for the phase-10 rethink, and 10-03/10-04/10-05 each carried an
acceptance criterion asserting `keyboard_panel.dart` stayed byte-unchanged. The
rethink reached one of the two keyboards. Key CODE coverage is already
equivalent — what diverges is the layout, the section vocabulary, the
persistence, and, worst, the stuck-key safety model, which 10-05 duplicated
verbatim into a second file.

Three changes, all client-side, across four tasks:

1. **Collapse the duplicated stuck-key logic into ONE owner** — a plain
   `KeyboardInputController` object each surface constructs and disposes. Pure
   collapse, zero behavior change, both existing suites green with zero edits
   to existing test bodies. (Task 1)
2. **Give the panel the four-pad vocabulary** — same order, same
   `kKeyboardTabLabels` / `kKeyboardTabIcons`, same `KeyboardTabBar`, a
   swipeable `PageView`, and a per-pad height that animates on the panel's
   existing 200ms ease while the trackpad shrinks above it and stays live.
   (Tasks 2 + 3)
3. **Converge persistence on `KeyboardPad` and retire the row-group surface** —
   `keyboard.panelPad` for the panel, `keyboard.pad` for the screen, a one-time
   read of the retired key, and the deletion of `KeyRowGroup` and everything
   downstream of it. (Tasks 2 + 4)

Purpose: one keyboard, two mount points. A stuck-key fix applied once lands on
both surfaces.
Output: `keyboard_input_controller.dart` + its suite; a rebuilt
`keyboard_panel.dart`; panel sizing consts in `key_pads.dart`; panel pad
persistence in `key_rows.dart`; the row-group surface deleted.
</objective>

<execution_context>
@$HOME/.claude/gsd-core/workflows/execute-plan.md
@$HOME/.claude/gsd-core/templates/summary.md
</execution_context>

<context>
@.planning/STATE.md
@./CLAUDE.md
@.planning/phases/10-keyboard-rethink-and-shortcuts-tile-full-screen-swipeable-ke/10-UI-SPEC.md
@app/remote_control/lib/keyboard/keyboard_panel.dart
@app/remote_control/lib/keyboard/keyboard_screen.dart
@app/remote_control/lib/keyboard/key_pads.dart
@app/remote_control/lib/keyboard/key_rows.dart
@app/remote_control/lib/keyboard/modifier_fsm.dart
@app/remote_control/lib/trackpad/trackpad_screen.dart
@app/remote_control/test/keyboard/keyboard_panel_test.dart
@app/remote_control/test/keyboard/keyboard_screen_test.dart
</context>

<decision_id_legend>
Owner decisions locked for THIS task are numbered **D-91 … D-95**, deliberately
outside the legacy phase-4 / phase-10 range so they can never be confused with
the older project decisions (`D-07` docked panel, `D-09` row groups, `D-10`
sticky modifiers, `D-11` server autorepeat, `D-12` disconnect reset). When this
plan says `D-07` it means the phase-4 decision; when it says `D-93` it means an
owner decision from the 2026-08-09 conversation.
</decision_id_legend>

<locked_decisions>
These came from the owner. They are LOCKED. Do not revisit, do not
re-litigate, do not offer alternatives.

- **D-91 — the panel STAYS docked under a LIVE trackpad.** The trackpad must
  remain usable for cursor movement while typing; that is D-07's entire reason
  to exist. Do NOT route the trackpad's keyboard button to `KeyboardScreen`.
  Do NOT delete `KeyboardPanel`.
- **D-92 — adopt the four-pad vocabulary in the panel.** Replace the Nav/Fn/Num
  segmented switcher with Type | Arrows | Numpad | Fn — same order, same
  `kKeyboardTabLabels`, same `kKeyboardTabIcons`, swipeable `PageView` plus the
  shared `KeyboardTabBar`, matching the full-screen surface.
- **D-93 — panel height varies per pad.** Type stays a slim strip; Arrows
  medium; Numpad and Fn expand taller. The trackpad shrinks above but stays
  LIVE at every height. Height changes animate on the panel's existing 200ms
  ease.
- **D-94 — unify persistence on the `KeyboardPad` model.** `KeyRowGroup` is
  retired. The retired `keyboard.rowGroup` key is migrated, not orphaned in
  code.
- **D-95 — collapse the duplicated stuck-key logic into ONE shared owner.**
  One owner, both surfaces.
</locked_decisions>

<decisions_this_plan_makes>
D-94 and D-95 delegated two choices to this plan. Both are resolved here and
must NOT be re-opened by the executor.

## 1. The shared owner is a plain controller object, not a mixin, not a lift

**Chosen:** `KeyboardInputController` — a plain Dart object, constructed in each
surface's `initState`, disposed from each surface's own `dispose()`.

Why, against the two alternatives:

- **A `State` mixin** would work but cannot be unit-tested without pumping a
  widget, so every sacred invariant would still only ever be provable twice,
  through two widget harnesses. That is the disease, not the cure. It also
  needs abstract getters to paper over the fact that the two surfaces reach the
  service differently (the panel takes injected `send` / `changes` /
  `isDisconnected` seams; the screen holds `_service` directly).
- **A lifted holder** (InheritedWidget / provider) would move ownership away
  from the surfaces — and ownership IS lifecycle. The panel is a docked child
  built and disposed with the trackpad screen; the screen is a route pushed and
  popped. A holder above both would decouple the flush from those two very
  different teardown moments, which is exactly the timing the risk section says
  must be preserved.
- **A plain object** preserves dispose timing by construction: nothing changes
  about WHEN `dispose()` runs, only WHERE the flush code lives. It is also the
  house pattern already — `ModifierFsm` (pure, effects out, driver executes),
  `ImeDiffProducer` (injected emitter), `TrackpadDriver` (plain engine) are all
  the same shape. And it is directly unit-testable: a test can drive
  `keyDown` / `keyUp` / the disconnect transition / `dispose()` and assert the
  exact `KeyMsg` sequence with no widget at all.

**Dispose timing, named per surface.** Flutter unmounts children BEFORE parents
(`_InactiveElements._unmount` recurses into `visitChildren` first), so a held
`KeyCap` releases through `KeyCap.dispose` → `controller.keyUp` → the
`remove()` guard, and only then does the surface's own `dispose()` run its
flush. That ordering is what makes each owed up fire exactly once, and it is
unchanged by this refactor. The tests that prove it, by name — every one of
them exists or is created in **Task 1**:

| Surface | Test that proves dispose timing |
|---|---|
| `KeyboardScreen` (route pop) | `keyboard_screen_test.dart` — `screen-dispose LIVE flush: a held cap AND a locked modifier both get their ups when the screen is popped on a live socket` (asserts the set AND the length: exactly once each) and `screen-dispose on a DISCONNECTED socket: NO sends`. Both already exist; both must stay green with untouched bodies. |
| `KeyboardPanel` (docked child) | `keyboard_panel_test.dart` — a NEW `panel-dispose LIVE flush` / `panel-dispose on a DISCONNECTED socket sends NOTHING` pair, added in Task 1, mirroring the screen's two, driven by unmounting the host |
| `KeyboardPanel` (collapse, not unmount) | `keyboard_panel_test.dart` — a NEW `collapsing the panel mid-hold releases the held key exactly once` test, added in Task 1. This path exists TODAY (collapsing swaps the chrome for a zero-height box, unmounting the caps) and is untested today. |
| Owner, surface-free | `keyboard_input_controller_test.dart` — `dispose on a LIVE socket flushes owed ups then releaseAll(), in that order` and `dispose on a DISCONNECTED socket sends NOTHING` |
| Pad/page leave | `keyboard_screen_test.dart` `CR-01: a cap held across a PAGE LEAVE releases`; `pad_widgets_test.dart` `CR-01: a pad disposed mid-hold releases its held key` |

## 2. Persistence: SEPARATE keys, ONE model

**Chosen:** the panel persists to a NEW key `keyboard.panelPad`; the full-screen
keyboard keeps `keyboard.pad`. Both hold `KeyboardPad` enum names. `KeyRowGroup`
and `kKeyRowGroupPrefsKey` are deleted.

Why separate rather than one shared selection:

1. **The two pads have different physical consequences.** The panel's pad
   choice resizes the live trackpad next to it; the screen's does not. A shared
   key means an action on one surface silently resizes the other surface's
   neighbour — the user taps Numpad on the full-screen keyboard, and the next
   time they open the trackpad panel the trackpad has lost 230dp for no reason
   they can see.
2. **The surfaces are used for different jobs.** The panel exists to type WHILE
   the cursor is live (D-07), so it is dominated by Type and Arrows; the full
   screen is where Numpad and Fn get real use. A shared key would have each
   surface continually yanking the other's landing pad.
3. **The migration only makes sense per-surface.** The retired
   `keyboard.rowGroup` was the PANEL's preference. Folding it into a shared key
   would rewrite the full-screen keyboard's landing pad from a docked-panel
   choice the user made about a different surface.

What D-94 actually asks for — one model, no duplication — is satisfied by
deleting `KeyRowGroup` and putting both surfaces on `KeyboardPad` with one
parameterized `KeyboardPadStore`. The prefs KEY is a mount-point preference,
and mount points legitimately differ.

**Retiring `keyboard.rowGroup` cleanly.** `PrefsKv` has no `remove()` and has
**28 implementers** (1 real + 27 test fakes), so widening that seam to delete
one string is not worth it and is out of scope. Instead the panel store does a
**one-time read**: when `keyboard.panelPad` is unset it reads
`keyboard.rowGroup` once, maps it, and immediately writes `keyboard.panelPad`,
so the legacy read never happens again. Mapping:

| Retired value | New pad | Why |
|---|---|---|
| `fn` | `KeyboardPad.fn` | a deliberate choice, and it has an exact successor |
| `num` | `KeyboardPad.numpad` | same |
| `nav` / unset / unknown / read throws | `KeyboardPad.type` | `nav` was the DEFAULT nobody chose, and it has no single successor — its caps split across Type and Arrows. Landing an upgrading user on the slim Type strip is also the least disruptive first open. |

After this, no code anywhere references the retired constant: it survives only
as a private literal inside the migration, and the test pins the literal
`'keyboard.rowGroup'` by hand so the migration cannot drift.

## 3. Paging glue stays per-surface — deliberately, with a named extraction point

The `PageController` + `onPageChanged` + one-shot async-restore-jump glue is
~25 lines and will exist on both surfaces. This is a knowing, bounded
duplication and it is NOT the duplication D-95 is about: a paging bug is
cosmetic, a stuck-key bug holds a real key down on the owner's PC. The panel's
deck also has requirements the screen's does not (it lives inside an animating
fixed-height box and must handle collapse). Everything genuinely shareable —
`kKeyboardTabLabels`, `kKeyboardTabIcons`, `KeyboardTabBar`, `capsForPad`, the
four pad widgets, `KeyCap`, and now `panelPadHeight()` — is already shared by
reference from `key_pads.dart` / `key_rows.dart`.

If a THIRD keyboard surface is ever added, extract `KeyboardPadDeck` (PageView +
tab bar + restore jump + IME raise/lower) first. Do not do it in this task.
</decisions_this_plan_makes>

<sizing_contract>
D-93 requires actual numbers. **Read this whole section before touching
`key_pads.dart` or `keyboard_panel.dart`.** The numbers are binding and the
`columnHeight` derivation is the single most delicate thing in this plan.

## Which figures are real constants and which are chosen targets

Do not go hunting `key_pads.dart` for a `64`. It is not there.

- **Real constants in `key_pads.dart`:** `_kPadPadding = 16`, `_kGap = 8`,
  `_kGapLg = 24`, `_kTypeRowHeight = 48`, `_kShortRowHeight = 56`,
  `_kTabBarHeight = 56`. Plus `KeyCap`'s hard `minHeight: 48` in
  `key_rows.dart`.
- **Chosen targets** (the pads size by `Expanded` flex, so they have no
  intrinsic height): the **64px Numpad row** and the **76px Arrows inverted-T
  cell**. These come from 10-UI-SPEC §Spacing ("64px minimum large-cap height
  on Arrows/Numpad/Fn pads") and are the figures this plan picks so that a
  docked panel still gives finger-sized caps. They are TARGETS that yield on
  short devices; the hard contract is "never overflows".

## Panel chrome (constant across pads)

**1px `HiddenTextInput`** + 1px top hairline + 64px modifier-chip row (48px
`ModifierChip` floor + 8px top + 8px bottom padding) + 56px `KeyboardTabBar` =
**`kPanelChromeHeight` = 122**.

> **The first pixel is NOT a rounding artifact and must never be tidied away.**
> `keyboard_panel.dart:280-313` is
> `Column(mainAxisSize: min, children: [HiddenTextInput, AnimatedSize(...)])`, and
> `hidden_text_input.dart:115-118` is a real `SizedBox(width: 1, height: 1)` that
> is laid out in BOTH states — deliberately never `Offstage`, because detaching it
> drops the Android input connection (04-05 Pitfall 6). It therefore contributes a
> real pixel to the panel's rendered height. Counting it is also what keeps the
> D-91 guarantee exact: with 122, a clamped panel renders at exactly
> `0.55 × columnHeight`, so the trackpad lands on `0.45 × columnHeight − 64`
> identically rather than a pixel under it. Put this reasoning in the constant's
> doc comment.

## Pad viewport heights (the animating `SizedBox` around the `PageView`)

| Pad | Arithmetic | Viewport | Panel total |
|---|---|---|---|
| Type | 32 padding + 48 extras row | **80** | **202** |
| Arrows | 32 padding + 56 top row + 24 lg gap + 160 inverted-T (2 × 76 + 8) | **272** | **394** |
| Numpad | 32 padding + 4 × 64 rows + 3 × 8 gaps | **312** | **434** |
| Fn | 32 padding + 56 Esc + 8 + 3 × 64 rows + 2 × 8 gaps | **304** | **426** |

Type ≈ today's ~200px strip (D-93: "Type stays a slim strip"); Arrows medium;
Numpad and Fn tallest. Order matches D-93 exactly.

## THE COLUMN HEIGHT — why the obvious formula is WRONG here

The naive read — `MediaQuery.sizeOf(context).height -
MediaQuery.paddingOf(context).top - MediaQuery.viewInsetsOf(context).bottom` —
**silently returns the full window height inside this widget tree**, and must
not be used. Verified against the Flutter SDK, not assumed:

- `trackpad_screen.dart:147-153` is
  `Scaffold(resizeToAvoidBottomInset: true, body: SafeArea(child: Column(...)))`
  and the panel is a child of that Column (mounted at `:299`).
- `Scaffold` passes `removeBottomInset: _resizeToAvoidBottomInset` into
  `_addIfNonNull`, which runs `data.removeViewInsets(removeBottom: true)`
  (`packages/flutter/lib/src/material/scaffold.dart:2921`, called at `:3034`).
  So inside the body **`viewInsets.bottom == 0`** — the IME height is gone.
- `SafeArea` wraps its child in `MediaQuery.removePadding`, so inside the panel
  **`padding.top == 0` and `padding.bottom == 0`**.
- Neither widget touches `size`, so **`size.height` is still the FULL window
  height**.

Net effect of the naive formula: the panel computes its ceiling against a
column larger than the one it actually shares with the trackpad — over by the
status inset, the bottom safe inset, and the ENTIRE IME height. The clamp is the
only thing protecting the live-trackpad guarantee on short devices and with the
IME raised, which is precisely where it would stop binding. A test run on an
inset-free harness cannot catch this: at zero insets the wrong formula and the
right one agree exactly.

**There is a second consequence.** Because the panel's resulting MediaQueryData
is value-equal across an IME animation (`viewInsets.bottom` zeroed, `padding`
zeroed, `size` and `viewPadding` unchanged), `MediaQuery.of` would not even
notify the panel when the IME rises or falls. The height would go stale mid
transition — and Type → Numpad, which lowers the IME while the panel grows by
232px, is exactly a transition where a stale (too large) column reading and a
growing panel race each other into a `RenderFlex` overflow.

## THE COLUMN HEIGHT — what to do instead

Read the RAW window metrics, bypassing every ancestor MediaQuery, and subscribe
to metric changes explicitly:

```dart
// In _KeyboardPanelState, which is `with WidgetsBindingObserver`:
//   initState:  WidgetsBinding.instance.addObserver(this);
//   dispose:    WidgetsBinding.instance.removeObserver(this);
//   @override void didChangeMetrics() { if (mounted) setState(() {}); }

final view = MediaQueryData.fromView(View.of(context));
final columnHeight = view.size.height
    - view.viewPadding.top                                   // SafeArea top
    - math.max(view.viewPadding.bottom, view.viewInsets.bottom);
```

- `viewPadding` is IME-independent, so `viewPadding.top` is the status inset
  `SafeArea` consumes whether or not the IME is up.
- At the bottom the Column loses whichever is larger: the IME (removed by
  `resizeToAvoidBottomInset`) or the bottom safe inset (removed by `SafeArea`).
  When the IME is up its inset always exceeds the nav-bar inset, since both are
  measured from the window edge — so `max()` is exactly right and never
  double-counts.
- `View.of(context)` depends on the view scope, which does NOT rebuild on
  metric changes; `didChangeMetrics` is what supplies the rebuild. Both halves
  are required. Say so in a code comment at the call site so a later reader
  does not "simplify" this back into the naive form.

**Rejected alternative, recorded so it is not re-litigated:** making the panel a
`Flexible(flex: 55, fit: FlexFit.loose)` beside `Expanded(flex: 45)` in the
trackpad Column would express the same 45/55 split in pure layout with no
metrics maths — but it requires editing `trackpad_screen.dart` (giving up the
byte-unchanged guarantee) and it fights `AnimatedSize`, which needs a child with
an intrinsic height to tween between.

## The clamp

```
ceiling  = columnHeight * kPanelMaxHeightFraction /* 0.55 */ - kPanelChromeHeight
viewport = max(kPanelMinPadHeight /* 96 */, min(kPanelPadHeights[pad], ceiling))
```

Guarantee, at any window size:

> **live trackpad height ≥ 0.45 × columnHeight − 64**

with one documented exception: when `kPanelMinPadHeight` binds (column below
~290dp, reachable only with the IME raised on a very short device) the fraction
yields to the 96px floor. Even then the panel totals 217 and the trackpad keeps
`columnHeight − 281`, which stays positive across every plausible device.

Caps flex below the 64px target when the ceiling binds. `KeyCap`'s
`minHeight: 48` is enforced against the incoming constraints
(`BoxConstraints.enforce`, `key_rows.dart:650`), so a tight cell wins and there
is **no RenderFlex overflow**.

## Resulting numbers

Reference device **411 × 891** logical, 24dp status inset, **24dp bottom safe
inset** (gesture nav), IME down, `MouseButtonsBar` at its default 64px.
`columnHeight = 891 − 24 − 24 = 843`; `ceiling = 843 × 0.55 − 121 = 342.65`, so
no pad is clamped:

| Pad open | Panel | Live trackpad remaining |
|---|---|---|
| Type | 201 | **578** |
| Arrows | 393 | **386** |
| Fn | 425 | **354** |
| Numpad (tallest) | 433 | **346** |

**Minimum live trackpad at the tallest pad: 346dp** on gesture nav; **322dp**
with a 48dp three-button nav bar (`columnHeight = 819`). Both comfortably
usable — today's entire panel is ~200dp.

Three further states, each of which is a REQUIRED test because each
discriminates the correct formula from the naive one:

| State | columnHeight | Panel | Trackpad (correct) | Trackpad (naive) |
|---|---|---|---|---|
| Type pad, IME raised 290dp, 411×891 | 577 | 201 | **312** | 312 (agrees — not a discriminator) |
| Numpad, IME inset still 290dp mid-transition, 411×891 | 577 | 317.35 | **195.65** | 80 — **fails the floor** |
| Numpad, short 360×640, insets 24/24 | 592 | 325.6 | **202.4** | 176 — **fails the floor** |

The floor asserted in those tests is `0.45 × columnHeight − 64`, computed in the
test from the driven metrics rather than hard-coded, so the assertion cannot
drift from the guarantee.

## Consequence for the trackpad screen

`KeyboardPanel`'s constructor signature does not change and
**`trackpad_screen.dart` is not modified by this plan at all.**
`git diff --quiet app/remote_control/lib/trackpad/trackpad_screen.dart` is an
acceptance criterion on every task — the Pitfall-6 isolation cannot have
regressed if the file was never touched.
</sizing_contract>

<already_established>
Facts confirmed by reading the tree and the Flutter SDK on 2026-08-09, several
independently re-verified by the plan checker. Do not re-derive them.

- `KeyboardPanel` has exactly ONE consumer: `trackpad_screen.dart:299`
  (inside the `ValueListenableBuilder<bool>` on `_panelExpanded`).
  `floating_trackpad_window.dart` does NOT mount it.
- `KeyRowGroup` / `keyRowGroupProvider` / `KeyRowGroupStore` /
  `KeyRowGroupSwitcher` / `KeyRows` / `capsForGroup` / `kNavClusterCaps` are
  consumed ONLY by `keyboard_panel.dart` and their own tests. Once the panel
  moves to pads they are dead. **But their NAMES also appear in doc comments in
  three other files** — see Task 4's enumerated list.
- `KeyCap` is PUBLIC and shared BY REFERENCE between both surfaces
  (`key_rows.dart:474`; `KeyRows` at `:355`, the switcher at `:671`). Its press
  model — `_live` / `_deferred`, IN-04 always-wired releases, CR-01 dispose
  release — must NOT be re-implemented, wrapped, or forked.
- `ValueKey('cap-<code>')` is set inside `KeyCapState` itself
  (`key_rows.dart:636`) and is therefore shared by pads and rows alike, so every
  existing `find.byKey(ValueKey('cap-...'))` finder survives the panel rebuild.
- The four pads and `KeyboardTabBar` are widget-only and service-agnostic,
  taking the same six-field injected-callback contract. They need no service
  fake.
- `pad_widgets_test.dart` already proves the shared emission model on pads:
  down/up ordering (`:225`), deferred tap+mods (`:248`), gated-inert (`:257`),
  IN-04 mid-press gate flip (`:267`), CR-01 dispose release (`:285`). Deleting
  the `KeyRows`-hosted duplicates in `key_rows_test.dart` loses nothing —
  EXCEPT the 48px touch-target floor assertion at `key_rows_test.dart:165`,
  which exists nowhere else and must be re-homed.
- `MouseButtonsBar` defaults to `height: 64`; the trackpad screen uses the
  default. `ModifierChip` has a 48px floor → the 64px chip row.
  `KeyboardTabBar` is 56 with an inner `SafeArea(top: false)` that contributes 0
  under the outer `SafeArea`.
- `Scaffold` strips the body's bottom view insets when
  `resizeToAvoidBottomInset` is true (`scaffold.dart:2921`, called `:3034`), and
  `SafeArea` strips padding. See `<sizing_contract>` — this is the B2 trap.
- `hapticTick()` is a top-level function gated on a cached bool — no `ref`, no
  widget. Safe to call from a plain controller object; already exercised in
  widget tests.
- `trackpad_core_test.dart:61-87` has `_RecordingService extends
  ConnectionService` with a `moves` list, a `reliable` list and a settable
  `authed` flag. Reuse that shape for the trackpad-live tests.
- `pumpAndSettle` cannot be used on any screen carrying `ConnectionHeaderChip`
  (its 500ms `Timer.periodic` never settles). Use explicit `pump(Duration)`.
  Tab-driven page changes need `pump()` (start the ticker) + `pump(250ms)`
  (run) + `pump()` (settle/dispose) — a single `pump(250ms)` never moves.
- `keyboard_panel_test.dart` currently holds **13** `testWidgets` and
  `keyboard_screen_test.dart` holds **10**. The panel has NO dispose-flush test
  and NO IN-04 test; the screen has both. Record real before/after counts.
- No test file outside the Task 3 / Task 4 file lists references any API this
  plan deletes.
</already_established>

<out_of_scope>
- **Server, extension, protocol.** No `SERVER_PROTO_VERSION` bump, no keymap
  change, no new key codes, no change to `kClientKeyCodes`. `server/` and
  `extension/` are not touched.
- **The typing path.** `HiddenTextInput`, `ImeDiffProducer`, `diff_ops.dart`
  are unchanged.
- **`trackpad_screen.dart`.** Byte-unchanged. Gated on every task.
- **Routing the trackpad keyboard button to `KeyboardScreen`, or deleting the
  panel** — forbidden by D-91.
- **Renaming `key_rows.dart`.** It still owns `kClientKeyCodes`, `KeyCapDef`,
  `KeyCap`, the pad cap tables and the pad stores. The filename is a historical
  artifact; leave it.
- **Extracting `KeyboardPadDeck`.** See decision 3 above.
- **Adding `remove()` to `PrefsKv`.** 28 implementers.
- **Making the panel a `Flexible` sibling of the trackpad.** See the rejected
  alternative in `<sizing_contract>`.
- **Changing what a panel COLLAPSE does to a locked modifier.** Today collapsing
  unmounts the caps (so held caps release) but the panel State survives, so a
  LOCKED modifier stays physically held. That is today's shipped behavior and it
  is preserved verbatim — Task 1's new collapse test pins the CAP half only. Do
  not "fix" the modifier half here; note it in the SUMMARY as an observation if
  you think it is wrong.
- **Adding any keep-alive** to any `PageView`, on either surface. Leaving a pad
  MUST dispose its caps — that dispose is the CR-01 release mechanism.
</out_of_scope>

<house_style>
- No inline copy literals — every user-visible string is a named const.
- `Symbols.*_rounded` only; classic `Icons.*` is banned in `lib/` by
  `icons_guard_test`.
- Only the seven `tokens.dart` colors; the palette guard forbids additions.
- Only `w400` and `w600` font weights.
- Pads and rows stay widget-only and service-agnostic (injected callbacks).
- **Grep-gate hygiene — this project has been bitten TWICE (see 12-16's carried
  notes in STATE.md).** Where a gate demands zero occurrences of an identifier
  in `lib/`, that means zero occurrences *including in comments and doc
  comments*. Do not write prose that spells a banned identifier; say "the
  retired Nav/Fn/Num row-group switcher" instead. Gates in this plan are
  deliberately UNFILTERED for exactly that reason.
</house_style>

<tasks>

<task type="auto" tdd="true">
  <name>Task 1: ONE owner — KeyboardInputController, a behavior-neutral collapse (D-95)</name>
  <files>app/remote_control/lib/keyboard/keyboard_input_controller.dart, app/remote_control/test/keyboard/keyboard_input_controller_test.dart, app/remote_control/lib/keyboard/keyboard_panel.dart, app/remote_control/lib/keyboard/keyboard_screen.dart, app/remote_control/test/keyboard/keyboard_panel_test.dart</files>
  <read_first>
    - app/remote_control/lib/keyboard/keyboard_panel.dart (L100-229 — the donor: _fsm, _heldCodes, _imeResetTick, _changesSub/_wasDisconnected, _onDisconnected, dispose flush, _sendEffects, _onChipTap, _onChipLongPress, _onKeyDown, _onKeyUp, _onKeyTapWithMods)
    - app/remote_control/lib/keyboard/keyboard_screen.dart (L84-260 — the verbatim copy 10-05 made of all of the above)
    - app/remote_control/lib/keyboard/modifier_fsm.dart (tap / longPress / onNonModifierTap / disconnected / releaseAll / stateOf / modsForTap and the Pitfall-7 rationale)
    - app/remote_control/test/keyboard/keyboard_screen_test.dart (L305-352 — the two dispose tests whose shape the new panel pair mirrors; L233-251 — the IN-04 cancelled-press test whose shape the new panel IN-04 test mirrors)
  </read_first>
  <behavior>
    `KeyboardInputController` in a new file, constructed with four seams:
    `send` (void Function(RemoteMessage)), `changes` (`Stream<void>`),
    `isDisconnected` (bool Function()), `onChanged` (VoidCallback — the
    surface's setState hook). It subscribes to `changes` in its constructor,
    seeding `_wasDisconnected = isDisconnected()`.

    Tests, written FIRST, driving the controller with no widget at all (a
    recording `send` list, a broadcast `StreamController<void>`, a mutable
    `disconnected` bool):

    - D-11 hold: `keyDown('Right')` then `keyUp('Right')` sends exactly
      `down:Right, up:Right`.
    - CR-02 rollover: down Right, down Down, up Right, up Down sends
      `down:Right, down:Down, up:Right, up:Down`.
    - CR-02 remove-guard: `keyUp('Right')` for a code never downed sends
      NOTHING (this is the same guard that makes IN-04's forwarded releases and
      the cap-level dispose release idempotent).
    - D-10 arm: `chipTap(Mod.ctrl)` sends nothing and fires `onChanged`;
      `keyTapWithMods('Esc')` then sends exactly one `tap:Esc mods:[ctrl]` and
      the FSM auto-resets, so a second `keyTapWithMods('Esc')` sends
      `tap:Esc mods:[]`.
    - D-10 lock: `chipLongPress(Mod.win)` sends `down:WinLeft`;
      `chipTap(Mod.win)` sends `up:WinLeft`.
    - D-12: with Win locked and Right held, flipping `disconnected` true and
      pinging `changes` sends ZERO frames, empties the held set, increments
      `imeResetTick`, and returns every chip to rest. A subsequent
      `keyUp('Right')` still sends nothing.
    - D-12 edge: the disconnected→connected transition fires NO reset (only the
      false→true edge does), and a repeated ping while already disconnected
      fires nothing.
    - Dispose LIVE: with Esc held and Win locked and the socket live,
      `dispose()` sends `up:Esc` then `up:WinLeft` — owed cap ups first, then
      `releaseAll()`, in that order.
    - Dispose DISCONNECTED: same setup but `isDisconnected()` true → `dispose()`
      sends NOTHING (never into a dead socket, never into a NEW session).
    - Dispose cancels the `changes` subscription: a ping after `dispose()`
      sends nothing and does not throw.
  </behavior>
  <action>
    Write `keyboard_input_controller_test.dart` first (RED), then the controller
    (GREEN), then rewire both surfaces (still GREEN).

    Move the donor bodies VERBATIM — copy, do not re-derive. Preserve the
    `dispose()` statement order exactly as both donors have it: cancel the
    subscription, then `if (!isDisconnected())` flush owed cap ups from
    `_heldCodes.toList()` followed by `_sendEffects(_fsm.releaseAll())`, then
    `_heldCodes.clear()`, then `imeResetTick.dispose()`. Preserve `keyUp`'s
    `if (!_heldCodes.remove(code)) return;` guard and `keyTapWithMods`'s
    `onNonModifierTap()` + `onChanged()`. Keep `hapticTick()` inside `chipTap` /
    `chipLongPress` so the two surfaces cannot drift on haptics either.

    Public surface: `stateOf(Mod)`, `hasArmedMods()`, `chipTap`,
    `chipLongPress`, `keyDown`, `keyUp`, `keyTapWithMods`, `imeResetTick`,
    `dispose()`, and a `@visibleForTesting` read-only view of the held set.
    The `ModifierFsm` stays private to the controller. Import
    `package:flutter/foundation.dart` (for `ValueNotifier` / `VoidCallback`),
    `package:remote_protocol/remote_protocol.dart`, `../settings/haptics.dart`
    and `modifier_fsm.dart` — and nothing from the Material library.

    Carry the donors' comments across: the CR-02 rollover rationale, the D-12
    "zero effects, CONN-07 release_all already freed the real keys" note, the
    CR-01 atomic-IME-wipe note (T-04-03), and the LIVE-only flush rationale.
    Add a header stating this file is the SINGLE owner of the stuck-key model
    for BOTH surfaces and that any fix here lands on both by construction.

    Rewire `keyboard_panel.dart`: delete the moved members, hold
    `late final KeyboardInputController _controller`, build it in `initState`
    with **stable forwarding closures** — `send: (msg) => widget.send(msg)`,
    `isDisconnected: () => widget.isDisconnected()` — so a rebuild that hands
    the panel a fresh closure is always honoured (the trackpad screen recreates
    both on every build). `changes: widget.changes`,
    `onChanged: () { if (mounted) setState(() {}); }`. Panel `dispose()` becomes
    `_controller.dispose(); super.dispose();`. `_rows()` reads
    `_controller.stateOf(mod)` and calls `_controller.chipTap` /
    `chipLongPress`; the active rows widget gets `_controller.keyDown` /
    `keyUp` / `keyTapWithMods` / `hasArmedMods`. `HiddenTextInput` takes
    `resetSignal: _controller.imeResetTick`. Everything else about the panel —
    the switcher, the row group, the layout — stays exactly as it is in this
    task.

    Rewire `keyboard_screen.dart` identically, with `send: _service.sendReliable`
    and `isDisconnected: () => _isDisconnected`. Screen `dispose()` becomes
    `_padSub?.close(); _controller.dispose(); _pageController.dispose();
    _imeFocusNode.dispose(); super.dispose();` — `_controller.dispose()` takes
    the place of the whole flush block, at the same position in the sequence.

    Finally APPEND three tests to `keyboard_panel_test.dart`, closing gaps the
    panel surface has today (see the dispose-timing table):
    1. `panel-dispose LIVE flush` — hold `cap-Esc`, long-press Win, unmount the
       host, assert exactly `{up:Esc, up:WinLeft}` with length 2.
    2. `panel-dispose on a DISCONNECTED socket sends NOTHING`.
    3. `IN-04: a cancelled press on the panel still emits the up` — hold a cap,
       `gesture.cancel()`, assert `down:X, up:X`. The screen has this
       (`keyboard_screen_test.dart:233`); the panel does not, and the plan's
       "proven on both surfaces" claim is otherwise unmet.
    4. `collapsing the panel mid-hold releases the held key exactly once` —
       hold a cap, `pumpWidget(host(expanded: false))`, assert exactly one
       `up:X`; a later pointer release adds nothing.
    These are ADDITIONS ONLY; every one of the 13 existing panel tests and 10
    existing screen tests must pass with their bodies untouched. That green is
    the proof the collapse was behavior-neutral.
  </action>
  <verify>
    <automated>cd app/remote_control && flutter test test/keyboard/ && flutter analyze</automated>
  </verify>
  <done>
    `keyboard_input_controller.dart` exists and its suite is green. Both
    existing keyboard suites pass. `git diff` on
    `test/keyboard/keyboard_screen_test.dart` is EMPTY and the only change to
    `test/keyboard/keyboard_panel_test.dart` is the four appended tests (no
    existing test body edited). `git diff --quiet
    app/remote_control/lib/trackpad/trackpad_screen.dart` is clean.
    `grep -c "ModifierFsm()" app/remote_control/lib/keyboard/keyboard_panel.dart
    app/remote_control/lib/keyboard/keyboard_screen.dart` is 0 for both — the
    FSM is constructed in exactly ONE place.
    `grep -c "_heldCodes" app/remote_control/lib/keyboard/keyboard_screen.dart`
    is 0. `grep -c "package:flutter/material.dart"
    app/remote_control/lib/keyboard/keyboard_input_controller.dart` is 0.
    `flutter analyze` clean.
  </done>
</task>

<task type="auto">
  <name>Task 2: The sizing contract and the panel pad key — pure additions, no panel surgery (D-93, D-94)</name>
  <files>app/remote_control/lib/keyboard/key_pads.dart, app/remote_control/lib/keyboard/key_rows.dart, app/remote_control/test/keyboard/key_pads_test.dart, app/remote_control/test/keyboard/key_pads_store_test.dart, app/remote_control/test/keyboard/pad_widgets_test.dart</files>
  <read_first>
    - app/remote_control/lib/keyboard/key_pads.dart (L66-122 layout consts, L273-333 TypePad)
    - app/remote_control/lib/keyboard/key_rows.dart (L279-350 — KeyboardPadStore / KeyboardPadNotifier / keyboardPadProvider, the trio the panel store copies)
    - app/remote_control/test/keyboard/key_pads_store_test.dart (the whole file — every assertion that names the retired const must be accounted for)
    - the `<sizing_contract>` section of this plan (the numbers are binding)
  </read_first>
  <action>
    This task adds and parameterises only. It touches no screen and no panel, so
    it can be reviewed and reverted independently of the UI rebuild.

    **`key_pads.dart` — the sizing contract.** Add, beside the existing private
    layout consts so the arithmetic can reference them: `kPanelChromeHeight`
    (= 1 + 64 + `_kTabBarHeight`, i.e. 121), `kPanelPadHeights`
    (`type: 80, arrows: 272, numpad: 312, fn: 304`), `kPanelMaxHeightFraction`
    (0.55), `kPanelMinPadHeight` (96), and the pure function
    `double panelPadHeight(KeyboardPad pad, double columnHeight)` implementing
    `max(kPanelMinPadHeight, min(kPanelPadHeights[pad]!, columnHeight *
    kPanelMaxHeightFraction - kPanelChromeHeight))`. Document each number's
    arithmetic from `<sizing_contract>`, and be honest in the comment about
    which figures are real constants and which are chosen targets (the 64 row
    and 76 cell are targets — do not imply a const exists). State the guarantee
    the clamp buys and its one documented exception.

    Add `showHint` (default `true`) to `TypePad`. When false the `Expanded` hint
    canvas is omitted and the Column uses `MainAxisAlignment.end` so the extras
    row stays docked at the bottom. The docked panel will pass `false` in Task 3
    — a ~200dp strip under a live trackpad has no room for a centered hint. The
    default keeps `pad_widgets_test.dart`'s `find.text(kKeyboardHint)`
    assertion green; add one test there that `showHint: false` renders the 7
    caps and no hint.

    **`key_rows.dart` — panel pad persistence (separate keys / one model).** Add
    `const String kPanelPadPrefsKey = 'keyboard.panelPad';`. Parameterise
    `KeyboardPadStore` with `{String key = kKeyboardPadPrefsKey,
    bool migrateRetiredPanelKey = false}` — every existing construction keeps
    compiling unchanged. When `migrateRetiredPanelKey` is true AND the primary
    key read comes back unset, read the private literal
    `_kRetiredPanelPrefsKey = 'keyboard.rowGroup'` once, map it per the table in
    `<decisions_this_plan_makes>` (`fn`→fn, `num`→numpad, everything else
    including `nav`/unset/unknown→type), and immediately `save()` the result
    under the primary key so the legacy read never happens again. Any throw
    anywhere in that path degrades to `KeyboardPad.type` — a broken pref must
    never take the keyboard down (T-10-04). Add `PanelPadNotifier` +
    `panelPadStoreProvider` + `panelPadProvider` mirroring the existing trio,
    with the panel store constructed as
    `KeyboardPadStore(key: kPanelPadPrefsKey, migrateRetiredPanelKey: true)`.
    Do NOT delete the row-group surface here — that is Task 4.

    **Tests.** In `key_pads_test.dart` add a pure group for `panelPadHeight`:
    each pad at an unclamped column returns its table value; Type < Arrows < Fn
    < Numpad; a short column clamps to the ceiling and the resulting panel total
    leaves `0.45 × column − 64`; an extreme column floors at
    `kPanelMinPadHeight`. No widgets.
    In `key_pads_store_test.dart`:
    - add `kPanelPadPrefsKey == 'keyboard.panelPad'`, distinct from
      `kKeyboardPadPrefsKey`;
    - panel store, no keys → type;
    - panel store, hand-written literal `'keyboard.rowGroup'` = `num` → numpad
      AND `keyboard.panelPad` is now `'numpad'`; `= fn` → fn; `= nav` → type;
      `= garbage` → type — each also writing the new key;
    - both keys present → the panel key wins, the legacy value is ignored;
    - throwing prefs → type;
    - **repoint the existing test currently named `save() never writes the
      docked panel's keyboard.rowGroup key`** at `kPanelPadPrefsKey`: the SCREEN
      store must not write the PANEL's key. Do not delete it — it will not
      compile after Task 4 otherwise, and the guarantee it expresses is one this
      task wants anyway.
    Pin the legacy literal by hand in the test; the migration must not drift.
  </action>
  <verify>
    <automated>cd app/remote_control && flutter test test/keyboard/ && flutter analyze</automated>
  </verify>
  <done>
    `panelPadHeight` exists and its pure tests are green, including the clamp and
    floor cases. `kPanelPadPrefsKey` exists and the migration round-trips for
    all five legacy inputs. `TypePad(showHint: false)` renders the extras row
    without the hint. No panel or screen file was edited. `flutter analyze`
    clean. `git diff --quiet app/remote_control/lib/trackpad/trackpad_screen.dart`
    is clean.
  </done>
</task>

<task type="auto">
  <name>Task 3: The panel becomes the same keyboard — four pads, tab bar, inset-correct height (D-91, D-92, D-93)</name>
  <files>app/remote_control/lib/keyboard/keyboard_panel.dart, app/remote_control/test/keyboard/keyboard_panel_test.dart, app/remote_control/test/trackpad/trackpad_screen_test.dart</files>
  <read_first>
    - app/remote_control/lib/keyboard/keyboard_screen.dart (L262-424 — _onPageChanged / _onTabSelected / _restorePad / _padRestoreDone and the build order; the panel mirrors this shape)
    - app/remote_control/lib/keyboard/key_pads.dart (L201-271 KeyboardTabBar, plus the Task 2 sizing consts)
    - app/remote_control/test/trackpad/trackpad_core_test.dart (L58-132 — the _RecordingService + moves idiom and the drag/pump sequence)
    - the `<sizing_contract>` section of this plan — ESPECIALLY the columnHeight subsections. The naive MediaQuery formula is wrong in this tree and no inset-free test can catch it.
  </read_first>
  <action>
    **Rewrite the `keyboard_panel.dart` library header first.** The current one
    describes FSM ownership (moved out in Task 1) and the Nav/Fn/Num switcher
    (removed here). It must describe: a docked deck of the same four pads as the
    full-screen surface; the shared owner it delegates the stuck-key model to;
    the IME-on-Type-only rule; the per-pad height and why the column height is
    read from the raw view. Do not spell any identifier Task 4 deletes.

    **The deck.** Replace `_rows()` with a deck mirroring `KeyboardScreen`'s,
    keeping the panel's own shell semantics:

    - Own a `PageController`, an `int _currentPage` seeded from
      `ref.read(panelPadProvider).index` in `initState`, and a
      `ProviderSubscription` doing the one-shot restore jump with the same
      `_padRestoreDone` guard the screen uses (a late prefs load must never yank
      a pad the user already navigated to). Dispose the page controller and the
      subscription in `dispose()` alongside `_controller.dispose()`.
    - Make `_KeyboardPanelState` a `WidgetsBindingObserver`: `addObserver` in
      `initState`, `removeObserver` in `dispose`, and
      `didChangeMetrics() => if (mounted) setState(() {})`. Without this the
      panel never learns the IME rose or fell — see `<sizing_contract>`.
    - Compute `columnHeight` EXACTLY as `<sizing_contract>` specifies, from
      `MediaQueryData.fromView(View.of(context))`, using `viewPadding.top` and
      `max(viewPadding.bottom, viewInsets.bottom)`. Put the "why not
      MediaQuery.of" explanation in a comment at the call site, naming Scaffold's
      `removeViewInsets` and SafeArea's `removePadding`, so nobody simplifies it
      back. Do NOT add a `LayoutBuilder` in or around the trackpad Column.
    - Build, inside the existing `AnimatedSize(200ms, Curves.ease,
      alignment: topCenter)` and the existing `Container` with the top hairline
      and `kBg`: a `SizedBox(height: panelPadHeight(pad, columnHeight))`
      wrapping a `PageView` of
      `[TypePad(showHint: false), ArrowsPad, NumpadPad, FnPad]` with
      `allowImplicitScrolling: false` and NO keep-alive of any kind; then the
      four-chip modifier row (`Padding` h16/v8, equal `Expanded` chips, 8px gaps
      — the same shape as `KeyboardScreen._chipRow`); then
      `KeyboardTabBar(current:, onSelect:)`. The container's blanket
      `EdgeInsets.all(16)` goes away: the pads carry their own 16px padding and
      the chip row carries its own, so the vertical vocabulary matches the
      full-screen surface. **Chips move BELOW the pad**, matching the screen.
    - `HiddenTextInput` stays exactly where it is: mounted in BOTH states,
      OUTSIDE the animating chrome (Pitfall 6). Do not move it inside.
    - `_onPageChanged(i)`: set `_padRestoreDone = true`, persist via
      `ref.read(panelPadProvider.notifier).set(...)`, then — only while
      `widget.expanded` — `requestFocus` on Type and `unfocus` on every other
      pad, then `setState(() => _currentPage = i)`.
    - `_onTabSelected(pad)`: `hapticTick()` + `animateToPage(200ms, Curves.ease)`.
    - `didUpdateWidget`: expanding requests focus ONLY when the current pad is
      Type; collapsing always unfocuses. Same rule in `initState`'s post-frame
      callback.
    - The panel's constructor signature does NOT change and
      `trackpad_screen.dart` is NOT edited.

    **`keyboard_panel_test.dart`.** Hoist the fake `PrefsKv` and the
    `KeyboardPadStore` into `setUp` so the `panelPadStoreProvider` override is
    the SAME value across successive `pumpWidget(host(...))` calls (the file
    currently rebuilds the store inline on every call, which would break the
    persistence test). Swap the row-group store override for the panel store
    override. Change the `expanded panel renders chips row + switcher + Nav
    rows` test to assert the four `kKeyboardTabLabels`, the four
    `kKeyboardTabIcons`, and one `KeyboardTabBar`.

    Every OTHER existing test keeps its body. That holds because
    `ValueKey('cap-<code>')` is set inside `KeyCapState` and `cap-Right`,
    `cap-Down` and `Esc` all live on the default Type pad's extras row. Note
    explicitly: the three surviving `ensureVisible(find.byKey(ValueKey('cap-…')))`
    calls (`:197`, `:346`, `:380`) now resolve against the new `PageView` as the
    nearest `Scrollable` instead of the host's `SingleChildScrollView`. For an
    on-page cap that is a no-op — but confirm it, because the "no existing body
    edited" claim depends on it.

    Add:
    - each pad's rendered panel height matches the `<sizing_contract>` table on
      a driven viewport, and Type < Arrows < Fn < Numpad;
    - the height change animates (assert an intermediate height mid-tween, then
      the settled height after 200ms);
    - paging to Numpad lowers the IME, paging back to Type raises it;
    - a page change persists `keyboard.panelPad`, and a fresh mount over the
      same prefs lands on the persisted pad.

    **`trackpad_screen_test.dart` — the D-91/D-93 proof, with REAL insets.**
    Drive metrics via `tester.view` at `devicePixelRatio = 1.0` (so
    `FakeViewPadding` values are 1:1 logical) and `addTearDown(tester.view.reset)`.
    Set `viewPadding`, `padding` and `viewInsets` consistently — when an IME
    inset is present, `padding.bottom` is 0 while `viewPadding.bottom` keeps the
    nav-bar value. Compute the asserted floor IN THE TEST as
    `0.45 * columnHeight - 64` from the driven metrics; do not hard-code it.
    Three cases, with a `_RecordingService` (authed):

    1. **411×891, top 24, bottom 48, IME down, Numpad.** Assert
       `find.byType(NumpadPad)` renders, the `TrackpadCore` height is 322 (±1),
       and a real drag on the shrunken surface produces a non-empty
       `service.moves`. Present is not enough — the trackpad must still MOVE
       THE CURSOR at the tallest pad.
    2. **411×891, top 24, viewPadding.bottom 24, `viewInsets.bottom = 290`,
       panel pad seeded to numpad** (the mid-transition state where the IME has
       not finished lowering). Assert the `TrackpadCore` height ≥ the computed
       floor (195.65) and that nothing overflows. **The naive formula yields 80
       here and fails this assertion — that is the point of the test.**
    3. **360×640, top 24, bottom 24, IME down, Numpad.** Assert the
       `TrackpadCore` height ≥ the computed floor (202.4). **The naive formula
       yields 176 and fails.**

    Add a comment in the test file naming these as the B2 regression guards, so
    a future edit that "simplifies" the metrics read is caught with an
    explanation attached.
  </action>
  <verify>
    <automated>cd app/remote_control && flutter test test/keyboard/ test/trackpad/ && flutter analyze</automated>
  </verify>
  <done>
    The docked panel renders Type | Arrows | Numpad | Fn with the shared tab bar
    and swipes between them. Panel heights match the `<sizing_contract>` table.
    The IME rises only on Type. `keyboard.panelPad` round-trips. All three
    trackpad-floor cases pass, and the two discriminating ones provably fail if
    the metrics read is reverted to the naive form (verify this ONCE by hand:
    temporarily swap in the naive formula, watch cases 2 and 3 go red, restore).
    `grep -c "MediaQueryData.fromView"
    app/remote_control/lib/keyboard/keyboard_panel.dart` is 1.
    `grep -c "allowImplicitScrolling: false"
    app/remote_control/lib/keyboard/keyboard_panel.dart` is 1 and
    `grep -cE "AutomaticKeepAlive|wantKeepAlive|keepAlive"
    app/remote_control/lib/keyboard/keyboard_panel.dart` is 0.
    `grep -c "LayoutBuilder" app/remote_control/lib/keyboard/keyboard_panel.dart
    app/remote_control/lib/trackpad/trackpad_screen.dart` is 0 for both.
    `git diff --quiet app/remote_control/lib/trackpad/trackpad_screen.dart` is
    clean. `flutter analyze` clean.
  </done>
</task>

<task type="auto">
  <name>Task 4: Retire the second keyboard — delete the row-group surface, comments included (D-94)</name>
  <files>app/remote_control/lib/keyboard/key_rows.dart, app/remote_control/lib/keyboard/key_pads.dart, app/remote_control/lib/keyboard/keyboard_screen.dart, app/remote_control/test/keyboard/key_rows_test.dart, app/remote_control/test/keyboard/key_pads_test.dart, app/remote_control/test/keyboard/key_pads_store_test.dart</files>
  <read_first>
    - app/remote_control/lib/keyboard/key_rows.dart (L1-19 header, L59-136 the row-group enum/store/notifier/provider, L160-216 kNavClusterCaps + capsForGroup, L355-463 the rows widget, L668-724 the segmented switcher)
    - app/remote_control/test/keyboard/key_rows_test.dart (the whole file — most of it goes)
    - app/remote_control/test/keyboard/pad_widgets_test.dart (proof that the emission-model coverage being deleted already exists on the pads)
  </read_first>
  <action>
    **Delete from `key_rows.dart`:** the `KeyRowGroup` enum, the public
    retired-prefs-key const, `KeyRowGroupStore`, its store provider,
    `KeyRowGroupNotifier`, its provider, `capsForGroup`, `kNavClusterCaps` (only
    `capsForGroup` consumed it — confirm with grep before deleting), the
    `KeyRows` widget, and the three-segment switcher widget. The ONLY surviving
    trace of the retired key is the private literal inside Task 2's migration.

    **Rewrite every doc reference outside `key_rows.dart`.** The gate below is
    unfiltered, and these are the exact remaining occurrences — all of them
    comments, none of them caught by "delete the class":

    | File | Line | What it says today |
    |---|---|---|
    | `lib/keyboard/key_pads.dart` | 4 | "widget-only and service-agnostic (mouse_buttons / [KeyRows] house style)" |
    | `lib/keyboard/key_pads.dart` | 5 | "the SAME injected-callback contract as [KeyRows]" |
    | `lib/keyboard/key_pads.dart` | 125 | "Shared plumbing for the four pads: the [KeyRows] callback contract" |
    | `lib/keyboard/key_pads.dart` | 185 | "The [KeyRowGroupSwitcher] idiom, re-shaped from segment to tab." |
    | `lib/keyboard/keyboard_screen.dart` | 327 | "Every pad takes the same six-field KeyRows contract" |
    | `lib/keyboard/keyboard_panel.dart` | 17 | the library header (already rewritten in Task 3 — re-verify it here) |

    Re-verify with the gate, not by eye. Rewrite each to name the surviving
    concept instead: "the shared injected-callback cap contract", "the six-field
    cap-callback contract", "the segmented-selector idiom, re-shaped into a tab
    bar". Also rewrite the `key_rows.dart` library header so it describes what
    the file now holds — the shared `key.code` vocabulary, `KeyCapDef`, the
    shared `KeyCap` emission model, the pad cap tables and the two pad stores.
    **Do not spell any deleted identifier anywhere in `lib/`, comments
    included** — a self-invalidating doc comment has already cost this project
    two debugging sessions (STATE.md, 12-16 carried notes).

    **Prune the tests, replacing rather than losing coverage:**
    - `key_rows_test.dart`: delete the whole `group switcher + persistence`
      group and the whole `key-cap emission model` group — every behavior in the
      latter (down/up ordering, deferred tap+mods, gated-inert, IN-04 mid-press
      gate flip) is already proven on the pads in `pad_widgets_test.dart` at the
      lines cited in `<already_established>`. **Delete** the first vocabulary
      test too rather than rewriting it: iterating `capsForPad` over
      `KeyboardPad.values` is verbatim what `key_pads_test.dart:20` already
      does. KEEP `new shortcut vocabulary codes are mirrored from keymap.rs
      (10-01)` verbatim. **Re-home the 48px touch-target floor test**
      (`:165` — it exists nowhere else) as a bare `KeyCap` widget test in this
      file, asserting a representative cap is ≥48 in both dimensions under
      loose constraints.
      Then delete what those removals orphan, or `flutter analyze` fails the
      task's own gate on `unused_element` / `unused_import`: the `_FakePrefsKv`
      class (`:25`), the `device_store.dart` import, and the
      `material_symbols_icons` and `tokens.dart` imports if the surviving tests
      no longer use them.
    - `key_pads_test.dart`: delete the final `exposing KeyCap did not disturb
      the docked panel groups (D-07)` test — the surface it guarded no longer
      exists.
    - `key_pads_store_test.dart`: drop the two assertions naming the deleted
      public const from the first test, keeping the `kKeyboardPadPrefsKey ==
      'keyboard.pad'` assertion and the panel-key assertions Task 2 added. The
      `save() never writes …` test was already repointed at `kPanelPadPrefsKey`
      in Task 2 and needs nothing further here.

    Do NOT edit `10-CONTEXT.md` — planning history is immutable. Record the
    deliberate reversal of its line-15 out-of-scope call in the SUMMARY.
  </action>
  <verify>
    <automated>cd app/remote_control && flutter test && flutter analyze</automated>
  </verify>
  <done>
    `grep -rEc "KeyRowGroup|capsForGroup|kNavClusterCaps|\bKeyRows\b"
    app/remote_control/lib` totals 0 across ALL files — comments included.
    `grep -rc "keyboard.rowGroup" app/remote_control/lib` is 1 (the private
    migration literal in `key_rows.dart`, and nowhere else). The full
    `flutter test` suite is green with no net loss of coverage beyond the
    enumerated deletions, all of which are covered elsewhere or re-homed.
    `git diff --quiet app/remote_control/lib/trackpad/trackpad_screen.dart` is
    clean. `flutter analyze` clean — in particular no `unused_element` or
    `unused_import` in `key_rows_test.dart`. The before/after `flutter test`
    counts are recorded in the SUMMARY with the delta explained line by line.
  </done>
</task>

</tasks>

<threat_model>
## Trust Boundaries

| Boundary | Description |
|----------|-------------|
| app-drawn keys → `key` frames → OS keystrokes | Chips, caps and pads become real OS input on the owner's authed session. A key left "down" is a live denial of service on the owner's own PC. |
| device IME → `text` frames → OS typing | Unchanged by this task, but the CR-01 atomic wipe that keeps pre-disconnect text from replaying now lives inside the shared owner. |

## STRIDE Threat Register

| Threat ID | Category | Component | Disposition | Mitigation Plan |
|-----------|----------|-----------|-------------|-----------------|
| T-IPC-01 | Denial of Service (local) | the collapse of the duplicated stuck-key model into `KeyboardInputController` | mitigate | Task 1 is a verbatim move with zero behavior change, gated on both existing suites passing with untouched bodies, PLUS a new surface-free suite that proves CR-01 / CR-02 / IN-04 / D-10 / D-11 / D-12 and both dispose paths directly on the owner |
| T-IPC-02 | Denial of Service (local) | LIVE-only dispose flush firing into a dead or a NEW session | mitigate | The `isDisconnected()` guard and the statement order are moved verbatim; three tests pin it — the owner's `dispose on a DISCONNECTED socket sends NOTHING`, the screen's existing equivalent, and the panel's new one (Task 1) |
| T-IPC-03 | Denial of Service (local) | a key held across a panel COLLAPSE or a pad SWIPE | mitigate | No keep-alive on the panel's PageView (`allowImplicitScrolling: false`, grep-gated); leaving a pad or collapsing the panel disposes the caps and `KeyCap.dispose` releases; the `remove()` guard keeps it idempotent with the surface flush; Task 1 adds the panel collapse-mid-hold test and the panel IN-04 cancelled-press test |
| T-IPC-04 | Denial of Service (local) | the trackpad rendered unusable by a tall panel | mitigate | The 0.55 fraction clamp guarantees live trackpad ≥ 0.45 × column − 64; the clamp is fed by RAW view metrics because the ancestor MediaQuery is stripped in this tree, and Task 3's cases 2 and 3 fail against the naive read, so the guard cannot silently rot |
| T-IPC-05 | Information Disclosure | pre-disconnect typed text replaying after reconnect (T-04-03) | mitigate | The CR-01 atomic IME reset tick moves into the shared owner unchanged; proven on the owner, on the screen (existing test) and on the panel (existing test) |
| T-IPC-06 | Tampering / Input Validation | emitted `key.code` strings | accept | No code vocabulary change at all; `kClientKeyCodes` is untouched and the pad cap tables it gates are unchanged |
| T-IPC-SC | Supply Chain | no installs | accept | No new packages, Dart or Rust. Nothing is fetched from any registry, so the package legitimacy gate does not apply |
</threat_model>

<verification>
- `cd app/remote_control && flutter test` — full app suite green. Capture the
  count BEFORE Task 1 and AFTER Task 4; the delta must be explainable line by
  line (additions: the controller suite, the four panel tests from Task 1, the
  `panelPadHeight` pure group, the migration tests, the `showHint` test, the
  panel height/IME/persistence tests, the three trackpad-floor tests, the
  re-homed 48px floor test; deletions: only the enumerated row-group tests).
- `cd app/remote_control && flutter analyze` — clean, with no `unused_import` or
  `unused_element` left behind by the Task 4 deletions.
- `git diff --quiet app/remote_control/lib/trackpad/trackpad_screen.dart` —
  clean after every task. The Pitfall-6 isolation is preserved by never
  touching the file.
- `grep -rEc "KeyRowGroup|capsForGroup|kNavClusterCaps|\bKeyRows\b"
  app/remote_control/lib` totals 0 (unfiltered — comments count).
- `grep -rc "keyboard.rowGroup" app/remote_control/lib` is 1 (the migration
  literal only).
- `grep -c "ModifierFsm()" app/remote_control/lib/keyboard/*.dart` is 1 in
  total, in `keyboard_input_controller.dart` only.
- `grep -c "MediaQueryData.fromView"
  app/remote_control/lib/keyboard/keyboard_panel.dart` is 1 — the panel reads
  raw view metrics, not the stripped ancestor MediaQuery. The negative case is
  guarded by Task 3's cases 2 and 3 rather than by a grep, because the code
  comment explaining the trap must be free to name the API it warns against.
- `grep -cE "AutomaticKeepAlive|wantKeepAlive|keepAlive"
  app/remote_control/lib/keyboard/keyboard_panel.dart
  app/remote_control/lib/keyboard/keyboard_screen.dart` is 0 for both.
- `grep -c "LayoutBuilder" app/remote_control/lib/keyboard/keyboard_panel.dart
  app/remote_control/lib/trackpad/trackpad_screen.dart` is 0 for both.
- No server, extension or protocol file appears in `git diff --name-only` for
  any commit of this plan.
- On-device sanity (owner, not a gate): open the trackpad, tap the keyboard
  button, swipe Type → Arrows → Numpad → Fn watching the panel grow and the
  trackpad shrink; move the cursor with Numpad open; go Type → Numpad while the
  IME is still lowering and watch for overflow stripes; hold an arrow and swipe
  pads mid-hold — the key must stop repeating on the PC.
</verification>

<success_criteria>
- The trackpad-docked keyboard and the full-screen keyboard are the same
  keyboard: same four pads, same order, same labels, same icons, same tab bar,
  same swipe (D-92).
- The panel is still docked under a trackpad that stays LIVE at every pad
  height, with the numbers in `<sizing_contract>` met on the reference device
  and the 0.45 × column − 64 floor holding under a raised IME and on a short
  viewport — proven by tests that fail against the naive metrics read
  (D-91, D-93).
- Exactly one implementation of the stuck-key model exists, and CR-01, CR-02,
  IN-04, D-10/D-11, D-12 and the LIVE-only flush are each proven on the owner
  AND on both surfaces (D-95).
- Persistence is one model (`KeyboardPad`) on two mount-point keys, the retired
  key is migrated on first read and referenced from exactly one private literal,
  and no row-group vocabulary survives anywhere in `lib/`, comments included
  (D-94).
- `trackpad_screen.dart` is byte-unchanged; no server, extension or protocol
  change; the typing path is untouched.
</success_criteria>

<output>
Create `.planning/quick/260809-ipc-unify-the-trackpad-docked-keyboard-panel/260809-ipc-SUMMARY.md` when done.

The SUMMARY must record, explicitly:
- the abstraction chosen for the shared owner and the test that proves dispose
  timing on EACH surface;
- the persistence decision (separate keys, one model) and the migration table;
- the final `columnHeight` expression as shipped, and the observed result of the
  by-hand naive-formula experiment (which cases went red);
- the measured panel height and remaining trackpad height for all four pads on
  each of the three driven viewports, next to the planned numbers;
- the `flutter test` count before and after, with the delta explained;
- that `10-CONTEXT.md` line 15's out-of-scope call is now deliberately reversed —
  the docked panel WAS the phase-10 rethink's remaining gap.
</output>
