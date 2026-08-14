# Phase 16 Test-Migration Checklist

**Written:** 2026-08-14, during Phase 13 plan 01 Task 1.
**Executed:** Phase 16 (the bubble/window deletion).
**Written before any `lib/shell/` code existed** — `app/remote_control/lib/shell/` was
verified absent at the moment this file was committed, so Phase 16 executes a document
that provably predates the first line of the code it retires.

---

## The rule (verbatim, non-negotiable)

> **Do not delete a file until its successor exists.** Copy each deleted suite's header
> contract block into its successor and tick every line.

(`13-RESEARCH.md` §12, P11.) A suite is not "migrated" because a new suite covers roughly
the same ground. It is migrated when every numbered contract in its header block has been
transcribed into the successor's header block and ticked off against a real assertion.

---

## Counts — the corrected figures

**Use 838 / 37 / 5.** The **882 / ~42 / 5** figures repeated in `.planning/ROADMAP.md` and
`13-CONTEXT.md` are **superseded** by `13-RESEARCH.md` correction X4. A later reader who
takes 882 as a declaration count will go hunting for a 44-test gap that does not exist.

| Figure | Value | What it counts |
|---|---|---|
| `app/remote_control/test` declarations | **823** | `test(` / `testWidgets(` declarations, tree-verified at `master @ e2741fa` and re-measured in this task |
| `app/packages/remote_protocol/test` declarations | **15** | same |
| **Total declarations** | **838** | 823 + 15 |
| Declarations that vanish in Phase 16 | **37** | 4 whole suites: 6 + 6 + 12 + 13 |
| Declarations rewritten | **5** | `bubble_scaffold_test.dart` |
| Suites re-run as a net | **2** | `widget_test.dart`, `hub_offline_test.dart` |

### Measured drift against RESEARCH (this task's baseline run)

| Measurement | RESEARCH | Measured 2026-08-14 | Drift |
|---|---|---|---|
| `app/remote_control/test` declarations | 823 | **823** | none |
| `app/packages/remote_protocol/test` declarations | 15 | **15** | none |
| **Total declarations** | **838** | **838** | none |

**Where the 882 actually comes from — reconciled, not dismissed.** The baseline run of
`cd app/remote_control && flutter test` reports **882 tests passed**. That is the *runner's*
executed-test count for `app/remote_control` alone; it exceeds the 823 declaration count
because several declarations sit inside `for` loops over case tables and execute more than
once (`widget_test.dart`'s "app shell homes on the dashboard" alone runs 13 times). So 882
is a real number — it is simply **not** a declaration count, and it is **not** the total
across both packages. Do not subtract 838 from 882 and call the difference missing tests.

**Baseline captured immediately before the first `lib/shell/` file** (the "before" half of
`13-RESEARCH.md` OQ-5, so a red test after the BAR-05 +56 reservation reads as signal, not
pre-existing noise):

| Package | Runner result | Exit |
|---|---|---|
| `app/remote_control` | **882 tests, All tests passed!** | 0 |
| `app/packages/remote_protocol` | **22 tests, All tests passed!** | 0 — untouched by this phase |

---

## The migration table

| Suite | Decls | Fate | Successor | Contracts that MUST survive |
|---|---|---|---|---|
| `test/bubble_scaffold_test.dart` | **5** | **Rewrite → `test/shell/summon_shell_test.dart`** | **`test/shell/summon_shell_test.dart`** — Phase 13 creates it; Phase 16 deletes the original | Header contracts at `:1-23`. See the C1-C5 subsection below — every line has a named fate |
| `test/trackpad_bubble_test.dart` | **6** (3 groups) | **Delete** (Phase 16) | none | none — bubble-specific |
| `test/floating_trackpad_window_test.dart` | **6** (5 groups) | **Delete** (Phase 16) | none | **Harvest** the `_RecordingService` + `KeepAwake` spy idiom (`:22-24`) into the shared shell harness *before* deleting |
| `test/window_position_test.dart` | **12** (3 groups) | **Delete** (Phase 16) | none | none |
| `test/bubble_position_test.dart` | **13** (3 groups) | **Delete** (Phase 16) | none | none — but run the grep-before-delete list below; the analyzer will not flag an unused public const |
| `test/widget_test.dart` | **2** | **Mutate — in Phase 13**, not 16 | itself | The only test that pumps `RemoteControlApp` (`main.dart`), so the only existing test that sees the shell. Plan 13-08 adds: the bar renders on the hub (BAR-01) |
| `test/hub_offline_test.dart` | **2** | **Re-run** in Phase 13 | itself | Asserts `onTap: null` + gear reachability. The +56 bottom padding must not break its finds |
| `test/hub_tiles_test.dart` | **4** | Phase 17 | itself | Out of Phase 13's scope; listed so the checklist is complete |
| `test/hub/hub_screen_test.dart` | **2** | Phase 17 | itself | `:22-35` pins "D-02: the trackpad is the full-width primary tile — always first in the registry". **The rationale is already stale** (the primary row died in 07-13). Phase 17 must give it a *new* rationale and **never** re-pin Trackpad to index 0 — that silently reverts RET-02 |
| `test/theme_tokens_guard_test.dart` | 1 | **Re-run every wave** | itself | Fails the build on any raw palette hex in new shell code |
| `test/icons_guard_test.dart` | 1 | **Re-run every wave** | itself | Fails the build on any `Icons.` in new shell code |
| `test/trackpad/trackpad_screen_test.dart` | 5 | **Unchanged in 13** | itself | The docked-panel inset guards at `:225-307` are the regression net proving the summon arithmetic did **not** disturb `panelPadHeight`. Re-run; do not touch |
| `test/keyboard/keyboard_panel_test.dart` | 20 | **Unchanged in 13** | itself | Re-run as the behaviour-neutrality net |

**Net for Phase 16:** **37** declarations vanish (4 whole suites: 6 + 6 + 12 + 13), **5** are
rewritten (`bubble_scaffold_test.dart`), **2** re-run (`widget_test.dart`,
`hub_offline_test.dart`). Not 42 / 882.

---

## `test/bubble_scaffold_test.dart` — C1 through C5, individually

The header contract block at `bubble_scaffold_test.dart:1-23` is the single most important
thing to migrate. Its five numbered lines, with a fate for each:

| ID | Contract (as written at `:1-23`) | Fate |
|---|---|---|
| **C1** | *presence* — `showBubble:true` renders the `TrackpadBubble` over the body and the `UipiBanner` host is present | **Dies with the bubble.** The `TrackpadBubble` half has no successor. The `UipiBanner`-host half does **not** die — it moves: the banner slot is rehomed into `SummonShell` (SAFE-03), and `summon_shell_test.dart` must assert `find.byType(UipiBanner)` resolves under the shell |
| **C2** | *absence* — `showBubble:false` renders neither `TrackpadBubble` nor `FloatingTrackpadWindow`, but the `UipiBanner` slot still rides | **Dies with the bubble.** `showBubble` ceases to exist as a concept; there is one app-scope shell and no per-screen opt-out |
| **C3** | *expand toggle (never both visible, D8-01)* — tapping the bubble replaces it with a `FloatingTrackpadWindow`; tapping the window's ✕ collapses back | **Mutates** → "tapping a bar icon raises the surface; tapping the same icon again lowers it; two surfaces are never up at once" (SUM-01, SUM-03). The invariant survives; only the affordance changes |
| **C4** | *body-hit-testable* — a tappable widget in the body **outside** the window's card rect still receives a tap while the window is open (the body is a `Positioned.fill` sibling, never rebuilt off it — Pitfall 3/6) | **Survives verbatim in spirit.** **This is the single most valuable contract in the milestone**: it is what proves "overlay, not screen" (SUM-02). The successor pumps a tap target in the body outside the raised surface's rect and asserts it still fires. Do not weaken it into a `findsOneWidget`; it must be an actual `t.tap` with a counter |
| **C5** | *back-intercept (D8-08)* — a system back while expanded collapses the window instead of popping the route; a second back pops | **Mutates** → the `SummonBackGuard` test (SUM-04, D-13-02, D-13-03) in `test/shell/summon_back_guard_test.dart`, with the ownership predicate added: only the *owning* route intercepts, and an orphaned surface leaves `canPop` true everywhere |

**Tick-off procedure for Phase 16:** copy the whole `:1-23` block into
`test/shell/summon_shell_test.dart`'s header, rewrite each line to its mutated form above,
and only then delete `bubble_scaffold_test.dart`.

---

## Grep-before-delete — symbols the analyzer will NOT flag

An unused *public* top-level const produces no analyzer warning. Grep each of these across
`lib/` **and** `test/` before deleting its home, or a dangling reference ships silently:

- `kBubbleSize`
- `kBubbleEdgeInset`
- `_bubbleAnchor`
- `bubblePositionProvider`
- `windowPositionProvider`

Also grep `kBubbleExpandDuration` — Phase 13 deliberately declares its own
`kSummonRaiseDuration = 200ms` rather than importing the bubble's, precisely so this
deletion is free.

---

## Harvest before deletion

Two test doubles live in files Phase 16 deletes and are needed by the shell suites. Lift
them into the shared shell harness (`test/shell/summon_test_harness.dart`, created by plan
13-02) **before** the deletion, not after:

| Double | Current home | Why it is needed |
|---|---|---|
| `_RecordingService` (+ `_FakeSecureKv` / `_FakePrefsKv`) | `test/bubble_scaffold_test.dart:40-81` | How a shell test gets a connected/disconnected `connectionStatusProvider` without a socket. Every `SummonBar` tint test needs it |
| the no-op wakelock stub | `test/trackpad/trackpad_screen_test.dart:41-47` | Keeps `KeepAwake` off the plugin channel when a shell test pumps a real trackpad surface (Phase 14) |
| the `KeepAwake` spy idiom | `test/floating_trackpad_window_test.dart:22-24` | Same, for the acquire/release assertion |

---

## Phase 16 exit condition

- [ ] `test/shell/summon_shell_test.dart` exists and its header carries the migrated C1-C5 block, every line ticked
- [ ] `_RecordingService` and the wakelock stub live in the shared harness
- [ ] The five grep-before-delete symbols return zero hits outside the files being deleted
- [ ] Only then: delete `bubble_scaffold_test.dart`, `trackpad_bubble_test.dart`, `floating_trackpad_window_test.dart`, `window_position_test.dart`, `bubble_position_test.dart`
- [ ] Full suite green; declaration count drops by exactly 37 + 5-rewritten, to a measured, recorded number
