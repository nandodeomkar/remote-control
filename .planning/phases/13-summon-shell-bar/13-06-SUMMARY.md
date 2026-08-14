---
phase: 13-summon-shell-bar
plan: 06
subsystem: flutter-app-browser
tags: [summon, back-guard, popscope, browser, bookmarks, SUM-04, D-13-05, D-13-18, T-13-12, T-13-07]
status: complete

requires:
  - "13-01: SummonScope.ownsRaisedSurface, SummonGuardScope, SummonBackGuard, SummonShellController"
  - "13-02: SummonShell, kSummonSurfaceKey, pumpShell / contextOf / RecordingService"
  - "13-05: the ownership semantics this plan extends to a second handler"
provides:
  - "The predicate guard in browser_screen.dart's back callback — the only place in lib/ where two back handlers share one route"
  - "test/browser/browser_back_priority_test.dart — the three-back sequence, the reverse configuration, and the no-rebuild-on-raise assertion"
  - "The pure-read-phase rule: a pop dispatch must not mutate the state its other voters read (summon_back_guard.dart)"
affects:
  - "Phase 16 (bubble retirement): bubble_scaffold.dart's PopScope dies; it is NOT a second handler on a route that also carries the guard, so nothing here changes"
  - "Phase 18 / any later PopScope: a third handler on any route inherits the pure-read-phase rule for free — no ordering, no latch"

tech-stack:
  added: []
  patterns:
    - "Two back handlers on one route resolve by mutually-exclusive predicates over one shared state, never by ordering and never by a consumed latch"
    - "A pop dispatch is a READ phase: the higher-priority handler defers its mutation one microtask so every voter reads identical state"
    - "Rebuild scope proven by widget identity — the instance a build returned, compared before and after, IS the build count"

key-files:
  created:
    - "app/remote_control/test/browser/browser_back_priority_test.dart"
  modified:
    - "app/remote_control/lib/browser/browser_screen.dart"
    - "app/remote_control/lib/shell/summon_back_guard.dart"

key-decisions:
  - "The guard's lower() is deferred one microtask. Two predicates over one shared state are order-independent only while that state is stable; the guard's own action destroyed it mid-dispatch, which is what case 1 caught."
  - "The deferral is NOT a latch: nothing records which callback ran first, and a third handler changes nothing about the rule."
  - "Case 3 asserts BrowserScreen's build did not re-run by comparing the Scaffold instance its build returned, plus a route-subtree build counter above the screen — two complementary instruments, because a counter above the screen cannot see the screen's own rebuild."

requirements-completed: [SUM-04]

coverage:
  - id: D1
    description: "On the Browser screen inside a bookmark folder with a surface raised, one back lowers the surface only with the folder depth numerically unchanged; a second back exits the folder; a third pops the route"
    requirement: "SUM-04"
    verification:
      - kind: unit
        ref: "test/browser/browser_back_priority_test.dart#case 1"
        status: pass
    human_judgment: false
  - id: D2
    description: "The bookmarks handler still steps up a folder when nothing is raised — the guard clause did not simply disable it"
    requirement: "SUM-04"
    verification:
      - kind: unit
        ref: "test/browser/browser_back_priority_test.dart#case 2"
        status: pass
    human_judgment: false
  - id: D3
    description: "The Browser screen does not rebuild when a surface is raised or lowered"
    verification:
      - kind: unit
        ref: "test/browser/browser_back_priority_test.dart#case 3"
        status: pass
    human_judgment: false
  - id: D4
    description: "Neither handler depends on which one runs first"
    verification:
      - kind: unit
        ref: "test/browser/browser_back_priority_test.dart#case 1 — red under BOTH hand-applied mutations (guard clause removed; deferral removed)"
        status: pass
    human_judgment: false

metrics:
  duration: ~40min
  completed: 2026-08-14
  tasks: 2
  commits: 2
  files: 3

actuals:
  tokens: 4100
  tasks: 2
  commits: 2
---

# Phase 13 Plan 06: One Back Gesture, One Thing Summary

**The one route in the app with two back handlers now resolves exactly one thing per gesture by predicate — and the invariant test caught that predicates alone were not enough, because the higher-priority handler was destroying the state the other one had to read.**

## Performance

- **Duration:** ~40 min
- **Completed:** 2026-08-14
- **Tasks:** 2
- **Files created:** 1, modified: 2

## Task Commits

1. **Task 1: Make the browser's back handler predicate-conditional** — `f16f2dd` (feat)
2. **Task 2: Pin the three-back sequence** — `4efdc05` (test + the Rule 1 fix it forced)

## What Was Built

**Task 1 — `browser_screen.dart` (`f16f2dd`).** One guard clause in the existing back callback, between the early return on a real pop and the folder step:

```dart
if (didPop) return;
// ... the comment block ...
if (SummonScope.ownsRaisedSurface(context)) return;
_onBookmarksBack();
```

The `canPop: !inFolder` expression is untouched — the two `canPop` values AND at the framework level, so either handler blocking the pop is sufficient and sharing the block is harmless. What must not combine is the two *actions*.

The comment block names the three framework facts by file and line (both callbacks fire when either `canPop` is false, `routes.dart:2044-2050`; the registration container is an unordered `Set`, `routes.dart:1980`; the callback also fires on a genuine pop, `navigator.dart:5620`), states that the lookup is non-subscribing and why (a subscribing read rebuilds the tab list and the whole bookmark tree on every raise), and explicitly forbids a consumed latch.

The diff is 21 lines, confined to that callback plus one import.

**Task 2 — `test/browser/browser_back_priority_test.dart` (`4efdc05`).** Three cases over the REAL shell (`pumpShell`) with `BrowserScreen` pushed as a guarded route — the production shape:

1. In a folder (`depth == 1`) with a surface raised: back 1 lowers the surface, leaves `depth` at 1 **and** leaves the route on screen; back 2 takes `depth` to 0; back 3 pops the route back to the harness root. Each `handlePopRoute()` return value is asserted too.
2. The reverse configuration — in a folder with **nothing** raised, the first back steps the folder up. This is what stops the guard clause from being a disguised "delete the bookmarks handler".
3. Raise then lower with the screen mounted, and assert the screen never rebuilt.

## The defect case 1 caught (and the fix)

**Both handlers were correctly written as predicates and the sequence still failed.** Case 1's first back lowered the surface *and* stepped up the folder — `Expected: <1>, Actual: <0>`, exactly the D-13-05 violation the case exists to name.

The cause is not ordering-as-written; it is that **the higher-priority handler's action destroys the shared state before the other voter reads it**. `ModalRoute.onPopInvokedWithResult` calls every registered `PopEntry` in one synchronous loop. `SummonBackGuard` runs first (it is the ancestor, so it registered first), and `controller.lower()` sets `raised.value = null` **synchronously**. The browser's callback then evaluates `SummonScope.ownsRaisedSurface(context)`, reads the already-lowered state, gets `false`, and steps up the folder. Two things, one gesture — and the outcome depends on which entry the `Set` yields first, which is precisely what D-13-18 forbids.

**Fix (deviation 1, below):** the guard defers its `lower()` by one microtask, making the dispatch a pure **read** phase. Every voter then sees identical state and both predicates agree in *any* order. This is deliberately **not** a latch — nothing anywhere records which callback ran first, and adding a third handler changes nothing about the rule. The lower still begins on the same frame; a microtask is not a frame.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] The pop dispatch must not mutate the state its other voters read**

- **Found during:** Task 2 — by case 1, on its first run, which is what the case is for.
- **Issue:** `SummonBackGuard`'s callback called `controller.lower()` synchronously inside the framework's `PopEntry` loop, so the browser's callback (iterated second) read post-lower state and acted as well. Two actions on one gesture; T-13-12 live in the tree.
- **Fix:** `scheduleMicrotask(controller.lower)` in `summon_back_guard.dart`, with a comment block stating the mechanism, citing `routes.dart:2044-2050` and `routes.dart:1980`, and stating that this is not a consumed latch.
- **Files modified:** `app/remote_control/lib/shell/summon_back_guard.dart` — **not in the plan's `files_modified`**. The plan scoped the fix to `browser_screen.dart`, and no change confined to that file can fix this: the browser cannot observe a raise that the guard already cleared, and the only way it could would be to subscribe, which the same plan forbids for rebuild-scope reasons.
- **Verification:** case 1 green; reverting the deferral turns it red at the same line and the same numbers (table below). `flutter test test/shell` unaffected — all 13-01/13-03/13-05 shell suites drive back through `await t.binding.handlePopRoute()`, and an awaited future flushes the microtask before the assertion.
- **Committed in:** `4efdc05`

---

**Total deviations:** 1 auto-fixed (1 bug, found by the plan's own invariant test).
**Impact on plan:** No assertion was weakened, dropped or added beyond the plan's three-case list. The plan's stated truth — *"each decides independently through mutually-exclusive predicates over one shared state, no ordering assumption and no consumed latch"* — now actually holds, which it did not with the guard clause alone.

## Manual Falsification (the acceptance criterion's required confirmation)

Each mutation was applied to the tree, run, then reverted; the tree is byte-identical to the committed state afterwards.

| Mutation | Result |
|---|---|
| `browser_screen.dart`: **guard clause removed** (`if (SummonScope.ownsRaisedSurface(context)) return;`) | Case 1 RED at **line 224** — `Expected: <1>, Actual: <0>`, the folder-depth assertion, with the D-13-05 reason string. **This is the criterion the plan asked to confirm.** |
| `summon_back_guard.dart`: **`scheduleMicrotask(controller.lower)` → `controller.lower()`** | Case 1 RED at **line 224**, identical numbers — the same violation reached from the other side. This is the confirmation for deviation 1. |

Both mutations red the *same assertion*, which is the point: the case does not care which handler misbehaved, only that one gesture resolved two things.

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/browser/browser_back_priority_test.dart` | 3 cases, all passed |
| `flutter test test/browser` | 97 tests, all passed (94 before this plan + 3) |
| `flutter test test/shell` | 65 tests, all passed — unchanged by the deferral |
| `flutter test` (full suite) | **954 passed** (951 before this plan + 3) |
| `flutter analyze --no-fatal-infos` | No issues found |
| `test "$(grep -c 'ownsRaisedSurface' lib/browser/browser_screen.dart)" -eq 1` | succeeds — exactly one predicate read |
| `grep -c 'dependOnInheritedWidgetOfExactType' lib/browser/browser_screen.dart` | 0 — the lookup does not subscribe |
| `git diff --stat -- lib/browser/browser_screen.dart` (task 1) | 21 changed lines (< 25) |

## Success Criteria

- [x] One back inside a bookmark folder with a surface raised lowers the surface only
- [x] The bookmarks handler still steps up a folder when nothing is raised
- [x] Neither handler depends on which one runs first
- [x] The Browser screen does not rebuild when a surface is raised or lowered

## Requirements Completed

- **SUM-04** — extended from 13-05's single-handler ownership to the one route that carries two handlers

## Threat Mitigations

| Threat ID | Disposition | Status |
|---|---|---|
| T-13-12 (two back handlers acting on one gesture) | mitigate | **Mitigated** — and it was live in the tree until case 1 found it. Mutually-exclusive predicates over one shared state, plus the pure-read-phase rule that keeps that state stable for the dispatch. Both wrong forms hand-applied; each reds the same committed line. |
| T-13-07 (Browser rebuild scope on summon) | mitigate | **Mitigated** — non-subscribing lookup (`dependOn…` count is 0), with case 3 asserting both a route-subtree build counter and the identity of the widget `BrowserScreen.build` returned across a raise/lower pair. |
| T-13-SC (package-manager installs) | accept | No installs; `pubspec.yaml` unchanged. |

## Threat Flags

None — this plan adds no network endpoint, auth path, file access or schema change. The only behavioural change on the wire side is that the folder walk stays local, which case 2 asserts.

## Known Stubs

None. All three cases drive the real shell, the real guard, the real controller and the real bookmarks notifier.

## Honest limits of case 3

The build counter sits **above** `BrowserScreen` in the pushed route's subtree, so it can catch a `ValueListenableBuilder` wrapped around the guarded content but cannot see a rebuild confined to the screen itself. That is why the case also asserts `identical(...)` on the `Scaffold` instance `BrowserScreen.build` returned — a fresh instance is a re-run build, so the pair covers both sides. Worth stating plainly: with `SummonScope.updateShouldNotify` returning false and the controller instance never changing, even a *subscribing* `dependOn…` would not by itself rebuild the screen today. What case 3 genuinely guards is the realistic regression — someone wrapping the screen or a large part of it in a listener over `controller.raised`.

## Notes for Next Phase

- **The pure-read-phase rule is now a property of the guard, not of the browser.** Any future handler on any route inherits it: read the shared state, decide, and let the highest-priority actor defer its mutation. A third handler needs no coordination and no latch.
- **Phase 16** deletes `bubble_scaffold.dart`'s `PopScope`. It is not a second handler on a guarded route, so nothing here moves with it.
- If case 1 ever reds after this plan, look first at whether something started mutating summon state synchronously inside a pop callback — that is the failure mode this case was built to name.

## Self-Check: PASSED

All three files exist on disk (`browser_back_priority_test.dart` created; `browser_screen.dart` and `summon_back_guard.dart` modified) and both commits (`f16f2dd`, `4efdc05`) are present in git history.

---
*Phase: 13-summon-shell-bar*
*Completed: 2026-08-14*
