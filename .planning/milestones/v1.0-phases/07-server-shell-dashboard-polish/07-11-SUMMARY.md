---
phase: 07-server-shell-dashboard-polish
plan: 11
subsystem: app
tags: [flutter, connection_service, uipi, input.blocked, banner, SRV-05, D-07]

# Dependency graph
requires:
  - phase: 07-02
    provides: "InputBlockedMsg (proto 1.3 Dart codec) this plan's connection_service arm decodes"
  - phase: 07-09
    provides: "theme/tokens.dart (kSurface/kHairline/kMuted/kText/kError/kAccent) this banner styles with"
provides:
  - "InputBlockedSnapshot + ConnectionService._inputBlocked parking + inputBlockedSnapshot getter"
  - "UipiBanner widget (+ UipiBanner.forService factory) — advisory-only, auto-dismissing banner over an injected snapshot/changes seam"
affects: [07-13]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SHARED-G client _onFrame decode arm cloned verbatim for InputBlockedMsg (park transient snapshot + _notify + return, S->C only, no payload logged)"
    - "Constructor-injected snapshot()/changes seam (mirrors ConnectionHeaderChip) keeps the widget unit-testable without Riverpod or a real ConnectionService"

key-files:
  created:
    - app/remote_control/lib/widgets/uipi_banner.dart
    - app/remote_control/test/uipi_banner_test.dart
  modified:
    - app/remote_control/lib/net/connection_service.dart

key-decisions:
  - "InputBlockedSnapshot equality includes BOTH reason and at (timestamp) — a repeat 'elevated' transition must still notify the banner as a fresh event, unlike VolumeSnapshot/ClipSnapshot which dedupe on value alone"
  - "UipiBanner seeds _lastSeenAt from any snapshot already parked at mount time WITHOUT showing it — only a snapshot observed strictly AFTER mount (a genuinely new transition, proven by a newer `at`) opens the banner; prevents an unrelated changes ping from replaying a stale block event on screen navigation"
  - "Dropped the AnimatedSwitcher slide-in from the initial sketch in favor of a plain conditional swap — the D-07 contract (appear-on-event, ~4s auto-dismiss, no touch interception) has no locked animation requirement, and the animation made the fake-async dismiss-timing assertions flaky (the transition needs its own extra frame after the timer fires, which a single tester.pump(duration) does not provide)"

patterns-established:
  - "UipiBanner.forService(ConnectionService) factory mirrors ConnectionHeaderChip.forService — the production wiring seam 07-13 uses to mount the banner without threading Riverpod through this widget"

requirements-completed: [SRV-05]

# Metrics
duration: ~20min
completed: 2026-07-13
---

# Phase 7 Plan 11: UIPI Transient Banner (Client Surface) Summary

**The phone-side surface of the `input.blocked` (proto 1.3) push: `connection_service.dart` parks a transient, timestamp-keyed snapshot (cloning the `ClipChangedMsg` arm), and a new `UipiBanner` widget renders the exact D-07 advisory copy on a fresh transition and auto-dismisses ~4s later — advisory styling only, never error-red or accent, and never intercepts touch.**

## Performance

- **Duration:** ~20 min
- **Tasks:** 2/2
- **Files created:** 2 (1 lib, 1 test)
- **Files modified:** 1 (connection_service.dart)
- **Tests:** 4 new (uipi_banner_test.dart) — all green; full suite 331/331 green

## What Was Built

### Task 1 — `connection_service.dart` — park `input.blocked` (SRV-05/D-07)
Added `InputBlockedSnapshot` (a `reason` + `at` value class, mirroring `ClipSnapshot` but with equality over BOTH fields so a same-reason repeat transition still counts as a fresh event), a private `_inputBlocked` field, and a public `inputBlockedSnapshot` getter. The `_onFrame` decode arm clones the `ClipChangedMsg` arm exactly: on `InputBlockedMsg`, park `InputBlockedSnapshot(reason: msg.reason, at: DateTime.now())`, call `_notify()`, and `return` — S→C only, never routed to the driver, no payload logged (the `reason` vocabulary carries no window title/exe/PID, T-07-18).

### Task 2 — `UipiBanner` widget + auto-dismiss (TDD)
`lib/widgets/uipi_banner.dart` exports `kUipiBannerCopy` (the exact locked D-07 copy) and `kUipiBannerDismissDelay` (4s) as named consts. `UipiBanner` takes an injected `snapshot()` supplier + a `changes` stream (mirrors `ConnectionHeaderChip`'s constructor-injection test seam — no Riverpod, no service needed to unit-test it); `UipiBanner.forService(ConnectionService)` wires the real service for production use (consumed by 07-13). On a `changes` ping, it re-reads the snapshot and treats a snapshot whose `at` differs from the last-seen one as a fresh transition: shows the strip and (re)starts a `Timer(kUipiBannerDismissDelay, ...)` that hides it again. The strip itself is `kSurface` fill + `kHairline` top/bottom edge + `Icons.info_outline` 16px `kMuted` + 14/400 `kText` copy — no destructive or accent color, no action button — wrapped in `IgnorePointer` so a parent overlaying it on live content (07-13's dashboard/quick-bar composition) never loses touches to it.

Followed RED → GREEN: `test/uipi_banner_test.dart` was written and confirmed failing to compile (widget didn't exist) before `uipi_banner.dart` was implemented.

## Task Commits

Each task was committed atomically:

1. **Task 1: connection_service.dart — park input.blocked + expose snapshot** - `cb17fa9` (feat)
2. **Task 2 RED: failing UipiBanner test** - `ae3f091` (test)
3. **Task 2 GREEN: UipiBanner widget + auto-dismiss** - `7705f3a` (feat)

**Plan metadata:** (this commit) (docs: complete plan)

## Files Created/Modified
- `app/remote_control/lib/net/connection_service.dart` - `InputBlockedSnapshot` class, `_inputBlocked` field, `inputBlockedSnapshot` getter, `InputBlockedMsg` `_onFrame` arm.
- `app/remote_control/lib/widgets/uipi_banner.dart` - `UipiBanner` widget (+ `.forService` factory), `kUipiBannerCopy`, `kUipiBannerDismissDelay`, private `_UipiBannerStrip`.
- `app/remote_control/test/uipi_banner_test.dart` - 4 widget tests: appear+auto-dismiss, timer-restart-on-newer-snapshot, advisory-only styling (no destructive/accent color), touch passthrough.

## Decisions Made
- **Equality includes the timestamp.** `InputBlockedSnapshot`'s `==` compares `reason` AND `at` (unlike `VolumeSnapshot`/`ClipSnapshot`, which dedupe on value alone) because a repeated "elevated" transition — the owner tries the elevated window again and gets blocked again — must still notify the banner as a NEW event, not get silently deduped as "the same value already seen."
- **Mount-time seeding without showing.** `UipiBanner` seeds its "already seen" marker from whatever snapshot is parked at mount time but does NOT show it immediately — only a snapshot observed strictly after mount (proven by a newer `at`) opens the banner. This stops an unrelated `changes` ping (e.g. a volume push on the same tick) from replaying a stale block event when the user navigates to a fresh tool screen.
- **No slide animation.** The initial sketch used an `AnimatedSwitcher` (mirroring `ReconnectingBannerSlot`'s slide-in), but the D-07 acceptance criteria only require appear-on-event + ~4s auto-dismiss + no touch interception — no locked animation. The animation also made the auto-dismiss test flaky under `flutter_test`'s fake-async `pump(duration)` (a fired `Timer`'s `setState` needs an *additional* pumped frame for the transition to actually elapse, not just for the clock to cross the deadline). Dropped in favor of a plain, deterministic conditional swap.

## Deviations from Plan

None beyond the TDD-cycle test-authoring fix documented above (adjusting two test cases to push a snapshot AFTER mount rather than before, and simplifying the widget to drop the animation) — both are internal to the RED→GREEN cycle of Task 2, not scope changes. No Rule 1-4 deviations.

## Testing

- `flutter analyze lib/net/connection_service.dart lib/widgets/uipi_banner.dart test/uipi_banner_test.dart` — clean.
- `flutter test test/uipi_banner_test.dart` — 4/4 green.
- `flutter test` (full suite) — 331/331 green, no regressions.
- Acceptance-criteria greps: `grep -n "running as administrator" lib/widgets/uipi_banner.dart` matches the exact UI-SPEC copy; `grep -n "kError\|kAccent" lib/widgets/uipi_banner.dart` returns nothing.

## TDD Gate Compliance

Task 2 followed RED → GREEN with distinct commits:
- `test(07-11)` `ae3f091` (RED — confirmed failing to compile, widget didn't exist)
- `feat(07-11)` `7705f3a` (GREEN — 4/4 tests passing)

No REFACTOR commit needed (the implementation was minimal and clean after the GREEN pass, aside from the animation simplification made during the same GREEN commit).

## Known Stubs

None. Both the connection-service parking and the `UipiBanner` widget are fully functional; the widget is not yet mounted into any screen (that composition is explicitly 07-13's job per the plan's objective — "the dashboard quick-bar (07-13) composes this banner").

## Threat Flags

None. Both STRIDE items from this plan's threat_model (T-07-18 information disclosure, T-07-19 UI spoofing) are directly mitigated by the fixed-vocabulary `reason` (never window title/exe/PID) and the advisory-only styling (never error-red) — no new surface introduced beyond what the threat_model already covers.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `UipiBanner.forService(connectionService)` is ready for 07-13 to mount in the dashboard/quick-bar scaffold composition so the banner appears contextually on whatever tool screen is active.
- On-device UIPI verification (running an elevated foreground window and attempting input) remains the phase-level manual gate — this plan ships the code-complete client surface only.

## Self-Check: PASSED

- FOUND: app/remote_control/lib/widgets/uipi_banner.dart
- FOUND: app/remote_control/test/uipi_banner_test.dart
- FOUND: app/remote_control/lib/net/connection_service.dart (modified)
- FOUND commit: cb17fa9 (Task 1)
- FOUND commit: ae3f091 (Task 2 RED)
- FOUND commit: 7705f3a (Task 2 GREEN)

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-13*
