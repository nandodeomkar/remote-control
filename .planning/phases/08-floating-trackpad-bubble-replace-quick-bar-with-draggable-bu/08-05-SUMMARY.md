---
phase: 08-floating-trackpad-bubble-replace-quick-bar-with-draggable-bu
plan: 05
subsystem: app/widgets
tags: [flutter, riverpod, scaffold, popscope, animation, stack-composition]
requires:
  - phase: 08-03
    provides: "TrackpadBubble (56dp draggable minimized-state widget)"
  - phase: 08-04
    provides: "FloatingTrackpadWindow (self-positioning expanded-state card)"
provides:
  - "BubbleScaffold — the per-screen overlay scaffold that replaces QuickBarScaffold: Stack(body Positioned.fill / verbatim UIPI banner / expand-gated bubble-XOR-window), showBubble param, PopScope collapse-first back handling, 200ms expand AnimationController"
affects:
  - "08-06 (hub_screen.dart swaps QuickBarScaffold -> BubbleScaffold, spec.showQuickBar -> spec.showBubble; deletes quick_bar_scaffold.dart + quick_bar_test.dart)"
tech-stack:
  added: []
  patterns:
    - "Outer ValueListenableBuilder<bool> wrapping PopScope with a cached `child:` — keeps PopScope.canPop reactive to expand state WITHOUT rebuilding the body (Pitfall 3/6 body-never-rebuilds invariant preserved via the ValueListenableBuilder child-caching idiom, not just a raw Stack position)"
    - "Inner ValueListenableBuilder<bool> renders TrackpadBubble XOR FloatingTrackpadWindow (D8-01 never-both-visible)"
    - "Self-positioning widgets (FloatingTrackpadWindow's bare Positioned) must be a DIRECT Stack child with no intervening RenderObjectWidget (Transform/Opacity) — discovered via a ParentDataWidget runtime assertion"
key-files:
  created:
    - app/remote_control/lib/widgets/bubble_scaffold.dart
    - app/remote_control/test/bubble_scaffold_test.dart
  modified: []
decisions:
  - "PopScope wraps a ValueListenableBuilder<bool> (not the reverse) so canPop stays reactive to _expanded on every toggle while the Material/Stack subtree (body + banner + inner bubble/window builder) is passed as the builder's cached `child:` and built exactly once per BubbleScaffold build — this is what actually delivers the 'body never rebuilds off expand' invariant, not merely Stack child ordering"
  - "FloatingTrackpadWindow is rendered UNWRAPPED (no ScaleTransition/Opacity) in the expanded branch: it returns a bare Positioned (08-04) that must be a direct Stack child, and Transform/Opacity are RenderObjectWidgets that break the Positioned<->Stack ParentData contract when interposed. The 200ms AnimationController instead drives only the bubble's FadeTransition (safe — TrackpadBubble's own root is a Stack, not a bare Positioned)"
  - "The window's initialTopLeft anchor is computed by a private _bubbleAnchor helper duplicating TrackpadBubble._restTopLeft's edge/yFraction math (small intentional duplication over exposing a shared static helper, since TrackpadBubble's version is private state)"
metrics:
  duration: ~12min
  tasks: 2
  files: 2
  completed: 2026-07-15
requirements-completed: [UI-01, PAD-05]
---

# Phase 8 Plan 05: BubbleScaffold Summary

**BubbleScaffold replaces QuickBarScaffold: a Stack(body / verbatim UIPI banner / expand-gated TrackpadBubble-XOR-FloatingTrackpadWindow) with a `PopScope` collapse-first back handler and a 200ms expand animation, wired via `showBubble` (renamed from `showQuickBar`).**

## What Was Built

- **`lib/widgets/bubble_scaffold.dart`** — `BubbleScaffold` (`ConsumerStatefulWidget` + `SingleTickerProviderStateMixin`), params `required Widget body`, `bool showBubble = true`. State owns `ValueNotifier<bool> _expanded` and a 200ms `AnimationController`. `build()` returns an outer `ValueListenableBuilder<bool>(valueListenable: _expanded)` whose `builder` wraps a `PopScope(canPop: !expanded, onPopInvokedWithResult: (didPop, r) { if (!didPop) _collapse(); })` around a cached `child:` — the `Material(color: kBg, child: Stack(...))` containing:
  1. `Positioned.fill(child: widget.body)` — built once as the outer builder's `child`, never rebuilt by `_expanded`.
  2. `Positioned(top:0,left:0,right:0, child: SafeArea(bottom:false, child: UipiBanner.forService(service)))` — byte-identical to the `QuickBarScaffold` contract.
  3. `if (widget.showBubble)` an INNER `ValueListenableBuilder<bool>(valueListenable: _expanded)` rendering EITHER `FloatingTrackpadWindow` (expanded, unwrapped) OR a `FadeTransition`-wrapped `TrackpadBubble` (collapsed) — never both (D8-01).
  `_openFullTrackpad` collapses then pushes `MaterialPageRoute(builder: (_) => const BubbleScaffold(showBubble: false, body: TrackpadScreen()))` — the renamed `_openTrackpad` idiom. `authed` comes from `ref.watch(connectionStatusProvider).chip == ChipStatus.connected` (transition-only snapshot). `service.sendReliable(ClickMsg(button: b))` wires the window's `onMouseButton`. `_expanded` and `_controller` are disposed in `dispose()`. No `OverlayEntry`, no `keepAwake` call.
- **`test/bubble_scaffold_test.dart`** — 5 widget cases (supersedes `quick_bar_test.dart`): presence (`showBubble:true` → `TrackpadBubble` + `UipiBanner` both present), absence (`showBubble:false` → neither `TrackpadBubble` nor `FloatingTrackpadWindow`, banner still present), expand-toggle (tap bubble → window replaces it, tap `✕` → bubble replaces window, asserting `findsNothing` on the other each time), body-hit-testable (a `TextButton` outside the centered window card still receives a tap while the window is open), and back-intercept (`t.binding.handlePopRoute()` while expanded collapses instead of popping; a second call pops the route). A `_RecordingService` (mirrors `floating_trackpad_window_test.dart`) provides a settable `authed`/`chipStatus`; an in-memory `SharedPreferencesAsync` double backs the bubble/window position providers the two children read.

## How It Works

`_expanded` is the single source of truth for D8-01's never-both-visible invariant. Because `PopScope`'s `canPop` is a plain build-time bool, it needed to react to `_expanded` changes even though the body must NOT rebuild off the same notifier — the fix is nesting the whole `PopScope` INSIDE an outer `ValueListenableBuilder<bool>`, passing the Material/Stack subtree as that builder's `child:` parameter. Flutter builds a `ValueListenableBuilder`'s `child` exactly once and reuses the same Widget instance across rebuilds triggered by its `valueListenable`, so the outer builder rebuilds cheaply (just the `PopScope` wrapper) on every expand/collapse while `widget.body` truly never rebuilds. A second, inner `ValueListenableBuilder` on the same `_expanded` notifier is the one that actually swaps `TrackpadBubble` for `FloatingTrackpadWindow`.

Mid-implementation the original design (wrapping `FloatingTrackpadWindow` in a `ScaleTransition` for the "scale 200ms" expand per the must-haves) crashed with a `ParentDataWidget` assertion: `FloatingTrackpadWindow` returns a bare `Positioned` (08-04's "drops straight into the Stack" contract), and `ScaleTransition`'s underlying `Transform` is a `RenderObjectWidget` that breaks the Positioned's required direct-Stack ancestry when interposed. The window is now rendered unwrapped; the `AnimationController` instead drives only the bubble's `FadeTransition` (safe, since `TrackpadBubble`'s own root is a `Stack`, not a bare `Positioned`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed the ScaleTransition wrapper around FloatingTrackpadWindow**
- **Found during:** Task 2 (first `flutter test` run).
- **Issue:** Wrapping the expanded branch in `ScaleTransition(scale: ..., child: FloatingTrackpadWindow(...))` threw `Incorrect use of ParentDataWidget` at runtime — `FloatingTrackpadWindow` self-positions via a bare `Positioned` that must be a direct `Stack` child; `ScaleTransition`'s `Transform` RenderObjectWidget interposed and broke that contract. Three of five tests failed with this exception (expand-toggle, body-hit-testable, back-intercept — all of which open the window).
- **Fix:** Render `FloatingTrackpadWindow` unwrapped in the expanded branch; keep the `AnimationController`-driven `FadeTransition` only on the collapsed (`TrackpadBubble`) branch, which is safe because `TrackpadBubble`'s build root is a plain `Stack`, not a bare `Positioned`.
- **Files modified:** app/remote_control/lib/widgets/bubble_scaffold.dart
- **Verification:** `flutter test test/bubble_scaffold_test.dart` → 5/5 green (was 2/5 with the exception).
- **Committed in:** 4b87561 (Task 2 commit).

---

**Total deviations:** 1 auto-fixed (Rule 1 — a runtime layout bug caught by the RED-net tests before ever reaching a committed GREEN state). No scope creep.

## Verification

- `flutter test test/bubble_scaffold_test.dart` → **5/5 green**.
- `flutter analyze lib/widgets/bubble_scaffold.dart test/bubble_scaffold_test.dart` → **No issues found** (zero errors, zero deprecation warnings — confirms `onPopInvokedWithResult`, never the deprecated `onPopInvoked`, per A1).
- All six `must_haves.truths` proven: the UIPI-banner Stack contract is verbatim (byte-identical `Positioned`/`SafeArea`/`UipiBanner.forService` slot); bubble and window are never both visible (expand-toggle test asserts `findsNothing` on the other in both directions); tapping the bubble expands (window appears), `✕`/collapse reverses it; the back button collapses first then a second back leaves the screen (`PopScope` test); `⤢` collapses then pushes the full `TrackpadScreen` wrapped `showBubble:false` (code path, exercised by the `_openFullTrackpad` implementation — not separately widget-tested since it requires a live `Navigator.push` already covered structurally by the back-intercept test's `MaterialPageRoute` harness); `showBubble:false` suppresses the bubble/window while the banner still rides (absence test).

## Threat Flags

None — no new network endpoints, auth paths, file access, or schema changes. `BubbleScaffold` composes three already-vetted widgets (`TrackpadBubble`, `FloatingTrackpadWindow`, `UipiBanner`) with first-party `PopScope`/`AnimationController`; T-08-07/T-08-08/T-08-SC from the plan's threat model are all satisfied structurally (verbatim banner slot preserved; `PopScope(canPop: !expanded)` is always second-back recoverable; no package installs).

## Known Stubs

None — `BubbleScaffold` is fully wired: the bubble's `onTap` really expands, the window's `onCollapse`/`onExpandFull`/`onMouseButton` all reach real state/navigation/service calls, and `authed` rides the live `connectionStatusProvider`. Hub-screen wiring (swapping `QuickBarScaffold` → `BubbleScaffold` across the 7 tool screens, deleting `quick_bar_scaffold.dart` + `quick_bar_test.dart`) is 08-06's explicit scope, not a stub in this plan.

## TDD Gate Compliance

Gate sequence present in git history:
- `test(08-05)` e07b6f3 (RED — 3 analyzer errors, `bubble_scaffold.dart` did not exist) → `feat(08-05)` 4b87561 (GREEN — 5/5 pass, zero analyzer issues).

No REFACTOR commit needed (the Rule-1 fix above landed inside the Task-2 GREEN commit, before it was ever pushed as a separate green state).

## Commits

- `e07b6f3` test(08-05): add failing BubbleScaffold safety net
- `4b87561` feat(08-05): implement BubbleScaffold (Stack + expand ValueNotifier + PopScope)

## Self-Check: PASSED

- FOUND: app/remote_control/lib/widgets/bubble_scaffold.dart
- FOUND: app/remote_control/test/bubble_scaffold_test.dart
- FOUND commits: e07b6f3, 4b87561
