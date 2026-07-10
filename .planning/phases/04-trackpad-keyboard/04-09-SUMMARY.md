---
phase: 04-trackpad-keyboard
plan: 09
subsystem: trackpad
tags: [flutter, trackpad, scroll, fling, gesture-classifier, wr-04, gap-closure]
requires:
  - phase: 04-03
    provides: GestureClassifier pure FSM with two-finger scroll + fling seeding
provides:
  - "_emitScroll scaled by live tracked-pointer count (n = _pointers.length) — WR-04 closed"
  - "WR-04 regression tests: post-lift full-rate scroll, unhalved fling seed, tapPending2 single-finger slop-crossing"
affects: [04-VERIFICATION end-of-phase feel gate (must re-run after this fix)]
tech-stack:
  added: []
  patterns:
    - "Live FSM state as scroll divisor — no new tuning constant (D-06), classifier stays pure IO-free FSM (D-04)"
key-files:
  created: []
  modified:
    - app/remote_control/lib/trackpad/gesture_classifier.dart
    - app/remote_control/test/trackpad/gesture_classifier_test.dart
key-decisions:
  - "Phase-04-03 decision refined: ScrollIntent carries delta/n per move event over LIVE tracked pointers (n=2 both fingers down — byte-identical to the shipped /2 averaging; n=1 after a lift so the remaining finger scrolls at full rate). The averaging intent is preserved; the constant just stopped lying when one finger lifts."
metrics:
  duration: 3min
  tasks: 2
  files: 2
completed: 2026-07-10
---

# Phase 04 Plan 09: WR-04 Post-Lift Scroll Rate Summary

Live-pointer-count scroll scaling closes WR-04: lifting one of two scrolling fingers no longer halves the remaining finger's scroll rate or the fling seed, while two-finger averaging stays byte-identical to 04-03.

## What Was Built

### `_emitScroll` divisor fix (gesture_classifier.dart)

- Replaced the constant `dx / 2` / `dy / 2` with `final n = _pointers.length;` then `dx / n` / `dy / n`. While both fingers are down n == 2 and behavior is byte-identical (only one pointer moves per event, the other contributes zero); after one finger lifts n == 1 and the remaining finger streams at full rate.
- n >= 1 is structurally guaranteed: `_emitScroll` is only reached from `onPointerMove` after the `_pointers[pointer]` null-check.
- Velocity samples record the correctly-scaled deltas, so a fling seeded from post-lift samples reflects the finger's true velocity (previously half-strength).
- `_emitScroll` and `ScrollIntent` doc comments rewritten to the "per-event average across the live tracked pointers" contract; `_flingFrom`, `onPointerUp`/`onPointerMove` phase logic, and tuning.dart untouched (n is live FSM state, not a D-06 tunable).

### WR-04 regression group (gesture_classifier_test.dart)

New group `'GestureClassifier — WR-04: post-lift scroll rate (PAD-03)'`, three exact-value tests:

1. **Post-lift full rate:** one of two fingers lifts mid-scroll; remaining finger's raw dy -24 emits `ScrollIntent(0, -24)` (the bug emitted -12). Also re-asserts the unchanged two-finger `ScrollIntent(0, -15)` average first.
2. **Unhalved fling seed:** four post-lift single-finger swipes of raw dy -24 over 40ms seed `FlingIntent(0, -2.4)` — exactly double the -1.2 the halving bug produced; the halved two-finger sample prunes out of the velocity window by design.
3. **tapPending2 path:** with one finger left in tapPending2, the slop-crossing move emits the FULL delta `ScrollIntent(0, -30)` (the bug emitted -15).

## TDD Cycle

Task 1 was `tdd="true"`; the three regression tests specified by Task 2 served as the RED phase (only sensible failing tests for the fix), so the two tasks interleaved as one RED→GREEN cycle:

- **RED** (`941b40a`): tests added, ran, failed with exactly the predicted halved values (-12, -1.2, -15); all 18 pre-existing classifier tests passed.
- **GREEN** (`7131c05`): divisor fix + doc updates; all 21 classifier tests pass with ZERO edits to any pre-existing test — the proof two-finger behavior is untouched.
- No REFACTOR commit needed.

## Verification Results

- `flutter analyze` — No issues found
- `flutter test test/trackpad/gesture_classifier_test.dart` — 21/21 pass (18 pre-existing unchanged + 3 new)
- Full `flutter test` — **233 tests, all passed** (matches the plan's >= 233 criterion exactly)
- `grep -c "_pointers.length" gesture_classifier.dart` = 3 (>= 2 required)
- Non-comment `d[xy] / 2` count = 0 (constant halving gone)
- `git diff --name-only -- tuning.dart` = empty (no tuning constant added)
- On-device confirmation rides the EXISTING end-of-phase human gate (04-VERIFICATION human_verification item 2 — trackpad feel vs Remote Mouse) which must re-run AFTER this fix so feel tuning happens against correct post-lift kinematics.

## Threat Model Verification

T-04-06 (local DoS via momentum loop) mitigations confirmed untouched by inspection: `StopFlingIntent` is still unconditionally first on every pointer-down (`onPointerDown` line 283), the driver momentum loop was not modified (generation-guarded, self-stopping below `kMomentumStopVelocity` with `kMomentumDecay`), and the classifier remains pure (no timers, no IO). A larger (now-correct) seed only decays from a truer starting point. No new packages; pubspec.yaml untouched (T-04-SC accept holds). No new trust boundaries — no Threat Flags.

## Deviations from Plan

None - plan executed exactly as written. (The RED/GREEN interleaving of Task 2's tests ahead of Task 1's fix is the plan's own `tdd="true"` flow, not a deviation; Task 1's "zero test-file edits" constraint referred to pre-existing tests, all of which passed unchanged.)

## Known Stubs

None — no placeholder values, TODO markers, or unwired data introduced.

## Commits

| Commit | Type | Description |
|--------|------|-------------|
| 941b40a | test | Failing WR-04 regression tests (RED) |
| 7131c05 | feat | Live tracked-pointer-count scroll scaling (GREEN) |

## Next Steps

- 04-VERIFICATION human feel gate (trackpad feel vs Remote Mouse, scroll momentum) must re-run against the corrected post-lift kinematics before phase close.
- WR-01/WR-02 (connection-layer dial races) and WR-03 (prefs load race) remain outside this phase's must-haves per the verifier — untouched by design.

## Self-Check: PASSED

- FOUND: app/remote_control/lib/trackpad/gesture_classifier.dart
- FOUND: app/remote_control/test/trackpad/gesture_classifier_test.dart
- FOUND: .planning/phases/04-trackpad-keyboard/04-09-SUMMARY.md
- FOUND commit: 941b40a (test, RED)
- FOUND commit: 7131c05 (feat, GREEN)
