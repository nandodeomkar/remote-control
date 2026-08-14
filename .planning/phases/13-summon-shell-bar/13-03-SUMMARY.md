---
phase: 13-summon-shell-bar
plan: 03
subsystem: flutter-app-shell
tags: [summon, motion, animation, swap, dismiss-seam, MOT-01, SUM-03, D-13-10]
status: complete

requires:
  - "13-01: SummonShellController, SummonScope, SummonSurfaceKind, SummonRaise"
  - "13-02: SummonShell, SummonSurface, summon_geometry.dart, summon_test_harness.dart"
provides:
  - "The swap AnimationController (_swap) — D-13-10's one motion, in place, never a lower-then-raise"
  - "The kind-typed lerp endpoints (_fromKind/_toKind), re-derived from live metrics every build"
  - "The single onSurfaceDismissed seam, invoked from exactly two call sites in SummonShell"
  - "test/shell/summon_motion_test.dart — MOT-01's falsifiable timing discriminators"
affects:
  - "Phase 14: TrackpadCoreState.dismissed() wires to onSurfaceDismissed (drag-lock flush, keep-awake release)"
  - "Phase 15: KeyboardInputController.dismissed() wires to the same seam (modifier release)"
  - "Plan 13-04 Task 2: the F4 retarget discriminator drives the derivation this plan preserved"

tech-stack:
  added: []
  patterns:
    - "Two AnimationControllers, one surface: _raise owns the translate, _swap owns the height"
    - "Lerp endpoints stored as enum kinds, never as dp figures — the snapshot anti-pattern, structurally excluded"
    - "Nested AnimatedBuilders: outer on the swap (runs only while the height changes), inner on the raise with a cached child"
    - "Falsifiable timing tests: every budget pinned by an assertion a wrong duration reds, verified by hand-mutating the constant"

key-files:
  created:
    - "app/remote_control/test/shell/summon_motion_test.dart"
  modified:
    - "app/remote_control/lib/shell/summon_shell.dart"
    - "app/remote_control/lib/shell/summon_scope.dart"

decisions:
  - "The shell owns both dismiss-seam call expressions; SummonShellController's two invocations were removed so each departing surface reports exactly once"
  - "The surface Positioned carries no explicit height — the slab sizes itself from the swap lerp, keeping one derivation site"
  - "An _armingSwap flag distinguishes the deliberate rewind-to-0 that starts a swap from a settled reverse, which report the same AnimationStatus"
  - "The dismiss's at-rest assertion at the 160ms mark reads through a loweredTop() helper, because the shell unmounts the slab the instant the lower settles"
  - "No reduced-motion branch — recorded in-file as a decision, per 13-UI-SPEC rule 7"

metrics:
  duration: ~55min
  completed: 2026-08-14
  tasks: 2
  commits: 2
  files: 3

actuals:
  tokens: 34000
  tasks: 2
  commits: 2
---

# Phase 13 Plan 03: Motion, Swap and the Dismiss Seam Summary

The summon's 200ms raise, 150ms lower and 200ms in-place swap are now each pinned by an assertion that a wrong duration turns red, and one named dismiss seam reports the outgoing surface on both the lower edge and the swap edge.

## What Was Built

**Task 1 — `summon_shell.dart` (commit `41ac6d7`).** A second `AnimationController`, `_swap`, at `kSummonSwapDuration` resting at `value: 1`. During a swap the raise controller is untouched at 1, so the surface resizes to the other surface's height without ever leaving the bar's top edge — one motion, with no lower-then-raise anywhere in the code path.

The two lerp endpoints are stored as `SummonSurfaceKind`s (`_fromKind`, `_toKind`) and nothing about the surface's size is stored at all. Both are resolved against the live `available` inside `build`, on every build, through `summonSurfaceHeight(...)` and lerped by `Curves.easeOut.transform(_swap.value)`. That is what keeps the rendered height a build-time derivation in **both** regimes — at rest (`_swap.value == 1`, the identity lerp is still evaluated) and mid-swap.

The three transitions land in `_onRaisedChanged`:

- **Raise** — both endpoints become the raised kind, `_swap.value = 1`, `_raise.forward()`.
- **Lower** — `_raise.reverse()` from the live value; no queue, no lockout.
- **Swap** — endpoints are reassigned, `_swap` runs 0 → 1, `_raise` is never touched.

Mid-swap the two taps are served as different requests, exactly as the plan specifies: the **origin** icon reverses `_swap` from its live value (a swap back, no size ever captured mid-flight); the **destination** icon is a lower, reversing `_raise` immediately while `_swap` runs on to completion underneath — neither cancelled nor held.

The surface layer became nested `AnimatedBuilder`s: the outer one listens to `_swap` and runs only while the height is actually changing, so a plain raise still builds the slab exactly once and pays only the inner translate — 13-02's cached-child rule, preserved.

**Task 2 — `test/shell/summon_motion_test.dart` (commit `f6dc85e`).** Five cases, 442 lines, every expected number computed from the driven metrics through the harness helpers and no absolute pixel figure quoted anywhere:

1. The 200ms summon discriminates against an instant cut (still fully lowered at frame 0), a delayed cut (moved by t=100), a too-fast cut (not at final geometry at t=100) and anything past 250ms.
2. The 150ms dismiss is pinned by the assertion at the 160ms mark — `kDismissRestMark`, a constant declared in the test file for that purpose, not `kSummonLowerDuration`.
3. The swap asserts bar-adjacency on **every** 25ms step, that `surfaceRect.bottom - barRect.top` (which *is* the raise controller's translate offset) stays 0 throughout, that the height never dips below the smaller of the two surfaces, and that at least one frame sits strictly between the two heights — so a cut fails too.
4. Mid-raise reverse settles in less than a full lower duration; the mid-swap destination tap produces no rendered-height jump on the tap frame and starts lowering on that frame.
5. Seam accounting: a plain lower reports once, the swap edge reports the origin kind, and a mid-swap destination tap reports the destination kind once more — never twice, never zero times.

## Key Implementation Details

**The seam moved from the controller to the shell.** `SummonShellController.raise()` and `.lower()` each carried an `onSurfaceDismissed?.call(...)`. The plan requires exactly two call expressions in `summon_shell.dart`; leaving the controller's in place would have reported every departing surface **twice**, which is worse than zero times — Phase 15 would release a modifier that a later frame re-holds. The two invocations were removed from `summon_scope.dart` and the seam's doc comment now states in one sentence that the shell owns both call sites and why. No test referenced the controller-side invocation, so nothing else moved.

**`_armingSwap`.** Starting a fresh swap requires rewinding `_swap` to 0, and `AnimationController` reports that rewind as `AnimationStatus.dismissed` — the same status a *settled reverse* reports. Without the flag, `_onSwapStatus` read the rewind as "the swap ended where it began", collapsed both endpoints onto the outgoing kind, and the swap then ran its full 200ms between two identical heights: the surface never resized. This was caught by 13-02's existing I1 test (expected 432, got 280) on the first run of the shell suite, which is exactly what that test is for.

**`Positioned` without `height`.** The slab's height is now animated by the swap, so stating it on the `Positioned` as well would be a second derivation site. `left`/`right`/`bottom` fix everything else and the child sizes itself.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Removed the duplicate dismiss-seam invocations from `SummonShellController`**
- **Found during:** Task 1
- **Issue:** `summon_scope.dart:161` and `:174` already invoked `onSurfaceDismissed`. The plan requires the shell to invoke it from the lower path and the swap path through exactly one call expression each; both sites live would have double-reported every departing surface.
- **Fix:** Removed both invocations from `raise()` and `lower()`; updated the seam's doc comment and both method docs to state that `SummonShell` owns the call sites and why (the seam reports a surface *leaving the screen*, and the shell is what knows about the screen).
- **Files modified:** `app/remote_control/lib/shell/summon_scope.dart` (not in the plan's `files_modified`)
- **Commit:** `41ac6d7`

**2. [Rule 1 - Bug] Added `_armingSwap` to distinguish a swap's starting rewind from a settled reverse**
- **Found during:** Task 1
- **Issue:** `_swap.forward(from: 0)` reports a transient `dismissed`, which `_onSwapStatus` collapsed as if a reverse had settled — every swap then animated between two identical heights and never resized.
- **Fix:** A `bool _armingSwap` guard around the explicit rewind; `_onSwapStatus` returns early while it is set.
- **Files modified:** `app/remote_control/lib/shell/summon_shell.dart`
- **Commit:** `41ac6d7`

### Interpretations recorded rather than silently absorbed

**The dismiss's "at rest within 0.5px at t=160" reads through a helper.** The shell unmounts the slab the instant the lower settles (13-02's contract, and the reason the slab is never yanked out from under its own exit animation), so at t=160 there is no rect to measure. The test's `loweredTop()` returns the measured top when the slab is mounted and the fully-lowered top when it is not — "gone" and "at the fully-lowered position" are the same fact one frame apart. This is not a loophole: a 200ms dismiss is *still mounted* at t=160 and measurably above the bar, which is precisely how it fails. Confirmed by hand (below). The case also asserts `findsNothing` at the same mark.

**`pumpAndSettle` could not even be named in a comment.** The plan's verify is a literal `! grep -q 'pumpAndSettle'` with no comment exclusion, so the header's ban paragraph deliberately does not spell the token.

## Manual Falsification (the acceptance criterion's required confirmation)

Each mutation was applied to the tree, run, and reverted:

| Mutation | Result |
|----------|--------|
| `kSummonLowerDuration` 150 → **200** | Case 2 RED (`Actual: 759.98` vs the bar's top edge) and case 4 RED. **This is the criterion the plan asked to confirm.** |
| `kSummonRaiseDuration` 200 → **300** | Case 1 RED |
| `_raise.reverse()` injected into the swap path (a lower-then-raise) | Case 3 RED on the bar-adjacency assertion, case 5 RED on seam accounting |

The tree was restored from backups after each; `git status` confirms `lib/` matches the committed state.

## The F4 retarget invariant (Task 1 acceptance, both regimes)

Verified with a throwaway suite, run and then **deleted** — plan 13-04 Task 2 owns the committed F4 discriminator and a second copy here would be the duplicate the plan warns about:

- **At rest** (`_swap.value == 1`): raise the keyboard on the reference device, change only the IME inset to 400, pump one frame — the rendered height re-derives from the new `available` (clamps from 432 to 411) instead of holding the pre-change value. PASS.
- **Mid-swap** (`_swap.value` strictly between 0 and 1): the same inset change moves both endpoints, so the in-flight surface retargets rather than animating toward a stale destination. PASS.

If 13-04's F4 goes red after this plan, the defect is in `summon_shell.dart`, not in that test.

## Verification Results

| Check | Result |
|-------|--------|
| `flutter analyze --no-fatal-infos` | No issues found |
| `flutter test test/shell/summon_motion_test.dart` | 5 tests, all passed |
| `flutter test test/shell` | 59 tests, all passed |
| `flutter test` (full suite) | **941 passed** (936 before this plan + 5) |
| `! grep -q 'pumpAndSettle' test/shell/summon_motion_test.dart` | succeeds |
| non-comment `onSurfaceDismissed` count in `summon_shell.dart` | **2** |
| non-comment stored-size pattern in `summon_shell.dart` | no match |
| non-comment `summonSurfaceHeight(` count in `summon_shell.dart` | 2 (≥ 2) |
| `grep -Ec 'disableAnimations' summon_shell.dart` | 0 |
| `grep -Ec 'Curves\.(easeOutCubic\|fastOutSlowIn\|bounce\|elastic)\|Cubic\(' summon_shell.dart` | 0 |
| `grep -Ec '[0-9]{3}\.[0-9]' summon_motion_test.dart` | 0 |

## Success Criteria

- [x] Summon is 200ms and dismiss is 150ms, each pinned by an assertion a wrong duration fails
- [x] Tapping the other bar icon swaps the surface in one motion that never detaches from the bar
- [x] A tap landing mid-animation reverses from the live value with no queue and no lockout
- [x] Exactly one named dismiss seam exists and it fires on both the lower and the swap edge

## Requirements Completed

- **MOT-01** — the summon/dismiss motion budgets, falsifiably pinned
- **SUM-03** — tapping the raised surface's own icon lowers it; tapping the other icon swaps in place

## Threat Mitigations

| Threat ID | Disposition | Status |
|-----------|-------------|--------|
| T-13-08 (dismiss seam missing on the swap edge) | mitigate | **Mitigated** — one seam, exactly two call sites, asserted by `test`; case 5 proves both edges fire and that each surface reports exactly once |
| T-13-09 (a green MOT-01 that measured nothing) | mitigate | **Mitigated** — no settle-until-idle pump in the file (grep-asserted), and all three budgets confirmed by hand-mutation |
| T-13-SC (package-manager installs) | accept | No installs; `pubspec.yaml` unchanged |

## Threat Flags

None — this plan adds no network endpoint, auth path, file access or schema change. The only new surface is an in-process animation controller.

## Known Stubs

None. Nothing in this plan renders a placeholder or defers a data source.

## Notes for Next Phase

- **Phase 14 / Phase 15:** wire `dismissed()` to `SummonShellController.onSurfaceDismissed`. It is one field, and the shell already fires it with the outgoing kind on both edges — do not add a second hook.
- **Plan 13-04:** the F4 discriminator is expected to pass against this implementation in both regimes (confirmed above). If it reds, look at `summon_shell.dart`'s build, not at the test.
- The mid-swap destination-tap rule is a behavioural contract Phases 14/15 inherit: a surface that is being swapped *in* can be dismissed before it arrives, and it still reports exactly once.
