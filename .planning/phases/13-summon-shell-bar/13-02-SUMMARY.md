---
phase: 13-summon-shell-bar
plan: 02
subsystem: flutter-app-shell
tags: [shell, chrome, geometry, animation, mediaquery, bar, surface]
status: complete

requires:
  - "app/remote_control/lib/shell/summon_scope.dart (SummonSurfaceKind, SummonShellController, SummonScope — from 13-01)"
  - "app/remote_control/lib/shell/summon_shell.dart (the MaterialApp.builder host — from 13-01)"
  - "app/remote_control/lib/theme/tokens.dart (kBg, kSurface, kHairline, kText, kMuted, kAccent)"
  - "app/remote_control/lib/net/connection_providers.dart (value-equal connectionStatusProvider)"
provides:
  - "summon_geometry.dart — the ONE shared derivation, 8 chrome consts, 3 motion budgets, 4 pure functions"
  - "SummonBar + kSummonBarKey — the 56dp two-icon bar chrome"
  - "SummonIconButton + the two icon keys and three copy consts — the total four-state bar icon"
  - "SummonSurface + kSummonSurfaceKey — the kSurface slab with the mandatory removePadding"
  - "SummonHandle + kSummonHandleKey/kSummonHandleLabel — the inert 48dp handle band"
  - "The shell's raise/lower animation: one controller, 200ms up / 150ms down"
  - "test/shell/summon_test_harness.dart — driveView / availableOf / summonSurfaceHeightFor / pumpShell / harvested doubles"
affects:
  - "app/remote_control/lib/shell/summon_shell.dart (five-child Stack, the bar's Overlay layer, the geometry locals)"
  - "every screen — the bar now renders over all 14 of them, and over modal routes"

tech-stack:
  added: []
  patterns:
    - "A dedicated full-screen Overlay for shell chrome, so a Tooltip can exist above the Navigator"
    - "Constant-length Stack children with keyed layers, because an OverlayEntry must not be re-parented"
    - "AnimatedBuilder with a cached `child` — the surface chrome is built once per raise, not once per frame"
    - "Pure geometry functions taking plain doubles, so the arithmetic is unit-testable without a pump"
    - "Computed-never-quoted test expectations re-derived independently of the production function"

key-files:
  created:
    - "app/remote_control/lib/shell/summon_geometry.dart"
    - "app/remote_control/lib/shell/summon_bar.dart"
    - "app/remote_control/lib/shell/summon_icon_button.dart"
    - "app/remote_control/lib/shell/summon_surface.dart"
    - "app/remote_control/lib/shell/summon_handle.dart"
    - "app/remote_control/test/shell/summon_geometry_test.dart"
    - "app/remote_control/test/shell/summon_shell_test.dart"
    - "app/remote_control/test/shell/summon_test_harness.dart"
  modified:
    - "app/remote_control/lib/shell/summon_shell.dart"

decisions:
  - "The bar rides its own full-screen Overlay. SummonIconButton's Tooltip is BINDING (13-UI-SPEC E2/long-text) and Tooltip asserts on an Overlay ancestor at BUILD time, not at show time — proven empirically against Flutter 3.44.5. The shell's chrome is a sibling of the Navigator, so the Navigator's own overlay is out of reach. Full-screen so a tooltip positions against the window rather than being squeezed into the 56dp band"
  - "The surface's 1px top rule gets an explicit Padding. A Border on a DecoratedBox is painted, not laid out, so without it the handle band sat UNDER the rule and the inherited content box was height-48 rather than height-1-48 — the number Phases 14 and 15 were handed"
  - "The surface's Stack slot is always present and collapses to a zero-height box, rather than dropping out of the children list. A Stack matches children by position, so a disappearing slot moved the bar layer onto a fresh element and its already-mounted OverlayEntry was re-inserted into a second Overlay, which asserts"
  - "The keyboard clamp binds on TWO of the five worked devices, not one. The plan's acceptance criterion said the clamp binds 'on device D and only there'; that is true of the 280dp trackpad and false of the 432dp keyboard, which also clamps on device E (available 410). The tests assert the arithmetic, not the sentence"
  - "The bar layer re-reads viewPadding/viewInsets from its own (un-injected, sibling-of-the-injection) context rather than capturing the shell's locals, because an OverlayEntry builder has no way to be told the value changed without a markNeedsBuild during build. Both sites call summonBarBottomOffset, and invariant I1 is the executable proof they agree"

metrics:
  duration: "~70 min"
  completed: 2026-08-14

actuals:
  tokens: 22400
  tasks: 3
  commits: 3
---

# Phase 13 Plan 02: The Bar, the Surface and the Arithmetic Summary

The host is now visible: a 56dp two-icon bar rides every screen with a byte-identical
`Rect`, tapping an icon raises a correctly-sized empty `kSurface` slab in place with no
navigation, and the slab's bottom edge rests exactly on the bar's top edge — all sized by
one shared derivation whose five worked devices are pinned with computed expectations.

## What Was Built

**Task 1 — the arithmetic.** `summon_geometry.dart`: eight chrome constants, the two
height design choices, three motion budgets, and four pure functions
(`summonBarBottomOffset`, `summonAvailableHeight`, `summonSurfaceHeight`,
`summonSurfaceContentHeight`). One `min` clamp serves both surfaces — there is no
per-surface formula, no screen fraction and no per-pad clamp anywhere in the file, and it
imports nothing from `key_pads.dart`.

**Task 2 — the chrome.** Four widgets: the bar, its four-state icon, the surface slab and
the inert handle. Tokens only, `Symbols.*_rounded` only, every string a named `const`.

**Task 3 — the wiring and the proof.** The five-child `Stack` with the bar last, the one
raise controller, the shared test harness, and eight end-to-end cases driven through the
real shell at `MaterialApp.builder`.

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | The one shared derivation + six chrome constants | `a5384b4` | `summon_geometry.dart`, `summon_geometry_test.dart` |
| 2 | The bar, its icon, the surface slab, the inert handle | `036e045` | `summon_bar.dart`, `summon_icon_button.dart`, `summon_surface.dart`, `summon_handle.dart` |
| 3 | Mount the chrome and prove the first raise end to end | `73c6db9` | `summon_shell.dart`, `summon_surface.dart`, `summon_test_harness.dart`, `summon_shell_test.dart` |

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/shell/summon_geometry_test.dart` | **pass** — 40/40 |
| `flutter test test/shell/summon_shell_test.dart` | **pass** — 8/8 |
| `flutter test test/shell` | **pass** — 54/54 (40 geometry + 8 shell + 6 spike) |
| `flutter test` (`app/remote_control`) | **pass** — **936**, exit 0 |
| `flutter test` (`app/packages/remote_protocol`) | **pass** — 22, unchanged |
| `flutter analyze --no-fatal-infos` | **No issues found!** |
| `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | **pass** — 2/2 |
| `git diff --name-only c305c11 HEAD -- pubspec.yaml android` | **empty** (zero new dependencies, D-13-01 honoured) |

**The suite count reconciles exactly.** 888 after 13-01 → **936** now, `+48`, which is
precisely the 40 new geometry declarations plus the 8 new shell declarations. Every
pre-existing test that passed with the bar merely *reserved* still passes with the bar
actually *rendered over every screen* — including `widget_test.dart` and
`hub_offline_test.dart`, the two suites that pump real screens through `RemoteControlApp`
and are therefore the only existing tests that see the chrome at all. No assertion was
loosened, no finder relaxed, no failure silenced, and no test file outside `test/shell/`
was touched.

## The Grep Contracts

| Contract | Result |
|---|---|
| `! grep -Ev '^\s*//' summon_geometry.dart \| grep -Eq 'kPanel\|panelPadHeight'` | pass — no docked-panel constant in code |
| `grep -c 'design choice' summon_geometry.dart` | 3 (≥2 required) |
| `grep -c "import.*key_pads" summon_geometry.dart` | 0 |
| `grep -Ec '(763\|536\|521\|270\|410)'` outside comments in `summon_geometry_test.dart` | 0 — every expectation computed |
| `! grep -Ev '^\s*//' summon_surface.dart summon_bar.dart \| grep -Eq 'ClipRRect\|BoxShadow\|elevation\|borderRadius'` | pass — the slab is flat |
| `! grep -Ev '^\s*//' summon_handle.dart \| grep -Eq 'GestureDetector\|Listener\|onTap'` | pass — the handle is inert |
| `grep -Ec 'spaceEvenly\|spaceAround\|Spacer\('` in `summon_bar.dart` | 0 |
| `grep -c "'Trackpad'"` in `summon_icon_button.dart` | 1 |
| `grep -Ec 'Color\(0x'` across `lib/shell/*.dart` | 0 on all eight files |
| `! grep -Ev '^\s*//' summon_shell.dart \| grep -Eq 'AnimatedPositioned\|AnimatedOpacity\|Opacity\(\|ClipRect'` | pass |
| `AnimationController(` / `reverseDuration:` in `summon_shell.dart` | 1 / 1 — one controller, two budgets |
| `pumpAndSettle` outside comments in `summon_shell_test.dart` | 0 |
| `_kBarReservation` in `summon_shell.dart` | 0 — replaced by the imported `kSummonBarHeight` |

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] A `Tooltip` cannot exist above the `Navigator` without an
`Overlay`, so the bar got its own**

- **Found during:** Task 2 design, confirmed empirically before writing the widget.
- **Issue:** 13-UI-SPEC marks the ancestor `Tooltip` **binding** — a disabled button does
  not surface its own tooltip, so `kSummonKeyboardBlockedLabel` would be unreachable by
  both long-press and TalkBack, which would undo CR-2's entire accessibility rationale.
  But `Tooltip` calls `debugCheckHasOverlay` in `RawTooltipState.build`, i.e. it asserts
  at **build time**, not at show time. A throwaway probe against Flutter 3.44.5 confirmed
  it: a `Tooltip` mounted as a sibling of the `Navigator` under `MaterialApp.builder`
  throws `No Overlay widget found` on the first frame. The plan's Task 3 would have
  produced a shell that crashes the moment it mounts.
- **Fix:** the bar's `Stack` layer is `Positioned.fill(child: Overlay(initialEntries:
  [_barLayer]))` and the bar's `Positioned` moved inside that entry. Full-screen rather
  than bar-sized, because a 56dp overlay would squeeze the tooltip into the band it is
  supposed to float above. The layer is still the **last** `Stack` child, so it still
  paints last and hit-tests first; a dedicated test asserts a body tap outside the bar
  still reaches the body, which is the pass-through this layer must not break.
- **Files modified:** `lib/shell/summon_shell.dart`
- **Commit:** `73c6db9`

**2. [Rule 1 — Bug] The surface's 1px rule was painted but not laid out, so the content
box was 1dp too tall**

- **Found during:** Task 3, caught by the assertion that the handle band's top is
  `surfaceRect.top + kSummonHairline`.
- **Issue:** a `Border` on a bare `DecoratedBox` is *painted over* the child, not
  reserved. The handle band therefore started at the slab's top edge with the hairline
  drawn across it, and the expanded region was `height - 48` rather than the
  `height - 1 - 48` that `summonSurfaceContentHeight` promises. Invisible in Phase 13
  (nothing is in the box), wrong in Phases 14 and 15, and impossible to attribute by then.
  `KeyboardTabBar` avoids this by accident — `Container` inserts the border's padding, a
  bare `DecoratedBox` does not.
- **Fix:** `Padding(padding: EdgeInsets.only(top: kSummonHairline))` between the
  `DecoratedBox` and the `Column`, with the reason in the code. A new test measures the
  rendered `Expanded` against `summonSurfaceContentHeight`, so the arithmetic and the
  layout are now joined by an assertion rather than by hope.
- **Files modified:** `lib/shell/summon_surface.dart`, `test/shell/summon_shell_test.dart`
- **Commit:** `73c6db9`

**3. [Rule 1 — Bug] A conditional `Stack` child re-parented the bar's `OverlayEntry`**

- **Found during:** Task 3, caught immediately by the 13-01 spike suite going red.
- **Issue:** the plan's surface layer was written as `if (rendered != null) Positioned(…)`.
  A `Stack` matches children by position, so raising a surface shifted the bar layer from
  index 3 to index 4, Flutter built a fresh `Overlay` element for it, and the
  already-mounted `_barLayer` was inserted into a second `Overlay` —
  `The specified entry is already present in a different Overlay`.
- **Fix:** the surface slot is always present and collapses to `SizedBox.shrink()` at
  zero height. Both chrome layers additionally carry a `ValueKey`. The comment names the
  failure so nobody re-introduces the conditional. This also keeps the "the bar's
  `Positioned` is the final entry in the children list" claim literally true on every
  frame rather than only while nothing is raised.
- **Files modified:** `lib/shell/summon_shell.dart`
- **Commit:** `73c6db9`

**4. [Rule 1 — Bug in the plan's acceptance criterion] The keyboard clamp binds on two
devices, not one**

- **Found during:** Task 1.
- **Issue:** the plan's criterion asked the tests to assert "the trackpad and keyboard
  heights clamp to `available` on device D and only there". That is true of the 280dp
  trackpad (only device D's `available` falls below 280) and **false of the 432dp
  keyboard**, which also clamps on device E, whose `available` is 410. Asserting the
  sentence would have required a wrong test.
- **Fix:** the suite asserts the arithmetic instead — a computed list of the devices where
  each surface's clamp binds, checked against the device identities. The trackpad list is
  `[D]`, the keyboard list is `[D, E]`, and the test that says so names *why* the taller
  surface runs out of room sooner. No number is quoted.
- **Files modified:** `test/shell/summon_geometry_test.dart`
- **Commit:** `a5384b4`

**5. [Rule 3 — Blocking] Test helpers made file-private to keep `analyze` silent**

- **Found during:** Task 1.
- **Issue:** helpers taking the file-private `_Device` record tripped
  `library_private_types_in_public_api` three times. Infos, not errors, but 13-01
  established "No issues found!" as this phase's bar.
- **Fix:** the five helpers are `_`-prefixed. Their shape — an independent re-derivation
  over the device inputs — is unchanged, which is the part the criterion is actually about.
- **Files modified:** `test/shell/summon_geometry_test.dart`
- **Commit:** `a5384b4`

### Non-deviations worth recording

- **`Semantics.fromProperties` was tried and abandoned.** The handle's band is otherwise
  const-buildable, but the const `Semantics` constructor needs
  `package:flutter/semantics.dart` and appears nowhere in this tree. A plain non-const
  `Semantics` around a const child is the house shape and costs nothing: the band is built
  once per raise, inside `AnimatedBuilder`'s cached `child`.
- **`isDone` is a strict `>`.** At exactly 200ms the raise controller's *value* has
  arrived but its *status* has not flipped, so a zero-duration pump after the budget still
  sees the old tree. Every "land it" helper advances the exact budget and then one more
  1ms frame, with the reason written down — which also keeps the assertion a genuine
  discriminator, since a 300ms summon would still be mid-flight at 201ms.

## Threat Mitigations Applied

| Threat | Disposition | How it landed |
|---|---|---|
| **T-13-06** (bar inside the Android gesture zone) | mitigated | The nav inset is padded **below** the band: `Positioned(bottom: barBottomOffset, height: kSummonBarHeight)`. Pinned early — `barRect.bottom == S - max(Pbot, Ibot)` (invariant I2) is asserted from the driven metrics in `summon_shell_test.dart`, ahead of plan 13-04 |
| **T-13-07** (bar rebuild scope on the cursor hot path) | mitigated | `grep -c 'Timer.periodic\|\.changes'` across `lib/shell/` → **0**. The bar watches the value-equal `connectionStatusProvider` and nothing else, and it is a `ConsumerWidget` precisely so that read rebuilds the bar rather than the host |
| **T-13-03** (bar over the power confirm dialog) | accepted | Unchanged and now real — the bar renders over modal routes. The shell's code comment states it is an accepted consequence AND an SC4 requirement, and that no second suppressor is to be added. Carried to the 13-10 UAT eyeball list |
| **T-13-SC** (package-manager installs) | accepted, verified nil | `git diff --name-only c305c11 HEAD -- pubspec.yaml android` is empty. Zero packages installed, zero manifest edits |

## Prohibitions — status

| Prohibition | Status | Evidence |
|---|---|---|
| No third icon, no labels, no overflow menu, no content in the dead width | **verified** | Exactly two `SummonIconButton`s, compile-time constant; the bar renders no `Text`; `grep -Ec 'spaceEvenly\|spaceAround\|Spacer\('` → 0 |
| No scrim or dim behind the surface | **verified** | The shell's `Stack` has five children and none of them is a scrim; nothing beneath the surface changes appearance |
| No swipe-down-to-dismiss, no hide-on-scroll, no auto-dismiss | **verified** | The handle carries no recognizer at all (grep guard); the shell installs no scroll listener, no inactivity timer and no disconnect hook |
| No haptic on summon or dismiss | **verified (judgment)** | No `hapticTick` and no `HapticFeedback` anywhere under `lib/shell/`; reviewed by reading all five new widget files |

## Known Stubs

| Stub | File | Why it is intentional | Resolved by |
|---|---|---|---|
| `keyboardBlocked` is hard-wired `false` | `lib/shell/summon_bar.dart` | BAR-03's gate is plan **13-09**, which implements D-13-17's corrected `EditableText`-ancestor predicate. State 2 is fully implemented and independently testable in `SummonIconButton`; only its input is pinned. Wired as a value rather than omitted so 13-09 changes one expression | plan 13-09 |
| The swap is a lower-then-raise | `lib/shell/summon_shell.dart` | D-13-10's one-motion swap and its `_swap` controller are plan **13-03**. Tapping the other icon today re-raises through the same controller; the `onSurfaceDismissed` seam already fires on the swap edge (13-01), so the dismiss obligation is not lost | plan 13-03 |
| `barVisible` has a consumer but no suppressor | `lib/shell/summon_shell.dart` | The bar's `ValueListenableBuilder` honours suppression now; BAR-04's `SummonBarSuppressor` (the QR screen) lands in a later 13-xx plan | later Phase 13 plan |
| `SummonSurface.kind` does not change what is rendered | `lib/shell/summon_surface.dart` | Both surfaces are empty in Phase 13 — that emptiness is D-13-08's deliverable. The field carries the discriminator Phases 14 and 15 branch on, and the height already differs per kind | Phases 14 and 15 |
| The bar layer re-reads the view metrics | `lib/shell/summon_shell.dart` | An `OverlayEntry` builder cannot be handed a changed value without a `markNeedsBuild` during build. Both sites call `summonBarBottomOffset` over the same un-injected scope, and invariant I1 asserts they agree on every frame | — (accepted, asserted) |

None of these prevent this plan's goal. The host shape, the chrome and the inset
arithmetic — the three things that are expensive to change later — are all settled and
pinned.

## Notes for the Next Plans

- **13-03 (swap)** inherits a `TickerProviderStateMixin` `State` with one controller and a
  `_rendered` field. Add `_swap` beside `_raise`; do **not** convert the raise into a
  lower-then-raise. `SummonShellController.raise` already fires `onSurfaceDismissed` for
  the outgoing surface on the swap edge.
- **13-04 (driven-viewport invariants)** should import the harness rather than re-copying
  `driveView`; `availableOf` and `summonSurfaceHeightFor` are already there. I1/I2/I3/I4
  are asserted on the reference device only in this plan — the five-device sweep is 13-04's.
- **The spike suite still carries its own copies of the three doubles.** It predates the
  harness. Folding `summon_back_guard_spike_test.dart` onto `summon_test_harness.dart` is
  a one-import change and would remove the last duplicate ahead of Phase 16.
- **CR-1 and CR-3 are both live UAT questions.** Resting-connected glyphs are `kText`
  (one-const change if wrong on hardware), and the raised trackpad's content box is
  **231dp** against the retiring bubble window's 234 — a test in
  `summon_geometry_test.dart` asserts that 3dp gap explicitly so it cannot drift before
  the UAT session records the tuned value.
- **`.gsd/` is still untracked**, as recorded in 13-01. Left alone deliberately.

## Self-Check: PASSED

All nine claimed artifacts exist on disk (five under `lib/shell/`, three under
`test/shell/`, plus the modified shell). All three claimed commit hashes — `a5384b4`,
`036e045`, `73c6db9` — resolve in `git log`.
