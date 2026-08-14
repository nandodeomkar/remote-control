---
phase: 13-summon-shell-bar
plan: 05
subsystem: testing
tags: [summon, back-guard, popscope, predictive-back, SUM-04, D-13-01, D-13-02, D-13-03, D-13-19]
status: complete

requires:
  - "13-01: SummonBackGuard, SummonShellController, SummonScope, SummonGuardScope, SummonRaise, the guard-id stack"
  - "13-02: SummonShell at MaterialApp.builder, kSummonSurfaceKey, kSummonTrackpadIconKey, pumpShell/contextOf/RecordingNavigatorObserver"
  - "13-03: kSummonRaiseDuration / kSummonLowerDuration as the settle budgets these cases pump past"
provides:
  - "test/shell/summon_back_guard_test.dart — the D-13-02 three-back ownership scenario, the D-13-03 orphan, the D-13-19 by-value stack, and the un-guarded dialog"
  - "test/shell/predictive_back_baseline_test.dart — the recorded setFrameworkHandlesBack baseline across raise and lower, plus the D-13-01 no-opt-in source guard"
  - "The falsified proof that `canPop: !raised` and `canPop: false` each turn a committed test red"
affects:
  - "Plan 13-06+ (pushGuarded and the un-wrapped-push scan): the guard-coverage suite builds on these scenarios"
  - "Phase 13 UAT: two hardware-only observations recorded below"
  - "Phase 18 / any later PopScope work: the browser's second PopScope must keep reading the same ownership predicate"

tech-stack:
  added: []
  patterns:
    - "Back gestures driven through `t.binding.handlePopRoute()`, whose return value IS the assertion: false means the framework declined and Android exits the app"
    - "Guard ids read through `SummonGuardScope` from a route's own context — the production question, never private state"
    - "`TargetPlatformVariant.only(...)` instead of a setUp/tearDown `debugDefaultTargetPlatformOverride` pair, because flutter_test verifies foundation debug vars at the end of the BODY"
    - "Every platform-channel capture asserts `isNotEmpty` first, with a reason naming the setup step whose absence emptied it"

key-files:
  created:
    - "app/remote_control/test/shell/summon_back_guard_test.dart"
    - "app/remote_control/test/shell/predictive_back_baseline_test.dart"
  modified: []

key-decisions:
  - "The lifecycle must be driven to resumed BEFORE the first pump, not after — 13-RESEARCH §10.3's ordering leaves the capture empty, because WidgetsApp latches the lifecycle once in initState and nothing re-dispatches the startup notification"
  - "The Android platform step is expressed as a TargetPlatformVariant, not a setUp assignment, so flutter_test's end-of-body debug-var invariant passes"
  - "'No retained Route' is proven by a source scan of the two shell files plus a behavioural assertion that the raise still records the DEAD id — absence of a live match is the mechanism, and nothing was cleared"
  - "The hub's guard id is captured BEFORE pushing, because an opaque route puts the route below offstage and a default Finder cannot reach it"

patterns-established:
  - "Falsification by mutation, recorded: each committed guard expression was replaced with its wrong form, the red line number recorded, and the tree restored"
  - "A test whose setup can silently disarm it asserts the disarming first"

requirements-completed: [SUM-04]

coverage:
  - id: D1
    description: "Back on the owning route lowers the surface; back on a route pushed after the raise pops that route normally with the surface riding along; back with nothing raised exits the app"
    requirement: "SUM-04"
    verification:
      - kind: unit
        ref: "test/shell/summon_back_guard_test.dart#1 — OWNERSHIP (D-13-02): three consecutive backs pop the pushed route with the surface still up, then lower, then exit"
        status: pass
    human_judgment: false
  - id: D2
    description: "An orphaned surface survives its owner's death un-owned, back then exits the app with it still up, and only the bar icon lowers it"
    requirement: "SUM-04"
    verification:
      - kind: unit
        ref: "test/shell/summon_back_guard_test.dart#2 — THE ORPHAN (D-13-03)"
        status: pass
    human_judgment: false
  - id: D3
    description: "Ownership retains no Route object: no live guard owns an orphaned raise, guard ids are removed by value under out-of-order disposal, and neither shell file names a Route type in code"
    verification:
      - kind: unit
        ref: "test/shell/summon_back_guard_test.dart#3a / #3b / #3c"
        status: pass
    human_judgment: false
  - id: D4
    description: "Modal routes stay deliberately un-guarded — a dialog is closed by the first back with the raised surface untouched"
    verification:
      - kind: unit
        ref: "test/shell/summon_back_guard_test.dart#4 — MODAL ROUTES STAY UN-GUARDED"
        status: pass
    human_judgment: false
  - id: D5
    description: "The framework's back claim is false on the hub with nothing raised, true while an owned surface is up, and false again after lowering"
    verification:
      - kind: unit
        ref: "test/shell/predictive_back_baseline_test.dart#1 / #2 / #3"
        status: pass
    human_judgment: false
  - id: D6
    description: "The phase enables nothing: no enableOnBackInvokedCallback attribute and no pageTransitionsTheme anywhere (D-13-01, T-13-11)"
    verification:
      - kind: unit
        ref: "test/shell/predictive_back_baseline_test.dart#4 — the phase enables nothing"
        status: pass
    human_judgment: false
  - id: D7
    description: "On hardware: the OS actually renders the back-to-home peek from the hub with nothing raised, and the raised surface renders correctly DURING that peek while the system compositor scales the app window"
    verification: []
    human_judgment: true
    rationale: "The system compositor's peek is drawn outside the Flutter frame — no widget test can observe it. 13-RESEARCH §10.3 states this explicitly and forbids asserting it."

metrics:
  duration: ~45min
  completed: 2026-08-14
  tasks: 2
  commits: 2
  files: 2

actuals:
  tokens: 7400
  tasks: 2
  commits: 2
---

# Phase 13 Plan 05: The Dismiss Vocabulary and the Predictive-Back Baseline Summary

**Back now resolves exactly one thing per gesture — proven by two committed suites whose red forms were produced by hand — and the framework's back claim is recorded as false / true / false across a raise and a lower, with a source guard that this phase enabled nothing.**

## Performance

- **Duration:** ~45 min
- **Completed:** 2026-08-14
- **Tasks:** 2
- **Files created:** 2

## Accomplishments

- **The inversion is now a red test.** `canPop` written as "anything is raised" no longer compiles into a silently trapped user — it fails at a named line with a reason naming Pitfall B.
- **The two decisions the ownership model was designed to make free are pinned as behaviour**, not as reasoning: a route pushed after the raise pops normally (D-13-02), and an orphaned surface survives its owner un-owned (D-13-03).
- **The predictive-back baseline is recorded**, not assumed: false on the hub with nothing raised, true while an owned surface is up, false again after lowering.
- **Two research-stated setup steps were corrected by measurement** rather than copied — the documented ordering would have left the baseline capture empty.

## Task Commits

1. **Task 1: The ownership scenario and the orphan scenario** — `c57136e` (test)
2. **Task 2: Record the predictive-back baseline** — `a2022ab` (test)

## Files Created

- `app/remote_control/test/shell/summon_back_guard_test.dart` — 6 cases: the D-13-02 three-back sequence, the D-13-03 orphan, D-13-19's absent-id proof in three parts (no live owner, by-value removal, a source scan), and the deliberately un-guarded dialog.
- `app/remote_control/test/shell/predictive_back_baseline_test.dart` — 4 cases: baseline / raised / restored across the platform channel, plus the D-13-01 manifest-and-theme guard.

`lib/` and `android/` are byte-identical to their pre-plan state — `git diff` over both is empty. This plan measures; it changes nothing.

## Key Implementation Details

**The three-back sequence, asserted step by step.** Each back's `handlePopRoute()` return value is itself an assertion. Back 1 returns true and pops the tool route with `controller.raised.value` still non-null. Back 2 returns true, lowers, and leaves `observer.pops` unchanged — one gesture, one thing, and that thing was the surface. Back 3 returns **false**, which is precisely "the framework declined and Android exits the app". A static `canPop: false` cannot produce that third value, and a `!raised` guard cannot produce the first.

**The orphan needs no machinery, and the test says so.** After the owning route is popped programmatically, the raise **still records the dead guard id** — case 2 asserts exactly that. Ownership evaporated because no *live* guard carries that id, not because anything was cleared. That is the sentence D-13-19 is made of, and it is now an `expect`.

**By-value removal, proven out of order.** Three routes are pushed, the *middle* one is removed with `Navigator.removeRoute`, and a fresh raise must land on the surviving pushed route. An index-based removal would have retired the wrong entry and left the stack pointing at a route that no longer exists. Popping the survivor and re-raising then lands on the hub, which pins the stack as exactly `[hub, second]` rather than merely "not obviously wrong".

**The hub's guard id is captured before the push.** An opaque `MaterialPageRoute` puts everything below it offstage in the `Overlay`, so `find.text('hub body')` with a default Finder finds nothing while a tool route is up. Reading the id first is not a convenience — reading it later throws.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] The lifecycle must be driven to resumed BEFORE the first pump**

- **Found during:** Task 2
- **Issue:** 13-RESEARCH §10.3's executable shape pumps the widget, *then* calls `handleAppLifecycleStateChanged(resumed)`, then asserts `handled.last`. Measured directly with a throwaway probe: in a widget test `WidgetsBinding.instance.lifecycleState` starts **null**, `WidgetsApp.initState` latches that null once (`widgets/app.dart:1468`), the startup notification is dropped by `_defaultOnNavigationNotification` (`:1443-1447`), and driving the lifecycle afterwards **re-dispatches nothing**. Probe trace with the research ordering: `after-pump=[]`, `after-resumed=[]`. The baseline case would have thrown `Bad state: No element`.
- **Fix:** The lifecycle is driven before `pumpShell` in all three widget cases, and the file's header states the mechanism with the framework line numbers. Probe trace with the corrected ordering: `after-pump=[false, false]`, `after-raise=[…, true]`, `after-lower=[…, true, false]`.
- **Files modified:** `test/shell/predictive_back_baseline_test.dart` (new file)
- **Verification:** All three cases green; removing the line reds case 1 at `Expected: non-empty / Actual: []`.
- **Committed in:** `a2022ab`

**2. [Rule 3 - Blocking] The platform override is a `TargetPlatformVariant`, not a `setUp` assignment**

- **Found during:** Task 2
- **Issue:** `debugDefaultTargetPlatformOverride` set in `setUp` and cleared in `tearDown` failed **every** widget case with *"The value of a foundation debug variable was changed by the test"* — `flutter_test` verifies foundation debug vars at the end of the test **body** (`binding.dart:1973` → `foundation/debug.dart:45`), which is before any `tearDown` runs.
- **Fix:** `TargetPlatformVariant.only(TargetPlatform.android)` on the three widget cases; it sets and restores inside the body's scope (`widget_tester.dart:306-313`), which is the framework's own answer to this.
- **Files modified:** `test/shell/predictive_back_baseline_test.dart` (new file)
- **Verification:** 4/4 green; `flutter analyze` clean.
- **Committed in:** `a2022ab`

---

**Total deviations:** 2 auto-fixed (1 bug in a cited research shape, 1 blocking framework constraint)
**Impact on plan:** Both are corrections to *how* the plan's stated assertions are made observable. No assertion was weakened, dropped or added beyond the plan's four-plus-three case list. No production code touched.

## Manual Falsification (the acceptance criteria's required confirmations)

Every mutation was applied to the tree, run, and reverted; `git diff` over `lib/` is empty afterwards.

| Mutation | Result |
|---|---|
| `canPop: !(raise != null && raise.ownerGuardId == id)` → **`!(raise != null)`** (the "anything raised" inversion) | Case 1 RED at **line 154** — `find.text('tool body')` still finds the tool route after back 1, i.e. the surface was dismissed instead of the route popping and the user is trapped on the tool screen. Case 2 also RED at line 259. **This is the criterion the plan asked to confirm.** |
| `canPop:` → **constant `false`** | Case 1 RED at line 154 and case 2 RED at **line 259** (`handled` was true where the app should have exited) — T-13-05's "the hub never traps the user", falsified. |
| Baseline suite: **lifecycle drive removed** from case 1 | RED — `Expected: non-empty / Actual: []`, with the reason string naming the missing setup step. |
| Baseline suite: **platform variant flipped** to `TargetPlatform.windows` | RED — same empty capture, because `setFrameworkHandlesBack` returns early off Android (`system_navigator.dart:31-43`). |

**Honest correction to the plan's wording.** The plan predicted that removing either setup step would make the baseline case *"pass vacuously"*. It does not — because each case asserts `isNotEmpty` first, both removals fail **loudly**, naming the cause. That guard was added deliberately: without it the failure is an opaque `Bad state: No element`, which is the shape a future maintainer "fixes" by deleting the assertion.

**A second correction, recorded rather than absorbed.** The Android platform override is a **pin, not a fix**, on this toolchain: `flutter test` already forces `TargetPlatform.android` via the `FLUTTER_TEST` environment check in `foundation/_platform_io.dart`. Removing the variant would therefore *not* red the suite today. It is kept — and the header says exactly this — because the suite must not silently depend on an implicit environment default, and forcing a non-Android target was verified to empty the capture entirely.

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/shell/summon_back_guard_test.dart` | 6 cases, all passed |
| `flutter test test/shell/predictive_back_baseline_test.dart` | 4 cases, all passed |
| `flutter test test/shell` | 65 tests, all passed (59 before this plan + 6) |
| `flutter test` (full suite) | **951 passed** (941 before this plan + 10) |
| `flutter analyze --no-fatal-infos` | No issues found |
| `! grep -q 'enableOnBackInvokedCallback' android/app/src/main/AndroidManifest.xml` | succeeds |
| `! grep -Eq 'pageTransitionsTheme\|PredictiveBackPageTransitionsBuilder' lib/theme/tokens.dart` | succeeds |
| `git diff` over `lib/` and `android/` | empty — this plan changed no production code |

## Success Criteria

- [x] Back lowers a raised surface on the owning route and pops normally on every other route
- [x] An orphaned surface survives its owner's death and is dismissible only by the icon tap
- [x] The framework's back claim is false on the hub with nothing raised, before and after any raise
- [x] The manifest and the theme are untouched

## Requirements Completed

- **SUM-04** — the Android back gesture dismisses a raised surface before it pops the screen, with the ownership rule and the orphan trade both pinned as behaviour

## Threat Mitigations

| Threat ID | Disposition | Status |
|---|---|---|
| T-13-05 (a `canPop` that traps the user, or that kills the back-to-home peek) | mitigate | **Mitigated** — case 1's third back asserts the app exits with nothing raised, case 2's back asserts it exits with an orphan up, and the baseline suite asserts the engine claim returns to false after a lower. Both wrong `canPop` forms were hand-applied and each reds a committed line. |
| T-13-11 (scope creep into the Android manifest) | mitigate | **Mitigated** — case 4 scans the manifest for `enableOnBackInvokedCallback` and the whole of `lib/` for `pageTransitionsTheme` / `PredictiveBackPageTransitionsBuilder`. Both absent; `git diff` over `android/` is empty. |
| T-13-SC (package-manager installs) | accept | No installs; `pubspec.yaml` unchanged. |

## Threat Flags

None — this plan adds no network endpoint, auth path, file access or schema change. It adds two test files and touches no production code.

## Known Stubs

None. Both suites assert real behaviour through the real shell, the real guard and the real controller.

## Hardware-only observations for the UAT plan

Neither is assertable in a widget test (13-RESEARCH §10.3 states this and forbids trying):

1. **Does the OS actually render the back-to-home peek** from the hub with nothing raised? The widget suite proves only that Flutter does not *claim* the gesture; whether Android draws the peek is a system-compositor behaviour outside the Flutter frame.
2. **Does the raised surface render correctly *during* that peek**, while the system compositor is scaling the app window? This is the one place the new chrome could look wrong without any test noticing — the surface, the bar and the shrinking window are composited by three different parties.

## Deferred Ideas (filed, not absorbed)

- **In-app route predictive peek has never existed in this app.** `buildAppTheme()` declares no `pageTransitionsTheme` and no `PredictiveBackPageTransitionsBuilder` — verified by a repo-wide scan over `lib/`, now a committed assertion. It therefore cannot regress, and SC3 can only be measuring the system back-to-home layer. Enabling it properly (the manifest attribute plus the transitions builder) stays a deferred idea with its evidence attached, per D-13-01 — **not** work for this phase.

## Next Phase Readiness

- The ownership predicate is now pinned from both directions: the guard's behaviour and the engine flag it produces. Any later plan that adds a second `PopScope` (the browser's, D-13-05) must read the same `SummonScope.ownsRaisedSurface` predicate; if it invents a "consumed" latch instead, case 1 and case 4 are where it will show.
- `summon_back_guard_spike_test.dart` (13-01) overlaps these scenarios deliberately — it is the *tracer* that settled the host shape, this is the *contract*. Neither was collapsed into the other; if the spike ever goes red the host shape changed, and if only this suite reds the predicate did.

## Self-Check: PASSED

Both created files exist on disk and both commits (`c57136e`, `a2022ab`) are present in git history. No production file was modified.

---
*Phase: 13-summon-shell-bar*
*Completed: 2026-08-14*
