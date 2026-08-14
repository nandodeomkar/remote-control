---
phase: 13
slug: summon-shell-bar
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
status: draft
nyquist_compliant: true
wave_0_complete: false
created: 2026-08-14
---

# Phase 13 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.
> Derived from `13-RESEARCH.md` `## Validation Architecture`.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | `flutter_test` from the pinned SDK — Flutter 3.44.5 / Dart 3.12.2 |
| **Config file** | none — no `dart_test.yaml`, no `flutter_test_config.dart`; `test/` layout is the convention |
| **Quick run command** | `flutter test test/shell` (from `app/remote_control`) |
| **Full suite command** | `flutter test` (from `app/remote_control`) — 823 declarations |
| **Estimated runtime** | quick ~seconds · full suite ~2-4 min |

**Second package:** `cd app/packages/remote_protocol && flutter test` — 15 declarations, **untouched by this phase**.

---

## Sampling Rate

- **After every task commit:** Run `flutter test test/shell` (the new suites only — seconds)
- **After every plan wave:** Run `flutter test` (full 823-declaration suite, from `app/remote_control`)
- **Before `/gsd-verify-work`:** Full suite green **plus** both guard suites (`theme_tokens_guard_test.dart`, `icons_guard_test.dart`) green
- **Max feedback latency:** ~10 seconds for the quick run

---

## Per-Task Verification Map

> Task IDs are assigned when PLAN.md files are written. This table maps requirements
> to their automated command and Wave-0 dependency. **Task ID / Plan / Wave filled from the
> ten committed PLAN.md files on 2026-08-14.** Task IDs are `{phase}-{plan}-T{task}`. Where a
> file is created by one task and extended by a later one, both are listed in commit order —
> the row is not green until the last of them is.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 13-02-T3 · 13-08-T1 | 13-02 · 13-08 | 2 · 3 | BAR-01 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart -j1` | ❌ W0 | ⬜ pending |
| 13-08-T2 | 13-08 | 3 | BAR-01 | — | N/A | widget | `flutter test test/widget_test.dart` | ✅ mutate | ⬜ pending |
| 13-02-T1 · 13-04-T1 | 13-02 · 13-04 | 2 · 4 | BAR-02 | — | N/A | widget | `flutter test test/shell/summon_geometry_test.dart` | ❌ W0 | ⬜ pending |
| 13-09-T1 | 13-09 | 4 | BAR-03 | T-13-01 | A pairing PIN can never be typed into the PC — keyboard icon disabled while a non-shell `EditableText` holds focus | widget | `flutter test test/shell/summon_bar_focus_gate_test.dart` | ❌ W0 | ⬜ pending |
| 13-09-T2 | 13-09 | 4 | BAR-04 | T-13-02 | Bar absent under `SummonBarSuppressor` (QR scan); depth-counted across push/pop | widget | `flutter test test/shell/summon_bar_scope_test.dart` | ❌ W0 | ⬜ pending |
| 13-08-T1 | 13-08 | 3 | BAR-05 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ W0 | ⬜ pending |
| 13-01-T3 · 13-08-T2 | 13-01 · 13-08 | 1 · 3 | BAR-05 | — | N/A | widget | `flutter test test/hub_offline_test.dart` | ✅ re-run | ⬜ pending |
| 13-02-T3 · 13-08-T1 | 13-02 · 13-08 | 2 · 3 | SUM-01 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ W0 | ⬜ pending |
| 13-08-T1 | 13-08 | 3 | SUM-02 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ W0 | ⬜ pending |
| 13-03-T1 · 13-03-T2 | 13-03 | 3 | SUM-03 | — | N/A | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ W0 | ⬜ pending |
| 13-01-T2 | 13-01 | 1 | SUM-04 | — | N/A | widget | `flutter test test/shell/summon_back_guard_spike_test.dart` | ❌ W0 | ⬜ pending |
| 13-05-T1 | 13-05 | 3 | SUM-04 | — | N/A | widget | `flutter test test/shell/summon_back_guard_test.dart` | ❌ W0 | ⬜ pending |
| 13-06-T2 | 13-06 | 3 | SUM-04 | — | N/A | widget | `flutter test test/browser/browser_back_priority_test.dart` | ❌ W0 | ⬜ pending |
| 13-05-T2 | 13-05 | 3 | SUM-04 | — | N/A | widget | `flutter test test/shell/predictive_back_baseline_test.dart` | ❌ W0 | ⬜ pending |
| 13-07-T2 | 13-07 | 3 | SUM-04 | — | N/A | unit | `flutter test test/push_sites_guard_test.dart` | ❌ new | ⬜ pending |
| 13-03-T2 | 13-03 | 3 | MOT-01 | — | N/A | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ W0 | ⬜ pending |
| 13-04-T2 | 13-04 | 4 | (geometry) | — | N/A | widget | `flutter test test/shell/summon_geometry_test.dart` | ❌ W0 | ⬜ pending |
| 13-01-T2 · 13-02-T2 · 13-07-T2 · 13-09-T1 · 13-10-T1 | all waves | 1 · 2 · 3 · 4 · 5 | (guards) | — | N/A | unit | `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ re-run | ⬜ pending |
| 13-01-T1 · 13-01-T3 · 13-10-T3 | all waves | 1 · 5 | (regression) | — | N/A | widget | `flutter test test/trackpad/trackpad_screen_test.dart test/keyboard/keyboard_panel_test.dart` | ✅ re-run | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

**Detail on the non-obvious rows:**

- **BAR-02** asserts `surfaceRect.bottom == barRect.top` and that the bar stays tappable while raised.
- **SUM-02** carries the surviving contract from `bubble_scaffold_test.dart:156-186` — *a tappable widget outside the raised surface still receives its tap* — plus a byte-identical `Rect` comparison for a body widget before and after a raise.
- **SUM-04 / D5 spike** is three test bodies: S1 ancestry (`MaterialApp.builder` result is the Navigator's ancestor), S2 intercept (per-route guard catches back), S3 the shell-level `PopScope` no-op as a diagnostic.
- **SUM-04 / D-13-02 scenario:** raise on hub → push tool → back pops tool → back lowers → back exits.
- **SUM-04 / D-13-03 orphan:** raise on a tool route → pop it via the AppBar arrow → back from the hub exits with the surface still raised.
- **SUM-04 / D-13-05 browser:** subfolder + raised → one back lowers only; second exits the folder; third pops.
- **Predictive-back baseline (D-13-01):** `setFrameworkHandlesBack(false)` on the hub with nothing raised, `true` while raised, `false` again after lowering. Requires `handleAppLifecycleStateChanged(resumed)` and `debugDefaultTargetPlatformOverride = android`, or it silently passes.
- **MOT-01 dismiss** asserts mid at t=75 and at rest at **t=160** — deliberately tight enough to fail a 200ms dismiss. `pumpAndSettle` is banned for every timing assertion in these suites.
- **`(geometry)` runs in wave 4, not wave 3.** 13-04 depends on 13-03: 13-03 replaces the resting surface height with the swap lerp, and F4 — the retarget discriminator — must be pinned against that final height source. Running the two in one wave would let F4 land green against 13-02's shell and be broken in parallel by 13-03's.
- **`(guards)` and `(regression)` have no single owning task.** The guard suites are re-run as an explicit `<automated>` gate in five tasks across every wave; the two regression suites are covered by the full-suite `flutter test` gate every plan carries, with 13-01-T1 recording the pre-phase baseline and 13-01-T3 auditing them immediately after the +56 reservation lands. Attributing either row to one task would be a fiction.
- **`test/push_sites_guard_test.dart`** was not in the seeded table. It is 13-07-T2's source-scanning guard against an un-guarded `Navigator.push`, so it belongs under SUM-04. It is a new file but not a Wave-0 blocker: no other task's verification depends on it.

---

## Wave 0 Requirements

- [ ] `test/shell/` directory — **does not exist** (verified: absent)
- [ ] `test/shell/summon_back_guard_spike_test.dart` — the D5 spike, **first file in the phase** (SUM-04)
- [ ] `test/shell/summon_shell_test.dart` — BAR-01, BAR-05, SUM-01, SUM-02
- [ ] `test/shell/summon_geometry_test.dart` — the five driven viewports + the F1/F2/F3/F4/F5 discriminators and probe
- [ ] `test/shell/summon_motion_test.dart` — MOT-01, SUM-03, the swap
- [ ] `test/shell/summon_bar_focus_gate_test.dart` — BAR-03
- [ ] `test/shell/summon_bar_scope_test.dart` — BAR-04
- [ ] `test/shell/summon_back_guard_test.dart` — D-13-02, D-13-03
- [ ] `test/shell/predictive_back_baseline_test.dart` — D-13-01
- [ ] `test/browser/browser_back_priority_test.dart` — D-13-05
- [ ] Shared harness: `pumpShell()` + `driveView()` + `availableOf()` helper file. **Harvest** `_RecordingService` from `test/bubble_scaffold_test.dart:65-81` and the `_NoopWakelock` stub from `test/trackpad/trackpad_screen_test.dart:41-47` **before** Phase 16 deletes their homes
- [ ] Framework install: **none** — `flutter_test` is already a dev dependency

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Summon/dismiss feel quick at dozens-of-summons-per-session frequency | MOT-01 / SC5 | Felt latency is a human judgement; no test can close OQ-A1 sub-question 1 | Raise and lower both surfaces repeatedly on the owner's device. 200/150 is a one-constant change each if it does not feel right |
| Height fractions correct on the owner's device | CONTEXT D-13-09 | Declared design choices, tuned on hardware | Raise each surface; confirm the raised trackpad beats the retiring bubble window's 234px and stays clearly smaller than the full Trackpad screen |
| System back-to-home peek still plays from the hub with nothing raised | SC3 / D-13-01 | Only the OS compositor renders the peek; a widget test can see the handler flag but not the animation | Gesture back from the hub with nothing raised; record what the peek does as the baseline |
| Browser tab list and bookmarks section at 640dp with the bar present | BAR-05 / SC1 | Real device height plus real content | Open Browser, both segments, confirm nothing is clipped or stranded behind the bar |
| Power confirm dialog with the bar rendered over it | BAR-01 | Dialog + app-scope shell interaction | Trigger restart/shutdown confirm; confirm the bar does not occlude the dialog's actions |

---

## Validation Sign-Off

- [x] All tasks have `<automated>` verify or Wave 0 dependencies — every non-checkpoint task across the ten plans carries at least one `<automated>` block
- [x] Sampling continuity: no 3 consecutive tasks without automated verify
- [x] Wave 0 covers all MISSING references (10 new test files + the shared harness) — each of the eleven is created by a named task, `summon_test_harness.dart` by 13-02-T3
- [x] No watch-mode flags
- [x] Feedback latency < 10s for the quick run — `flutter test test/shell`, projected from the existing suite's per-file cost; re-check against the real number once wave 2 lands
- [x] `nyquist_compliant: true` set in frontmatter

**Still open (deliberately unticked):** `wave_0_complete` stays `false` — none of the eleven
Wave-0 files exist yet, so every box under **Wave 0 Requirements** is correctly empty. They
are ticked by execution, not by planning.

**Approval:** pending — Task ID / Plan / Wave filled and Dimension 8 signed off by the
plan-phase revision pass on 2026-08-14. `status:` stays `draft`; `validated` is set by
validate-phase §6.
