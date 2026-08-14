---
phase: 13
slug: summon-shell-bar
# status lifecycle: draft (seeded by plan-phase) → validated (set by validate-phase §6)
status: draft
nyquist_compliant: false
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
> to their automated command and Wave-0 dependency; the planner fills Task ID / Plan /
> Wave columns.

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| TBD | TBD | TBD | BAR-01 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart -j1` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BAR-01 | — | N/A | widget | `flutter test test/widget_test.dart` | ✅ mutate | ⬜ pending |
| TBD | TBD | TBD | BAR-02 | — | N/A | widget | `flutter test test/shell/summon_geometry_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BAR-03 | T-13-01 | A pairing PIN can never be typed into the PC — keyboard icon disabled while a non-shell `EditableText` holds focus | widget | `flutter test test/shell/summon_bar_focus_gate_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BAR-04 | T-13-02 | Bar absent under `SummonBarSuppressor` (QR scan); depth-counted across push/pop | widget | `flutter test test/shell/summon_bar_scope_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BAR-05 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | BAR-05 | — | N/A | widget | `flutter test test/hub_offline_test.dart` | ✅ re-run | ⬜ pending |
| TBD | TBD | TBD | SUM-01 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SUM-02 | — | N/A | widget | `flutter test test/shell/summon_shell_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SUM-03 | — | N/A | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SUM-04 | — | N/A | widget | `flutter test test/shell/summon_back_guard_spike_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SUM-04 | — | N/A | widget | `flutter test test/shell/summon_back_guard_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SUM-04 | — | N/A | widget | `flutter test test/browser/browser_back_priority_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | SUM-04 | — | N/A | widget | `flutter test test/shell/predictive_back_baseline_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | MOT-01 | — | N/A | widget | `flutter test test/shell/summon_motion_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | (geometry) | — | N/A | widget | `flutter test test/shell/summon_geometry_test.dart` | ❌ W0 | ⬜ pending |
| TBD | TBD | TBD | (guards) | — | N/A | unit | `flutter test test/theme_tokens_guard_test.dart test/icons_guard_test.dart` | ✅ re-run | ⬜ pending |
| TBD | TBD | TBD | (regression) | — | N/A | widget | `flutter test test/trackpad/trackpad_screen_test.dart test/keyboard/keyboard_panel_test.dart` | ✅ re-run | ⬜ pending |

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

---

## Wave 0 Requirements

- [ ] `test/shell/` directory — **does not exist** (verified: absent)
- [ ] `test/shell/summon_back_guard_spike_test.dart` — the D5 spike, **first file in the phase** (SUM-04)
- [ ] `test/shell/summon_shell_test.dart` — BAR-01, BAR-05, SUM-01, SUM-02
- [ ] `test/shell/summon_geometry_test.dart` — the five driven viewports + F3/F5 discriminators
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

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references (10 new test files + the shared harness)
- [ ] No watch-mode flags
- [ ] Feedback latency < 10s for the quick run
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
