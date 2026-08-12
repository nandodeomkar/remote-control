---
phase: 05-media-power-presenter-browser
plan: 04
subsystem: ui
tags: [flutter, presenter, fsm, wakelock, hub, timer]

# Dependency graph
requires:
  - phase: 05-media-power-presenter-browser
    plan: 02
    provides: HubScreen + kHubTiles ordered registry (tile insertion point), tool-screen skeleton (chip + banner + sendReliable + gated-muted)
  - phase: 04-trackpad-keyboard
    provides: wakelock + haptic-on-press-down pattern, pure-FSM house style, header chip/banner chrome
  - phase: 01-protocol-contract
    provides: PresentMsg codec + server present_macro table (next/prev/start/end/blank)
provides:
  - PresenterTimer pure clock-injected FSM (stopped/running/paused) — client-local elapsed clock, no wire types
  - PresenterScreen (split tap zones + bottom bar + manual timer + wakelock lifecycle)
  - Presenter hub tile (Icons.slideshow) between Trackpad and Browser
affects: [05-06, 05-07, 07-polish-dashboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure clock-injected FSM over injected nowMillis (mirrors modifier_fsm/GestureClassifier) — deterministic, no timers/IO/Flutter"
    - "Widget-local lazy 1s Timer.periodic drives rendering cadence; the FSM owns no timer (Pitfall 13)"

key-files:
  created:
    - app/remote_control/lib/presenter/presenter_timer.dart
    - app/remote_control/lib/presenter/presenter_screen.dart
    - app/remote_control/test/presenter/presenter_timer_test.dart
  modified:
    - app/remote_control/lib/hub/hub_screen.dart

key-decisions:
  - "Timer text tap/long-press stays interactive even when disconnected — the elapsed timer is strictly client-local (D-08), so its pause/resume/reset never depends on the socket"
  - "Prev/Next each construct their own PresentMsg at distinct handlers (readable + matches the PRES-01 per-advance vocabulary) rather than sharing one param-driven call site"
  - "Ticker created lazily on the first Start show (not in initState) so no 1s rebuild loop runs before a show begins; always cancelled in dispose"

requirements-completed: [PRES-01, PRES-02]

# Metrics
duration: ~12min
completed: 2026-07-11
---

# Phase 5 Plan 04: Presenter Slice Summary

**Presenter vertical slice ships end-to-end against the existing 04-02 server present_macro table: full-screen split tap zones drive slides, a client-local manual elapsed timer (pure FSM over an injected clock) runs with pause/resume/reset, the phone stays awake while presenting, and the Presenter tile is reachable from the hub — zero server changes.**

## Performance

- **Duration:** ~12 min (resumed — prior executor left the RED test uncommitted)
- **Completed:** 2026-07-11
- **Tasks:** 2 (Task 1 TDD RED+GREEN + Task 2)
- **Files:** 3 created, 1 modified

## Accomplishments

- `PresenterTimer` (PRES-02, D-08): pure clock-injected FSM over `int Function() nowMillis` — states stopped/running/paused; `startShow()` resets+runs from any state, `tap()` pauses/resumes with the pause gap excluded, `reset()` → stopped, `elapsedMs()` = accumulated + live span while running. No Flutter, no IO, no Timer objects (Pitfall 13). All six deterministic behavior cases green.
- `PresenterScreen` (PRES-01, D-07): slim "Presenter" app bar + header chip + reconnecting banner (D-02) over a full-bleed `#0E0F12` body. Split tap zones — Prev left third / Next right two-thirds separated by a 1px `#2A2D34` hairline — each press-down sends `present {prev|next}` reliably, fires a haptic tick, and flashes the chevron accent for 100ms. 64px bottom bar with Start show (`present {start}` + `timer.startShow()`), End show (`present {end}`, timer untouched — manual only), Blank toggle (`present {blank}` + optimistic armed-chip flip), and a right-aligned 28/600 tabular mm:ss timer (tap=pause/resume, long-press=reset, tooltip "Tap to pause, hold to reset").
- D-09 keep-awake: `WakelockPlus.enable()` in initState / `disable()` in dispose — scoped so it never leaks past the screen.
- Sends render gated-muted (`#6B7280`, inert) when the header chip is not connected — never red.
- Hub tile: `Presenter` (Icons.slideshow) inserted into `kHubTiles` between Trackpad and Browser; hub registry test still green with Trackpad first.

## Task Commits

1. **Task 1 RED: failing PresenterTimer FSM tests** — `7eed1f3` (test) — the resumed uncommitted RED artifact, verified against the plan's six-case contract and committed after confirming compile-failure RED.
2. **Task 1 GREEN: PresenterTimer implementation** — `460d4ae` (feat) — all 6 tests pass, 0 Flutter imports.
3. **Task 2: PresenterScreen + hub tile** — `0635546` (feat) — full suite (249 tests) green, `flutter analyze --no-pub` clean.

## TDD Gate Compliance

- RED gate: `7eed1f3` — test failed to load (impl absent, `PresenterTimerState` undefined), verified before implementation.
- GREEN gate: `460d4ae` — all 6 FSM tests pass; `grep -c "import 'package:flutter" presenter_timer.dart` = 0 (pure Dart).
- REFACTOR: not needed for the FSM. PresenterScreen received one clarity pass (explicit per-zone PresentMsg construction, wakelock doc wording) before its commit — still within Task 2.

## Verification Evidence

- `flutter test` — 249 tests pass (6 new presenter FSM cases included).
- `flutter analyze --no-pub` — No issues found.
- Acceptance greps on `presenter_screen.dart`: `WakelockPlus.enable`=1, `WakelockPlus.disable`=1, `PresentMsg`=6 (≥5: prev/next/start/end/blank), `cancel` present (ticker cancelled in dispose). `PresenterScreen` in `hub_screen.dart`=1. `presenter_screen.dart` 464 lines (≥120).
- On-device PowerPoint/Impress drive + blank + timer + keep-awake: deferred to the end-of-phase on-device gate (05-VALIDATION Manual-Only, SC4) per the plan.

## Decisions Made

- The timer's tap/long-press gestures stay live regardless of connection state — D-08 makes the timer strictly client-local, so pausing/resetting must not depend on the socket. Only the present-sending controls (zones, Start/End show, Blank) gate on auth.
- Prev and Next each build their own `const PresentMsg` at dedicated handlers for readability and to match the PRES-01 per-advance vocabulary, rather than a single param-driven call site.
- The 1s ticker is created lazily on the first Start show (not eagerly in initState) so no rebuild loop runs before a show starts; it is always cancelled in dispose.

## Deviations from Plan

None — plan executed exactly as written. (The RED test file was pre-existing from a prior out-of-tokens executor; it matched the plan's six-case contract unchanged and was committed as the RED gate.)

## Threat Surface

Both plan threats handled as designed:
- T-05-07 (present macros, accept): modifier-free benign keys behind the existing auth + gating; no new surface.
- T-05-08 (wakelock + 1s timer DoS, mitigate): wakelock strictly scoped initState→dispose; ticker cancelled in dispose — no battery/CPU leak past the screen. No new endpoints, auth paths, or trust-boundary changes introduced.

## Known Stubs

None — the slice is wired end-to-end against the live 04-02 server present_macro table; no placeholder data or unwired components.

## Issues Encountered

None.

## Next Phase Readiness

- The hub registry accepts the remaining tool tiles: 05-06 (Power) and 05-07 (Media) insert ahead of Presenter to reach the final Trackpad/Media/Power/Presenter/Browser order.
- The Presenter feature is live against the 04-02 server keymap (Right/Left/F5/Esc/B); the on-device slide-driving + timer accuracy check is the only remaining item, folded into the end-of-phase manual gate.

---
*Phase: 05-media-power-presenter-browser*
*Completed: 2026-07-11*

## Self-Check: PASSED

All three claimed files exist on disk; all three task commits (7eed1f3, 460d4ae, 0635546) verified in git log.
