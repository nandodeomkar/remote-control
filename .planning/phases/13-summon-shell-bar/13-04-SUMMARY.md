---
phase: 13-summon-shell-bar
plan: 04
subsystem: testing
tags: [summon, geometry, mediaquery, insets, viewport, discriminator, BAR-02, BAR-05]
status: complete

requires:
  - phase: 13-02
    provides: "summon_geometry.dart's four pure functions, SummonSurface + kSummonSurfaceKey with its removePadding strip, SummonBar + the three keys, and summon_test_harness.dart (driveView / availableOf / barBottomOffsetOf / summonSurfaceHeightFor / pumpShell)"
  - phase: 13-03
    provides: "the swap lerp — the FINAL height source. Both its endpoints are re-derived from the live `available` on every build, which is what F4 is written against; against 13-02's intermediate resting height F4 would have proved something that 13-03 then replaced"
provides:
  - "The rendered half of test/shell/summon_geometry_test.dart: five driven viewports through the REAL shell, both surface kinds on each"
  - "expectSurfaceInvariants — I1/I2/I3/I4 as one helper, in the expectColumnFits shape"
  - "The five named failure modes as named tests: F1 and F1b (devices C and D), F2 and F3 (device A), F4 (the retarget), F5 (the padding-strip probe) plus its corollary"
  - "A recorded correction to 13-RESEARCH §6.5's F5 assertion, with the framework source cited in-file"
affects:
  - "Phase 15: the F5 probe is the only detector that exists for the padding strip — it fails there if the strip is removed here, and the corollary warns Phase 15 off maintainBottomViewPadding inside the surface"
  - "Phase 14: the same five-device invariant helper is the shape a populated surface must keep satisfying"

actuals:
  tokens: 7700
  tasks: 2
  commits: 2

tech-stack:
  added: []
  patterns:
    - "One invariant helper per contract, taking the driven metrics, with a `reason:` per assertion that states the guarantee rather than restating the assertion"
    - "Hand-falsification before trust: every discriminator was proved red by mutating production code, and the observed delta is recorded in the commit message"
    - "Probe assertions for failures that are invisible in the current phase and expensive in a later one"

key-files:
  created: []
  modified:
    - "app/remote_control/test/shell/summon_geometry_test.dart"

key-decisions:
  - "13-RESEARCH §6.5's F5 second assertion (`viewPaddingOf` inside the surface still reports 48) is WRONG against Flutter's MediaQueryData.removePadding, which subtracts the consumed padding from viewPadding. The assertion was corrected rather than the production code, because making the original literally true would weaken the guard"
  - "Device D's clamped case asserts the surface fills `available` exactly and its top lands ON the status inset — the plan's 'still leaves the host screen visible above it' is a leftover from the retired fraction+floor model"
  - "F3's rendered tripwire is I1, not a height: with fixed heights `available` reaches the render tree only through the clamp, and the clamp only binds where the IME already dominates max(Pbot, Ibot)"
  - "The F5 corollary is documentation, not the guard — deleting the strip leaves it green, and the file says so"

patterns-established:
  - "Reference cases and discriminators are named as such in the suite preamble, with the wrong number each discriminator catches"
  - "A test name carries the wrong outcome the naive formula produces, so breaking it tells the reader what they broke"

requirements-completed: [BAR-02, BAR-05]

coverage:
  - id: D1
    description: "The four geometry invariants (I1 surface.bottom == bar.top, I2 bar.bottom == S − max(Pbot, Ibot), I3 surface.top >= Ptop, I4 height == the one shared derivation) hold for BOTH surface kinds on all five driven viewports"
    requirement: "BAR-02"
    verification:
      - kind: unit
        ref: "test/shell/summon_geometry_test.dart#rendered on the five driven viewports (13-04) — A/B/C/D/E — both surfaces hold I1-I4"
        status: pass
    human_judgment: false
  - id: D2
    description: "F1/F1b — the bar clears the raised IME on devices C and D; the naive paddingOf read puts it at the window bottom, behind the keyboard and untappable"
    requirement: "BAR-02"
    verification:
      - kind: unit
        ref: "test/shell/summon_geometry_test.dart#F1 on device C / F1b on device D"
        status: pass
      - kind: other
        ref: "hand-falsified: barBottomOffset = MediaQuery.paddingOf(context).bottom in summon_shell.dart → both red, differing by 290 (the driven IME)"
        status: pass
    human_judgment: false
  - id: D3
    description: "F2 — the surface's bottom edge is the bar's top edge on device A; omitting kSummonBarHeight lands it a full bar height lower, overlapping the bar"
    requirement: "BAR-02"
    verification:
      - kind: unit
        ref: "test/shell/summon_geometry_test.dart#F2 on device A"
        status: pass
      - kind: other
        ref: "hand-falsified: dropped `+ kSummonBarHeight` from the surface Positioned → red, differing by 56"
        status: pass
    human_judgment: false
  - id: D4
    description: "F3 — the shell's geometry comes from the UN-injected ancestor query; reading the +56 copy back costs exactly one bar height"
    requirement: "BAR-05"
    verification:
      - kind: unit
        ref: "test/shell/summon_geometry_test.dart#F3 on device A with the IME DOWN"
        status: pass
      - kind: other
        ref: "hand-falsified: fed viewPadding.bottom + kSummonBarHeight through both derivations → red through I1, differing by 56"
        status: pass
    human_judgment: false
  - id: D5
    description: "F4 — the raised surface retargets on the next frame when only the IME inset moves, at REST, against 13-03's swap lerp"
    requirement: "BAR-02"
    verification:
      - kind: unit
        ref: "test/shell/summon_geometry_test.dart#F4: the surface RETARGETS on the very next frame"
        status: pass
      - kind: other
        ref: "hand-falsified: MediaQueryData.fromView(View.of(context)) in the shell's build → red, stuck at the covered height instead of the mid-fall one"
        status: pass
    human_judgment: false
  - id: D6
    description: "F5 — the mandatory bottom-padding strip on the surface subtree is present, scoped to that subtree, and leaves viewInsets alone"
    verification:
      - kind: unit
        ref: "test/shell/summon_geometry_test.dart#F5 PROBE + F5 corollary"
        status: pass
      - kind: other
        ref: "hand-falsified: removed MediaQuery.removePadding from summon_surface.dart → probe red by 48 (the full nav inset)"
        status: pass
    human_judgment: false
  - id: D7
    description: "The suite quotes no computed geometry figure and contains no settle-until-idle pump"
    verification:
      - kind: other
        ref: "! grep -Eq '763|572.25|419.65|536|521|390.75|270|410' and ! grep -q 'pumpAndSettle' over the file"
        status: pass
    human_judgment: false

duration: 45min
completed: 2026-08-14
---

# Phase 13 Plan 04: Five Driven Viewports Summary

**The inset arithmetic is now pinned on five real viewports rendered through the real shell — four invariants for both surface kinds on each, and every one of the five named failure modes proved red by hand before being trusted.**

## Performance

- **Duration:** ~45 min
- **Tasks:** 2
- **Files modified:** 1 (`app/remote_control/test/shell/summon_geometry_test.dart`, +587 / −6)
- **Suite:** the file went 39 → 53 tests; the full app suite 962 → 975, all green

## Accomplishments

- The file that was arithmetic-only now has a rendered half: devices A–E driven through `SummonShell` at `MaterialApp.builder`, each raising the trackpad surface and then swapping to the keyboard surface, with `expectSurfaceInvariants` asserting I1–I4 on both.
- Five named discriminators, each hand-falsified against a real mutation of production code before being trusted:
  | ID | Mutation applied | Observed red | Delta |
  |----|------------------|--------------|-------|
  | F1 / F1b | `barBottomOffset = MediaQuery.paddingOf(context).bottom` | bar drawn at the window bottom | 290 (the IME) |
  | F2 | dropped `+ kSummonBarHeight` from the surface `Positioned` | surface ends at the bar's *bottom* | 56 |
  | F3 | fed the injected `viewPadding.bottom` through both derivations | I1 breaks | 56 |
  | F4 | `MediaQueryData.fromView(View.of(context))` in `build` | height never leaves the covered value | 140 |
  | F5 | deleted `MediaQuery.removePadding` from `summon_surface.dart` | probe reads the nav inset | 48 |
- **`lib/` was not touched.** `git diff --name-only -- app/remote_control/lib/` is empty across both task commits; every mutation above was applied, observed, and reverted with `git checkout --` on the single file.

## Task Commits

1. **Task 1: five driven viewports, four invariants, three discriminators** — `73b0dd4` (test)
2. **Task 2: the retarget discriminator and the padding-strip probe** — `fc23bbf` (test)

## Files Created/Modified

- `app/remote_control/test/shell/summon_geometry_test.dart` — the rendered half: a preamble naming references vs discriminators, `_Device` extended with a width so it can drive a viewport, `expectSurfaceInvariants`, the five per-device cases, device D's clamp case, and the six named failure-mode tests.

## Decisions Made

**1. The F5 assertion was wrong; the production code was right.**
13-RESEARCH §6.5, 13-UI-SPEC binding rule 3 and this plan's own must_have all state the probe as *"`viewPaddingOf` inside the surface still reports 48"*. `MediaQueryData.removePadding` (`media_query.dart:930-953`) sets `padding.bottom` to 0 **and** sets `viewPadding.bottom` to `max(0, viewPadding.bottom − padding.bottom)` — it subtracts what it consumed. With the IME **down** (the state the plan specifies) `padding.bottom == viewPadding.bottom`, so both land on 0 and the quoted assertion is red against correct code.

Making it literally true would mean replacing `removePadding` with a hand-rolled `copyWith` that leaves `viewPadding` at the full inset — which **weakens** the guard, because a `SafeArea(maintainBottomViewPadding: true)` inside the surface would then read that number and reintroduce exactly the dead space F5 exists to prevent. So the guarantee was split across two cases instead: the probe (the strip is real, scoped to the surface subtree, and leaves `viewInsets` alone) and a corollary on the IME-up state (where `padding` is already 0, so the inset survives — and Phase 15 is warned off `maintainBottomViewPadding` there). The correction, the framework line numbers and the reasoning are written into the test file, not only here.

**2. F5 is a PROBE, not a rendering assertion — and its value is entirely downstream.**
Phase 13's surface contains no inner `SafeArea`, so the strip's absence changes nothing measurable with a `Rect` today. It changes 24–48dp the moment Phase 15 mounts `KeyboardTabBar` (which carries its own `SafeArea` at `key_pads.dart:349-353`). This probe is the only detector that exists for that, and it fails in Phase 15 if the strip is ever removed here. The falsification also showed the corollary stays **green** with the strip deleted — the file says so explicitly, so nobody keeps the wrong half of the pair.

**3. Device D's clamped case asserts what is true, not what the plan predicted.**
The plan asked for "the resulting surface still leaves the host screen visible above it". Under the shipped derivation the clamped surface fills `available` **exactly**, so its top lands *on* the status inset and no host content remains above it. That prediction is a leftover from the retired fraction-plus-floor model (where the floor left ~50px). The case now asserts: both kinds clamp to the same number, the surface's top equals the status inset (I3 holding with equality — the tightest the geometry ever gets), the bar keeps its full band, and the handle band plus its rule still fit inside the clamped height.

**4. F3's rendered tripwire is I1, not a height.**
Falsification showed that feeding the injected copy through **both** derivations reds the case via I1, but feeding it through `available` **alone** reds nothing on any of the five devices. That is a property of the design, not a gap: a fixed surface height only consults `available` through the clamp; the clamp only binds where the IME is up; and where the IME is up it dominates `max(Pbot, Ibot)` and swallows the injected term whole. Since the offset half shares the same local, I1 is the tripwire for both — which is exactly why the shell reads its metrics once, into locals, before constructing the wrap. Recorded in-file so a later reader does not "strengthen" the case into an assertion that cannot fail.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] The F5 probe's second assertion contradicts Flutter's `removePadding`**
- **Found during:** Task 2
- **Issue:** The plan's must_have, the UI-SPEC binding rule and the research code example all require `MediaQuery.viewPaddingOf` read inside the surface to report the driven 48 with the IME down. `MediaQueryData.removePadding` subtracts the consumed padding from `viewPadding`, so the correct value there is 0.
- **Fix:** Asserted the guarantee instead of the mis-stated number — padding is 0 inside, the strip is scoped (the sibling bar layer still sees the full inset), `viewInsets` pass through — plus a corollary case on the IME-up state where the inset genuinely does survive. The mechanism, the framework line numbers and the reason for not "fixing" the production code are recorded in the test file.
- **Files modified:** `app/remote_control/test/shell/summon_geometry_test.dart` only. `lib/` untouched.
- **Verification:** F5 probe hand-falsified red by 48 with the strip deleted; restored and green.
- **Committed in:** `fc23bbf`

**2. [Rule 1 - Bug] Device D no longer leaves host screen visible above the clamped surface**
- **Found during:** Task 1
- **Issue:** Acceptance criterion asks device D's case to assert the clamped surface "still leaves the host screen visible above it". Under the shipped clamp the surface fills `available` exactly and its top lands on the status inset.
- **Fix:** Asserted the true and stronger set: both kinds collapse to `available`, the top equals the status inset, the bar keeps its band, and the handle band still fits — with the reason naming this as the documented consequence of one shared derivation.
- **Files modified:** `app/remote_control/test/shell/summon_geometry_test.dart`
- **Verification:** green; the equality is derived from the driven inputs, never quoted.
- **Committed in:** `73b0dd4`

**3. [Rule 3 - Blocking] The verify grep bans the literal string `pumpAndSettle`**
- **Found during:** Task 1
- **Issue:** The preamble prose explained the ban by *naming* the method, which trips `! grep -q 'pumpAndSettle'`.
- **Fix:** Rewrote the paragraph to describe a settle-until-idle pump without the token, and noted that the harness's `pumpShell` settles the initial route transition inside its own file.
- **Files modified:** `app/remote_control/test/shell/summon_geometry_test.dart`
- **Verification:** both greps succeed.
- **Committed in:** `73b0dd4`

---

**Total deviations:** 3 auto-fixed (2 plan-expectation corrections, 1 blocking). **Impact:** no scope creep and no production change — `git diff -- app/remote_control/lib/` is empty. Two of the three correct assertions that would have been red against correct code; suppressing them by editing `lib/` would have weakened a guard Phase 15 depends on.

## Issues Encountered

None beyond the deviations above. The three verify greps, the analyzer, `flutter test test/shell` (87) and the full `flutter test` (975) are all green.

## Known Stubs

None.

## Threat Flags

None — no new network, auth, file-access or schema surface. T-13-10 (bar behind the raised IME) and T-13-06 (bar in the gesture-nav zone) are the two `mitigate` dispositions this plan owed, and both are now executable: T-13-10 by F1/F1b, T-13-06 by invariant I2 on every driven viewport.

## User Setup Required

None.

## Next Phase Readiness

- Wave 4's other plan, `13-09` (bar state: the keyboard focus gate and depth-counted QR suppression), is unblocked.
- `BAR-02` is complete. `BAR-05` is held by the shared-ID gate: `13-10-PLAN.md` also declares it and has no summary yet.
- Phase 15 inherits two written obligations from this plan: the F5 probe must keep passing (do not remove the strip), and `maintainBottomViewPadding` must not be used inside the raised surface.

## Self-Check: PASSED

- `app/remote_control/test/shell/summon_geometry_test.dart` — FOUND on disk (906 lines)
- `73b0dd4` — FOUND in `git log`
- `fc23bbf` — FOUND in `git log`
- `flutter test test/shell/summon_geometry_test.dart` — 53 passed
- `flutter test test/shell` — 87 passed
- `flutter test` — 975 passed
- `! grep -q 'pumpAndSettle' …` — succeeds
- `! grep -Eq '763|572\.25|419\.65|536|521|390\.75|270|410' …` — succeeds
- `git diff --name-only -- app/remote_control/lib/` — empty

---
*Phase: 13-summon-shell-bar*
*Completed: 2026-08-14*
