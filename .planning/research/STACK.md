# Stack Research

**Domain:** Client-side Flutter UI restructuring — a persistent bottom "summon bar" raising trackpad/keyboard surfaces as in-place overlays (v1.1)
**Researched:** 2026-08-12
**Confidence:** HIGH

---

## Verdict: NO NEW DEPENDENCIES

**This milestone needs zero new packages.** Every capability it requires is a first-party
Flutter widget already compiled into the pinned SDK, and in three of four cases the app
already ships a working instance of the exact pattern.

The right primitive is a **`Stack` inside a shared shell widget that every screen
composes** — i.e. the existing `BubbleScaffold` composition point (`bubble_scaffold.dart`,
wired centrally at `hub_screen.dart:282-293`), rebuilt with a new payload. That is not a
compromise pick: it is the only one of the five candidate primitives that satisfies all
three hard requirements simultaneously (no resize beneath, State survives dismiss,
`PopScope` back-intercept works).

Three concrete facts, verified against the pinned SDK on disk, drive that:

1. **`OverlayPortal` destroys its child on hide.** Official docs, verbatim: *"When
   `OverlayPortalController.hide` is called, the widget built using `overlayChildBuilder`
   will be removed from the widget tree the next time the widget rebuilds. Stateful
   descendants in the overlay child subtree may lose states as a result."* Disqualifying
   for the keyboard surface.
2. **`PopScope` is a silent no-op without a `ModalRoute` ancestor.**
   `_PopScopeState.didChangeDependencies` registers via `ModalRoute.of(context)`
   (`packages/flutter/lib/src/widgets/pop_scope.dart:196`); with no route above it,
   `_route` is null and nothing registers. This kills `MaterialApp.builder` as a mounting
   strategy, because the current back-to-collapse contract (D8-08,
   `bubble_scaffold.dart:159-165`) depends on `PopScope`.
3. **A persistent `Scaffold.bottomSheet` genuinely does NOT resize the body** — surprising,
   and it is real (`material/scaffold.dart:1146-1155`: the `bottomSheet` slot is laid out
   *after* the body and positioned at `contentBottom - sheetHeight`; it never contributes
   to `bottomWidgetsHeight`). But it is still disqualified, because
   `Scaffold.didUpdateWidget` calls `_closeCurrentBottomSheet()` the moment `bottomSheet`
   goes null (`scaffold.dart:2841`), destroying the child. It fails requirement 2 while
   passing requirement 1.

Everything below is the evidence and the shape it implies.

---

## Recommended Stack

### Core Technologies

All already in `app/remote_control/pubspec.yaml` or the SDK. Nothing to install.

| Technology | Version | Purpose | Why Recommended |
|------------|---------|---------|-----------------|
| Flutter SDK | **3.44.5** (pinned; `/c/dev/flutter/version`, `pubspec.lock` `flutter: ">=3.44.0"`) | Everything below | Already the locked SDK; the `bubble_scaffold.dart:27-28` note ("the pinned Flutter 3.44.5") is accurate |
| Dart SDK | **3.12.2** (`pubspec.yaml` `sdk: ^3.12.2`) | Language | No language feature needed beyond what is in use |
| `Stack` + `Positioned` / `Positioned.fill` | SDK (`widgets/basic.dart`) | Hosts the raised surface over an unresized body | The ONLY primitive that overlays without touching the body's constraints, keeps the child mounted, and stays inside the route so `PopScope` works. Already the shape of `bubble_scaffold.dart:168-214` |
| `AnimationController` + `SingleTickerProviderStateMixin` | SDK (`animation/`) | Drives the 200ms summon/dismiss | Already present at `bubble_scaffold.dart:83-92` with `kBubbleExpandDuration = 200ms`; `KeyboardPanel` independently uses a 200ms `AnimatedSize` (`keyboard_panel.dart:425-427`). One vocabulary, already established |
| `Offstage` (or `Visibility(maintainState: true)`) | SDK (`widgets/basic.dart`, `widgets/visibility.dart`) | Keeps the keyboard surface **mounted** while dismissed | Docs: *"Offstage children are still active: they can receive focus and have keyboard input directed to them."* That property is exactly landmine #3 (the hidden IME connection must survive a dismiss). State is preserved because the child stays in the tree |
| `TickerMode` | SDK (`widgets/ticker_provider.dart`) | Stops tickers in the dismissed surface | Offstage's own doc warns *"Animations continue to run in offstage children, and therefore use battery and CPU time."* `Visibility(visible: x, maintainState: true)` composes exactly `TickerMode(enabled: x, child: Offstage(offstage: !x, ...))` — verified in `visibility.dart` `build` |
| `Listener` (raw pointer) | SDK | Trackpad hot path | Unchanged. `trackpad_core.dart:238-245` — `HitTestBehavior.opaque`, zero gesture-arena participation. This is why sheet packages are hostile (below) |
| `GestureDetector` | SDK | The one-gesture dismiss handle | Must be a spatially-disjoint **sibling** of the trackpad `Listener`, never an ancestor — the rule is already recorded and implemented at `floating_trackpad_window.dart:6-7, 23, 245-248` (RESEARCH Pitfall 2) |
| `PopScope` | SDK (`widgets/pop_scope.dart`) | Back = dismiss the surface, not pop the route | Already the D8-08 contract. Requires the shell to live **inside** a `ModalRoute`, which is the decisive mounting constraint |
| `flutter_riverpod` | **3.3.2** locked (pub.dev latest 3.4.2, 2026-07-28) | Durable "restore where it was" state | `panelPadProvider` / `keyboardPadProvider` already persist the last-open pad through `shared_preferences` (`keyboard_panel.dart:52-54, 165-166`). Cross-screen restore is a solved problem; do not reinvent it in the shell |

### Supporting Libraries

| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| `shared_preferences` | 2.5.5 (locked) | Persist raised-surface preference (which pad, maybe last-raised surface) | Only if the bar itself needs a persisted preference. The pad already persists — reuse `kPanelPadPrefsKey`'s model (D-94, "one model, two mount-point keys") rather than adding a third store |
| `material_symbols_icons` | 4.2951.0 (locked) | The two bar icons | `Symbols.touch_app_rounded` + `Symbols.keyboard_rounded` are already the hub tile icons (`hub_screen.dart:89, 97`). Const `IconData` only — there is a lint guard (`test/icons_guard_test.dart`) |
| `wakelock_plus` (via `KeepAwake`) | 1.6.1 (locked) | Screen-awake ref count | **Do not touch directly.** `TrackpadCore` is the sole owner (`trackpad_core.dart:194, 209`); the ref-counted wrapper is `widgets/keep_awake.dart`. See the trackpad lifecycle warning below — this is the reason the two surfaces need *different* mount policies |

### Development Tools

| Tool | Purpose | Notes |
|------|---------|-------|
| `flutter_test` (SDK) | Widget tests for the shell | `bubble_scaffold_test.dart` and `floating_trackpad_window_test.dart` are the tests being migrated/retired. No new test package |
| `flutter_lints` 6.0.0 | Lint baseline | Unchanged |
| `WidgetTester.takeException` drain | Pins the 7.3px chip overflow | `test/trackpad/trackpad_screen_test.dart:182-194, 296-304`. Per the design note, **that drain going empty is the signal the bug was fixed, not a flake** — the third mount point must not add a fourth copy of the drain |

## Installation

```bash
# Core
# (nothing)

# Supporting
# (nothing)

# Dev dependencies
# (nothing)
```

`app/remote_control/pubspec.yaml` is unchanged by this milestone. If a plan proposes editing
it, that is a signal the plan drifted from this research — challenge it before merging.

---

## Primitive Comparison: does it rebuild its child on dismiss?

The disqualifying question, answered for every candidate. "Destroys child" means the
child's `State.dispose()` runs on dismiss, so which-pad, controller state, and the Android
input connection are all lost and the re-summon shows a visible jump.

| Primitive | Resizes content beneath? | **Destroys child on dismiss?** | `PopScope` works? | Verdict |
|---|---|---|---|---|
| **`Stack` in a shared shell** (recommended) | **No** — `Positioned` children do not constrain siblings | **No, if you gate with `Offstage`/`Visibility(maintainState:true)` instead of `if (raised)`** — the choice is yours, per-surface | **Yes** — the shell is inside the screen's `MaterialPageRoute` | ✅ **Chosen** |
| `showModalBottomSheet` | No (barrier overlays) | **YES — fatal.** `ModalBottomSheetRoute<T> extends PopupRoute<T>` (`material/bottom_sheet.dart:870`); `Navigator.pop` disposes the route and unmounts the child | N/A (it *is* the route) | ❌ Fails req. 2 |
| `DraggableScrollableSheet` | No | No (it is a plain widget) — but see below | Needs its own wiring | ❌ Fails on gestures: it is built on a `Scrollable`, which **wins the gesture arena**. The trackpad's `Listener` is arena-free and would still fire, so a cursor drag would move the cursor *and* drag the sheet simultaneously. Directly contradicts `floating_trackpad_window.dart:23` |
| **persistent `Scaffold.bottomSheet`** | **No** — genuinely overlays (`scaffold.dart:1146-1155`); it never adds to `bottomWidgetsHeight`, unlike `bottomNavigationBar`/`persistentFooter` (`scaffold.dart:1046-1070`) | **YES — fatal.** `didUpdateWidget` → `bottomSheet == null` → `_closeCurrentBottomSheet()` (`scaffold.dart:2841, 2418-2430`) | Sheet is not a `LocalHistoryEntry`; back does not reach it | ❌ Fails req. 2. Also unavailable: the shell sits *above* each screen's own `Scaffold` (`hub_screen.dart:286-289` wraps `spec.builder(context)`, and e.g. `TrackpadScreen` is itself a `Scaffold` at `trackpad_screen.dart:147`) |
| raw `Overlay` + `OverlayEntry` | No | No (entries persist) — but entry **ordering vs. the Navigator's own route entries** is undefined territory: a route pushed later can land above a manually inserted entry | **No** — the entry is not inside the screen's `ModalRoute` subtree, so `PopScope` silently does nothing (`pop_scope.dart:196`) | ❌ Already rejected in this codebase: `bubble_scaffold.dart:6-8` — *"Stack children, NOT `OverlayEntry`, which would fight `PopScope` + the per-screen-ephemeral lifecycle."* That reasoning still holds |
| `OverlayPortal` | No | **YES — fatal, documented.** *"…will be removed from the widget tree… Stateful descendants in the overlay child subtree may lose states as a result."* | Same problem as raw Overlay | ❌ Fails req. 2. The modern-looking answer is the wrong one here |
| `PopupRoute` / custom `ModalRoute` subclass | No | **YES — fatal.** A route's subtree is built by the route and torn down on pop, by design | Yes (it is a route) | ❌ Fails req. 2. Also makes dismiss a Navigator transaction, which is exactly the "feels like navigation" the design note forbids |
| `Hero` | N/A | N/A | N/A | ❌ Not applicable. `Hero` animates a widget *between two routes*. There is no second route here — the whole point is not navigating |

**Reading of the table:** every route-based option fails identically and for the same
reason. That is not a coincidence — routes own their subtrees, and "state survives
dismissal" is a statement that nothing may own the subtree except something longer-lived
than the dismissal. Only a `Stack` child under a long-lived shell satisfies that.

### Per-surface mount policy — they are NOT the same

This is the finding most likely to be missed, and it is worth more than any package
recommendation.

| Surface | Policy on dismiss | Why |
|---|---|---|
| **Keyboard** | **Stay mounted.** Gate with `Offstage` / `Visibility(maintainState: true)`, animate only the chrome | Its State is expensive and load-bearing: the pad index, `KeyboardInputController`'s FSM + held-code set, and the `HiddenTextInput` Android input connection. `keyboard_panel.dart:414-420` already mounts the hidden field "in BOTH states and OUTSIDE the animating chrome" — landmine #3 is *already solved* by this exact idiom; the port must preserve it, not reinvent it |
| **Trackpad** | **Unmount.** A plain `if (raised)` in the `Stack` is correct | `TrackpadCore` acquires the keep-awake hold on mount and releases on dispose (`trackpad_core.dart:194, 209`). Keeping it mounted-but-hidden would hold the screen awake **forever, on every screen** — a battery bug with no symptom until the user notices. It also has no state worth restoring: the cursor lives on the PC. `Offstage` would additionally keep its `Listener` laid out for nothing |

The mixed policy is safe because the two surfaces are independent `Stack` children. A plan
that applies one uniform policy to both is wrong in one direction or the other.

### Landmine cross-check against the design note

| Note landmine | Stack status | Bearing on stack choice |
|---|---|---|
| #1 LOCKED modifier survives dismiss | **Already fixed** — `keyboard_panel.dart:241-249` calls `_controller.dismissed()` on collapse (quick `260812-tsw`, 2026-08-12), backed by `KeyboardInputController.dismissed()` (`keyboard_input_controller.dart:143`) | No package. The third mount point must route its dismiss through the same `dismissed()` call — a Stay-Mounted policy makes this *mandatory*, since nothing else unmounts to free the key |
| #2 pad-height clamp reads RAW window metrics | Unchanged hazard. `keyboard_panel.dart:405-408` computes `columnHeight` from `MediaQueryData.fromView(View.of(context))` with a 27-line load-bearing comment at 379-404 | No package fixes this. But note: a shell that shrinks screens by a bar height introduces a **fourth** inset context, and `View.of` will not see the bar at all. Re-derive; flag for ARCHITECTURE |
| #3 hidden IME must stay mounted outside animating chrome | Solved idiom exists (`keyboard_panel.dart:414-420`); `Offstage`'s documented "still active… can receive focus and have keyboard input directed to them" is the property that makes it survive dismissal too | Confirms the built-in is sufficient. Must pair with an explicit `unfocus()` on dismiss (the docked panel already does — `keyboard_panel.dart:242`) or the system IME stays up over a dismissed surface |
| #4 chip row overflows 7.3px at 360dp | `_chipRow()` at `keyboard_panel.dart:306-326` — four `Expanded` + fixed 8px gaps + 16px padding; "Shift" does not fit its quarter | Pure layout fix (`FittedBox` / smaller label style / `Flexible` text). **No package.** Do not reach for `auto_size_text` |
| #5 `showBubble: false` semantics | The flag is `bubble_scaffold.dart:61-68`, set only by the Trackpad tile (`hub_screen.dart:91-92`) | Naming/semantics decision, not a stack decision |

---

## Mounting: shell-level, not route-level, not go_router

**Recommendation: a shared shell widget that each screen composes — the existing
`BubbleScaffold` seam, renamed and re-payloaded.**

| Option | Verdict | Evidence |
|---|---|---|
| **Shared shell widget (recommended)** | ✅ | One central wiring point already exists: `hub_screen.dart:282-293` `_open()` wraps every tool screen. The bar reaches every tool screen by editing **one function**. Two more edits reach the rest: `main.dart:116` (`home: const HubScreen()` — currently unwrapped, and the design note's assumption #4 requires the hub to get the bar) and, if "every screen" is read literally, the four unwrapped pushes at `settings_screen.dart:218, 659`, `device_list_screen.dart:93-95`, `pairing_dialog.dart:359-360`. Crucially, the shell is inside the `MaterialPageRoute`, so `PopScope` registers |
| `MaterialApp.builder` | ❌ | **`PopScope` becomes a silent no-op** — `pop_scope.dart:196` registers through `ModalRoute.of(context)`, and above the `Navigator` there is no `ModalRoute`. Back-to-dismiss (D8-08) would break with no error message. Also `Navigator.of(context)` throws above the Navigator, and the bar would paint over the sensitivity sheet (`trackpad_screen.dart:103`), the power confirm dialog (`power_screen.dart:153`), and the pairing sheet (`pairing_dialog.dart:321`) |
| Custom `NavigatorObserver` | ❌ | An observer is a notification callback, not a mounting mechanism — it cannot put a widget on screen. Anything it drives ends up being an `OverlayEntry`, inheriting all of that row's problems |
| `ShellRoute` (go_router) | ❌ | Would require adopting go_router, which `PROJECT.md` and `hub_screen.dart:15-16` record as explicitly **not** adopted ("plain `MaterialPageRoute` push of the spec's builder (house rule — no go_router)"). **Argued, not ignored:** `ShellRoute`'s genuine advantage is a shell instance that survives across route changes, so a raised surface would persist through navigation. That advantage is *worthless here* because the design note states usage is sequential ("dismisses quickly", "I require other remotes when using the trackpad… but it can be sequential") — the surface is meant to be dismissed before navigating, not carried across screens. And the durable half of "restore where it was" (which pad) is already cross-screen via `panelPadProvider` + `shared_preferences`. Paying a routing-library migration across ~11 screens and 872 tests to buy a property the requirement does not ask for is a bad trade. **Do not adopt.** |

**Consequence to record:** with per-screen shell instances, each screen gets its own
`KeyboardInputController`, so navigating away runs its LIVE-only dispose flush and releases
held keys. That is the *safe* direction — a route-surviving shell would keep a locked
modifier alive across navigation, which is landmine #1 wearing a different hat.

**Predictive-back note (verified in the pinned SDK):** `PopScope.canPop`'s doc states
*"Android's predictive back feature will not animate when this boolean is false."* Since
the shell holds `canPop: !raised` while a surface is up, the predictive-back peek is
suppressed exactly while the overlay is raised. That is correct behaviour here (back should
dismiss the overlay, not preview leaving the screen), but it is a real, observable
difference on Android 14+ and should not surprise a reviewer.

---

## Animation & Gesture: nothing beyond what is here

**No animation or gesture package is warranted.** The requirement is a single
0→1 slide/fade over ~200ms and a one-gesture dismiss. `AnimationController` +
`AnimatedBuilder`/`SlideTransition` + `GestureDetector` cover it completely.

- **Duration vocabulary is already unified at 200ms**: `kBubbleExpandDuration`
  (`bubble_scaffold.dart:50`), `KeyboardPanel`'s `AnimatedSize`
  (`keyboard_panel.dart:425-427`), and the pad-tab page animation
  (`keyboard_panel.dart:290-293`). Reuse the constant; do not introduce a second one.
- **Prefer `SlideTransition` / `AnimatedBuilder` + `FractionalTranslation` over
  `AnimatedOpacity` for the raised surface.** `Opacity` between 0 and 1 forces a
  `saveLayer` on a full-width surface every frame; a translate does not. The existing
  `FadeTransition` at `bubble_scaffold.dart:206-211` is fine because it wraps a 56px bubble,
  not a half-screen panel.
- **`AnimatedPositioned` vs. `SlideTransition`:** `AnimatedPositioned` is implicit and
  re-lays-out every frame; `SlideTransition` is a paint-time transform. For a surface as
  heavy as the four-pad deck, prefer the transform. Either is built in.
- **Do NOT use `Dismissible` / `DismissDirection` for the trackpad surface.** `Dismissible`
  is a `GestureDetector` **ancestor** of its child, which is precisely the arena conflict
  `floating_trackpad_window.dart:6-7` exists to avoid — a swipe-to-dismiss over a live
  trackpad would race every cursor throw. Use a dedicated grab-handle `GestureDetector` as a
  spatial sibling, exactly as `floating_trackpad_window.dart:245-248` already does.
  `Dismissible` on the *keyboard* surface is also a poor fit: it removes its child from the
  tree on dismiss (its whole contract), which is the Stay-Mounted violation.

Verified currency of the animation/sheet packages, so the "no" is grounded rather than
reflexive:

| Package | Latest on pub.dev | Published | What it would add here |
|---|---|---|---|
| `smooth_sheets` | 1.1.1 | **2026-08-11** (very active) | Genuinely the best-maintained sheet library in 2026 — but it is *route-based* (its headline feature is nested navigation inside sheets), so its child is destroyed on dismiss. Solves a problem this milestone does not have, and fails the one it does |
| `sheet` | 1.0.1 | 2026-07-21 | Same author lineage as `modal_bottom_sheet`; draggable route-based sheet. Same disqualification |
| `modal_bottom_sheet` | 3.0.0 | **2024-03-12 (~2.4 years stale)** | Cupertino-style modal routes. Stale *and* route-based |
| `flutter_animate` | 4.5.2 | 2024-11-25 | Declarative sugar over `AnimationController`. Zero new capability; adds a second animation vocabulary alongside the established 200ms controller idiom |
| `sliding_up_panel` | 2.0.0+1 | **2021-04-27 (~5 years stale)** | Abandoned. Also drag-based, arena-hostile to the trackpad |
| `persistent_bottom_nav_bar` | 6.2.1 | 2024-07-11 | Nested-Navigator tab shell. Would restructure navigation to deliver a bar the app can draw in ~40 lines |

---

## Alternatives Considered

| Recommended | Alternative | When to Use Alternative |
|-------------|-------------|-------------------------|
| `Stack` in a shared shell | `OverlayPortal` | If the raised surface ever becomes genuinely stateless AND must escape the shell's paint bounds (e.g. render above a dialog). Neither is true; and the moment either surface holds state, this option is off the table again |
| `Offstage` gate (keyboard) | `IndexedStack` | If a *third* summonable surface appears and only one may ever be up. `IndexedStack` keeps all children mounted and shows one — same State-preserving property, better ergonomics at N≥3. At N=2 it is heavier than needed and it lays out every child |
| `Offstage` gate | `Visibility(visible:, maintainState: true)` | Functionally identical and arguably clearer at the call site — its `build` composes exactly `TickerMode(enabled:) + Offstage(offstage:)` (verified in `visibility.dart`). Prefer `Visibility` if you want the ticker suppression for free; prefer bare `Offstage` if the surface has no tickers to suppress |
| Shared shell widget | `ShellRoute` (go_router) | Only if a future milestone needs deep links, or needs the raised surface to *survive navigation*. The design note explicitly says usage is sequential, so this is not that milestone. Revisit only with new evidence, and record it as a reversal of the recorded house rule |
| Shell as `Column [Expanded(screen), bar]` | Shell as `Stack` + `MediaQuery` bottom-padding injection | If shrinking the screen's box breaks a screen's own layout maths. Note that neither approach is visible to `View.of(context)`, so landmine #2's clamp is unaffected either way — and that is the point: it must be re-derived, not copied |
| Reuse `kBubbleExpandDuration` (200ms) | A new, faster constant | If on-device judgement says 200ms feels slow at summon-dozens-of-times-per-session frequency. This is a one-constant change, not a stack change. The design note's "speed contract" lives in the spec, not in a package |

---

## What NOT to Use

| Avoid | Why | Use Instead |
|-------|-----|-------------|
| `smooth_sheets` 1.1.1 | Route-based → **child destroyed on dismiss**, failing the restore-without-a-jump requirement. Well-maintained, wrong tool | `Stack` child + `Offstage` |
| `sheet` 1.0.1 / `modal_bottom_sheet` 3.0.0 | Same route-based disqualification; `modal_bottom_sheet` is also ~2.4 years stale | `Stack` child + `Offstage` |
| `sliding_up_panel` 2.0.0+1 | **Abandoned since 2021.** Drag-based sheet that would fight the trackpad's arena-free `Listener` | `AnimationController` + `SlideTransition` |
| `flutter_animate` 4.5.2 | Adds a second animation vocabulary for zero capability; the app already has one 200ms controller idiom used in three places | `AnimationController` at `kBubbleExpandDuration` |
| `go_router` (any version) | Contradicts a recorded house rule (`PROJECT.md`, `hub_screen.dart:15-16`) to buy cross-route shell persistence the requirement does not ask for. ~11 screens, 872 tests | Plain `Navigator` + shared shell widget |
| `persistent_bottom_nav_bar` 6.2.1 | Restructures navigation into nested Navigators to deliver a two-icon bar the app can draw itself. Massive blast radius, and it would break the `PopScope` back contract | A `Row` of two `IconButton`s in the shell |
| `OverlayPortal` / raw `OverlayEntry` | Destroys child state (`OverlayPortal`, documented) and/or puts the surface outside the `ModalRoute` so `PopScope` silently no-ops. The latter was already rejected in this codebase at `bubble_scaffold.dart:6-8` | `Stack` child inside the shell |
| `showModalBottomSheet` / any `PopupRoute` | Dismiss becomes a Navigator transaction *and* destroys the child. Both halves of the requirement fail | `Stack` child inside the shell |
| `DraggableScrollableSheet` | Built on a `Scrollable` that **wins the gesture arena** while the trackpad's `Listener` also fires — every cursor drag would also drag the sheet | Dedicated grab-handle `GestureDetector`, sibling of the `Listener` |
| `Dismissible` / `DismissDirection` | It is a gesture **ancestor** of its child (arena conflict, `floating_trackpad_window.dart:6-7`) and it removes the child on dismiss (Stay-Mounted violation) | Grab-handle `GestureDetector` + explicit controller reverse |
| `auto_size_text` (for landmine #4) | A whole package to shrink one "Shift" label by 7.3px | `FittedBox` / `Flexible` / a 1pt smaller `TextStyle` in `_chipRow()` |
| `flutter_keyboard_visibility` | The app already reads IME height first-party via `MediaQueryData.fromView(View.of(context)).viewInsets` + `didChangeMetrics` (`keyboard_panel.dart:196-199, 405-408`), with a documented reason for doing it that way | The existing `WidgetsBindingObserver` idiom |
| `keyboard_actions` | Designed for toolbars above the *system* IME for on-device text fields. This app has no on-device input target — that is the entire "Overlay, not IME-style resize" decision in `PROJECT.md` | Nothing |
| `provider` / `get_it` for the shell's state | Riverpod 3 is the locked state solution; a second container is the classic way two sources of truth appear | `flutter_riverpod` 3.3.2 / `ValueNotifier` for hot-path-local state |

---

## Stack Patterns by Variant

**If the keyboard surface is the one being raised:**
- Keep it **mounted** across dismiss — `Visibility(visible: raised, maintainState: true)`
  or bare `Offstage`, with the `HiddenTextInput` outside the animating chrome.
- Because the pad index, the `KeyboardInputController` FSM/held-set, and the Android input
  connection must all survive, and `Offstage` children *"can receive focus and have keyboard
  input directed to them"* (official docs) — the property landmine #3 depends on.
- **Must** call `KeyboardInputController.dismissed()` on every dismiss
  (`keyboard_input_controller.dart:143`), because with Stay-Mounted nothing else ever frees
  a LOCKED modifier. `keyboard_panel.dart:241-249` is the reference implementation.

**If the trackpad surface is the one being raised:**
- **Unmount** it on dismiss — a plain `if (raised)` `Stack` child.
- Because `TrackpadCore` acquires the ref-counted keep-awake hold on mount and releases it
  on dispose (`trackpad_core.dart:194, 209`, `widgets/keep_awake.dart`). Mounted-but-hidden
  = screen awake forever, on every screen, silently.
- The dismiss gesture must live on a dedicated handle that is a **sibling** of the
  `Listener`, never an ancestor (`floating_trackpad_window.dart:23, 245-248`).

**If both surfaces must be raisable simultaneously (they must not, per the design note):**
- Do not build it. `bubble_scaffold.dart:16` records the "never both" invariant (D8-01) and
  it is why the current expand gate is a single `ValueNotifier<bool>`. A tri-state
  (`none | trackpad | keyboard`) enum notifier is the natural successor — still no package.

**If a third summonable surface is ever added:**
- Switch the gate from per-surface `Offstage` to a single `IndexedStack`.
- Because at N≥3 the "exactly one visible, all mounted" semantics are what `IndexedStack`
  *is*, and hand-rolled gates start to drift.

---

## Version Compatibility

| Package A | Compatible With | Notes |
|-----------|-----------------|-------|
| Flutter 3.44.5 (pinned) | Dart 3.12.2 | Confirmed on disk (`/c/dev/flutter/version`) and in `pubspec.lock` (`dart: ">=3.12.2 <4.0.0"`, `flutter: ">=3.44.0"`) |
| Flutter 3.44 | `PopScope` / `onPopInvokedWithResult` | Non-deprecated API on this SDK — already asserted and relied upon at `bubble_scaffold.dart:27-28, 161`. Do **not** revert to `onPopInvoked` |
| Flutter 3.44 | `OverlayPortal`, `Visibility.maintainState`, `TickerMode.forceFrames` | All present. `TickerMode` on 3.44 additionally carries `forceFrames`; irrelevant here but note it exists if a plan reads older docs |
| `flutter_riverpod` 3.3.2 (locked) | pub.dev latest **3.4.2** (2026-07-28) | A minor behind. **Not a blocker and not part of this milestone** — this work adds no provider surface beyond the existing `panelPadProvider`. Bump only as a separate quick task, never inside a UI-restructuring phase |
| `flutter_riverpod` 3.x | `ProviderSubscription` / `ref.listenManual` | The idiom the pad restore uses (`keyboard_panel.dart:165-166`). Unchanged in 3.4.x |
| `material_symbols_icons` 4.2951.0 | const `IconData` only | `test/icons_guard_test.dart` enforces it; the bar's two icons must be const, never `Symbols.get()` |
| Android `minSdk` | ≥23 (from `flutter_secure_storage` 10.x) | Unaffected by this milestone; no new platform channel is introduced |

---

## Open Questions for ARCHITECTURE / phase planning

Not stack decisions, but the stack choice constrains them — flag them forward:

1. **Which inset context does the bar create?** A shell that shrinks screens (`Column
   [Expanded(screen), bar]`) leaves `MediaQuery.sizeOf` inside each screen reporting the
   full window, and `MediaQueryData.fromView(View.of(context))` reporting it too. Landmine
   #2's clamp at `keyboard_panel.dart:405-408` will be wrong by the bar height in the new
   mount. Re-derive; do not copy.
2. **Does "every screen" include Settings, Device List, Updates, QR Scan, and modal
   sheets?** Today only tool screens route through `hub_screen.dart:_open`. The hub itself
   (`main.dart:116`) is unwrapped. Four other pushes bypass the wrapper entirely.
3. **Does the bar suppress its own icon on the corresponding full screen?** The
   `showBubble: false` flag (`bubble_scaffold.dart:61-68`) encodes "no shortcut to the
   screen you are on"; the design note's landmine #5 asks for a deliberate re-read, not a
   mechanical port.
4. **Where does the trackpad's keep-awake hold sit when raised?** Unmount-on-dismiss makes
   this automatic, but a plan that "optimises" the trackpad to Stay-Mounted would silently
   break it. Worth a test that asserts the `KeepAwake` ref count returns to zero on dismiss.

---

## Sources

- **Pinned Flutter SDK source on disk, `/c/dev/flutter` @ 3.44.5** — `material/scaffold.dart:1040-1155` (body vs. bottomSheet layout), `:2418-2430, 2841` (persistent sheet teardown), `material/bottom_sheet.dart:870` (`ModalBottomSheetRoute extends PopupRoute`), `widgets/pop_scope.dart:171-215` (`ModalRoute.of` registration) and `:63-68` (predictive-back note), `widgets/visibility.dart` build (Offstage+TickerMode composition) — **HIGH** (this is the exact code that will compile; strongest tier available)
- [api.flutter.dev OverlayPortal](https://api.flutter.dev/flutter/widgets/OverlayPortal-class.html) — verbatim confirmation that hide removes the overlay child and stateful descendants may lose state — **HIGH**
- [api.flutter.dev Offstage](https://api.flutter.dev/flutter/widgets/Offstage-class.html) — child stays in tree, animations keep running, offstage children can still receive keyboard input — **HIGH**
- [api.flutter.dev TickerMode](https://api.flutter.dev/flutter/widgets/TickerMode-class.html) — ticker suppression without tree teardown — **HIGH**
- pub.dev JSON API (`/api/packages/<name>`, fetched 2026-08-12) — `smooth_sheets` 1.1.1 (2026-08-11), `sheet` 1.0.1 (2026-07-21), `modal_bottom_sheet` 3.0.0 (2024-03-12), `flutter_animate` 4.5.2 (2024-11-25), `sliding_up_panel` 2.0.0+1 (2021-04-27), `persistent_bottom_nav_bar` 6.2.1 (2024-07-11), `flutter_riverpod` 3.4.2 (2026-07-28) — **HIGH** (registry-of-record)
- **Repository source, read directly** — `app/remote_control/pubspec.yaml` / `pubspec.lock`, `lib/main.dart:112-118`, `lib/hub/hub_screen.dart:15-16, 86-144, 278-302`, `lib/widgets/bubble_scaffold.dart` (full), `lib/widgets/keep_awake.dart:1-40`, `lib/keyboard/keyboard_panel.dart` (full), `lib/keyboard/keyboard_screen.dart:1-120`, `lib/trackpad/trackpad_screen.dart` (full), `lib/trackpad/trackpad_core.dart:194-245`, `lib/trackpad/floating_trackpad_window.dart:1-115, 245-248`, `test/trackpad/trackpad_screen_test.dart:175-204` — **HIGH**
- `.planning/notes/summon-bar-trackpad-keyboard.md`, `.planning/PROJECT.md`, `CLAUDE.md` — locked stack, "What NOT to Use", the five landmines — **HIGH**

**Tooling note (honesty):** the `classify-confidence` seam returns `LOW` for the
`webfetch` provider generically, since it cannot see which URL was fetched. The HIGH tiers
above are assigned on the strength of cross-checking every load-bearing claim against the
pinned SDK source on disk and against first-party registries — not on the provider id. Every
behavioural claim in this document is traceable to a file path and line number.

---
*Stack research for: Flutter summon-bar / in-place overlay surfaces (v1.1)*
*Researched: 2026-08-12*
