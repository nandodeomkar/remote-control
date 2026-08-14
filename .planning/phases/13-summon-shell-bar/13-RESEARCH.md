# Phase 13: Summon Shell & Bar — Research

**Researched:** 2026-08-14
**Domain:** Flutter (Android) app-scope host restructuring — a permanent bottom bar + an in-place raised overlay, mounted at `MaterialApp.builder`
**Confidence:** HIGH (every framework claim read from the pinned SDK on disk at `C:/dev/flutter` @ **3.44.5**, `frameworkRevision f94f4fc76b4d74543ed9b085bbd75341ef65de22`, `dartSdkVersion 3.12.2` — `[VERIFIED: C:/dev/flutter/bin/cache/flutter.version.json]`; every codebase claim read from the working tree this session)

> **Scope discipline.** Milestone research (`.planning/research/{SUMMARY,ARCHITECTURE,PITFALLS,STACK}.md`) is the baseline. This document does **not** re-derive it. It closes the eight gaps the milestone research left open for Phase 13, verifies ARCHITECTURE §4 against the SDK and the tree, and corrects **three** milestone-research claims that are wrong or under-specified (see `## Corrections to Milestone Research`).

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

Copied verbatim from `.planning/phases/13-summon-shell-bar/13-CONTEXT.md` `## Implementation Decisions`.

**Back handling & the D5 spike**

- **D-13-01:** **Predictive back is measured, not enabled.** The D5 spike records what predictive back actually does on hardware today as an observed baseline, and the `SummonBackGuard` must not change it. **No `AndroidManifest.xml` edit and no `pageTransitionsTheme` edit in this phase.** SC3's "predictive back still animates" is therefore an assertion against the recorded baseline, not a task to make it animate. Grounding: the manifest never declares `android:enableOnBackInvokedCallback`, but `targetSdk` resolves to **36** through Flutter 3.44 (so Android's system predictive-back animations are default-on regardless of the flag), and the theme has no `PredictiveBackPageTransitionsBuilder` (so in-app route transitions have no predictive peek). The spike must record which of those two SC3 is measuring.

- **D-13-02:** **The guard is per-route AND per-owner:** `canPop: !(raised && owner == thisRoute)`. Only the route that *raised* the surface intercepts back. Back on a route pushed **after** the surface was raised pops that route normally and the surface rides along. So: raise on the hub → tap a hub tile → Media pushes underneath with the surface still up → back pops to the hub → back lowers the surface → back exits. This preserves SUM-04 ("back dismisses a raised surface before it pops the screen") on the owning screen while keeping the surface alive across navigation, which the anti-feature list requires. The shell must track route ownership of the raised surface — that is a **new obligation for the D5 spike** to prove alongside the intercept itself. — **Reversibility:** costly — the ownership token threads through the shell state, every `SummonBackGuard` instance and the Phase 17 `activeSurfaceProvider` stack; changing the rule later means re-deriving back behaviour on all 14 screens.

- **D-13-03:** **An orphaned surface stays raised and un-owned.** Tool screens have an AppBar back arrow, so the owning route can be popped without a back gesture. When that happens the surface stays up with no owner; from then on only the icon tap (and from Phase 14 the handle) dismisses it. **Accepted consequence, stated explicitly by the owner:** back from the hub with an orphaned surface raised will exit the app with the surface still raised. Ownership transfer was offered and declined — do not add transfer machinery. This is a deliberate trade for less state, not an oversight.

- **D-13-04:** **If the D5 spike fails, stop and check in with the owner.** If `SummonBackGuard` does not intercept back from a route below a `MaterialApp.builder` shell, the executor does **not** pick a fallback host shape. The per-route-shell fallback resurrects the exact defect the app-scope shell exists to prevent (N `KeyboardInputController`s → a Shift locked on the hub stays physically held on the PC with no chip anywhere to release it). Raise it as a checkpoint. — **Reversibility:** one-way — the host shape determines whether the hidden IME field can be a sibling of the animating chrome at all; recovering from the wrong choice is a host rewrite (research PITFALLS P4).

- **D-13-05:** **On the Browser screen, back resolves the surface first, then the bookmark folder, then the route.** Strict one-thing-per-gesture. **Implementation constraint:** `browser_screen.dart:576` already holds `PopScope(canPop: !inFolder)`, and multiple `PopScope`s in one subtree **AND** together — both callbacks fire when `canPop` is false. So `_onBookmarksBack` must become conditional on nothing being raised, or the two guards must resolve through a single decision point. This is PITFALLS P8's "audit before adding" with a concrete answer. It is the **only** other `PopScope` in `lib/` (`bubble_scaffold.dart`'s dies with the bubble in Phase 16).

**Overlay geometry**

- **D-13-06:** **Each icon raises its real final height in Phase 13**, not a placeholder. The trackpad icon raises the trackpad fraction; the keyboard icon raises the keyboard's (~0.75). Both come from **one shared derivation** — deriving once and applying a per-surface fraction, never forking the arithmetic per surface. Phases 14 and 15 then only fill a box that is already the right size. This is the reason the phase exists ahead of the surfaces: validating the formula against a number nothing ships would reproduce exactly the "invisibly wrong until a real device" failure the ordering was designed to prevent. — **Reversibility:** costly — the derivation is pinned by driven-viewport discriminator tests across five devices; changing its shape means re-deriving and re-pinning all of them.

- **D-13-07:** **The 48dp drag handle ships in Phase 13 as inert chrome.** SUM-05 (the handle as a working dismiss route, a11y-drivable) stays mapped to Phase 14, but the handle is *rendered* in 13 so the geometry this phase pins is the geometry that ships. Phase 14 adds behaviour to a box that already reserves the space — no re-derivation, and no second round of five-device viewport tests in a phase whose research flag is "not needed".

- **D-13-08:** **The empty overlay contains nothing throwaway.** `kSurface` fill, the real top-edge treatment the surfaces will keep, and the 48dp handle. No placeholder label, no debug height readout. Every pixel of Phase 13's overlay is chrome that Phases 14 and 15 inherit.

- **D-13-09:** **The height fractions are tuned on hardware during Phase 13's UAT.** Ship research's proposals as starting values (keyboard ~0.75; trackpad sized so the raised pad beats the retiring bubble window's 234px on the reference device while staying clearly smaller than the full Trackpad screen), then adjust in the same UAT session that judges 200/150ms and closes OQ-A1 sub-question 1. Both are one-constant changes. `kSummonMaxHeightFraction` / `kSummonTrackpadFraction` are declared design choices, not derived values — name them as such in code so a later reader does not treat them as arithmetic.

**Summon / dismiss behaviour**

- **D-13-10:** **Tapping the other icon swaps in place, in one animation.** The surface stays raised and crosses over, resizing to the other surface's height in a single motion — not a 150ms lower followed by a 200ms raise. **Consequence the planner must carry into Phases 14 and 15:** a swap is a dismiss for the outgoing surface, so the trackpad's dismiss-side cleanup (`TrackpadCoreState.dismissed()` drag-lock flush, keep-awake release) and the keyboard's `dismissed()` modifier release must fire on the **swap** edge too, not only on a full dismiss. A dismiss path that only triggers on "surface → nothing" leaves a held button or a locked modifier on the PC every time the owner swaps.

- **D-13-11:** **The raised surface's bar icon is accent-tinted (`kAccent`); the other stays `kMuted`.** This is what makes the tap-to-dismiss toggle legible rather than a guess, and it matters more given D-13-10 (with swap-in-place, nothing else on the bar says which surface is up). **Note for Phase 17:** this is a *different* state from RET-02's "you are here" (selected-and-inert for the screen you are currently on). Both eventually render on the same two icons — Phase 17 must compose with this treatment, not invent a conflicting one.

**The bar as chrome**

- **D-13-12:** **`kBg` fill with a `kHairline` top edge.** The bar reads as the edge of the screen, not as a component sitting on it — consistent with how the app already separates regions, and it honours "ship the bar looking empty". Icons carry all the visual weight. **Two icons centered as a pair**, dead width split evenly left and right — deliberate emptiness rather than two orphaned buttons, both in one thumb's reach, and the composition survives a hypothetical third icon (explicitly v2+).

- **D-13-13:** **`kSummonBarHeight = 56`, sitting above the Android gesture-nav inset** — the inset is padded *below* the 56dp, so total reserved space is `56 + viewPadding.bottom` and the icons never sit in the system gesture zone where the trackpad icon would compete with swipe-up-to-home. **When disconnected, both icons render `kMuted` but stay tappable**, mirroring the hub's D-08 offline tiles (which mute yet still open their screens); the raised surface shows its own disconnected state. This must be driven by the value-equal `connectionStatusProvider` — **never** a `ConnectionService.changes` subscription (research P9: the bar is on every screen including the trackpad's hot path, and the bar needs no `Timer.periodic`).

**Already Locked Upstream — do not re-open**

- Host shape: `SummonShell` at `MaterialApp.builder` + a thin per-route `SummonBackGuard` (research C1). The one-`KeyboardInputController`-per-process property is a **correctness** requirement, not tidiness.
- The phase **opens with the D5 spike** — prove the guard intercepts, plus one `find.byType` assertion that the builder sits above the Navigator.
- Bar scope: every screen including the hub; keyboard icon gated on local field focus (BAR-03, so a pairing PIN can never reach the PC); QR scan screen suppressed entirely (BAR-04).
- Motion: 200ms summon / 150ms dismiss (MOT-01), on-device UAT is the gate.
- Zero new dependencies. Exactly two icons. No scrim, no swipe-down-to-dismiss, no haptics on summon/dismiss, no hide-on-scroll, no auto-dismiss on inactivity/disconnect/screen-change, no nested `Navigator`, never a static `PopScope(canPop: false)`.
- **Not** an IME-style resize contract — nothing beneath a raised surface resizes, reflows or scrolls.
- Phase 13 writes the **test-migration checklist** that Phase 16 executes (~42 tests vanish, ~5 mutate, from a suite of 882).

### Claude's Discretion

- **A tap landing mid-animation reverses from the current animation value** (`AnimationController.reverse()`) — no queue, no input lockout. The owner expressed no preference; this is the default framework behaviour and therefore the least code.
- The exact composition of the test-migration checklist (format, per-suite contract capture) — the owner cares that it exists before anything is deleted, not what it looks like.
- Which five devices/viewports the inset discriminator tests drive, provided at least one is a 360dp-wide gesture-nav device with a raised IME (the case where a naive read yields an obviously wrong number).

### Deferred Ideas (OUT OF SCOPE)

- **Enabling in-app predictive back properly** (declare `android:enableOnBackInvokedCallback="true"` and add `PredictiveBackPageTransitionsBuilder` to `buildAppTheme()`). Deliberately out of Phase 13 per D-13-01. If the spike's recorded baseline shows in-app route transitions have no predictive peek, that is a finding to file with the evidence attached — not work to absorb here.
- **Ownership transfer for an orphaned surface** — considered and declined (D-13-03). Revisit only if exiting the app with a surface raised proves annoying in dogfooding.
- **A third bar icon, user-reorderable icons, swipe-on-bar to switch surfaces** — v2+, per research's defer list.
- **Deleting either hub tile (HUBF-01)** — explicitly deferred beyond v1.1; must not be pulled forward.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| **BAR-01** | A permanent bottom bar carrying a trackpad icon and a keyboard icon is visible on the hub and on every tool screen | §2 host shape (`MaterialApp.builder` proven above the Navigator, `[VERIFIED: C:/dev/flutter/packages/flutter/lib/src/widgets/app.dart:1690-1731]`); §7 bar geometry |
| **BAR-02** | The bar stays visible and tappable while a surface is raised — the surface sits on top of it, never under it | §7.4 Stack child ordering — bar is the **last** child so it paints over and hit-tests before the sliding surface; invariant test I1 (`surfaceRect.bottom == barRect.top`) |
| **BAR-03** | The keyboard icon is disabled whenever a local text field holds focus, so a pairing PIN can never be typed into the PC | §8 — **milestone research's predicate is wrong**; the corrected `EditableText`-ancestor predicate + `FocusManager` as the notify source |
| **BAR-04** | The bar is suppressed entirely on the QR scan screen | §9 — a shell-scope depth counter set by a `SummonBarSuppressor` wrapper at `pairing_dialog.dart:360`; the lifecycle-ordering trap and why a bool fails |
| **BAR-05** | Every screen's content stays fully reachable with the bar present — nothing clipped or stranded behind it | §6 Step 4 — the `MediaQuery` padding injection, verified against `Scaffold._addIfNonNull` `[VERIFIED: material/scaffold.dart:2915-2936, 3028-3034]`; all 14 screens already `SafeArea`-wrap |
| **SUM-01** | Tapping a bar icon raises that surface over the current screen without navigating away | §7 animation shape; no route push anywhere in the summon path |
| **SUM-02** | Nothing beneath a raised surface resizes or reflows, and a tappable widget outside the surface still receives its tap | §7.4 — the overlay is a `Positioned` sibling of the Navigator, never an ancestor of it; the surviving `bubble_scaffold_test.dart:156-186` contract |
| **SUM-03** | Tapping the same bar icon again dismisses the raised surface | §7.5 mid-animation reverse; §7.6 timing tests |
| **SUM-04** | The Android back gesture dismisses a raised surface before it pops the screen | §3 the D5 spike (exact test code); §4 route ownership; §5 the two-`PopScope` resolution |
| **MOT-01** | Summon completes in 200ms and dismiss in 150ms | §7.6 — the exact `pump(Duration)` sequences that discriminate 200 from a cut and 150 from 200; `pumpAndSettle` banned |
</phase_requirements>

---

## Summary

Phase 13 is a **host restructuring**, not a feature. Its entire risk surface is three framework behaviours that milestone research could only cite from docs, and one arithmetic derivation that is invisible until it runs on a real device. All three framework behaviours are now **read from the pinned SDK source on disk and confirmed**, which downgrades D5 from "the thing most likely to invalidate the host shape" to "a cheap regression pin". Specifically: `MaterialApp.builder`'s output is passed the Navigator as its `child` and is therefore unambiguously its ancestor (`widgets/app.dart:1690-1731`); `PopScope` registers with `ModalRoute.of(context)` in `didChangeDependencies` and is a silent no-op with no route above it (`widgets/pop_scope.dart:194-202`); and `ModalRoute` fans a pop out to **every** registered `PopEntry` in a `Set`, so two `PopScope`s on one route both fire, in unspecified order (`widgets/routes.dart:1980, 2034-2050`). The D5 spike should still be written — but as the first *test*, not as a gate on the design.

Three milestone-research claims need correcting before the planner uses them. (1) **BAR-03's gating predicate is wrong.** PITFALLS P12 and SUMMARY C5 both propose gating the keyboard icon on `FocusManager.instance.primaryFocus` being *null*. `primaryFocus` reverts to `rootScope` whenever nothing else claims it (`widgets/focus_manager.dart:1965-1969`) and `WidgetsApp` autofocuses a `FocusScope` around the Navigator (`widgets/app.dart:1692-1694`), so it is essentially **never null in a live app** — that predicate disables the keyboard icon permanently. The correct predicate is "the focused node lives inside an `EditableText` that is not the shell's own hidden field". (2) **SC3's "predictive back still animates" measures exactly one thing**, and it is measurable in a widget test: Flutter reports `SystemNavigator.setFrameworkHandlesBack(false)` only when the Navigator cannot pop *and* no route blocks pop (`widgets/navigator.dart:3743-3753`, `widgets/app.dart:1442-1455`), so the *only* predictive-back animation this app has today is back-to-home from the hub. In-app route peeking has never existed here and cannot regress. (3) **The `available` formula must be read from the un-injected MediaQuery**, which milestone research states but never guards — and reading the *injected* one (the bar-reserving copy) is a 56px error that is a discriminator on the reference device with the IME **down**, i.e. the easiest case to get wrong and the hardest to notice.

The load-bearing new design work is **route ownership** (D-13-02, entirely absent from milestone research). Holding a `Route` reference in the shell both leaks the popped route's object graph while a surface is orphaned and makes D-13-03 hard to express. The recommendation is a **monotonic `int` guard-id stack**: each `SummonBackGuard` mints an id on mount, appends it to a shell-scope `List<int>`, removes it on dispose; summon records `owner = stack.last`. Orphaning is then the natural consequence of the owner's id no longer being in the stack — no transfer machinery, no retained `Route`, and `canPop` evaluates to `true` on every route once the owner is gone, which is D-13-03 stated exactly. The second new piece is the **two-`PopScope` resolution**: because both callbacks fire and `Set` order is not a contract, the browser's `_onBookmarksBack` must be made *predicate*-conditional (not order-dependent), reading the shell's live state through a non-subscribing `getInheritedWidgetOfExactType` lookup so the browser never rebuilds off summon state.

**Primary recommendation:** open with a three-assertion spike plan (builder-above-Navigator, guard intercepts from a pushed route, guard is a no-op above the Navigator), then build the shell in one plan with the geometry pinned by five driven-viewport tests whose expected values are **computed from the driven metrics, never quoted** — the `floorFor()` idiom already at `test/trackpad/trackpad_screen_test.dart:143-145, 176`.

---

## Corrections to Milestone Research

| # | Milestone claim | Correction | Evidence |
|---|---|---|---|
| **X1** | "gate the **keyboard** icon on 'no `TextField` currently focused' via `FocusManager.instance.primaryFocus`" (PITFALLS P12:784-786); "gated on `FocusManager.instance.primaryFocus` being **null**" (SUMMARY C5:101) | `primaryFocus` is **not null** when no field is focused — it reverts to `rootScope`, and `WidgetsApp` autofocuses a `FocusScope` around the Navigator. Gating on null disables the keyboard icon **always**. Use the `EditableText`-ancestor predicate in §8. | `[VERIFIED: C:/dev/flutter/packages/flutter/lib/src/widgets/focus_manager.dart:1965-1969]` — *"If we don't have any current focus, and nobody has asked to focus yet, then revert to the root scope."* `[VERIFIED: widgets/app.dart:1692-1694]` — `FocusScope(debugLabel: 'Navigator Scope', autofocus: true, child: Navigator(...))` |
| **X2** | "Keep exactly ONE `PopScope`, at the summon host" (PITFALLS P8:520) | There cannot be exactly one — `browser_screen.dart:576` already exists and the guard is per-route, so there are **N+1**. The correct rule is "exactly one *decision*", implemented as mutually-exclusive predicates, not as ordering. | `[VERIFIED: app/remote_control/lib/browser/browser_screen.dart:576-580]`; `[VERIFIED: widgets/routes.dart:2044-2050]` — `onPopInvokedWithResult` iterates **all** `_popEntries` |
| **X3** | "back must be intercepted with `NavigatorObserver`/`WidgetsBindingObserver`-level handling" as an option (PITFALLS P8:506-507) | A shell-level `WidgetsBindingObserver.didPopRoute` override is a dead end: `handlePopRoute` returns on the **first** observer that returns true, and `WidgetsApp`'s own observer is registered in its `initState` before any builder child exists. | `[VERIFIED: C:/dev/flutter/packages/flutter/lib/src/widgets/binding.dart:1113-1131]` — `for (final observer in ...) { if (await observer.didPopRoute()) return true; }` |
| **X4** | "~42 tests vanish and ~5 mutate, from a suite of **882**" (CONTEXT.md, SUMMARY D4) | Tree-verified count at `master @ e2741fa`: **823** `test(`/`testWidgets(` declarations in `app/remote_control/test` + **15** in `app/packages/remote_protocol/test` = **838**. **37** vanish (4 whole suites) and **5** are rewritten. Use 838/37/5 in the checklist so a later reader does not chase a 44-test gap that does not exist. | `[VERIFIED: grep -coE "\b(testWidgets\|test)\(" over app/remote_control/test and app/packages/remote_protocol/test, run this session]` |

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Bar rendering + hit-testing | Flutter app-scope shell (above Navigator) | — | One mount reaches every route incl. `home:`; per-route mounting yields N `KeyboardInputController`s (SUMMARY C1) |
| Raised-surface geometry (inset arithmetic) | Flutter app-scope shell | — | Only the un-stripped ancestor `MediaQuery` at `builder` has real `viewPadding`/`viewInsets` |
| Back-gesture interception | Flutter **route** scope (`SummonBackGuard`) | — | `PopScope` registers with `ModalRoute.of(context)`; there is no route above the Navigator |
| Route ownership of the raised surface | Flutter app-scope shell (id stack) | route-scope guard (mints/retires its id) | Shell must not retain a `Route` object (D-13-03 orphan case) |
| Bar-suppression (QR) | Flutter route scope (`SummonBarSuppressor` wrapper) → shell counter | — | The shell cannot read route identity; the route declares itself |
| Keyboard-icon focus gate | Flutter app-scope shell, scoped `ListenableBuilder` on `FocusManager.instance` | — | Focus is a global singleton; a narrow rebuild scope is P9's requirement |
| Connection state for icon tint | Riverpod `connectionStatusProvider` (value-equal) | — | D-13-13; never `ConnectionService.changes` (P9) |
| Predictive-back enablement | **Android platform** (`targetSdk 36` default-on) | Flutter framework (`setFrameworkHandlesBack`) | Nothing in Phase 13's Dart code enables or disables it; the guard only changes *when* Flutter claims the back |
| PC-side input safety (PIN never typed to PC) | Flutter client (BAR-03 gate) | — | No server or protocol change in this milestone |

---

## Project Constraints (from CLAUDE.md)

Actionable directives extracted from `C:/Users/omkar/Projects/Remote Control/CLAUDE.md`. All are compatible with this phase; the planner must verify compliance.

| Directive | Source | Effect on Phase 13 |
|---|---|---|
| **Tech stack locked**: Flutter (Android-first) client, `flutter_riverpod` 3.3.2 | `## Constraints`, `## Recommended Stack` | No package additions; Riverpod 3 unified `Notifier` only — never `StateNotifier`, never `AutoDispose*`/`Family*` variants |
| **Riverpod 3.x, v2 patterns banned** | `## What NOT to Use` | Any new provider (bar suppression, if provider-based) uses `NotifierProvider` with the v3 unified `Notifier` |
| **UI: dark minimal theme (#0E0F12, blue accent)** — locked by mockup | `## Constraints` | The bar is `kBg` + `kHairline` (D-13-12); no new colour may be introduced |
| **No protocol change / `protoVersion` bump** | `## Constraints` (transport locked by spec) + REQUIREMENTS `## Out of Scope` | Client-only phase; no `remote_protocol` edit |
| **Performance: cursor response visually instant (<30ms)** | `## Constraints` | The bar must never rebuild on the trackpad hot path — hence `connectionStatusProvider` (value-equal), never `ConnectionService.changes` |
| **GSD workflow enforcement** — no direct repo edits outside a GSD workflow | `## GSD Workflow Enforcement` | Execution happens under `/gsd-execute-phase` |
| **Conventions/Architecture "not yet established"** | `## Conventions`, `## Architecture` | Follow the in-tree house patterns cited throughout this document rather than inventing new ones |

**Two build-failing guards (repeat, because they are discovered as mystery failures otherwise):**

- `test/theme_tokens_guard_test.dart` — no `.dart` file under `lib/` except `lib/theme/tokens.dart` may contain any of the seven hex literals `0xFF0E0F12 / 0xFF16181D / 0xFF2A2D34 / 0xFFE6E8EB / 0xFF6B7280 / 0xFF4C8DFF / 0xFFFF6B6B`. Line comments (`//`) are exempt. `[VERIFIED: app/remote_control/test/theme_tokens_guard_test.dart:20-27, 44-57]`
- `test/icons_guard_test.dart` — `RegExp(r'(^|[^A-Za-z0-9_$])Icons\.')` may not match any non-comment line under `lib/`. Allowlist is **empty**. Use `Symbols.<name>_rounded` from `package:material_symbols_icons/symbols.dart`. `[VERIFIED: app/remote_control/test/icons_guard_test.dart:36, 40, 59-64]`
- The two bar glyphs already exist in the tree and are const: `Symbols.touch_app_rounded` (trackpad) and `Symbols.keyboard_rounded` (keyboard). `[VERIFIED: app/remote_control/lib/hub/hub_screen.dart:89, 97]`

---

## Standard Stack

**Zero new dependencies. `pubspec.yaml` is unchanged by this phase.** Every primitive is already in the pinned SDK. If a plan proposes a `pubspec.yaml` edit, that is a drift signal — re-read `.planning/research/STACK.md`, which disqualifies `OverlayPortal`, `showModalBottomSheet`, `DraggableScrollableSheet`, raw `OverlayEntry` and every third-party sheet on the **same** ground: route/portal-based, destroys child `State` on dismiss.

### Core (all already present)

| Primitive | Source | Purpose in Phase 13 | Why this one |
|---|---|---|---|
| `MaterialApp.builder` | Flutter 3.44.5 `material/app.dart:1028-1045` | The single insertion point for the shell | Its result is handed the Navigator as `child` — it is unambiguously the Navigator's ancestor `[VERIFIED: widgets/app.dart:1690-1731]` |
| `Stack` + `Positioned` | `widgets/basic.dart` | Overlay + bar without touching the Navigator's constraints | The only primitive that overlays without re-laying-out the body and keeps children mounted |
| `PopScope` | `widgets/pop_scope.dart` | The per-route `SummonBackGuard` | Registers with `ModalRoute.of(context)` `[VERIFIED: widgets/pop_scope.dart:194-202]` |
| `AnimationController` (+`reverseDuration`) | `animation/animation_controller.dart` | 200ms summon / 150ms dismiss; `reverse()` from the live value | One controller expresses both budgets; mid-flight reverse is free |
| `Transform.translate` | `widgets/basic.dart` | The raise/lower motion | No `saveLayer` (unlike `Opacity`), no per-frame relayout (unlike `AnimatedPositioned`) — P9 |
| `MediaQuery` / `MediaQuery.removePadding` | `widgets/media_query.dart` | Reserve the bar for all 14 screens with zero per-screen edits; strip the overlay's bottom padding | `Scaffold` passes `padding` through to the body unmodified when there is no `bottomNavigationBar` `[VERIFIED: material/scaffold.dart:2915-2936, 3028-3034]` |
| `ValueListenableBuilder` | `widgets/value_listenable_builder.dart` | Keep `canPop` reactive without rebuilding the body | The in-tree shape at `bubble_scaffold.dart:157-165` already solves this |
| `ListenableBuilder` over `FocusManager.instance` | `widgets/focus_manager.dart:1636` (`with ... ChangeNotifier`) | BAR-03's keyboard-icon gate | `FocusManager` `notifyListeners()` fires exactly on primary-focus change `[VERIFIED: widgets/focus_manager.dart:1999-2001]` |
| `InheritedWidget` + `getInheritedWidgetOfExactType` | `widgets/framework.dart:2470, 5092` | Browser reads shell state at callback time with **zero** subscription | `dependOn…` would rebuild `browser_screen` on every summon; `get…` creates no dependency |
| `flutter_test` `t.view.*` driven metrics | `flutter_test` | The five-viewport discriminator suite | The house idiom already at `test/trackpad/trackpad_screen_test.dart:151-164` |

### Supporting (already present, used only if the planner chooses)

| Primitive | Purpose | When |
|---|---|---|
| `TestDefaultBinaryMessengerBinding…setMockMethodCallHandler(SystemChannels.platform, …)` | Capture `SystemNavigator.setFrameworkHandlesBack` for the predictive-back baseline assertion | §10; house idiom at `test/haptics_gate_test.dart:19-30` |
| `tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed)` | Required before the above fires at all | `_defaultOnNavigationNotification` early-returns while `_appLifecycleState == null` `[VERIFIED: widgets/app.dart:1442-1455]` |
| `debugDefaultTargetPlatformOverride = TargetPlatform.android` | Same — `setFrameworkHandlesBack` no-ops off Android | `[VERIFIED: services/system_navigator.dart:26-44]` |

### Alternatives Considered

| Instead of | Could Use | Tradeoff |
|---|---|---|
| Per-route `SummonBackGuard` | Shell-level `WidgetsBindingObserver.didPopRoute` | **Rejected — proven dead.** `handlePopRoute` returns on the first observer that handles it, and `WidgetsApp`'s observer is registered first `[VERIFIED: widgets/binding.dart:1113-1131]` |
| Guard-id `int` stack | Holding the `Route` object in the shell | Retains a popped route's object graph while the surface is orphaned (D-13-03 makes that state reachable and long-lived) |
| Guard-id `int` stack | `route.settings.name` | All 7 page-route pushes use default `RouteSettings` (name `null`) `[VERIFIED: hub_screen.dart:285, 299; settings_screen.dart:219, 660; device_list_screen.dart:94; pairing_dialog.dart:360; bubble_scaffold.dart:118]` — would need 7 edits and still collide on duplicates |
| `Transform.translate` + Stack paint order | `ClipRect` around the overlay | A clip on a half-screen surface is a per-frame raster cost for nothing; painting the bar **last** hides the slide for free (§7.4) |
| Depth-counted suppression | A `bool` suppression flag | On push, the new route's `initState` runs while the old route is still mounted; on pop, `dispose` runs after the transition — a bool flickers at both boundaries (ARCHITECTURE §6.4's own warning about `activeSurfaceProvider`) |

**Installation:** none. `flutter --version` on PATH resolves to the pinned 3.44.5; `flutter_test` comes from `sdk: flutter` `[VERIFIED: app/remote_control/pubspec.yaml:83-84]`.

---

## Package Legitimacy Audit

**Not applicable — this phase installs zero external packages.** `pubspec.yaml` is unchanged (locked by `.planning/ROADMAP.md` `## Milestone-Wide Constraints` and repeated in CONTEXT.md). No registry lookup was performed and none is needed.

**Packages removed due to [SLOP] verdict:** none.
**Packages flagged as suspicious [SUS]:** none.

---

## Architecture Patterns

### 1. The proven ancestor chain (closes the `MaterialApp.builder` gap)

`MaterialApp` → `_MaterialAppState._materialBuilder` wraps `widget.builder!(context, child)` in a `Builder`, then in `ScaffoldMessenger` → `DefaultSelectionStyle`, then in `AnimatedTheme`/`Theme` `[VERIFIED: C:/dev/flutter/packages/flutter/lib/src/material/app.dart:1026-1067]`. That whole thing is handed to `WidgetsApp` as its `builder`, and `WidgetsApp.build` does:

```dart
// C:/dev/flutter/packages/flutter/lib/src/widgets/app.dart:1690-1731 (verbatim, elided)
} else if (_usesNavigator) {
  routing = FocusScope(
    debugLabel: 'Navigator Scope',
    autofocus: true,
    child: Navigator( ... key: _navigator, initialRoute: _initialRouteName, ... ),
  );
}
Widget result;
if (widget.builder != null) {
  result = Builder(
    builder: (BuildContext context) {
      return widget.builder!(context, routing);
    },
  );
}
```

**Therefore, above the shell (available from its `BuildContext`):** `Theme` / `AnimatedTheme`, `ScaffoldMessenger`, `DefaultSelectionStyle`, `Localizations`, `Directionality`, `Shortcuts`, `Actions`, `FocusTraversalGroup`, `TapRegionSurface`, `NotificationListener<NavigationNotification>`, `SharedAppData`, `RootRestorationScope`, and the root `View`'s `MediaQuery`. **Below the shell:** `FocusScope('Navigator Scope')` → `Navigator` → routes. `[VERIFIED: widgets/app.dart:1690-1857, material/app.dart:1026-1067]`

`MaterialApp` never introduces its own `MediaQuery` — *"MaterialApp never introduces its own MediaQuery; the View widget takes care of that."* `[VERIFIED: material/app.dart:267]`. **This is the load-bearing fact for §6:** the shell reads the raw, un-stripped view metrics, exactly as ARCHITECTURE §4.2 predicted.

**HIGH confidence.** This upgrades ARCHITECTURE.md's LOW/webfetch-classified claim.

### 2. `PopScope` is a route-scoped registration (closes D5's first half)

```dart
// C:/dev/flutter/packages/flutter/lib/src/widgets/pop_scope.dart:193-202 (verbatim)
@override
void didChangeDependencies() {
  super.didChangeDependencies();
  final ModalRoute<dynamic>? nextRoute = ModalRoute.of(context);
  if (nextRoute != _route) {
    _route?.unregisterPopEntry(this);
    _route = nextRoute;
    _route?.registerPopEntry(this);
  }
}
```

`ModalRoute.of(context)` returns `null` above the Navigator, so `_route?.registerPopEntry` is a **null-aware no-op with no error, no assert and no log** — D5's premise confirmed. `[VERIFIED: widgets/pop_scope.dart:196-201]`

### 3. Two `PopScope`s on one route: what actually happens (closes D-13-05)

Three verbatim facts:

```dart
// widgets/routes.dart:1980
final Set<PopEntry<Object?>> _popEntries = <PopEntry<Object?>>{};

// widgets/routes.dart:2033-2042
@override
RoutePopDisposition get popDisposition {
  for (final PopEntry<Object?> popEntry in _popEntries) {
    if (!popEntry.canPopNotifier.value) {
      return RoutePopDisposition.doNotPop;
    }
  }
  return super.popDisposition;
}

// widgets/routes.dart:2044-2050
@override
void onPopInvokedWithResult(bool didPop, T? result) {
  for (final PopEntry<Object?> popEntry in _popEntries) {
    popEntry.onPopInvokedWithResult(didPop, result);
  }
  super.onPopInvokedWithResult(didPop, result);
}
```

And the dispatch site:

```dart
// widgets/navigator.dart:5546-5578 (elided) — maybePop
final _RouteEntry? lastEntry = _lastRouteEntryWhereOrNull(_RouteEntry.isPresentPredicate);
...
switch (lastEntry.route.popDisposition) {
  case RoutePopDisposition.bubble:   return false;
  case RoutePopDisposition.pop:      pop(result); return true;
  case RoutePopDisposition.doNotPop: lastEntry.route.onPopInvokedWithResult(false, result); return true;
}
```

**Consequences the planner must build against:**

1. Only the **topmost present route** is consulted. A guard on a route below never participates. This is what makes D-13-02's "back on a route pushed after the surface was raised pops that route normally" free — the lower guard is not even asked. `[VERIFIED: widgets/navigator.dart:5547, 5569]`
2. `canPop` ANDs: **any** `false` blocks the pop. Confirmed by the public doc too: *"If multiple `PopScope` widgets appear in a route's widget subtree, then each and every `canPop` must be `true` in order for the route to be able to pop."* `[VERIFIED: widgets/pop_scope.dart:158-160]`
3. **Both callbacks fire, unconditionally**, with the same `didPop`. There is no veto, no "handled" return. `[VERIFIED: widgets/routes.dart:2044-2050]`
4. `_popEntries` is a `Set`. Dart's default `{}` literal is a `LinkedHashSet` (insertion-ordered), and insertion order is `didChangeDependencies` order — ancestor before descendant. **Do not rely on this.** It is not part of `Set`'s contract, and re-registration on a route change (`pop_scope.dart:197-201`) reshuffles it.
5. `onPopInvokedWithResult(true, result)` **also** fires on a successful pop `[VERIFIED: widgets/navigator.dart:5620]`, so every callback must start with `if (didPop) return;`. Both existing call sites already do (`browser_screen.dart:579`, `bubble_scaffold.dart:162`).

**The idiom (order-independent, one action per gesture):**

```dart
// SummonBackGuard — owns the highest-priority action.
onPopInvokedWithResult: (didPop, _) {
  if (didPop) return;
  if (_ownsRaisedSurface) shell.lower();     // else: not mine, do nothing
},

// browser_screen.dart:576-580 — becomes conditional on the SAME predicate.
onPopInvokedWithResult: (didPop, _) {
  if (didPop) return;
  if (SummonScope.ownsRaisedSurface(context)) return;   // the surface consumed this gesture
  _onBookmarksBack();
},
```

Both predicates read the **same** shell state, so exactly one action runs regardless of iteration order. `SummonScope.ownsRaisedSurface(context)` must use `context.getInheritedWidgetOfExactType<SummonScope>()` (**non-subscribing**, `[VERIFIED: widgets/framework.dart:2452-2470, 5092]`) and read a `ValueNotifier` held by that inherited widget — so `browser_screen` never rebuilds when a surface is raised, satisfying P9's rebuild-scope rule.

**Anti-pattern to forbid in the plan text:** a "consumed" latch set by whichever callback runs first. It works today and breaks silently the first time `Set` iteration order shifts.

### 4. Route ownership without retaining a `Route` (closes D-13-02 / D-13-03)

The shell cannot call `ModalRoute.of` — it is above the Navigator. Four candidate mechanisms:

| Mechanism | Verdict |
|---|---|
| `ModalRoute.of(context)` identity, captured by the guard and pushed up to the shell at summon time | Works, but the shell then holds a `Route` reference. When the owner pops (D-13-03), the shell retains the popped `MaterialPageRoute` — its `AnimationController`s, `_settings`, overlay entries — for as long as the surface stays orphaned. Functionally harmless, structurally a leak, and it makes "un-owned" a *dangling-pointer* state rather than an *absent-id* state |
| `route.settings` / named routes | All 7 page pushes use default `RouteSettings` (name `null`) — see §Alternatives. Rejected |
| `NavigatorObserver` tracking the current route | Same `Route` retention, plus a second source of truth for "what is current" that can desync from the guard stack |
| **Monotonic `int` guard-id stack** | **Recommended.** No `Route` retained, orphaning is a pure predicate, and it composes with Phase 17's `activeSurfaceProvider` because both want the same "topmost route" notion |

**Recommended shape:**

```dart
// summon_shell_state.dart (shell-scope, plain object — no Riverpod needed)
int _nextGuardId = 0;
final List<int> _guardStack = <int>[];          // push on mount, remove on dispose
int mintGuardId() => _nextGuardId++;
void registerGuard(int id) => _guardStack.add(id);
void unregisterGuard(int id) => _guardStack.remove(id);   // remove by VALUE, not by index

int? _ownerGuardId;                              // set at summon, never cleared on route pop
SummonSurface? _raised;

bool ownsRaisedSurface(int guardId) =>
    _raised != null && _ownerGuardId == guardId;

void raise(SummonSurface s) {
  _ownerGuardId = _guardStack.isEmpty ? null : _guardStack.last;   // may legitimately be null
  _raised = s;
}
```

**Lifecycle-ordering behaviour, stated explicitly** (this is the trap ARCHITECTURE §6.4 records for `activeSurfaceProvider`, and it applies identically here):

| Moment | `_guardStack` | Consequence |
|---|---|---|
| Push begins — new route's guard `initState` runs while the old route is still mounted | `[old, new]` — `.last == new` | A summon during the push animation is owned by the **incoming** route. Correct. |
| Pop begins — the popped route's guard is still mounted until the transition ends | `[old, dying]` — `.last == dying` | A summon during a pop animation is owned by a route about to die → instantly orphaned. Benign, and unreachable in practice (the bar is the only summon affordance and it is occluded by nothing during a transition). **Note it; do not add machinery for it.** |
| Pop completes — `dispose` runs after the transition | `[old]` | If `_ownerGuardId` was the dying route's, no live guard matches → `ownsRaisedSurface` is `false` **everywhere** → every route's `canPop` is `true` → back exits from the hub with the surface still up. **That is D-13-03, verbatim, with zero extra code.** |
| `removeRoute` / out-of-order disposal | remove-by-value keeps the stack consistent | Never index-based removal |

**Guard `canPop` expression (the only one allowed):**

```dart
canPop: !shell.ownsRaisedSurface(_id)
```

Never `!raised` alone (that would make **every** route intercept, contradicting D-13-02), and never a static `false`.

**Guard coverage.** `SummonBackGuard` must wrap every **page** route or SUM-04 silently fails on the un-wrapped ones. Verified push sites in `lib/` `[VERIFIED: grep MaterialPageRoute over app/remote_control/lib, run this session]`:

| Site | Destination | Guard needed |
|---|---|---|
| `main.dart:116` (`home:`) | `HubScreen` | **Yes** — root route |
| `hub_screen.dart:285` | the 9 tool screens (central) | **Yes** |
| `hub_screen.dart:299` | `SettingsScreen` | **Yes** |
| `settings_screen.dart:219` | `DeviceListScreen` | **Yes** |
| `settings_screen.dart:660` | `UpdatesScreen` | **Yes** |
| `device_list_screen.dart:94` | `HubScreen` (re-push) | **Yes** |
| `pairing_dialog.dart:360` | `QrScanScreen` | **Yes** — and also the `SummonBarSuppressor` (§9) |
| `bubble_scaffold.dart:118` | `TrackpadScreen` via `⤢` | Dies in Phase 16 — **wrap it anyway**, one line, so the bubble and the bar coexist correctly in 13-15 |

**Recommendation:** add a `pushGuarded<T>(BuildContext, Widget)` helper beside `SummonBackGuard` and convert all 8 sites mechanically. It makes future pushes obviously correct and it is the same "one central seam" move that `BubbleScaffold` proved at `hub_screen.dart:286`.

**Modal routes are deliberately un-guarded.** `showDialog` / `showModalBottomSheet` push their own `ModalRoute`; with one open it is `lastEntry`, so back closes the dialog first and the raised surface is untouched. Six such sites exist (`bookmark_confirm.dart:77`, `power_screen.dart:150`, `device_list_screen.dart:248`, `pairing_dialog.dart:314`, `trackpad_screen.dart:103`, `updates_screen.dart:636`) `[VERIFIED: grep showDialog|showModalBottomSheet over lib, run this session]`. State this as intended behaviour in the plan so nobody "fixes" it.

### 5. Anti-Patterns to Avoid

- **A static `PopScope(canPop: false)`** — official doc, verbatim: *"Android's predictive back feature will not animate when this boolean is false."* `[VERIFIED: widgets/pop_scope.dart:162-163]`. On the hub (the root route, `main.dart:116`) it also makes back stop exiting the app.
- **A shell-level `WidgetsBindingObserver.didPopRoute` override** — see X3. Dead end.
- **Reading the *injected* MediaQuery for the bar/overlay arithmetic** — see §6, failure mode F4. This is a 56px error that is wrong on the reference device with the IME down.
- **`MediaQueryData.fromView(View.of(context))` at the shell** (AP-1) — numerically identical today, but it registers **no dependency**, so the shell never rebuilds on an IME metric change and the overlay's height goes stale mid-animation. Discriminator test D5-E in §6.5.
- **Reusing `kPanelMaxHeightFraction = 0.55` or `kPanelColumnOverhead = 122`** — `0.55` is a contract reserving room for a live trackpad *beneath* the panel (`key_pads.dart:208-211`), which does not exist here; `122`'s `+1` is the docked panel's in-`Column` IME sliver (`key_pads.dart:164-180`), and the shell's hidden field is a `Positioned` sibling costing zero layout.
- **Porting `keyboard_panel.dart`'s `didChangeMetrics` observer** — at the shell the MediaQuery is not value-equal across the IME animation, so rebuilds are automatic; porting the observer doubles them on the hottest surface in the app.
- **An order-dependent "consumed" latch across the two `PopScope`s** — see §3.
- **`Opacity` / `AnimatedOpacity` on the overlay** — forces a `saveLayer` on a half-screen surface every frame (P9).
- **`AnimatedPositioned` for the raise** — re-lays-out every frame; `Transform.translate` does not.

---

## The Inset Arithmetic — verified against the tree, extended for two heights (closes D-13-06)

### 6.1 The formula (one derivation, per-surface fraction)

All four inputs read from the shell's own `BuildContext` — i.e. the **un-injected**, un-stripped ancestor `MediaQuery`:

```
S     = MediaQuery.sizeOf(context).height          // full window, logical px
Ptop  = MediaQuery.viewPaddingOf(context).top      // status bar   — IME-independent
Pbot  = MediaQuery.viewPaddingOf(context).bottom   // gesture nav  — IME-independent
Ibot  = MediaQuery.viewInsetsOf(context).bottom    // system IME, 0 when down

barBottomOffset = max(Pbot, Ibot)                  // never double-counts: the IME draws OVER the nav bar
barBlock        = kSummonBarHeight + barBottomOffset          // kSummonBarHeight = 56
available       = S - Ptop - max(Pbot, Ibot) - kSummonBarHeight
```

Then **one** height function with a per-surface fraction — never a forked arithmetic (D-13-06):

```dart
const double kSummonBarHeight        = 56;    // D-13-13 — content only, excl. the safe inset
const double kSummonKeyboardFraction = 0.75;  // DESIGN CHOICE (D-13-09), not a derived number
const double kSummonTrackpadFraction = 0.55;  // DESIGN CHOICE (D-13-09), not a derived number
const double kSummonMinSurfaceHeight = 220;   // DESIGN CHOICE — absolute floor, both surfaces

double summonSurfaceHeight(SummonSurface s, double available) => math.min(
      available,
      math.max(kSummonMinSurfaceHeight, available * _fractionOf(s)),
    );
```

`math.min(available, …)` is what makes the floor safe on a very short viewport: the floor can never push the surface past the space that exists.

**`viewPaddingOf`, not `paddingOf`** — `padding.bottom` collapses to 0 while the IME is up (the engine subtracts the inset); `viewPadding` does not. Same rule the docked panel states at `keyboard_panel.dart:399-403`; it is the one piece of the old arithmetic that transfers verbatim.

### 6.2 Reserving the bar for all 14 screens (BAR-05), verified against `Scaffold`

```dart
// summon_shell.dart — wraps ONLY the Navigator
Positioned.fill(
  child: MediaQuery(
    data: mq.copyWith(
      padding:     mq.padding.copyWith(bottom: mq.padding.bottom + kSummonBarHeight),
      viewPadding: mq.viewPadding.copyWith(bottom: mq.viewPadding.bottom + kSummonBarHeight),
      // viewInsets DELIBERATELY untouched
    ),
    child: child!,   // the Navigator
  ),
),
```

Why this reaches every screen with zero per-screen edits, proven end-to-end this session:

1. `Scaffold` passes `padding` to its body **unchanged** unless there is a `bottomNavigationBar` or `persistentFooterButtons` — `removeBottomPadding: widget.bottomNavigationBar != null || widget.persistentFooterButtons != null` `[VERIFIED: material/scaffold.dart:3032-3033]`. No screen in `lib/` has either.
2. `Scaffold` **does** strip `viewInsets.bottom` from the body (`removeBottomInset: _resizeToAvoidBottomInset`, default `true`) `[VERIFIED: material/scaffold.dart:3034, 2921-2923, 2779-2781]` — which is why leaving `viewInsets` untouched at the shell is correct: the Scaffold still shrinks by the real IME.
3. Every one of the 14 screens wraps its body in `SafeArea`, which consumes `padding.bottom` — including the injected 56. `[VERIFIED: ARCHITECTURE.md §1.1, cross-checked this session at hub_screen.dart:367, browser_screen.dart:581, keyboard_screen.dart:267, trackpad_screen.dart:152, qr_scan_screen.dart:117]`

**Both IME states, no conditional logic** (the claim ARCHITECTURE §4 Step 4 said to verify rather than trust):

| IME | `padding.bottom` at the shell | injected | Scaffold body bottom | after `SafeArea` | = |
|---|---|---|---|---|---|
| down | `Pbot` (e.g. 48) | `Pbot + 56` | window bottom | window bottom − 48 − 56 | the bar's top edge ✓ |
| up | `0` (engine-collapsed) | `0 + 56` | `IME top` (Scaffold shrank by `Ibot`) | `IME top − 56` | the bar's top edge ✓ |

### 6.3 `MediaQuery.removePadding(removeBottom: true)` around the overlay — mandatory

`KeyboardTabBar` wraps itself in `SafeArea(top: false)` `[VERIFIED: app/remote_control/lib/keyboard/key_pads.dart:349-353]`, and `_kTabBarHeight = 56` is documented as *"The bottom tab bar's height (excluding the bottom SafeArea inset)"* `[VERIFIED: key_pads.dart:112-113]`. In the docked panel that inner `SafeArea` contributes **0** because `trackpad_screen.dart:152`'s ancestor `SafeArea` already stripped the padding. **In the shell nothing has stripped it** — the overlay would silently grow by `Pbot` (24-48px of dead space) the moment Phase 15 mounts the tab bar.

Phase 13's overlay contains no inner `SafeArea`, so this cannot be caught by a rendering assertion in 13. **It must be caught by a probe assertion** (test P1 in §11): read `MediaQuery.paddingOf` from the *handle's* element and assert `bottom == 0` while the driven `viewPadding.bottom == 48`.

### 6.4 Worked values across five devices (dpr = 1, `kSummonBarHeight = 56`)

| # | Device / state | S | Ptop | Pbot | Ibot | `barBottomOffset` | **`available`** | keyboard ×0.75 | trackpad ×0.55 | surface `top` (kb) |
|---|---|---|---|---|---|---|---|---|---|---|
| **A** | 411×891, gesture nav 48, IME down — **reference** | 891 | 24 | 48 | 0 | 48 | **763** | **572.25** | **419.65** | 214.75 |
| **B** | 360×640, nav 24, IME down — **short** | 640 | 24 | 24 | 0 | 24 | **536** | **402** | **294.8** | 158 |
| **C** | 411×891, nav 24, IME up 290 — **discriminator** | 891 | 24 | 24 | 290 | 290 | **521** | **390.75** | **286.55** | 154.25 |
| **D** | 360×640, nav 24, IME up 290 — **discriminator, floor binds** | 640 | 24 | 24 | 290 | 290 | **270** | **220** (floor) | **220** (floor) | 74 |
| **E** | 360×640, nav 24, IME mid-fall 150 — **retarget discriminator** | 640 | 24 | 24 | 150 | 150 | **410** | **307.5** | **225.5** | 126.5 |

Sanity checks:
- Every `top` ≥ `Ptop` — the surface never reaches under the status bar. ✓
- **D:** the floor binds for both surfaces (`270 × 0.75 = 202.5 < 220`, `270 × 0.55 = 148.5 < 220`), and `min(available, …)` keeps 220 ≤ 270 so 50px of host screen remains. This is the documented single-fraction consequence of one shared derivation — say so in the code comment so nobody "fixes" it into two floors.
- **A vs the thing being retired:** `FloatingTrackpadWindow` was `0.38 × screen height` = 338 on device A, of which 48 header + 56 buttons = **234 of actual pad** `[CITED: .planning/research/ARCHITECTURE.md §4.4, sourced to floating_trackpad_window.dart:52, :232]`. The trackpad block here is **419.65** on the same device — comfortably better, which is D-13-09's "beats the retiring bubble window's 234px" criterion, met.

### 6.5 The discriminators — what the *wrong* formula yields

A viewport test is only a discriminator if the correct and the naive numbers differ **visibly**. Four distinct failure modes, each with the device that catches it:

| ID | Failure mode | Naive formula | Caught on | Correct | Naive | Visible symptom |
|---|---|---|---|---|---|---|
| **F1** | `paddingOf` instead of `viewPaddingOf` for the bar's offset AND the available height | `S − padding.top − padding.bottom − 56`; `barBottomOffset = padding.bottom` | **C** | `available 521`, kb **390.75**, bar 290 above the window bottom | `available 811`, kb **608.25**, bar **at the window bottom** | The bar is drawn **behind the raised IME** and is untappable — "dismiss costs one gesture" is false on the Type pad |
| **F1b** | same | same | **D** | `available 270`, kb **220** | `available 560`, kb **420** | The bottom 234px of the surface is behind the IME |
| **F2** | forgetting `kSummonBarHeight` in `available` | `S − Ptop − max(Pbot,Ibot)` | **A** | kb **572.25**, `surface.bottom == bar.top` | kb **614.25** | The surface's bottom edge overlaps the bar — BAR-02 violated. Caught by invariant **I1**, not by a number |
| **F3** | reading the **injected** MediaQuery (the +56 copy) for the arithmetic | `Pbot` reads `48 + 56` | **A** | `available 763` | `available 707`, kb **530.25** | 42px of dead space above the bar; nothing looks broken. **The nastiest one — IME down, reference device** |
| **F4** | `MediaQueryData.fromView(View.of(context))` (AP-1) | numerically identical *at a fixed metric* | **C → E transition** | height retargets 390.75 → **307.5** on the next frame | stays **390.75** forever | The overlay is the wrong height for the rest of the IME animation and does not correct |
| **F5** | omitting `MediaQuery.removePadding(removeBottom: true)` | — | **A**, probe test | `paddingOf(handleContext).bottom == 0` | `== 48` | Invisible in Phase 13; adds 48px of dead space the moment Phase 15 lands |

**A and B are the reference cases, not discriminators, for F1** (IME down ⇒ `padding == viewPadding`). They are still required: A catches F2 and F3, and B is where the short-viewport arithmetic is exercised.

**The house rule to carry into the tests, verbatim from the existing suite:** every asserted number is **computed from the driven metrics, never hard-coded** — the `floorFor()` / `columnOf()` idiom at `test/trackpad/trackpad_screen_test.dart:143-145, 166-176`, so an assertion cannot drift away from the guarantee it stands for. `[VERIFIED: app/remote_control/test/trackpad/trackpad_screen_test.dart:143-145, 166-176]`

---

## 7. The animation shape (closes D-13-10 and MOT-01)

### 7.1 Constants

```dart
const Duration kSummonRaiseDuration = Duration(milliseconds: 200);  // MOT-01; matches kBubbleExpandDuration
const Duration kSummonLowerDuration = Duration(milliseconds: 150);  // MOT-01
const Duration kSummonSwapDuration  = Duration(milliseconds: 200);  // D-13-10 — one motion, not 150+200
```

200ms is the incumbent, not a proposal: `kBubbleExpandDuration = Duration(milliseconds: 200)` `[VERIFIED: app/remote_control/lib/widgets/bubble_scaffold.dart:50]`. Reuse the *value*; declare a new named constant in the shell rather than importing the bubble's (which dies in Phase 16).

### 7.2 Two controllers, one surface

```dart
late final AnimationController _raise = AnimationController(
  vsync: this,
  duration: kSummonRaiseDuration,
  reverseDuration: kSummonLowerDuration,   // 150ms on the way down — one controller, two budgets
);
late final AnimationController _swap = AnimationController(
  vsync: this, duration: kSummonSwapDuration, value: 1,
);

double _fromH = 0, _toH = 0;
double get _height => lerpDouble(_fromH, _toH, Curves.easeOut.transform(_swap.value))!;
```

- **Raise:** `_toH = summonSurfaceHeight(s, available); _fromH = _toH; _swap.value = 1; _raise.forward();`
- **Lower:** `_raise.reverse();` — from the live value, no queue, no lockout (Claude's Discretion).
- **Swap (D-13-10):** `_fromH = _height; _toH = summonSurfaceHeight(other, available); _swap.forward(from: 0);` — `_raise` is **untouched** and stays at 1. One motion, exactly as decided; there is no lower-then-raise anywhere in the code path.

**The dismiss-edge obligation D-13-10 creates:** the swap path must call the *outgoing* surface's `dismissed()` hook. Phase 13 has no surfaces, so what Phase 13 owes Phases 14/15 is a **named seam** — a single `void _onSurfaceDismissed(SummonSurface outgoing)` called from **both** the lower path and the swap path, with a doc comment saying so. If Phase 13 ships two separate call sites, Phase 15 will wire `dismissed()` to one of them.

### 7.3 `reverse()` from a partial value — what actually happens

`AnimationController.reverse()` animates to `lowerBound` over `reverseDuration`, **scaled by the remaining distance**: from `value == 0.5` a 150ms reverse takes ~75ms. This is the framework default and is exactly the "reverses from the current animation value" behaviour the owner left to discretion. `[ASSUMED — standard `AnimationController` semantics; not re-read from the SDK this session. Cheap to pin: one test asserting a mid-flight reverse settles before a full 150ms.]`

### 7.4 Stack composition, and why the bar goes **last**

```dart
Material(
  color: kBg,
  child: Stack(children: [
    Positioned.fill(child: MediaQuery(data: bumped, child: child!)),   // 1. the Navigator
    Positioned(top: 0, left: 0, right: 0,                              // 2. the rehomed UipiBanner slot
        child: SafeArea(bottom: false, child: UipiBanner.forService(service))),
    // 3. (Phase 15) const Positioned(left:0, bottom:0, width:1, height:1, child: HiddenTextInput(...))
    Positioned(                                                        // 4. the raised surface
      left: 0, right: 0,
      bottom: barBottomOffset + kSummonBarHeight,
      height: _height,
      child: Transform.translate(
        offset: Offset(0, (1 - _curvedRaise) * _height),
        child: _surfaceChrome,                                         // built ONCE, cached
      ),
    ),
    Positioned(                                                        // 5. the bar — LAST
      left: 0, right: 0, bottom: barBottomOffset, height: kSummonBarHeight,
      child: const SummonBar(),
    ),
  ]),
)
```

**Why the ordering is load-bearing:**

- Later `Stack` children **paint on top**, so the bar occludes the surface while it slides up from behind it. That is the whole reason **no `ClipRect` and no `saveLayer` is needed** — the visual "emerges from behind the bar" effect is free. (P9: `saveLayer` is one of the two real jank causes here.)
- `Stack` hit-tests in **reverse paint order**, so the bar wins taps in its own rect throughout the animation — BAR-02's "stays tappable the whole time".
- The surface is a **sibling** of the Navigator, never an ancestor, so nothing beneath it is re-laid-out — SUM-02.
- The banner slot is built here in Phase 13 (it costs one `Positioned`); Phase 16 moves the only production mount into it (SAFE-03). `bubble_scaffold.dart:181` is the sole `UipiBanner.forService` call site in `lib/` `[CITED: .planning/research/ARCHITECTURE.md §6.2, verified this session at app/remote_control/lib/widgets/bubble_scaffold.dart:181]`.

**Reactive `canPop` without rebuilding the body** — reuse `bubble_scaffold.dart:157-165` verbatim in structure: an outer `ValueListenableBuilder<T>` whose cached `child` (the whole `Material`+`Stack`) is built exactly once and never rebuilt by the notifier. `[VERIFIED: app/remote_control/lib/widgets/bubble_scaffold.dart:152-166]`

### 7.5 The `barBottomOffset` / surface-bottom invariant

Assert this, on every device, rather than only asserting heights:

```
I1:  surfaceRect.bottom == barRect.top                    (±0.01)
I2:  barRect.bottom     == S - max(Pbot, Ibot)            (±0.01)
I3:  surfaceRect.top    >= Ptop
I4:  surfaceRect.height == summonSurfaceHeight(s, availableFromDrivenMetrics)   (computed, never quoted)
```

I1 and I2 together are what "the surface sits on top of the bar, never under it" (BAR-02) actually means as an executable statement.

### 7.6 Timing tests without `pumpAndSettle` (MOT-01)

`pumpAndSettle` advances until no frames are scheduled, so a 200ms summon and a 900ms summon are indistinguishable. **It is banned for every timing assertion in the new summon suites.** Model: `test/trackpad/trackpad_screen_test.dart:217-222` `[VERIFIED: app/remote_control/test/trackpad/trackpad_screen_test.dart:217-222]`.

**Summon — discriminates 200ms from an instant cut AND from anything > 250ms:**

```dart
final restTop = /* computed: S - barBottomOffset - kSummonBarHeight - h */;
final downTop = restTop + h;                       // fully lowered == translated down by h

await t.tap(find.byKey(kSummonKeyboardIconKey));
await t.pump();                                     // t = 0 — the controller starts
final t0 = t.getRect(find.byKey(kSummonSurfaceKey)).top;
expect(t0, closeTo(downTop, 1),
    reason: 'frame 0 must still be fully lowered — a cut would already be at rest');

await t.pump(const Duration(milliseconds: 100));    // t = 100
final t100 = t.getRect(find.byKey(kSummonSurfaceKey)).top;
expect(t100, lessThan(downTop - 1),
    reason: 'it must have MOVED by t=100 — otherwise this is a delayed cut');
expect(t100, greaterThan(restTop + 1),
    reason: 'it must NOT be at final geometry at t=100 — a 200ms summon is mid-flight here');

await t.pump(const Duration(milliseconds: 150));    // t = 250
expect(t.getRect(find.byKey(kSummonSurfaceKey)).top, closeTo(restTop, 0.5),
    reason: 'a 200ms summon is complete by t=250; a 300ms one is not');
```

**Dismiss — tightened to 150ms, and it fails against a 200ms dismiss:**

```dart
await t.tap(find.byKey(kSummonKeyboardIconKey));    // toggle down
await t.pump();                                     // t = 0
await t.pump(const Duration(milliseconds: 75));     // t = 75 — mid-flight
final mid = t.getRect(find.byKey(kSummonSurfaceKey)).top;
expect(mid, greaterThan(restTop + 1));
expect(mid, lessThan(downTop - 1));

await t.pump(const Duration(milliseconds: 85));     // t = 160  ← the discriminator
expect(t.getRect(find.byKey(kSummonSurfaceKey)).top, closeTo(downTop, 0.5),
    reason: '150ms dismiss is complete by t=160; a 200ms dismiss is NOT — '
            'this assertion is what pins the 150, not the constant');
```

**Swap (D-13-10) — proves it is one motion, not lower-then-raise:**

```dart
// keyboard raised at rest, then tap the trackpad icon
await t.tap(find.byKey(kSummonTrackpadIconKey));
await t.pump();
for (var ms = 0; ms <= 200; ms += 25) {
  await t.pump(const Duration(milliseconds: 25));
  final r = t.getRect(find.byKey(kSummonSurfaceKey));
  expect(r.bottom, closeTo(barTop, 0.5),
      reason: 'the surface never leaves the bar during a swap — a '
              'lower-then-raise would detach at some frame');
  expect(r.height, greaterThanOrEqualTo(math.min(kbH, tpH) - 0.5));
}
```

`tester.getRect` resolves through `RenderBox.localToGlobal`, so an ancestor `Transform` is applied — the translated position is what the assertions see. Use `Key`s on the surface and each bar icon; do not locate by `Symbols.*` alone, because the tab bar carries the same keyboard glyph once Phase 15 lands (`trackpad_screen_test.dart:215-217` already documents that collision).

---

## 8. BAR-03 — the keyboard-icon focus gate, corrected

**The milestone-research predicate is wrong (X1).** `FocusManager.instance.primaryFocus` reverts to `rootScope` whenever nothing else has focus:

```dart
// C:/dev/flutter/packages/flutter/lib/src/widgets/focus_manager.dart:1965-1969 (verbatim)
if (_primaryFocus == null && _markedForFocus == null) {
  // If we don't have any current focus, and nobody has asked to focus yet,
  // then revert to the root scope.
  _markedForFocus = rootScope;
}
```

and `WidgetsApp` autofocuses a `FocusScope` around the Navigator `[VERIFIED: widgets/app.dart:1692-1694]`. So `primaryFocus == null` is essentially never true in this app, and gating on it disables the keyboard icon permanently.

**The correct predicate — "a *local text field* holds focus":**

```dart
/// True when the focused node belongs to an EditableText that is NOT the
/// shell's own hidden IME field. This is BAR-03's actual condition: a PIN
/// typed on the phone must never reach the PC.
bool _localFieldHasFocus(FocusNode? shellImeNode) {
  final node = FocusManager.instance.primaryFocus;
  if (node == null) return false;
  if (identical(node, shellImeNode)) return false;   // our own hidden field is not "local"
  final ctx = node.context;
  if (ctx == null) return false;                     // rootScope has no context
  return ctx.findAncestorWidgetOfExactType<EditableText>() != null;
}
```

Why the ancestor lookup works: `EditableText`'s build wraps the caller-supplied node in `Focus(focusNode: widget.focusNode, …)`, and that `Focus` is a descendant of `EditableText` itself `[VERIFIED: C:/dev/flutter/packages/flutter/lib/src/widgets/editable_text.dart:5750, 5804-5805]`. `TextField` and `TextFormField` both delegate to `EditableText`, so this covers `device_list_screen.dart:491, :509` and `pairing_dialog.dart:242` without naming them — which is the property C5 chose the focus gate for in the first place.

**Rebuild source and scope.** `FocusManager` is a `ChangeNotifier` `[VERIFIED: widgets/focus_manager.dart:1636]` and calls `notifyListeners()` precisely when the primary focus changed `[VERIFIED: widgets/focus_manager.dart:1999-2001]`. Wrap **only the keyboard icon**:

```dart
ListenableBuilder(
  listenable: FocusManager.instance,
  builder: (context, _) => SummonIconButton(
    icon: Symbols.keyboard_rounded,
    enabled: !_localFieldHasFocus(_imeFocusNode),
    ...
  ),
)
```

P9's rule is satisfied: the rebuild scope is one `IconButton`, not the bar, not the shell, not the Navigator.

**The trap Phase 15 will hit if this is not written down now:** once the shell mounts `HiddenTextInput` and a raised keyboard focuses it, `primaryFocus` **is** inside an `EditableText`. Without the `identical(node, shellImeNode)` escape, the keyboard icon disables itself the instant the keyboard is raised — and tap-to-dismiss (SUM-03) becomes impossible. Ship the escape in Phase 13 even though the hidden field arrives later, and pin it with a test that focuses a `FocusNode` the shell owns.

**Disabled ≠ hidden.** D-13-12 requires the bar's geometry to be identical on every screen. The disabled keyboard icon must still occupy its slot — `kMuted`, `onPressed: null`. Assert `find.byIcon(Symbols.keyboard_rounded)` is still `findsOneWidget` and that the bar's `Rect` is unchanged.

---

## 9. BAR-04 — suppressing the bar on the QR screen

The shell is above the Navigator and cannot read route identity. Mechanism, in the same "less state" spirit as D-13-03:

```dart
/// Wraps a route whose screen must not show the summon bar (BAR-04).
/// Depth-counted, NOT a bool: on push the incoming route's initState runs
/// while the outgoing route is still mounted, and on pop dispose runs after
/// the transition — a bool flickers at both boundaries.
class SummonBarSuppressor extends StatefulWidget { final Widget child; ... }
// initState: shell.suppressBar();   dispose: shell.releaseBar();
// shell: int _suppressDepth = 0;  bool get barVisible => _suppressDepth == 0;
```

Applied at exactly one site: `pairing_dialog.dart:360` (`MaterialPageRoute(builder: (_) => const QrScanScreen())`) `[VERIFIED: app/remote_control/lib/screens/pairing_dialog.dart:360]`. It is the only push of `QrScanScreen` in `lib/`.

**Alternative rejected:** a `NavigatorObserver` allowlist — it needs route identity that does not exist (all pushes use default `RouteSettings`) and adds a second source of truth for "what is current".

**Consequence to record, not to fix:** the bar renders **over** modal routes (the pairing sheet, the sensitivity sheet, the power confirm dialog). That is an accepted consequence of the app-scope host — SC4 explicitly requires the bar to be present on the pairing sheet with the keyboard icon disabled, so suppression there would contradict the success criterion. Add "the power confirm dialog with the bar over it" to the phase's UAT eyeball list.

---

## 10. Predictive back — what the baseline actually is, and what is executable (closes D-13-01)

### 10.1 The two independent layers

| Layer | Governed by | State in this app today |
|---|---|---|
| **System predictive back** (back-to-home / cross-activity peek) | Android's `enableOnBackInvokedCallback`, **and** Flutter's `SystemNavigator.setFrameworkHandlesBack(false)` | **ON.** `targetSdk` resolves to **36** `[VERIFIED: android/app/build.gradle.kts:35 → C:/dev/flutter/packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:34 `val targetSdkVersion: Int = 36`]`, the manifest never sets the flag to `false` `[VERIFIED: android/app/src/main/AndroidManifest.xml — no enableOnBackInvokedCallback attribute]`, and Android's docs state *"Predictive back is enabled by default"* with opt-out via `android:enableOnBackInvokedCallback="false"` `[CITED: developer.android.com/guide/navigation/predictive-back-gesture]` |
| **In-app route predictive peek** (peek at the previous route) | `pageTransitionsTheme` containing `PredictiveBackPageTransitionsBuilder` | **OFF, and always has been.** `buildAppTheme()` sets only `brightness`, `scaffoldBackgroundColor`, `colorScheme`, `iconTheme` `[VERIFIED: app/remote_control/lib/theme/tokens.dart:44-67]` — no `pageTransitionsTheme` anywhere in `lib/` |

**Therefore SC3's "predictive back still animates" can only be measuring layer 1: back-to-home from the hub with nothing raised.** Layer 2 has never existed and cannot regress. The spike must record exactly this, with the evidence, and the "in-app peek is absent" finding goes to `## Deferred Ideas` per CONTEXT.md, not into this phase's scope.

### 10.2 The mechanism that connects the guard to layer 1

```dart
// widgets/navigator.dart:3743-3753 (verbatim, elided)
void _handleHistoryChanged() {
  final bool navigatorCanPop = canPop();
  final bool routeBlocksPop;
  if (!navigatorCanPop) {
    final _RouteEntry? lastEntry = _lastRouteEntryWhereOrNull(_RouteEntry.isPresentPredicate);
    routeBlocksPop = lastEntry != null && lastEntry.route.popDisposition == RoutePopDisposition.doNotPop;
  } else { routeBlocksPop = false; }
  final notification = NavigationNotification(canHandlePop: navigatorCanPop || routeBlocksPop);
  ...
}

// widgets/app.dart:1442-1455 (verbatim, elided)
bool _defaultOnNavigationNotification(NavigationNotification notification) {
  switch (_appLifecycleState) {
    case null: case AppLifecycleState.detached:  return true;   // ← does NOT call through
    case AppLifecycleState.inactive: case AppLifecycleState.resumed:
    case AppLifecycleState.hidden:   case AppLifecycleState.paused:
      SystemNavigator.setFrameworkHandlesBack(notification.canHandlePop);
      return true;
  }
}
```

And the framework's own statement of what this means: *"Android API 33+ introduced a feature called predictive back… Flutter enables or disables this feature ahead of time, before a back gesture occurs, and back gestures that trigger predictive back are handled entirely by the system… By default, the framework communicates when it would like to handle system back gestures using `SystemNavigator.setFrameworkHandlesBack` in `WidgetsApp`. This is done automatically based on the status of the `Navigator` stack and the state of any `PopScope` widgets present."* `[VERIFIED: C:/dev/flutter/packages/flutter/lib/src/widgets/binding.dart:1091-1110]`

**The baseline, stated as a truth table:**

| Situation | `navigatorCanPop` | `routeBlocksPop` | `setFrameworkHandlesBack` | System peek |
|---|---|---|---|---|
| Hub, nothing raised (**today, and must not change**) | false | false | **false** | back-to-home peek plays |
| Hub, surface raised & owned | false | **true** (guard `canPop:false`) | **true** | peek suppressed — correct: back must dismiss, not exit |
| Any pushed route, nothing raised | true | — | **true** | peek suppressed (unchanged from today) |
| Any pushed route, surface raised & owned | true | — | **true** | unchanged |

Only row 2 is new, and it is the intended behaviour. **The regression to guard against is row 1 flipping to `true`** — which is exactly what a static `PopScope(canPop: false)` would do.

### 10.3 The executable check (widget test), and the part only hardware can show

**Executable in a widget test:**

```dart
setUp(() {
  debugDefaultTargetPlatformOverride = TargetPlatform.android;   // else setFrameworkHandlesBack no-ops
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(SystemChannels.platform, (call) async {
    if (call.method == 'SystemNavigator.setFrameworkHandlesBack') {
      handled.add(call.arguments as bool);
    }
    return null;
  });
});
tearDown(() { debugDefaultTargetPlatformOverride = null; /* + clear the handler */ });

testWidgets('BASELINE: on the hub with nothing raised the framework does NOT '
    'claim back — the system back-to-home peek is preserved', (t) async {
  await t.pumpWidget(appUnderTest());
  t.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);  // REQUIRED
  await t.pump();
  expect(handled.last, isFalse);
});

testWidgets('with a surface raised on the hub the framework DOES claim back', (t) async {
  ... raise ...
  expect(handled.last, isTrue);
});

testWidgets('lowering restores the baseline', (t) async {
  ... raise, then lower ...
  expect(handled.last, isFalse, reason: 'a static canPop:false would leave this true forever');
});
```

`handleAppLifecycleStateChanged(AppLifecycleState.resumed)` is **not optional**: without it `_appLifecycleState` is `null` and `_defaultOnNavigationNotification` returns before touching the channel `[VERIFIED: widgets/app.dart:1442-1447]`. The channel-mocking shape is the house idiom at `test/haptics_gate_test.dart:19-30` `[VERIFIED: app/remote_control/test/haptics_gate_test.dart:19-30]`.

**Only hardware can show:** whether the OS actually renders the back-to-home peek, its duration, and whether the raised surface renders correctly *during* the peek (the app window is scaled by the system compositor). Record these as a one-paragraph UAT note with a video or a described observation — CONTEXT.md D-13-01's "recorded baseline". **Do not** attempt to assert them in a test.

---

## 11. The D5 spike — exact shape (closes gap 1)

Three assertions, one file, no production code beyond `SummonBackGuard` itself. If **S2** fails, stop and raise a checkpoint (D-13-04) — do not choose a fallback host.

```dart
// test/shell/summon_back_guard_spike_test.dart
//
// D5 SPIKE (13-01). Three assertions settle the host shape:
//   S1  the MaterialApp.builder child is an ANCESTOR of the Navigator
//   S2  a per-route SummonBackGuard DOES intercept a system back from a route
//       below a MaterialApp.builder shell
//   S3  a PopScope placed in the builder itself is a SILENT no-op (the reason
//       S2's guard has to be per-route at all)
//
// If S2 fails, the host shape changes -> checkpoint, per CONTEXT.md D-13-04.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('S1: MaterialApp.builder sits ABOVE the Navigator', (t) async {
    final shellKey = GlobalKey();
    await t.pumpWidget(MaterialApp(
      builder: (context, child) => KeyedSubtree(key: shellKey, child: child!),
      home: const Scaffold(body: Text('root')),
    ));

    // The Navigator must be a DESCENDANT of the builder's subtree.
    expect(
      find.descendant(of: find.byKey(shellKey), matching: find.byType(Navigator)),
      findsOneWidget,
      reason: 'MaterialApp.builder is handed `routing` (FocusScope > Navigator) '
              'as its child — widgets/app.dart:1690-1731',
    );
    // And the builder's context must NOT be inside a ModalRoute.
    expect(ModalRoute.of(shellKey.currentContext!), isNull,
        reason: 'there is no route above the Navigator — pop_scope.dart:196');
  });

  testWidgets('S2: a per-route guard intercepts back from a route BELOW the '
      'builder shell', (t) async {
    final nav = GlobalKey<NavigatorState>();
    final raised = ValueNotifier<bool>(false);
    var dismissals = 0;

    Widget guard(Widget child) => ValueListenableBuilder<bool>(
          valueListenable: raised,
          builder: (_, isRaised, cached) => PopScope(
            canPop: !isRaised,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) return;
              dismissals++;
              raised.value = false;
            },
            child: cached!,
          ),
          child: child,   // built ONCE — never rebuilt by the notifier
        );

    await t.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: (context, child) => Stack(children: [
        Positioned.fill(child: child!),
        const Positioned(bottom: 0, left: 0, right: 0, height: 56,
            child: ColoredBox(color: Color(0xFF000001), child: SizedBox())),
      ]),
      home: guard(const Scaffold(body: Text('root'))),
    ));

    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => guard(const Scaffold(body: Text('tool'))),
    )));
    await t.pumpAndSettle();                       // navigation only — NOT a timing assertion
    expect(find.text('tool'), findsOneWidget);

    raised.value = true;
    await t.pump();

    await t.binding.handlePopRoute();              // the system back
    await t.pumpAndSettle();

    expect(dismissals, 1, reason: 'the guard intercepted');
    expect(find.text('tool'), findsOneWidget,
        reason: 'the first back must NOT pop the route (SUM-04)');

    await t.binding.handlePopRoute();              // a second back pops
    await t.pumpAndSettle();
    expect(find.text('root'), findsOneWidget);
  });

  testWidgets('S3: a PopScope in the builder itself is a SILENT no-op', (t) async {
    var invoked = 0;
    final nav = GlobalKey<NavigatorState>();
    await t.pumpWidget(MaterialApp(
      navigatorKey: nav,
      builder: (context, child) => PopScope(
        canPop: false,
        onPopInvokedWithResult: (_, __) => invoked++,
        child: child!,
      ),
      home: const Scaffold(body: Text('root')),
    ));
    unawaited(nav.currentState!.push(MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('tool')))));
    await t.pumpAndSettle();

    await t.binding.handlePopRoute();
    await t.pumpAndSettle();

    expect(invoked, 0, reason: 'no ModalRoute above the Navigator to register with');
    expect(find.text('root'), findsOneWidget,
        reason: 'the route popped despite canPop:false — the shell-level '
                'PopScope never registered (pop_scope.dart:196-201)');
  });
}
```

Notes for the planner:

- `t.binding.handlePopRoute()` is the in-tree way this app already simulates a system back — `bubble_scaffold_test.dart:220-222` uses exactly it `[VERIFIED: app/remote_control/test/bubble_scaffold_test.dart:220-222]`.
- `pumpAndSettle` is fine **here**: these are navigation assertions, not timing assertions. The ban is scoped to timing (MOT-01).
- S3 is what makes the spike *diagnostic* rather than merely confirmatory: if someone later "simplifies" the guard up into the shell, S3 goes red with a message that names the reason.

---

## 12. Test-Migration Checklist (written in Phase 13, executed in Phase 16)

**The rule:** copy each deleted suite's header contract block into its successor and tick every line. **Do not delete a file until its successor exists.** (P11.)

Counts are tree-verified this session; they correct SUMMARY's "882 / ~42" (see X4).

**Suite totals at `master @ e2741fa`:** 823 `test(`/`testWidgets(` declarations in `app/remote_control/test`, 15 in `app/packages/remote_protocol/test` = **838**.

| Suite | Decls | Fate | Successor | Contracts that MUST survive |
|---|---|---|---|---|
| `test/bubble_scaffold_test.dart` | **5** | **Rewrite → `test/shell/summon_shell_test.dart`** | Phase 13 creates the successor; Phase 16 deletes the original | Header contracts at `:1-23`. C1 (bubble presence) and C2 (`showBubble:false`) **die**. C3 (expand toggle, `:134-154`) **mutates** → "tapping a bar icon raises; tapping it again lowers; never two surfaces". **C4 (`:13-16`, `:156-186`) — a tappable widget in the body OUTSIDE the raised surface still receives a tap — survives verbatim in spirit. This is the single most valuable test in the milestone: it is what proves "overlay, not screen" (SUM-02).** C5 (back-intercept, `:17-18`, `:188-236`) **mutates** → the `SummonBackGuard` test (SUM-04) |
| `test/trackpad_bubble_test.dart` | **6** (3 groups) | **Delete** (Phase 16) | none | none — bubble-specific |
| `test/floating_trackpad_window_test.dart` | **6** (5 groups) | **Delete** (Phase 16) | none | **Harvest** the `_RecordingService` + `KeepAwake` spy idiom (`:22-24`) into the new shell tests before deleting |
| `test/window_position_test.dart` | **12** (3 groups) | **Delete** (Phase 16) | none | none |
| `test/bubble_position_test.dart` | **13** (3 groups) | **Delete** (Phase 16) | none | none — and grep `kBubbleSize` / `kBubbleEdgeInset` / `_bubbleAnchor`; the analyzer will not flag an unused public const |
| `test/widget_test.dart` | **2** | **Mutate — in Phase 13**, not 16 | itself | It is the only test that pumps `RemoteControlApp` (`main.dart`), so it is the only existing test that will see the shell. Add: the bar renders on the hub (BAR-01) |
| `test/hub_offline_test.dart` | **2** | **Re-run** in Phase 13 | itself | Asserts `onTap: null` + gear reachability. The +56 bottom padding must not break its finds |
| `test/hub_tiles_test.dart` | **4** | Phase 17 | itself | Out of Phase 13's scope; listed so the checklist is complete |
| `test/hub/hub_screen_test.dart` | **2** | Phase 17 | itself | `:22-35` pins "D-02: the trackpad is the full-width primary tile — always first in the registry". **The rationale is already stale** (the primary row died in 07-13). Phase 17 must update it with a *new* rationale, **never** re-pin Trackpad to index 0 — that silently reverts RET-02 |
| `test/theme_tokens_guard_test.dart` | 1 | **Re-run every wave** | itself | Will fail the build on any raw palette hex in new shell code |
| `test/icons_guard_test.dart` | 1 | **Re-run every wave** | itself | Will fail the build on any `Icons.` in new shell code |
| `test/trackpad/trackpad_screen_test.dart` | 5 | **Unchanged in 13** | itself | The docked-panel inset guards at `:225-307` are the regression net proving the summon arithmetic did **not** disturb `panelPadHeight`. Re-run; do not touch |
| `test/keyboard/keyboard_panel_test.dart` | 20 | **Unchanged in 13** | itself | Re-run as the behaviour-neutrality net |

**Net for Phase 16:** **37** declarations vanish (4 whole suites: 6+6+12+13), **5** are rewritten (`bubble_scaffold_test.dart`), **2** re-run (`widget_test.dart`, `hub_offline_test.dart`). Not 42/882.

**Checklist artifact:** write this table to `.planning/phases/13-summon-shell-bar/TEST-MIGRATION.md` (or as a section of the phase's VERIFICATION) **before any Phase 13 code lands**, so Phase 16 executes a document that predates the first deletion.

---

## Don't Hand-Roll

| Problem | Don't build | Use instead | Why |
|---|---|---|---|
| Back-gesture interception | A `WidgetsBindingObserver.didPopRoute` override at the shell | `PopScope` in a per-route `SummonBackGuard` | `handlePopRoute` returns on the first observer that handles it and `WidgetsApp`'s is registered first `[VERIFIED: widgets/binding.dart:1113-1131]` |
| "Is a text field focused?" | A per-screen `hasTextField` flag, or a screen allowlist | `FocusManager.instance` + the `EditableText`-ancestor predicate (§8) | Stays correct for any future screen that gains a field — the reason C5 chose focus gating |
| "Which route is current?" | A `NavigatorObserver` + route bookkeeping | The guard-id stack (§4) | The observer duplicates state the guards already hold and retains `Route` objects |
| Reserving 56px on 14 screens | 14 per-screen edits | One `MediaQuery` padding injection around the Navigator | Every screen already `SafeArea`-wraps; verified against `Scaffold._addIfNonNull` `[VERIFIED: material/scaffold.dart:2915-2936, 3028-3034]` |
| Overlay that survives dismiss | `OverlayPortal`, `showModalBottomSheet`, `DraggableScrollableSheet`, raw `OverlayEntry`, any sheet package | `Stack` + `Positioned` | All are route/portal-based and destroy child `State` on dismiss `[CITED: .planning/research/STACK.md; SUMMARY §Recommended Stack]` |
| Animating the surface in | `AnimatedPositioned` / `AnimatedOpacity` / a `ClipRect` | `Transform.translate` + bar painted last | Relayout-per-frame / `saveLayer` are P9's two real jank causes; paint order gives the reveal for free |
| Detecting IME metric changes at the shell | A `WidgetsBindingObserver.didChangeMetrics` | `MediaQuery.viewInsetsOf(context)` | At the shell the data is not value-equal across the IME animation, so rebuilds are automatic; the observer doubles them |
| A "which callback ran first" latch across two `PopScope`s | A boolean consumed-flag | Mutually-exclusive predicates on one shared state | `_popEntries` is a `Set`; order is not a contract `[VERIFIED: widgets/routes.dart:1980]` |

**Key insight:** every hand-rolled option in this phase fails for the same structural reason — it tries to recover, at the shell, information that only the *route* has (identity, pop context, focus context). The correct shape is always "the route declares itself upward to the shell", which is why the guard, the suppressor and (in Phase 17) `activeSurfaceProvider` are all the same pattern.

---

## Common Pitfalls

### Pitfall A — The bar's arithmetic reads the injected MediaQuery
**What goes wrong:** the shell builds the bumped `MediaQueryData` for the Navigator, then reads `MediaQuery.viewPaddingOf(context)` from a context *inside* that wrap (e.g. by building the whole `Stack` under the injection).
**Why it happens:** the injection and the arithmetic are in the same `build()`; nothing warns.
**Symptom:** `available` is 56 short, the surface is 42px too short on the reference device, IME **down**. Nothing looks broken.
**How to avoid:** compute `S/Ptop/Pbot/Ibot/available/barBottomOffset` into locals **before** constructing the `MediaQuery` wrap, and pass them down. Add the F3 discriminator (device A) with a computed expectation.

### Pitfall B — `canPop: !raised` instead of `canPop: !(raised && owned)`
**Symptom:** back on Media (pushed after the surface was raised on the hub) dismisses the surface instead of popping Media — D-13-02 inverted, and the user cannot leave the screen without dismissing first.
**How to avoid:** the ownership predicate is the *only* allowed `canPop` expression; pin it with the D-13-02 scenario test (raise on hub → push tool → back pops tool with the surface still up → back lowers → back exits).

### Pitfall C — Both `PopScope`s act on one gesture
**Symptom:** on Browser, inside a bookmark folder, with a surface raised: one back both lowers the surface **and** exits the folder. Two things per gesture — D-13-05 violated.
**How to avoid:** make `_onBookmarksBack` conditional on the shared predicate (§3). Test: bookmarks in a subfolder + surface raised → one back lowers the surface only, folder depth unchanged; a second back exits the folder; a third pops the route.

### Pitfall D — `pumpAndSettle` in a timing test
**Symptom:** MOT-01 passes at 200ms and would pass at 900ms. The suite already uses `pumpAndSettle` 95 times, 45 of them in `keyboard_panel_test.dart` `[CITED: .planning/research/SUMMARY.md §The Animation Budget]`, so the habit is strong.
**How to avoid:** the §7.6 sequences. Add a plan-text line: *"any `pumpAndSettle` in `test/shell/` that precedes a geometry assertion is a review-blocking defect."*

### Pitfall E — The keyboard icon disables itself when the keyboard is raised
**Symptom (Phase 15, caused by Phase 13):** raising the keyboard focuses `HiddenTextInput`; the focus gate sees an `EditableText`; the icon greys out; tap-to-dismiss is impossible and the only way out is back.
**How to avoid:** the `identical(node, shellImeNode)` escape in §8, shipped in 13 with a test.

### Pitfall F — Reusing the docked panel's constants
**Symptom:** `0.55` reserves room for a trackpad that does not exist beneath the overlay; `122`'s `+1` is a sliver that costs zero here.
**How to avoid:** the new constants must be **named as design choices** (D-13-09) and must not import from `key_pads.dart`. Add a source-scanning guard, or at minimum a doc comment on each new const saying "declared design choice, not derived — see 13-RESEARCH §6".

### Pitfall G — Missing `SummonBackGuard` on the non-tile routes
**Symptom:** SUM-04 works on the 9 tool screens and the hub, and silently does not work on Settings, Device List, Updates and QR.
**Why it happens:** `BubbleScaffold`'s central seam covers only `hub_screen.dart:286`; the other 5 pushes are separate.
**How to avoid:** the `pushGuarded()` helper + the 8-site table in §4; add a source-scanning test that every `MaterialPageRoute` in `lib/` is constructed through the helper (a grep guard in the house style of `icons_guard_test.dart`).

### Pitfall H — The `Set` iteration-order assumption creeps back
**Symptom:** a future refactor introduces a third `PopScope` and the "surface first" ordering silently changes.
**How to avoid:** a comment at both call sites naming `widgets/routes.dart:1980` and the predicate rule; plus the Pitfall C test, which fails if either becomes order-dependent.

---

## Code Examples

### The shell insertion (`main.dart:112-118`)

```dart
// main.dart — the ONLY production edit needed to reach every screen.
// Verified: MaterialApp.builder's result is handed the Navigator as `child`
// (widgets/app.dart:1690-1731), so SummonShell is the Navigator's ancestor and
// reads the raw, un-stripped View MediaQuery (material/app.dart:267).
return MaterialApp(
  title: 'Remote Control',
  debugShowCheckedModeBanner: false,
  theme: buildAppTheme(),
  builder: (context, child) => SummonShell(child: child!),   // NEW
  home: const SummonBackGuard(child: HubScreen()),           // NEW wrap — the root route
);
```

### The guard (`lib/shell/summon_back_guard.dart`)

```dart
/// The per-route half of the summon host. `PopScope` registers with the
/// ENCLOSING ModalRoute (widgets/pop_scope.dart:194-202) — above the Navigator
/// there is no route, so this cannot live in the shell.
///
/// D-13-02: only the route that RAISED the surface intercepts back. The id is
/// an int, never a Route reference: when the owning route pops, no live guard
/// matches the owner id and the surface is simply orphaned (D-13-03) with
/// nothing retained and no transfer machinery.
class SummonBackGuard extends StatefulWidget {
  final Widget child;
  const SummonBackGuard({super.key, required this.child});
  @override State<SummonBackGuard> createState() => _SummonBackGuardState();
}

class _SummonBackGuardState extends State<SummonBackGuard> {
  late final int _id;
  late final SummonShellState _shell;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _shell = SummonScope.of(context);      // non-subscribing lookup
  }

  @override
  void initState() { super.initState(); /* id minted + pushed on first build */ }

  @override
  void dispose() { _shell.unregisterGuard(_id); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    // The outer ValueListenableBuilder exists ONLY so canPop stays reactive;
    // its `child` is built exactly once and never rebuilt by the notifier —
    // the bubble_scaffold.dart:152-166 shape, verbatim.
    return ValueListenableBuilder<SummonRaise?>(
      valueListenable: _shell.raised,
      builder: (context, raise, cached) => PopScope(
        canPop: !(raise != null && raise.ownerGuardId == _id),
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;                       // routes.dart:5620 fires on real pops too
          if (raise != null && raise.ownerGuardId == _id) _shell.lower();
        },
        child: cached!,
      ),
      child: widget.child,
    );
  }
}
```

### The browser's existing `PopScope`, made predicate-conditional (`browser_screen.dart:576-580`)

```dart
body: PopScope(
  canPop: !inFolder,
  onPopInvokedWithResult: (didPop, result) {
    if (didPop) return;
    // D-13-05: strict one-thing-per-gesture. BOTH PopScope callbacks on a route
    // fire when either canPop is false (widgets/routes.dart:2044-2050), and the
    // _popEntries Set gives NO ordering guarantee (routes.dart:1980) — so this
    // must be a predicate, never an ordering assumption or a "consumed" latch.
    if (SummonScope.ownsRaisedSurface(context)) return;   // the surface took this back
    _onBookmarksBack();
  },
  child: SafeArea( ... ),
),
```

### A driven-viewport discriminator (mirrors `trackpad_screen_test.dart:151-176`)

```dart
/// Drives the raw view metrics. dpr 1 keeps FakeViewPadding 1:1 with logical
/// px. With an IME inset, `padding.bottom` is 0 while `viewPadding` keeps the
/// nav-bar value — that is how the platform reports it, and the difference is
/// the whole point (F1).
void driveView(WidgetTester t,
    {required Size size, required double top, required double bottom, double ime = 0}) {
  t.view.devicePixelRatio = 1.0;
  t.view.physicalSize = size;
  t.view.viewPadding = FakeViewPadding(top: top, bottom: bottom);
  t.view.padding     = FakeViewPadding(top: top, bottom: ime > 0 ? 0 : bottom);
  t.view.viewInsets  = FakeViewPadding(bottom: ime);
  addTearDown(t.view.reset);
}

/// COMPUTED, never quoted — the assertion cannot drift from the guarantee.
double availableOf({required Size size, required double top,
        required double bottom, double ime = 0}) =>
    size.height - top - math.max(bottom, ime) - kSummonBarHeight;

testWidgets('C DISCRIMINATOR: 411x891, IME up 290 — the keyboard surface is '
    '390.75 and the bar clears the IME (a paddingOf read yields 608.25 and a '
    'bar drawn BEHIND the keyboard)', (t) async {
  const size = Size(411, 891);
  driveView(t, size: size, top: 24, bottom: 24, ime: 290);
  final available = availableOf(size: size, top: 24, bottom: 24, ime: 290);  // 521

  await pumpShell(t);
  await raise(t, SummonSurface.keyboard);

  final surface = t.getRect(find.byKey(kSummonSurfaceKey));
  final bar     = t.getRect(find.byKey(kSummonBarKey));

  expect(surface.height, closeTo(available * kSummonKeyboardFraction, 0.01));  // 390.75
  expect(surface.bottom, closeTo(bar.top, 0.01));                              // I1
  expect(bar.bottom, closeTo(size.height - 290, 0.01));                        // I2 — above the IME
  expect(surface.top, greaterThanOrEqualTo(24.0));                             // I3

  await t.pumpWidget(const SizedBox());
});

testWidgets('E DISCRIMINATOR: the height RETARGETS mid-IME-animation with no '
    'didChangeMetrics observer (a MediaQueryData.fromView read stays stale)', (t) async {
  const size = Size(360, 640);
  driveView(t, size: size, top: 24, bottom: 24, ime: 290);
  await pumpShell(t);
  await raise(t, SummonSurface.keyboard);
  expect(t.getRect(find.byKey(kSummonSurfaceKey)).height,
      closeTo(kSummonMinSurfaceHeight, 0.01));            // available 270 -> floor 220

  t.view.viewInsets = const FakeViewPadding(bottom: 150); // the IME falls
  await t.pump();

  final available = availableOf(size: size, top: 24, bottom: 24, ime: 150);   // 410
  expect(t.getRect(find.byKey(kSummonSurfaceKey)).height,
      closeTo(available * kSummonKeyboardFraction, 0.01),                     // 307.5
      reason: 'the ancestor MediaQuery is NOT value-equal across the IME '
              'animation, so the rebuild is automatic — AP-1');
  await t.pumpWidget(const SizedBox());
});

testWidgets('F5 PROBE: the overlay subtree has its bottom padding stripped '
    '(MediaQuery.removePadding is mandatory — key_pads.dart:349-353)', (t) async {
  driveView(t, size: const Size(411, 891), top: 24, bottom: 48);
  await pumpShell(t);
  await raise(t, SummonSurface.keyboard);

  final handleCtx = t.element(find.byType(SummonHandle));
  expect(MediaQuery.paddingOf(handleCtx).bottom, 0,
      reason: 'without removeBottom, KeyboardTabBar\'s own SafeArea would add '
              '48px of dead space the moment Phase 15 lands');
  expect(MediaQuery.viewPaddingOf(handleCtx).bottom, 48,
      reason: 'viewPadding must survive — only padding is stripped');
  await t.pumpWidget(const SizedBox());
});
```

---

## Runtime State Inventory

Phase 13 is **additive**, not a rename or migration. Recorded so a later reader does not re-open it.

| Category | Items Found | Action Required |
|---|---|---|
| Stored data | **None.** Phase 13 adds no prefs key and reads none. `keyboard.summonPad` / `kSummonPadPrefsKey` belongs to Phase 15 (ARCHITECTURE §3.4); `bubble.position` / `window.position` retire in Phase 16 | none |
| Live service config | **None** — client-only phase, no server, protocol or extension change (REQUIREMENTS `## Out of Scope`) | none |
| OS-registered state | **None** — no manifest edit (D-13-01 forbids it), no new permission, no Android component | none |
| Secrets / env vars | **None** — the phase touches no credential path. BAR-03 *protects* a secret (the pairing PIN) but stores nothing | none |
| Build artifacts | **None** — no `pubspec.yaml` change, so no lockfile churn and no plugin registration change | none |

---

## Validation Architecture

### Test Framework

| Property | Value |
|---|---|
| Framework | `flutter_test` from the pinned SDK — Flutter **3.44.5** / Dart **3.12.2** `[VERIFIED: C:/dev/flutter/bin/cache/flutter.version.json; app/remote_control/pubspec.yaml:27, 83-84]` |
| Config file | none — no `dart_test.yaml`, no `flutter_test_config.dart`; `test/` layout is the convention |
| Quick run command | `flutter test test/shell` (from `app/remote_control`) |
| Full suite command | `flutter test` (from `app/remote_control`) — 823 declarations |
| Second package | `cd app/packages/remote_protocol && flutter test` — 15 declarations, **untouched by this phase** |

### Phase Requirements → Test Map

| Req | Behavior | Type | Automated command | File exists? |
|---|---|---|---|---|
| **BAR-01** | Bar renders on the hub and on a pushed tool screen, geometrically identical | widget | `flutter test test/shell/summon_shell_test.dart -j1` | ❌ Wave 0 |
| **BAR-01** | Bar renders when the whole app is pumped (`RemoteControlApp`) | widget | `flutter test test/widget_test.dart` | ✅ mutate |
| **BAR-02** | `surfaceRect.bottom == barRect.top`; bar tappable while raised | widget | `flutter test test/shell/summon_geometry_test.dart` | ❌ Wave 0 |
| **BAR-03** | Keyboard icon disabled while an `EditableText` (not the shell's) holds focus; still present, bar Rect unchanged | widget | `flutter test test/shell/summon_bar_focus_gate_test.dart` | ❌ Wave 0 |
| **BAR-04** | Bar absent under `SummonBarSuppressor`; present again after it unmounts; depth-counted across a push/pop pair | widget | `flutter test test/shell/summon_bar_scope_test.dart` | ❌ Wave 0 |
| **BAR-05** | Content reachable on the hub grid and on `browser_screen` at 640dp with tab list + bookmarks | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ Wave 0 |
| **BAR-05** | Existing offline-hub finds still resolve with +56 bottom padding | widget | `flutter test test/hub_offline_test.dart` | ✅ re-run |
| **SUM-01** | Tapping an icon raises without a route push (`Navigator` history length unchanged) | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ Wave 0 |
| **SUM-02** | **A tappable widget outside the raised surface still receives its tap** (the surviving `bubble_scaffold_test.dart:156-186` contract) | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ Wave 0 |
| **SUM-02** | Nothing beneath reflows — a body widget's `Rect` is byte-identical before and after a raise | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ Wave 0 |
| **SUM-03** | Tapping the same icon lowers; tapping the other **swaps** without leaving the bar | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ Wave 0 |
| **SUM-04** | D5 spike S1/S2/S3 | widget | `flutter test test/shell/summon_back_guard_spike_test.dart` | ❌ Wave 0 |
| **SUM-04** | D-13-02 scenario: raise on hub → push tool → back pops tool → back lowers → back exits | widget | `flutter test test/shell/summon_back_guard_test.dart` | ❌ Wave 0 |
| **SUM-04** | D-13-03 orphan: raise on a tool route → pop it via the AppBar arrow → back from the hub exits with the surface still raised | widget | `flutter test test/shell/summon_back_guard_test.dart` | ❌ Wave 0 |
| **SUM-04** | D-13-05 browser: subfolder + raised → one back lowers only; second exits the folder; third pops | widget | `flutter test test/browser/browser_back_priority_test.dart` | ❌ Wave 0 |
| **SUM-04** | Predictive-back baseline: `setFrameworkHandlesBack(false)` on the hub with nothing raised, `true` while raised, `false` again after lowering | widget | `flutter test test/shell/predictive_back_baseline_test.dart` | ❌ Wave 0 |
| **MOT-01** | Summon: not at rest at t=100, at rest at t=250 | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ Wave 0 |
| **MOT-01** | Dismiss: mid at t=75, at rest at **t=160** (fails a 200ms dismiss) | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ Wave 0 |
| **Geometry** | Five driven viewports A–E + F3/F5 discriminators, every expectation computed | widget | `flutter test test/shell/summon_geometry_test.dart` | ❌ Wave 0 |
| **Guards** | No raw palette hex, no `Icons.` in new shell code | unit | `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ re-run |
| **Regression** | Docked-panel inset guards untouched | widget | `flutter test test/trackpad/trackpad_screen_test.dart test/keyboard/keyboard_panel_test.dart` | ✅ re-run |

**Manual-only (hardware UAT, closes OQ-A1 sub-question 1 and D-13-09):**
- Does 200/150 feel quick at dozens-of-summons-per-session frequency? (one-constant change if not)
- Are the 0.75 / 0.55 fractions right on the owner's device?
- Does the system back-to-home peek still play from the hub with nothing raised? (only the OS compositor can show this)
- The browser tab list and bookmarks section at 640dp with the bar present.
- The power confirm dialog with the bar rendered over it.

### Sampling Rate

- **Per task commit:** `flutter test test/shell` (the new suites only — seconds)
- **Per wave merge:** `flutter test` (full 823-declaration suite, from `app/remote_control`)
- **Phase gate:** full suite green **plus** both guard suites green, before `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `test/shell/` directory — **does not exist** `[VERIFIED: ls app/remote_control/test/shell → absent]`
- [ ] `test/shell/summon_back_guard_spike_test.dart` — the D5 spike, **first file in the phase** (SUM-04)
- [ ] `test/shell/summon_shell_test.dart` — BAR-01, BAR-05, SUM-01, SUM-02
- [ ] `test/shell/summon_geometry_test.dart` — the five viewports + F3/F5 discriminators
- [ ] `test/shell/summon_motion_test.dart` — MOT-01, SUM-03, the swap
- [ ] `test/shell/summon_bar_focus_gate_test.dart` — BAR-03
- [ ] `test/shell/summon_bar_scope_test.dart` — BAR-04
- [ ] `test/shell/summon_back_guard_test.dart` — D-13-02, D-13-03
- [ ] `test/shell/predictive_back_baseline_test.dart` — D-13-01
- [ ] `test/browser/browser_back_priority_test.dart` — D-13-05
- [ ] Shared harness: a `pumpShell()` + `driveView()` + `availableOf()` helper file. **Harvest** `_RecordingService` from `test/bubble_scaffold_test.dart:65-81` and the `_NoopWakelock` stub from `test/trackpad/trackpad_screen_test.dart:41-47` **before** Phase 16 deletes their homes
- [ ] Framework install: **none** — `flutter_test` is already a dev dependency

---

## Security Domain

ASVS L1 (`security_asvs_level: 1`). This phase moves no data and adds no I/O, but it *does* own one real control.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard control in this phase |
|---|---|---|
| V2 Authentication | **yes, indirectly** | BAR-03 — the pairing PIN is an authentication credential; the focus gate is what keeps it on the phone. Verified predicate in §8 |
| V3 Session Management | no | No token, session or credential is read, written or transported by the shell |
| V4 Access Control | no | No new capability is exposed; the bar reaches only surfaces the user already had |
| V5 Input Validation | **yes, narrowly** | The only "input" is a tap on two icons. The real control is *routing* input to the right target (BAR-03), not validating it |
| V6 Cryptography | no | Nothing cryptographic is touched. Token hashing stays in `remote_protocol`/server |
| V7 Error Handling & Logging | **yes** | The shell must log nothing about focus, field contents or the raised surface. `HiddenTextInput`'s existing redaction contract (`ExcludeSemantics`, no logging — `hidden_text_input.dart:14-15`) must not be weakened by the shell hosting it in Phase 15 |

### Known Threat Patterns

| Pattern | STRIDE | Standard mitigation |
|---|---|---|
| **The 6-digit pairing PIN is typed into the PC** because the summon keyboard stole focus from the local `TextField` | Information Disclosure | BAR-03's focus gate (§8). **This is the phase's one genuine security requirement.** The v1.0 threat model already treats the PIN as a secret (PIN pairing, 60s expiry, lockout — CLAUDE.md `## Constraints`); typing it into whatever window has focus on the laptop discloses it to any application there |
| A raised surface over the **QR pairing scanner** obscures or interferes with credential capture | Tampering / DoS | BAR-04 suppression (§9), applied at the single `QrScanScreen` push site |
| The bar renders over the **power confirm dialog**, making a spec-locked double-confirm easier to mis-tap | Tampering | Bar and dialog do not overlap geometrically (the dialog is centered; the bar is a 56dp bottom strip), but this is an **eyeball item for UAT**, not an assertion |
| Typed content leaking into the accessibility tree or logs via a new shell-hosted field | Information Disclosure | Phase 15's concern; Phase 13 must not add any `Semantics` label carrying field state to the bar |
| A `PopScope(canPop: false)` bricks the back gesture so the user cannot leave a screen | DoS (self-inflicted) | The reactive ownership predicate (§4) plus the predictive-back baseline test (§10.3) |

**Nothing in this phase touches the network, storage, or the server.** No new attack surface is added.

---

## Environment Availability

| Dependency | Required by | Available | Version | Fallback |
|---|---|---|---|---|
| Flutter SDK (pinned) | Everything | ✓ | **3.44.5** stable, Dart 3.12.2, at `C:/dev/flutter` and on PATH | — |
| `flutter_test` | All tests | ✓ | bundled (`sdk: flutter`) | — |
| Android device / emulator | Hardware UAT only (D-13-01 baseline, D-13-09 fractions, OQ-A1) | ⚠ not probed this session | — | Every automated check in §Validation Architecture runs headless; only the five manual items need hardware |
| Android SDK / gradle | APK build for UAT | ⚠ not probed this session | `targetSdk 36` via `flutter.targetSdkVersion` | — |
| `gh.exe` | not needed this phase | n/a (`C:\Program Files\GitHub CLI\gh.exe`, not on PATH) | — | — |

**Missing dependencies with no fallback:** none.
**Missing dependencies with fallback:** none blocking; hardware UAT is the phase gate by design (D-13-09), so an unavailable device delays sign-off, not implementation.

---

## State of the Art

| Old approach (in this tree) | Current approach (this phase) | Why it changed |
|---|---|---|
| `BubbleScaffold` per-route wrapper at `hub_screen.dart:286` — reaches 9 of 14 screens | `SummonShell` at `MaterialApp.builder` — reaches all 14 including the root | One `KeyboardInputController` per process is a **correctness** requirement (SUMMARY C1) |
| `PopScope(canPop: !expanded)` on a per-route scaffold | `PopScope(canPop: !(raised && owned))` on a per-route guard, with the state at app scope | The surface now outlives the route (D-13-02) |
| `MediaQueryData.fromView(View.of(context))` (docked panel, `keyboard_panel.dart:378-408`) | `MediaQuery.viewPaddingOf` / `viewInsetsOf` at the shell | Opposite inset context: the shell's MediaQuery is un-stripped and rebuilds automatically |
| `WidgetsBindingObserver.didChangeMetrics` (`keyboard_panel.dart:157, :196-199`) | **deleted, not ported** | At the shell the data is not value-equal across the IME animation |
| `onPopInvoked` | `onPopInvokedWithResult` | `onPopInvoked` is `@Deprecated` since v3.22.0-12.0.pre `[VERIFIED: widgets/pop_scope.dart:138-142]`; the tree already migrated (`bubble_scaffold.dart:26-28`) |
| `WillPopScope` | `PopScope` | Zero `WillPopScope` usages remain in `lib/` `[CITED: CONTEXT.md `## Implementation Decisions`, verified this session by grep]` |

**Deprecated / outdated — do not reintroduce:**
- `onPopInvoked` (use `onPopInvokedWithResult`)
- `WillPopScope` (removed from this tree)
- `Route.willPop()` / `addScopedWillPopCallback` — `@Deprecated` after v3.12.0-1.0.pre `[VERIFIED: widgets/routes.dart:2000-2003, 2070-2073]`
- `StateNotifier` / Riverpod 2 patterns (CLAUDE.md `## What NOT to Use`)

---

## Assumptions Log

| # | Claim | Section | Risk if wrong |
|---|---|---|---|
| **A1** | `AnimationController.reverse()` from a partial value takes `reverseDuration` scaled by remaining distance | §7.3 | Low — a mid-flight reverse would feel slower than expected. Pinned by one test; cheap to correct |
| **A2** | `kSummonMinSurfaceHeight = 220` is the right floor for **both** surfaces (device D collapses them to the same height) | §6.1, §6.4 | Medium — it is a design choice (D-13-09), tunable on hardware. But if the owner wants two floors, "one derivation" (D-13-06) needs a stated amendment. **Surface this at UAT** |
| **A3** | The Phase-13 keyboard box is `available × 0.75` (a *fraction*), and Phase 15 sizes its pads inside that fixed box with `Expanded` — as `keyboard_screen.dart:275-318` already does — rather than porting the docked panel's per-pad `kPanelPadHeights` | §6.1, Open Question OQ-1 | **High** — this is the difference between "Phases 14/15 fill a box that is already the right size" (D-13-06) and a geometry change in Phase 15. See OQ-1; needs an owner/planner decision, not a silent pick |
| **A4** | `SummonBarSuppressor`'s depth counter, rather than a `NavigatorObserver`, is acceptable for BAR-04 | §9 | Low — one wrapper at one push site; reversible |
| **A5** | The bar rendering over modal routes (pairing sheet, sensitivity sheet, power confirm) is acceptable | §9 | Low-Medium — SC4 requires it on the pairing sheet, so it is at least partly decided. The power dialog is an eyeball item |
| **A6** | Android's predictive back is default-on at `targetSdk 36` without a manifest flag | §10.1 | Medium — `[CITED: developer.android.com/guide/navigation/predictive-back-gesture]`, *"Predictive back is enabled by default"*, opt-out via `false`. The hardware baseline recording (D-13-01) is what actually settles it, which is why D-13-01 exists |
| **A7** | `_popEntries`' `LinkedHashSet` insertion order is ancestor-before-descendant | §3 | **None by construction** — the recommendation is explicitly not to rely on it. Listed so nobody "optimises" into an order-dependent latch |

---

## Open Questions

### OQ-1 — What exactly is "the keyboard's real final height" in Phase 13? (**blocks the geometry plan**)

- **What we know:** D-13-06 requires each icon to raise its *real final height* in Phase 13, from one shared derivation with a per-surface fraction. ARCHITECTURE §4.3 Step 6, however, gives the summon keyboard a **per-pad** height (`min(kPanelPadHeights[pad], max(96, available × 0.75 − 121))`), which yields 201 for Type and 433 (clamped) for Numpad on device A — not one number, and not `available × 0.75 = 572.25`.
- **What's unclear:** with an empty overlay and no pad selected, Phase 13 cannot compute a per-pad height. So either (a) Phase 13 ships `available × fraction` and Phase 15 must **not** switch to per-pad heights, or (b) Phase 13 ships `available × fraction` and the geometry *does* change in Phase 15 — which is exactly the "Phases 14/15 only fill a box that is already the right size" promise broken.
- **Recommendation: (a).** Size the box by fraction in Phase 13; in Phase 15 the deck sizes its pads **inside** that fixed box with `Expanded`, which is what the full-screen keyboard already does `[VERIFIED: app/remote_control/lib/keyboard/keyboard_screen.dart:275-318]`. This also means `kPanelPadHeights` / `panelPadHeight` / `kPanelColumnOverhead` are **never reused**, which is what "re-derive, do not copy" asked for in the first place. The cost is that the Type pad occupies a taller box than it needs — a legibility/aesthetics judgement for UAT, not a correctness issue. **Put this in the plan as an explicit note to Phase 15.**

### OQ-2 — Does `SummonShell` mount `HiddenTextInput` in Phase 13, or Phase 15?

- **What we know:** ARCHITECTURE §7's P1 row lists "the unconditional hidden IME field" as a Phase-1 deliverable; CONTEXT.md's decisions never mention it and D-13-08 scopes the overlay's contents to fill + top edge + handle (the field is a shell sibling, not overlay content, so D-13-08 does not settle it).
- **What's unclear:** mounting it in 13 costs one `Positioned` and guarantees P4's "outside the animating chrome" property is structural from day one. Not mounting it means Phase 15 adds it to a shell that already animates — the exact retrofit P4 says is a host rewrite to recover from.
- **Recommendation:** mount the `Positioned(width:1, height:1)` **slot** in Phase 13 with a `const SizedBox.shrink()` placeholder and a doc comment naming the constraint, and let Phase 15 drop `HiddenTextInput` into it. Zero behaviour in 13, zero retrofit risk in 15. Flag the BAR-03 `identical(node, shellImeNode)` escape (§8, Pitfall E) as shipping in 13 regardless.

### OQ-3 — SC2's wording "the surface sits **on top of** it"

- **What we know:** BAR-02 says "the surface sits on top of it, never under it"; SUMMARY C4 is unambiguous — *"the surface's bottom edge sitting on top of the bar, never under it… otherwise the primary dismiss is occluded"*; ARCHITECTURE §2.5 places the bar at `Positioned(bottom: barBottomOffset, height: 56)` and the surface at `Positioned(bottom: barTop, …)`.
- **What's unclear:** SC2's clause "the bar stays visible and tappable the whole time **because** the surface sits on top of it" reads, in isolation, as z-order rather than vertical stacking — which would occlude the bar and contradict the same sentence.
- **Recommendation:** implement vertical stacking (surface *above* the bar, bar never occluded) and pin it with invariants I1+I2. Note the wording in VERIFICATION so UAT confirms it rather than a later reader re-litigating it.

### OQ-4 — Should the `pushGuarded()` conversion be enforced by a source-scanning guard?

- **What we know:** SUM-04 fails silently on any un-guarded page route, and there are 8 push sites in 5 files.
- **Recommendation:** yes — a test in the style of `icons_guard_test.dart` that bans a bare `MaterialPageRoute(` in `lib/` outside `lib/shell/`, with a reasoned allowlist. It is ~30 lines, it matches the house style exactly, and it makes Pitfall G impossible. Present it to the planner as **recommended**, not mandatory (it is new scope beyond the requirements).

### OQ-5 — Does the +56 bottom padding break any existing test's finder?

- **What we know:** `widget_test.dart` and `hub_offline_test.dart` pump real screens and will see the injection. `hub_screen.dart:376` already scrolls.
- **Recommendation:** run `flutter test` **before** writing new shell code and again immediately after the injection lands, as a discrete task. Anything that goes red is signal about BAR-05, not noise.

---

## Sources

### Primary (HIGH confidence)

**Pinned Flutter SDK on disk, `C:/dev/flutter` @ 3.44.5** (`frameworkRevision f94f4fc76b4d74543ed9b085bbd75341ef65de22`, `frameworkCommitDate 2026-07-06`) — every file read this session:
- `packages/flutter/lib/src/widgets/app.dart:1442-1455, 1690-1731, 1692-1694, 1813-1857` — `setFrameworkHandlesBack` plumbing; builder receives the Navigator as `child`; the autofocused Navigator `FocusScope`
- `packages/flutter/lib/src/material/app.dart:267, 1026-1067` — `MaterialApp` never introduces a `MediaQuery`; the builder's `Theme`/`ScaffoldMessenger` ancestry
- `packages/flutter/lib/src/widgets/pop_scope.dart:82-99, 138-142, 152-165, 171-219` — `ModalRoute.of` registration; the multi-`PopScope` AND rule; predictive-back note; `onPopInvoked` deprecation
- `packages/flutter/lib/src/widgets/routes.dart:1980, 2000-2003, 2033-2050, 2070-2073, 2117-2142` — `_popEntries` is a `Set`; `popDisposition`; `onPopInvokedWithResult` fans out to all entries; `_maybeDispatchNavigationNotification`
- `packages/flutter/lib/src/widgets/navigator.dart:3743-3769, 5546-5579, 5620` — `canHandlePop` computation; `maybePop` consults only the topmost route; `onPopInvokedWithResult(true, …)` on a real pop
- `packages/flutter/lib/src/widgets/binding.dart:1091-1143, 1148-1169, 1330` — the predictive-back doc block; `handlePopRoute` first-observer-wins; `handleAppLifecycleStateChanged`
- `packages/flutter/lib/src/widgets/focus_manager.dart:1636, 1845-1846, 1955-2001` — `FocusManager` is a `ChangeNotifier`; `primaryFocus` reverts to `rootScope`
- `packages/flutter/lib/src/widgets/editable_text.dart:5750, 5804-5805` — `Focus(focusNode: widget.focusNode)` inside `EditableText`
- `packages/flutter/lib/src/widgets/framework.dart:2452-2470, 5092` — `getInheritedWidgetOfExactType` creates no dependency
- `packages/flutter/lib/src/material/scaffold.dart:2779-2781, 2915-2936, 3028-3034, 3222` — body `MediaQuery` derivation, `removeBottomInset`, `minInsets`
- `packages/flutter/lib/src/services/system_navigator.dart:15-44` — `setFrameworkHandlesBack` is Android-only, on `SystemChannels.platform`
- `packages/flutter/lib/src/services/system_channels.dart:91-98` — the `flutter/backgesture` channel
- `packages/flutter_tools/gradle/src/main/kotlin/FlutterExtension.kt:34` — `val targetSdkVersion: Int = 36`
- `bin/cache/flutter.version.json` — the pinned version tuple

**Working tree `C:/Users/omkar/Projects/Remote Control` @ `master e2741fa`** — every `file.dart:line` above, read this session:
- `app/remote_control/lib/main.dart:110-118`, `lib/widgets/bubble_scaffold.dart:50, 100-126, 142-218`, `lib/browser/browser_screen.dart:527-530, 540-600`, `lib/hub/hub_screen.dart:55-100, 265-389`, `lib/keyboard/key_pads.dart:100-251, 340-360`, `lib/keyboard/keyboard_screen.dart:266-330`, `lib/keyboard/hidden_text_input.dart:1-30`, `lib/theme/tokens.dart:16-67`, `lib/net/connection_providers.dart:1-50, 120-133`, `lib/screens/qr_scan_screen.dart:1-40`
- `app/remote_control/test/bubble_scaffold_test.dart` (whole), `test/trackpad/trackpad_screen_test.dart:1-308`, `test/theme_tokens_guard_test.dart:1-60`, `test/icons_guard_test.dart` (whole), `test/widget_test.dart` (whole), `test/haptics_gate_test.dart:1-45`
- `app/remote_control/android/app/src/main/AndroidManifest.xml` (whole), `android/app/build.gradle.kts:22, 34-35`, `pubspec.yaml:27, 83-84`
- `.planning/config.json` — `nyquist_validation: true`, `security_enforcement: true`, `security_asvs_level: 1`

**Milestone research (cited, not repeated):** `.planning/research/SUMMARY.md` (Design-Note Drift D1-D6; C1-C6; The Animation Budget; OQ-A1), `.planning/research/ARCHITECTURE.md` §§1-9 (esp. §4 the derivation, §6 the retirement lists, §8 the design-note audit), `.planning/research/PITFALLS.md` P4/P8/P9/P10/P11/P12, `.planning/research/STACK.md` (the rejected-package list)

### Secondary (MEDIUM confidence)

- [developer.android.com — Predictive back gesture](https://developer.android.com/guide/navigation/predictive-back-gesture) — *"Predictive back is enabled by default"*; opt-out via `android:enableOnBackInvokedCallback="false"`; Android 15 removed the developer option. Read this session

### Tertiary (LOW confidence — flagged, not relied on)

- `AnimationController.reverse()` partial-value semantics (A1) — training knowledge, not re-read from the SDK this session. One test pins it.

---

## Metadata

**Confidence breakdown:**

| Area | Level | Reason |
|---|---|---|
| Host shape (`MaterialApp.builder` above the Navigator) | **HIGH** | Read from `widgets/app.dart:1690-1731`. Upgrades ARCHITECTURE's LOW/webfetch classification |
| `PopScope` registration & multi-`PopScope` semantics | **HIGH** | Read from `pop_scope.dart:194-202` + `routes.dart:1980, 2033-2050` + `navigator.dart:5546-5579` |
| Route ownership design (D-13-02/03) | **HIGH** on mechanism, **MEDIUM** on ergonomics | The `int`-stack is provably leak-free and orphan-correct, but it is a **new design** with no in-tree precedent — the D-13-02 scenario test is what validates it |
| Inset arithmetic + BAR-05 injection | **HIGH** | Verified end-to-end against `material/scaffold.dart:2915-2936, 3028-3034`; the five worked devices are arithmetic |
| Which discriminator catches which failure (§6.5) | **HIGH** | Derived from the same verified formulas; F3's "wrong on the reference device, IME down" is the new finding |
| BAR-03 focus predicate | **HIGH** | `focus_manager.dart:1965-1969` and `editable_text.dart:5804-5805` both read directly; corrects milestone research |
| Predictive-back baseline | **HIGH** for the Flutter mechanism, **MEDIUM** for the Android default | Flutter side read from `binding.dart:1091-1110` + `app.dart:1442-1455` + `navigator.dart:3743-3753`; the Android default is doc-cited and D-13-01 exists precisely to record it on hardware |
| Animation shape & timing tests | **HIGH** for the test sequences, **MEDIUM** for A1 | The `pump(Duration)` discriminators are arithmetic against a stated duration; `reverse()` scaling is `[ASSUMED]` |
| Test-migration counts | **HIGH** | Counted this session; corrects SUMMARY's 882/42 |
| BAR-04 suppression mechanism | **MEDIUM** | Sound and minimal, but a design choice with one alternative (`NavigatorObserver`) that was rejected on state-duplication grounds, not measured |

**Research date:** 2026-08-14
**Valid until:** 2026-09-13 (30 days) — the SDK is pinned and the tree is the only moving part; re-verify the `file.dart:line` citations if the working tree advances past `master @ e2741fa` before planning.
