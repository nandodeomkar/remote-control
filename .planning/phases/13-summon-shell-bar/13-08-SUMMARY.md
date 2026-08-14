---
phase: 13-summon-shell-bar
plan: 08
subsystem: testing
tags: [summon, overlay, hit-testing, BAR-01, BAR-05, SUM-01, SUM-02, test-migration, backstop]
status: complete

requires:
  - "13-01: kSummonBarHeight, the +56 reservation, and the recorded pre/post full-suite backstop"
  - "13-02: SummonShell at MaterialApp.builder, summon_shell_test.dart, summon_test_harness.dart"
  - "13-03: the raise/lower/swap motion this suite lands on before every geometry assertion"
  - "13-07: pushGuarded, which the hub-grid reach case's tile tap now travels through"
provides:
  - "The surviving hit-testability contract (C4) in the successor suite, with its complementary negative and a nothing-raised control"
  - "The no-reflow contract: a body widget's Rect is byte-identical across a raise"
  - "The route-STACK-length assertion for SUM-01, beside the existing mutation counter"
  - "The three named SC1 reach cases at 360x640, all three hand-falsified red"
  - "test/widget_test.dart as the BAR-01 end-to-end anchor through main.dart"
  - "deferred-items.md — the pre-existing 360dp macro-grid overflow, classified"
affects:
  - "Phase 16 (bubble retirement): C1/C3/C4 are transcribed and ticked here; C5 lives in summon_back_guard_test.dart. widget_test.dart must be RE-RUN, not deleted"
  - "Phase 14/15: the inside-the-surface negative is the contract a filled surface must keep, not one it may drop"

actuals:
  tokens: 11700
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "A negative hit-test case carries a nothing-raised CONTROL tap, so a target that was never tappable cannot pass for 'the overlay swallowed it'"
    - "A tolerated exception is drained by a helper that ASSERTS what it swallows — horizontal overflow only; a vertical one, the failure under test, still reds"
    - "Reach cases jump the scroll position to maxScrollExtent rather than dragging: an under-shooting drag passes without ever testing reach"
    - "Every reach case is hand-falsified by deleting the reservation it exists to guard, and the ones that stayed green were strengthened until they did not"

key-files:
  created:
    - ".planning/phases/13-summon-shell-bar/deferred-items.md"
  modified:
    - "app/remote_control/test/shell/summon_shell_test.dart"
    - "app/remote_control/test/widget_test.dart"

key-decisions:
  - "The two browser reach cases also assert the PINNED macro footer clears the bar. Deleting the reservation left both of them green — the browser's scroll region is bounded by that footer, not by the safe area, so its last row cannot be stranded no matter what the reservation does. Without the footer line the two cases SC1 names would have been a green that measures nothing."
  - "The 12px horizontal macro-grid overflow at 360dp width is drained, not fixed: it reproduces identically with no shell mounted at all, and editing browser_screen.dart would destroy the zero-per-screen-edit property BAR-05 depends on."
  - "widget_test.dart's pump was extracted into _pumpApp so the new BAR-01 case pumps byte-identically to the homing case; no assertion or comment was dropped."
  - "The wider 'nothing clipped on all fourteen screens' claim stays closed by the BACKSTOP plus these three named cases — deliberately neither fourteen assertions nor one aggregate. Recorded so it is not silently upgraded or downgraded later."

patterns-established:
  - "Control-then-negative: prove the target is reachable with nothing raised before asserting it is unreachable with something raised"
  - "Falsify the reach case by deleting the reservation, not by trusting the number"

requirements-completed: [BAR-01, BAR-05, SUM-01, SUM-02]

coverage:
  - id: D1
    description: "A tappable widget OUTSIDE a raised surface still receives its tap, and one INSIDE it does not — the contract that proves overlay-not-screen, carried into its successor before Phase 16 deletes the original"
    requirement: "SUM-02"
    verification:
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#SUM-02: a tappable widget in the body outside the surface still receives its tap while a surface is raised"
        status: pass
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#SUM-02: a tappable widget INSIDE the raised surface's rect does not receive the tap — the slab is above it"
        status: pass
    human_judgment: false
  - id: D2
    description: "Nothing beneath a raised surface resizes or reflows: a bottom-aligned body widget's Rect is identical before and after a raise"
    requirement: "SUM-02"
    verification:
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#SUM-02: nothing beneath the surface RESIZES — a body widget's Rect is identical before and after a raise"
        status: pass
    human_judgment: false
  - id: D3
    description: "Raising navigates nowhere — the route STACK LENGTH is unchanged across a raise and a lower, beside the existing zero-mutations assertion"
    requirement: "SUM-01"
    verification:
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#SUM-01: raising navigates NOWHERE — no push, pop, replace or remove crosses a raise or a lower"
        status: pass
    human_judgment: false
  - id: D4
    description: "The browser tab list, the browser bookmarks section and the already-scrolling hub grid each reach their last item at 360x640 with the bar present, and that item still reaches its handler"
    requirement: "BAR-05"
    verification:
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#BAR-05/SC1: the browser TAB LIST reaches its last row at 360x640 with the bar present, and that row is hit-testable"
        status: pass
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#BAR-05/SC1: the browser BOOKMARKS section reaches its last row at 360x640 with the bar present, and that row is hit-testable"
        status: pass
      - kind: unit
        ref: "test/shell/summon_shell_test.dart#BAR-05/SC1: the already-scrolling HUB GRID reaches its last tile at 360x640 with the bar present, and that tile is hit-testable"
        status: pass
      - kind: command
        ref: "manual falsification — the +56 MediaQuery reservation deleted from summon_shell.dart; all three cases RED at 576.0 vs a bar top of 536.0; tree restored, git diff over lib/ empty"
        status: pass
    human_judgment: false
  - id: D5
    description: "The bar renders on the hub through the REAL application widget — both icon slots by key, and the bar's rendered height equal to the declared constant"
    requirement: "BAR-01"
    verification:
      - kind: unit
        ref: "test/widget_test.dart#BAR-01: the summon bar renders on the hub through the REAL application widget"
        status: pass
      - kind: command
        ref: "manual falsification — the SummonShell mount removed from main.dart; widget_test.dart RED while test/shell/summon_shell_test.dart stayed fully green; tree restored"
        status: pass
    human_judgment: false
  - id: D6
    description: "Nothing is clipped or stranded behind the bar across all fourteen screens"
    requirement: "BAR-05"
    verification:
      - kind: command
        ref: "BACKSTOP — the full-suite run recorded immediately before and immediately after the reservation landed (13-01), plus D4's three named cases. 962 tests pass after this plan (956 + 6)."
        status: pass
    human_judgment: true
    rationale: "A rendering claim across fourteen screens is not closed by any assertion this plan could write. The owner-directed shape of this evidence is the recorded before/after suite plus three hand-named cases; the remaining eleven screens are a UAT observation on hardware, not a test."

metrics:
  duration: ~50min
  completed: 2026-08-14
  tasks: 2
  commits: 2
  files: 3
---

# Phase 13 Plan 08: The Overlay Contracts and the Named Reach Cases Summary

**The milestone's most valuable test — a tap outside a raised surface still lands — now lives in the suite that survives Phase 16, with the negative it was missing; and the three surfaces SC1 names by hand all reach their last item at 640dp, each proved red by deleting the reservation.**

## Performance

- **Duration:** ~50 min
- **Completed:** 2026-08-14
- **Tasks:** 2
- **Files created:** 1, modified: 2
- **Suite:** 956 → **962** green

## Task Commits

1. **Task 1: The overlay contracts and the three named reach cases** — `df0c67c` (test)
2. **Task 2: Prove the bar on the real application widget** — `35da6c9` (test)

## What Was Built

### Task 1 — `test/shell/summon_shell_test.dart`, 8 cases → 13

**The successor header.** The file now states in its own header that it is the successor of `test/bubble_scaffold_test.dart`, with a fate per contract rather than a vague "covers roughly the same ground":

| | Contract | Where it landed |
|---|---|---|
| C1 | presence | Bubble half **dies**. The `UipiBanner` host half is asserted here (SAFE-03), so Phase 16 cannot delete the SRV-05 advisory by accident |
| C2 | absence | **Dies** — `showBubble` ceases to exist |
| C3 | expand toggle | **Mutated** into the raise/lower toggle case, plus `summon_motion_test.dart`'s swap accounting |
| C4 | body-hit-testable | **Survives**, and is now a PAIR — see below |
| C5 | back-intercept | **Mutated** into `test/shell/summon_back_guard_test.dart`. It does NOT live here, and the header says so |

**C4, and the half it was missing.** The positive case (a target outside the surface still fires, counter exactly 1) already existed from 13-02. On its own it is also satisfied by an overlay that swallows *nothing* — a different defect wearing the same green, where the user taps an opaque slab and the hub tile underneath opens. The new negative asserts a target inside the surface's rect gets **zero** taps, and carries a **nothing-raised control tap** first: without the control, a target that was mis-placed, zero-sized or behind the bar would pass the negative for entirely the wrong reason.

The mechanism is now written on the case, because it was measured rather than assumed: the slab's own `BoxDecoration` makes `RenderDecoratedBox.hitTestSelf` return true inside its rect, and a `Stack` hit-tests in reverse paint order, so the surface consumes the tap before the `Navigator` sees it. (Confirmed by a throwaway probe that printed the hit-test path terminating at `RenderDecoratedBox`; probe deleted.)

**The no-reflow contract.** A **bottom-aligned** body widget's `Rect` is captured before a raise and again with the surface fully raised, and asserted identical within 0.01 on all four edges. Bottom-aligned deliberately: a resize contract would move exactly this widget and leave a centred one alone. The reason on the case states why this is not an IME-style resize contract — nothing on the phone is the input target, so there is no field to keep visible, and converting "raise in place" into a resize would make every tool screen scrollable for a problem this app does not have.

**The no-navigation contract.** The existing case asserted the observer's mutation counter. It now also asserts the **route stack length**, via a second observer that tracks the live stack. The two are complementary and the reason says how: a push immediately followed by a pop leaves the counter changed and the length identical; a push without a matching pop leaves the counter unchanged only if nothing else moved. Neither alone is "raising navigates nowhere".

**The three named 640dp reach cases.** Each drives a real screen under the production shell shape (`MaterialApp.builder` → `SummonShell`, root route guarded) at 360x640 with a 48dp gesture-nav inset, jumps the scroll region to `maxScrollExtent`, and asserts (a) the region genuinely scrolls, (b) the last row's bottom edge is at or above the bar's top edge, (c) tapping that row reaches its handler:

| Surface | Last item | Handler proof |
|---|---|---|
| Browser tab list | `Tab 11` of 12 | `TabsActivateMsg(id: 11)` recorded |
| Browser bookmarks | `Link 19` inside `Bookmarks bar` | `BmOpenMsg(nodeId: 'b19')` recorded |
| Hub grid | the last `kHubTiles` entry | the guarded route pushed (stack depth +1) |

A **jump**, not a drag: a drag that under-shoots would leave the last row above the fold and the reach assertion would pass without ever testing reach.

**No screen was edited.** `git diff --name-only -- lib/` is empty for this plan, asserted in the exit-code form the plan specifies. A per-screen fix here would have destroyed the zero-per-screen-edit property the reservation depends on.

### Task 2 — `test/widget_test.dart`

A second `testWidgets` asserts, against `RemoteControlApp` itself, that the hub renders, that `kSummonBarKey` resolves once, that both icon slot keys resolve, and that the **rendered** bar height equals `kSummonBarHeight`. The existing pump was extracted into `_pumpApp` so both cases pump byte-identically; every prior assertion and every prior comment is present unchanged, and `test/hub_offline_test.dart` was re-run untouched (2 cases, green — no finder assumed the old geometry).

The header records why this file matters: it is the **only** test that pumps `main.dart`'s entry point, so it is the only place BAR-01 is proved through production wiring rather than through a harness that mounts `SummonShell` itself.

## The falsifications — every reach claim proved red by hand

Each mutation was applied, run, and reverted; `git status` over `lib/` is clean afterwards.

| Mutation | Result |
|---|---|
| The +56 `MediaQuery` reservation deleted from `summon_shell.dart` | **Hub grid RED** — last tile bottom `576.0` against a bar top of `536.0`, stranded by 40px. The inside-the-surface control also reds (its target moves under the bar). **This is the failure the cases exist to catch.** |
| Same mutation, first attempt at the browser cases | **GREEN — and that is why the footer assertion exists.** See below. |
| Same mutation, after the footer assertion was added | **Both browser cases RED**, `576.0` vs `536.0` |
| The `SummonShell` mount removed from `main.dart` | **`widget_test.dart` RED**, while `summon_shell_test.dart` stayed **fully green** — the anchor property, demonstrated rather than asserted |

**The browser finding, stated plainly.** With the reservation deleted, both browser reach cases stayed green. The browser's scroll region is bounded by its **pinned macro-grid footer**, not by the safe area, so its last list row cannot be stranded no matter what the reservation does — the footer is what a lost reservation actually buries on that screen, and losing back/forward/refresh entirely is worse than a list ending one item early. Both cases now also assert the footer's bottom edge clears the bar, and the comment on the helper records the falsification that forced it. Two of the three cases SC1 names would otherwise have been a green that measured nothing.

## The BAR-05 backstop — recorded, so it is not re-litigated

The wider claim — *nothing clipped or stranded on all fourteen screens* — is closed by:

1. the **backstop**: the full-suite run recorded immediately before and immediately after the reservation landed in plan 13-01, plus
2. the **three named cases** above.

It is **not** closed by fourteen hand-written assertions, and it is not closed by one aggregate assertion either. That is the owner-directed shape of this evidence and it should not be silently upgraded or downgraded by a later phase. The eleven unnamed screens remain a UAT observation on hardware (coverage `D6`, `human_judgment: true`).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] The two browser reach cases asserted nothing against the failure they exist to catch**

- **Found during:** Task 1, at the hand-falsification step.
- **Issue:** with the +56 reservation deleted from `summon_shell.dart`, the hub-grid case went red as designed but **both browser cases stayed green**. The browser's `SingleChildScrollView` is bounded by the pinned macro-grid footer rather than by the safe area, so its last row is structurally incapable of being stranded — the assertion was true for a reason unrelated to the reservation.
- **Fix:** both cases now also assert `BrowserMacroGrid`'s bottom edge is at or above the bar's top edge, via one shared helper whose doc comment records the falsification that forced it.
- **Files modified:** `test/shell/summon_shell_test.dart` (in the plan's `files_modified`).
- **Verification:** re-falsified — both cases now RED at `576.0` vs `536.0` with the reservation deleted, green with it restored.
- **Committed in:** `df0c67c`

**2. [Rule 3 - Blocking] A pre-existing horizontal overflow at 360dp width failed both browser cases**

- **Found during:** Task 1, first run of the reach cases.
- **Issue:** `BrowserMacroGrid` throws `A RenderFlex overflowed by 12 pixels on the right` at 360dp width under the widget-test font (`browser_screen.dart:377`), which fails any test that renders it. The existing browser suite never saw it because it drives 800x1600.
- **Fix:** `drainPreExistingHorizontalOverflow` drains exactly that exception and **asserts what it swallows** — the message must say `on the right`. The reservation is vertical only and changes no horizontal constraint, so a vertical overflow (the failure under test) does not match and still fails.
- **Why not fixed:** verified pre-existing by hand — it reproduces identically against a bare `MaterialApp(home: BrowserScreen())` with **no shell mounted at all** at the same viewport, one exception, same 12px. Fixing it means editing a screen, which is exactly what BAR-05's zero-per-screen-edit property forbids and what this plan's `git diff -- lib/` verify exists to prevent. Logged to `deferred-items.md` (D1) instead.
- **Files modified:** `test/shell/summon_shell_test.dart`; `.planning/phases/13-summon-shell-bar/deferred-items.md` (new).
- **Committed in:** `df0c67c`

**3. [Rule 3 - Blocking] Row press-flash timers left pending at teardown**

- **Found during:** Task 1, second run.
- **Issue:** the browser rows fire a 100ms accent press flash from `onTapDown`; the reach cases' taps left that timer pending and `flutter_test` asserts `!timersPending`.
- **Fix:** one explicit `pump(kRowFlash)` after each row tap — **after** the geometry assertions, never before, so no settle precedes a measurement.
- **Committed in:** `df0c67c`

### Additions recorded rather than silently absorbed

**C1's surviving half was ticked, not just named.** The plan asks the header to name which of the retiring suite's contracts land here. Naming `UipiBanner` as landing here without asserting it would have been a claim the file did not keep, so the BAR-01 case gained one `find.byType(UipiBanner)` expectation. It closes a Phase 16 exit-condition line early and costs one line.

---

**Total deviations:** 3 auto-fixed (1 missing-critical assertion, 2 blocking test-environment constraints), plus 1 recorded addition.
**Impact on plan:** no production code changed — `git diff --name-only -- lib/` is empty. No assertion anywhere was weakened, dropped or re-pinned; the only change of strength was upward.

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/shell/summon_shell_test.dart` | **13 cases**, all passed |
| `flutter test test/shell` | **74 tests**, all passed |
| `flutter test test/widget_test.dart test/hub_offline_test.dart` | **5 tests**, all passed |
| `flutter test` (full suite) | **962 passed** (956 before this plan + 6) |
| `flutter analyze --no-fatal-infos` | No issues found |
| `test -z "$(git diff --name-only -- lib/)"` | succeeds — exit-code form, not a printed count |
| `grep -c 'kSummonBarKey' test/widget_test.dart` | **2** (≥ 1) |
| `git status --porcelain -- test/hub_offline_test.dart` | empty — re-run unchanged, no finder repaired |

## Success Criteria

- [x] A tappable widget outside a raised surface still receives its tap, and one inside does not
- [x] A body widget's rect is identical before and after a raise
- [x] The browser tab list, the bookmarks section and the hub grid all reach their last item at 640dp with the bar present
- [x] The bar is proved present through the real application widget, and no screen was edited to achieve any of it

## Requirements Completed

- **BAR-01** — the bar proved present end to end through `main.dart`, by key, at its declared height
- **BAR-05** — the reservation reaches real content on a real short viewport, closed by the backstop plus three named cases
- **SUM-01** — raising navigates nowhere: zero route mutations AND an unchanged stack length
- **SUM-02** — overlay-not-screen: the hit-test pair, plus the no-reflow contract

## Threat Mitigations

| Threat ID | Disposition | Status |
|---|---|---|
| T-13-14 (host content stranded behind the bar) | mitigate | **Mitigated** — three named 640dp reach cases, each hand-falsified red by deleting the reservation, plus the recorded backstop. No per-screen fix was made; `lib/` is byte-identical |
| T-13-15 (a raised surface swallowing taps meant for the screen beneath) | mitigate | **Mitigated** — the C4 pair with a control tap, carried into the successor suite before the original is deleted |
| T-13-SC (package-manager installs) | accept | No installs; `pubspec.yaml` unchanged |

## Threat Flags

None — this plan adds no network endpoint, auth path, file access or schema change. It is test-only.

## Known Stubs

None. Every case drives a real screen or the real application widget; nothing renders a placeholder or defers a data source.

## Notes for Next Phase

- **Phase 16 must RE-RUN `test/widget_test.dart`, not delete it.** It is the BAR-01 end-to-end anchor and the only test that sees `main.dart`'s shell mount; the header says so in-file.
- **Phase 16's C1-C5 tick-off is already done** for C1 (the surviving `UipiBanner` half), C3 and C4. C5 lives in `test/shell/summon_back_guard_test.dart`. What remains before deleting `bubble_scaffold_test.dart` is confirming C2 genuinely has no successor — it does not; `showBubble` ceases to exist.
- **Phases 14 and 15 inherit the inside-the-surface negative as a contract to KEEP.** A filled surface must still absorb taps in its own rect; today that comes free from the slab's `BoxDecoration`, so a refactor that makes the slab decoration-less would silently break it and the negative is what catches that.
- **`deferred-items.md` D1** is open: the 360dp macro-grid overflow. It is very probably a test-font artefact (the same trap 13-UI-SPEC flags for Phase 18's chip row) — confirm on hardware before spending anything on it.
- **Plan 13-04 is still outstanding.** This plan completes 13-08 only; the phase is not contiguous.

## Self-Check: PASSED

`.planning/phases/13-summon-shell-bar/deferred-items.md`, `test/shell/summon_shell_test.dart` and `test/widget_test.dart` all exist on disk; both commits (`df0c67c`, `35da6c9`) are present in git history. Neither commit deletes a tracked file (`git diff --diff-filter=D` over the pair is empty). Both throwaway probes written during Task 1 were deleted and are confirmed absent from `test/shell/`.

---
*Phase: 13-summon-shell-bar*
*Completed: 2026-08-14*
