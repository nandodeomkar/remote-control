---
phase: 13-summon-shell-bar
plan: 01
subsystem: flutter-app-shell
tags: [shell, back-handling, mediaquery, tracer, spike]
status: complete

requires:
  - "app/remote_control/lib/widgets/uipi_banner.dart (UipiBanner.forService — the rehomed banner slot)"
  - "app/remote_control/lib/net/connection_providers.dart (connectionServiceProvider)"
  - "app/remote_control/lib/theme/tokens.dart (kBg)"
provides:
  - "SummonShellController — app-scope summon state, guard-id stack, onSurfaceDismissed seam"
  - "SummonScope / SummonGuardScope — non-subscribing InheritedWidget lookups"
  - "SummonShell — the MaterialApp.builder host with the +56 BAR-05 reservation"
  - "SummonBackGuard — the per-route back guard with the ownership canPop"
  - "The hidden-IME slot (empty in Phase 13, filled by Phase 15)"
  - "The rehomed UipiBanner slot (Phase 16 moves the production mount into it)"
  - ".planning/phases/13-summon-shell-bar/TEST-MIGRATION.md"
affects:
  - "app/remote_control/lib/main.dart (builder: + home: wrap)"
  - "every screen's inherited MediaQuery (padding.bottom / viewPadding.bottom +56)"

tech-stack:
  added: []
  patterns:
    - "InheritedWidget + getInheritedWidgetOfExactType (first InheritedWidget in lib/)"
    - "Monotonic int guard-id stack for route ownership, never a retained Route"
    - "ValueListenableBuilder with a build-once cached child wrapping PopScope (from bubble_scaffold.dart:152-166)"
    - "One MediaQuery injection above the Navigator instead of N per-screen edits"

key-files:
  created:
    - ".planning/phases/13-summon-shell-bar/TEST-MIGRATION.md"
    - "app/remote_control/lib/shell/summon_scope.dart"
    - "app/remote_control/lib/shell/summon_shell.dart"
    - "app/remote_control/lib/shell/summon_back_guard.dart"
    - "app/remote_control/test/shell/summon_back_guard_spike_test.dart"
  modified:
    - "app/remote_control/lib/main.dart"

decisions:
  - "D5 spike passed on first run against the real shell and real guard — the app-scope host shape is settled and D-13-04's failure branch was never taken"
  - "S2 was driven through the real SummonShell + SummonBackGuard + SummonShellController rather than the research draft's inline closure, so the shipped mechanism is the proven mechanism"
  - "Three extra spike cases (S2b/S2c/S2d) were added to pin the must_haves edges — no-raise exit, D-13-02 push-after-raise, D-13-03 orphan — rather than deferring them to a later plan"
  - "SummonShell reads MediaQuery.of (not sizeOf/viewInsetsOf locals) because copyWith needs the whole MediaQueryData and unused locals fail the analyzer; viewPaddingOf is still used for the viewPadding value"
  - "The shell does not watch connectionStatusProvider in this plan — nothing here is tinted by connection state yet, so the hot-path rebuild scope stays minimal"

metrics:
  duration: "~50 min"
  completed: 2026-08-14

actuals:
  tokens: 12100
  tasks: 3
  commits: 3
---

# Phase 13 Plan 01: Summon Shell Tracer Summary

The back-dismiss mechanism the whole milestone rests on is now proven in this tree: an app-scope `SummonShell` at `MaterialApp.builder` plus a per-route `SummonBackGuard` intercepts a real system back from a route below the builder, and the +56 bar reservation reaches all 14 screens through one `MediaQuery` injection without breaking a single existing test.

## What Was Built

**Task 1 — baseline + Phase 16 checklist.** Recorded a green pre-shell baseline (the "before" half of RESEARCH OQ-5) and wrote `TEST-MIGRATION.md` while `app/remote_control/lib/shell/` provably did not exist.

**Task 2 (tracer) — the host shape.** Three new files under `lib/shell/`, the two-line `main.dart` insertion, and the D5 spike.

**Task 3 — BAR-05 reservation audit.** Re-ran both packages with the injection live and diffed against the baseline.

## Task Commits

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Pre-flight baseline + test-migration checklist | `f7afc58` | `TEST-MIGRATION.md` |
| 2 | Tracer — end-to-end back interception | `8807ea4` | `summon_scope.dart`, `summon_shell.dart`, `summon_back_guard.dart`, `main.dart`, `summon_back_guard_spike_test.dart` |
| 3 | BAR-05 reservation audit | (no code change — audit recorded here) | none |

## The D5 Spike Result — the headline

**All six assertions passed on the first run. The host shape is settled; the D-13-04 failure branch was never taken.**

| ID | Asserts | Result |
|----|---------|--------|
| **S1** | The `MaterialApp.builder` subtree is an ancestor of the `Navigator`, **and** `ModalRoute.of(builderContext)` is null | pass |
| **S2** | A per-route `SummonBackGuard` intercepts a system back from a route below the **real** `SummonShell`; the first back lowers the surface and leaves the route on screen, the second pops it | pass |
| **S2b** | With nothing raised, `handlePopRoute()` returns false from the root route — the framework declines and Android exits. The hub never traps the user (T-13-05) | pass |
| **S2c** | D-13-02 — a route pushed *after* the raise does not own it, pops normally on back, and the surface rides along | pass |
| **S2d** | D-13-03 — when the owning route is popped by other means, `ownsRaisedSurface` is false on every live route and back exits with the surface still raised | pass |
| **S3** | A `PopScope` in the builder itself never fires and does not stop the route popping — the silent no-op that forces the guard to be per-route | pass |

S2 was deliberately driven through the real `SummonShell` + real `SummonBackGuard` + real `SummonShellController`, not the research draft's inline throwaway closure. The mechanism that ships is the mechanism that is proven.

## BAR-05 Reservation Audit (Task 3)

| Measurement | Pre-injection (Task 1) | Post-injection (Task 3) | Delta |
|---|---|---|---|
| `app/remote_control` runner tests | **882**, all passed, exit 0 | **888**, all passed, exit 0 | **+6** |
| `app/remote_control/test` declarations | **823** | **829** | **+6** |
| `app/packages/remote_protocol` | **22**, all passed | **22**, all passed | 0 — untouched |

**The counts match.** The +6 on both lines is exactly the six new spike declarations (S1, S2, S2b, S2c, S2d, S3). Every pre-existing test that passed before the injection passes after it.

### Triage of status changes across the injection

**The list is empty, and that is the recorded outcome.** Zero tests changed status. Specifically:

- **(a) genuine content-reachability regressions the injection caused, fixed here:** none.
- **(b) tests whose finder assumed the old geometry and were legitimately updated:** none. No test file was touched in Task 3.
- **(c) cases deferred to a later plan:** none newly discovered. `widget_test.dart`'s BAR-01 mutation remains plan 13-08's task as planned, untouched here.

No assertion was loosened, no finder was relaxed, and no failure was silenced. The two suites research flagged as sensitive because they pump real screens through `RemoteControlApp` — `test/widget_test.dart` and `test/hub_offline_test.dart` — both passed unmodified, which is the strongest available evidence that the injection is transparent: they are the only existing tests that see the shell at all.

**Why it was transparent, restated from the evidence:** the injection adds 56 to `padding.bottom` and `viewPadding.bottom` only. `viewInsets` is untouched (`grep -c viewInsets lib/shell/summon_shell.dart` → 3, all three in comments; the `copyWith` call sites are `padding` and `viewPadding` alone), so `Scaffold` still shrinks by the real IME, and every screen's own `SafeArea` absorbs the extra 56 without any screen's child order changing.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 — Blocking] `MediaQuery.sizeOf` / `viewInsetsOf` locals dropped from the shell**

- **Found during:** Task 2
- **Issue:** The plan's action text said to compute `MediaQuery.sizeOf`, `viewPaddingOf` and `viewInsetsOf` into locals before constructing the `MediaQuery` wrap. In this plan the shell has no geometry arithmetic yet (that lands with `summon_geometry.dart` in the next plan), so `size` and `viewInsets` locals would be unused — `unused_local_variable` fails `flutter analyze --no-fatal-infos`. A `viewInsetsOf` local would also have violated this plan's own acceptance criterion that `viewInsets` appear only inside comments.
- **Fix:** Read `MediaQuery.of(context)` for the whole `MediaQueryData` (required anyway — no aspect-scoped accessor returns the full data to `copyWith` from, and `of` subscribes to all metrics, which is precisely the F4 protection the plan wanted) plus `MediaQuery.viewPaddingOf(context)` for the viewPadding value. `MediaQuery.paddingOf` and building from `View.of` are both absent, as required.
- **Files modified:** `app/remote_control/lib/shell/summon_shell.dart`
- **Commit:** `8807ea4`

**2. [Rule 2 — Missing critical coverage] Three extra spike cases added (S2b, S2c, S2d)**

- **Found during:** Task 2
- **Issue:** The plan's `must_haves.truths` include an `[EDGE SUM-04/unclassified]` entry requiring that `canPop` is exactly `!(raised && owner == thisRoute)` — that with nothing raised back still exits from the hub, and that an orphaned surface leaves `canPop` true everywhere. The three-assertion spike as drafted proves none of those three; it only proves the happy path. Shipping a guard whose failure mode is "the phone appears frozen on the dashboard" (T-13-05, severity high) without a test for the exit path would have left the highest-severity threat in the register unpinned.
- **Fix:** Added S2b (no-raise exit asserts `handlePopRoute()` returns false), S2c (D-13-02 push-after-raise), S2d (D-13-03 orphan). All three ride the same real objects as S2.
- **Files modified:** `app/remote_control/test/shell/summon_back_guard_spike_test.dart`
- **Commit:** `8807ea4`

**3. [Rule 2 — Missing critical functionality] Guard re-registration made idempotent**

- **Found during:** Task 2
- **Issue:** `didChangeDependencies` can run more than once. A naive "mint and register every time" would leak stale ids into the guard stack, and each stale id would be a phantom owner candidate.
- **Fix:** `_SummonBackGuardState.didChangeDependencies` early-returns when the controller is identical, and otherwise retires the previous id before minting a new one.
- **Files modified:** `app/remote_control/lib/shell/summon_back_guard.dart`
- **Commit:** `8807ea4`

### Non-deviations worth recording

- `TEST-MIGRATION.md` **reconciles** rather than merely dismisses the 882 figure. The baseline run reports exactly 882 executed tests for `app/remote_control`, so 882 is a real number — it is the runner's executed-test count for one package, not a declaration count across both. Recording only "882 is superseded" would have left the next reader to rediscover that. The corrected 838 / 37 / 5 figures are used throughout, and the supersession of ROADMAP.md's and CONTEXT.md's numbers is stated in the document.
- Declaration counts re-measured this session match RESEARCH X4 exactly: 823 + 15 = 838, zero drift.

## Threat Mitigations Applied

| Threat | Disposition | How it landed |
|---|---|---|
| **T-13-05** (DoS — `canPop` traps the user) | mitigated | Exactly one `canPop:` expression exists in `summon_back_guard.dart` and it is `!(raise != null && raise.ownerGuardId == id)`. Pinned by S2b (nothing raised ⇒ back exits) and S2d (orphan ⇒ back exits). No static false anywhere; predictive back is therefore unaffected |
| **T-13-04** (info disclosure — hidden IME slot) | mitigated | The slot is an empty `SizedBox.shrink()`. The shell adds no `Semantics` label and logs nothing about focus. The constraint and the "do not weaken `HiddenTextInput`'s `ExcludeSemantics`/no-logging contract" instruction are recorded in the slot's own doc comment where Phase 15 will read them |
| **T-13-01** (BAR-03 keyboard gate) | tracked to 13-09 | `hiddenImeNode` is published on `SummonShellController` (always null in Phase 13) so 13-09 can implement the corrected `EditableText`-ancestor predicate. RESEARCH X1's warning that `primaryFocus`-is-null would disable the icon permanently is recorded in that field's doc comment |
| **T-13-SC** (package-manager installs) | accepted, verified nil | `git diff --name-only HEAD~1 -- app/remote_control/android app/remote_control/pubspec.yaml` is empty. Zero packages installed |

## Prohibitions — status

| Prohibition | Status | Evidence |
|---|---|---|
| MUST NOT make Android back unable to leave the app | **verified** | S2b asserts `handlePopRoute()` returns false with nothing raised on the root route; S2d asserts the same for the orphan case. `grep -c 'canPop:'` → 1, and that expression references `ownerGuardId` |
| MUST NOT log or expose focus/text-field/PIN data through semantics | **verified (judgment)** | The shell contains no `Semantics`, no logging call, and no text field — the slot is `SizedBox.shrink()`. Reviewed by reading the whole of `summon_shell.dart` |

## Verification Results

| Check | Result |
|---|---|
| `flutter test test/shell/summon_back_guard_spike_test.dart` | **pass** — 6/6 |
| `flutter test` (`app/remote_control`) | **pass** — 888, exit 0 |
| `flutter test` (`app/packages/remote_protocol`) | **pass** — 22, exit 0 |
| `flutter analyze --no-fatal-infos` | **No issues found!** |
| `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | **pass** — 2/2 |
| `git diff --name-only HEAD~1 -- android pubspec.yaml` | **empty** (D-13-01 honoured) |
| `getInheritedWidgetOfExactType` in `summon_scope.dart` | 5 (≥2 required) |
| `viewPaddingOf` in `summon_shell.dart` | 2 (≥1 required) |
| `MediaQuery.paddingOf` \| `MediaQueryData.fromView` in `summon_shell.dart` | 0 |
| `didChangeMetrics` \| `WidgetsBindingObserver` in `summon_shell.dart` | 0 |
| `unregisterGuard` removal is by value | `remove(` 1, `removeAt(` 0 |

## Known Stubs

| Stub | File | Why it is intentional | Resolved by |
|---|---|---|---|
| Hidden-IME slot is an empty `SizedBox.shrink()` | `lib/shell/summon_shell.dart` | Phase 13 owns the *slot*, not its contents. The slot must exist now because the field has to be a sibling of the animating chrome, and that is a host-shape decision — the whole reason this plan is the tracer | Phase 15 (`HiddenTextInput`) |
| `SummonShellController.hiddenImeNode` is always null | `lib/shell/summon_scope.dart` | Published in this plan so the interface is stable for 13-09's BAR-03 gate; there is no field to point it at yet | Phase 15 |
| `onSurfaceDismissed` has no consumers | `lib/shell/summon_scope.dart` | Phase 13 has no surfaces. The seam is published now specifically so Phases 14/15 cannot each wire their own — D-13-10's requirement | Phases 14 and 15 |
| `barVisible` / `suppressBar` / `releaseBar` have no callers | `lib/shell/summon_scope.dart` | BAR-04's `SummonBarSuppressor` lands in a later plan; the depth counter is published here because the interface section of this plan specifies it | Later Phase 13 plan (BAR-04) |

None of these prevent this plan's goal — proving the host shape — from being achieved. All four are interface commitments this plan was explicitly asked to publish.

## Notes for the Next Plan

- `const double _kBarReservation = 56` is a **local** in `summon_shell.dart` by design. The next plan introduces `summon_geometry.dart` and must replace it with the imported `kSummonBarHeight`; a one-line comment at the declaration says so.
- `lib/shell/` now contains the tree's **first** `InheritedWidget`s. `13-PATTERNS.md` correctly recorded "no analog in tree" — `summon_scope.dart` is now the analog for anything similar later.
- The `_RecordingService` + `_FakeSecureKv` / `_FakePrefsKv` trio was copied into the spike suite rather than imported, because the shared harness (`summon_test_harness.dart`) does not exist yet. Plan 13-02 creates it; the spike should then import from it rather than keeping a second copy.
- `.gsd/` appeared as an untracked directory during this run (GSD tooling runtime state, not project output). Left untracked and uncommitted deliberately — deciding whether it belongs in `.gitignore` is a repo-wide call outside this plan's scope.
- **Tracer feedback gate note:** the plan carries no expansion tasks after the tracer (Task 3 is a read-only audit that changed no code), so there was no expansion to gate. The tracer's `<verify>` was re-run end-to-end and is green, and the audit hands over a fully verified tree rather than an unverified one.

## Self-Check: PASSED

All six claimed artifacts exist on disk; both claimed commit hashes (`f7afc58`, `8807ea4`) resolve in `git log`.
