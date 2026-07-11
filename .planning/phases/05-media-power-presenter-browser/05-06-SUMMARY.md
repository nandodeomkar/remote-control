---
phase: 05-media-power-presenter-browser
plan: 06
subsystem: ui
tags: [flutter, power, fsm, slide-to-confirm, dialog, hub, safety-gate]

# Dependency graph
requires:
  - phase: 05-media-power-presenter-browser
    plan: 02
    provides: HubScreen + kHubTiles ordered registry (tile insertion point), tool-screen skeleton (chip + banner + sendReliable + gated-muted)
  - phase: 05-media-power-presenter-browser
    plan: 04
    provides: hub-tile insertion + tool-screen wiring pattern (Presenter tile precedent)
  - phase: 05-media-power-presenter-browser
    plan: 05
    provides: real WinPower executor (LockWorkStation/SetSuspendState/ExitWindowsEx) behind the router power->confirm 10s gate — the client now drives live actions
  - phase: 01-protocol-contract
    provides: PowerMsg + ConfirmMsg codecs; server router power->confirm double-confirm gate
provides:
  - ConfirmTrackFsm pure slide-to-confirm FSM (idle -> dragging(progress) -> completed) — IO-free, effects out, no wire types
  - PowerScreen — four slide-to-confirm tracks + the app's ONE modal (red countdown dialog) wired to sendReliable
  - Power hub tile (Icons.power_settings_new) between Trackpad and Presenter
affects: [05-07, 07-polish-dashboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure per-instance slide-to-confirm FSM (mirrors modifier_fsm/presenter_timer): events in, sealed effects out, driver executes — no Flutter/IO/timers/wire types"
    - "Effect-to-message mapping lives in the screen only: PowerMsg from exactly one FSM-effect site, ConfirmMsg from exactly two (lock/sleep effect + dialog button)"
    - "Dialog-local 1s Timer.periodic drives the countdown render; auto-dismiss at 0 sends nothing (the timeout surface); the FSM owns no timer"

key-files:
  created:
    - app/remote_control/lib/power/confirm_track_fsm.dart
    - app/remote_control/lib/power/power_screen.dart
    - app/remote_control/test/power/confirm_track_fsm_test.dart
  modified:
    - app/remote_control/lib/hub/hub_screen.dart
    - app/remote_control/test/hub/hub_screen_test.dart

key-decisions:
  - "ConfirmTrackFsm completion transitions to a real `completed` state (not straight to idle) so the widget can render the full-fill flash; the next dragStart resets it (completed -> fresh drag). All explicit plan test cases assert effect lists, not a post-completion idle."
  - "SendPower is ALWAYS effect[0]; the second effect diverges by pair via a single conditional (SendConfirm for lock/sleep, OpenCountdown for restart/shutdown) — the FSM can never yield SendConfirm for the destructive pair (T-05-12/PWR-03 proven at unit level)."
  - "Track drag progress = finger localPosition.dx / trackWidth (per plan), clamped 0..1; thumb/fill animate with duration 0 while dragging and 200ms on spring-back."
  - "The bare-grid hub test host (no scroll) overflowed once a 4th tile made two half-tile rows; enlarged its test surface to 800x1400 rather than change production layout (HubScreen already hosts the grid in a SingleChildScrollView)."

requirements-completed: [PWR-01, PWR-02, PWR-03]

# Metrics
duration: ~7min
completed: 2026-07-11
---

# Phase 5 Plan 06: Power Control Slice Summary

**All four power actions now live behind a deliberate-gesture safety contract: a pure IO-free ConfirmTrackFsm gates every send behind a completed ≥0.9 slide, lock/sleep fire `power`+`confirm` back-to-back on completion (D-05), restart/shutdown fire `power` only and open the app's one red countdown dialog whose confirm button is the sole `confirm` sender (D-06) — no single-action path to any host power action exists (T-05-12, SC3), driving the real WinPower executor 05-05 landed this wave.**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-07-11T02:50:17Z
- **Completed:** 2026-07-11
- **Tasks:** 2 (Task 1 TDD RED+GREEN, Task 2 screen + hub tile)
- **Files:** 3 created, 2 modified

## Accomplishments

- **ConfirmTrackFsm (PWR-01..03, D-05/D-06):** pure per-track FSM over `idle → dragging(progress) → completed`. `dragStart`/`dragUpdate(progress, clamped 0..1)`/`dragEnd` events; sealed effects (`SendPower`, `SendConfirm`, `OpenCountdown`, `SpringBack`) carry only the action string. Completion threshold `kConfirmCompletionThreshold = 0.9` (inclusive). Lock/sleep completion → `[SendPower, SendConfirm]` in strict order; restart/shutdown → `[SendPower, OpenCountdown]` with NO `SendConfirm` anywhere for the destructive pair; below-threshold release → `[SpringBack]`, idle, nothing sent. Zero Flutter imports, no timers, no wire types. 18 deterministic tests green.
- **PowerScreen (D-05/D-06):** slim "Power" app bar + header chip + reconnecting banner (D-02) over four stacked slide tracks — Lock, Sleep (safe pair, `#4C8DFF`), md-gapped, then a lg gap, then Restart, Shut down (destructive pair, `#FF6B6B`). Each track owns one ConfirmTrackFsm; horizontal drags feed the FSM with `progress = localPosition.dx / trackWidth`. Render per the UI-SPEC state table: 64px track, 56px thumb (4px inset) carrying action icon + chevron, 20%-opacity action-color fill behind the thumb, label fades as progress grows, 200ms spring-back on cancel, full-fill flash + `HapticFeedback.mediumImpact()` on completion. Tracks inert/muted (`#6B7280`) when the header chip is not connected — never red.
- **Effect execution — the single-action-path gate (T-05-12):** `PowerMsg` is sent from exactly ONE site (the `SendPower` effect branch); `ConfirmMsg` from exactly TWO (the lock/sleep `SendConfirm` branch, same-tick after `SendPower` so the reliable queue preserves FIFO order per D-05, and the dialog confirm button). There is no plain button anywhere on the screen that maps to a power send.
- **Red countdown dialog (D-06 — the app's ONE modal):** `AlertDialog` on `#16181D`, `#FF6B6B` heading icon + "Restart PC?"/"Shut down PC?", body "This will close everything open on your PC.", tabular "Confirm within {n}s" ticking `kPowerConfirmWindowSeconds = 10` → 0 (mirror of server CONFIRM_WINDOW). A dialog-local 1s `Timer.periodic` (cancelled on dispose) drives the count; reaching 0 auto-pops sending NOTHING; Cancel/barrier-dismiss pop without sending; the destructive `FilledButton` (`#FF6B6B` fill, `#0E0F12` label, ≥48px) sends `ConfirmMsg` + haptic and pops.
- **Quiet-after-confirm (RESEARCH Pattern 5):** no error plumbing on this screen — a post-confirm socket drop (PC suspending/rebooting) surfaces only the inherited reconnecting banner; a late `confirm` earning `err{noPendingAction}` is silently ignored (the auto-dismiss at 0s IS the timeout surface).
- **Hub tile:** `Power` (`Icons.power_settings_new`) inserted into `kHubTiles` between Trackpad and Presenter → order now Trackpad, Power, Presenter, Browser (Media inserts ahead of Power in 05-07 to reach the final UI-SPEC reading order).

## Task Commits

1. **Task 1 RED — failing ConfirmTrackFsm effect-sequence tests** — `b582e6d` (test)
2. **Task 1 GREEN — ConfirmTrackFsm implementation** — `c73c9a7` (feat)
3. **Task 2 — PowerScreen + countdown dialog + hub tile** — `061db58` (feat)

## TDD Gate Compliance

- RED gate `b582e6d`: the test file failed to load (`ConfirmTrackFsm`/`ConfirmTrackState` undefined), verified before implementation.
- GREEN gate `c73c9a7`: all 18 FSM tests pass; `grep -c "import 'package:flutter"` on confirm_track_fsm.dart = 0 (pure Dart).
- REFACTOR: not needed.

## Verification Evidence

- `flutter test` — 267 tests pass (18 new ConfirmTrackFsm cases included).
- `flutter analyze --no-pub` — No issues found.
- Acceptance (send-site inspection, the T-05-12 contract): `sendReliable(PowerMsg` = 1 site; `sendReliable(ConfirmMsg` = 2 sites (lock/sleep effect + dialog button) — the only power/confirm senders. `kPowerConfirmWindowSeconds` present as the constant + dialog seed. `PowerScreen` in hub_screen.dart = 1; hub registry test green with Trackpad first. power_screen.dart 520 lines (≥150). No plain-button power send exists (source inspection).
- On-device two-gesture restart/shutdown, slide-gated lock/sleep, partial-slide-springs-back: deferred to the end-of-phase on-device gate (05-VALIDATION Manual-Only, SC2/SC3) per the plan's `<human-check>`.

## Decisions Made

- Completion leaves the FSM in a real `completed` state (widget renders the full-fill flash); a subsequent `dragStart` begins a fresh drag. The plan's explicit test cases assert effect lists/order, not a post-completion `idle`, so this reading satisfies the contract while giving every enum value meaning.
- `SendPower` is unconditionally effect[0]; a single `if (isDestructive)` picks the second effect — structurally impossible for the destructive pair to emit `SendConfirm` (unit-proven, T-05-12/PWR-03).
- Drag progress uses the finger's local x over the track width (per plan); thumb/fill animation duration is 0 during the drag (thumb tracks the finger) and 200ms on spring-back / completion-reset.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Bare-grid hub test overflowed once a 4th tile was added**
- **Found during:** Task 2 (full-suite run after inserting the Power tile).
- **Issue:** `hub_screen_test.dart` hosts `HubTileGrid` directly in a Scaffold body (no scroll). With a 4th tile the grid became two half-tile rows and overflowed the default 800×600 test surface by 88px (RenderFlex overflow), failing the "grid renders every tile" widget test. Production `HubScreen` wraps the grid in a `SingleChildScrollView`, so this is a bare-test-host limitation, not a production layout bug.
- **Fix:** Enlarged that test's view to 800×1400 (with teardown reset) so the registry fits as it grows — no change to production layout.
- **Files modified:** app/remote_control/test/hub/hub_screen_test.dart
- **Verification:** hub test green (Trackpad still asserted first); full suite 267 green.
- **Committed in:** 061db58

**Total deviations:** 1 auto-fixed (test-fixture layout). No architectural changes; no scope creep; no new packages (T-05-SC accept).

## Threat Surface

Both mitigations in the plan's `<threat_model>` implemented as designed:
- **T-05-12 (single-action-path EoP, mitigate):** `PowerMsg` sent only from a completed ≥0.9 slide's FSM effect (one site); `ConfirmMsg` for restart/shutdown only from the dialog button; the FSM structurally cannot emit `SendConfirm` for the destructive pair (unit-proven). Server single-shot 10s gate remains authoritative (unchanged).
- **T-05-13 (accidental trigger, mitigate):** 0.9 completion threshold + spring-back on early release, unit-tested at 0.0/0.5/0.89; tracks inert when disconnected.
- T-05-14 (stale confirm replay, accept) and T-05-SC (supply chain, accept): honored — late confirm ignored by design; no new packages. No new endpoints, auth paths, or trust-boundary surface introduced.

## Known Stubs

None — the slice is wired end-to-end against the live 05-05 WinPower executor and the existing router power→confirm gate; no placeholder data or unwired components.

## Issues Encountered

None beyond the one documented deviation.

## Next Phase Readiness

- The hub registry has room for the final tile: 05-07 inserts Media ahead of Power to reach the final Trackpad, Media, Power, Presenter, Browser reading order.
- Power is live end-to-end (client slide-to-confirm → server WinPower); the on-device double-gesture / no-single-action-path check is the only remaining item, folded into the end-of-phase manual gate (SC2/SC3).

---
*Phase: 05-media-power-presenter-browser*
*Completed: 2026-07-11*

## Self-Check: PASSED

All three created source/test files plus 05-06-SUMMARY.md exist on disk; all three task commits (b582e6d, c73c9a7, 061db58) verified in git log.
