---
phase: 05-media-power-presenter-browser
plan: 07
subsystem: ui
tags: [flutter, riverpod, media, volume, slider, mute, hub, vol-changed, d-04, tdd]

# Dependency graph
requires:
  - phase: 05-01
    provides: "VolChangedMsg Dart codec + decodeText registry entry (protoVersion 1.1)"
  - phase: 05-03
    provides: "server-side authed-gated vol.changed push + after-auth snapshot the store reflects"
  - phase: 05-05
    provides: "real WASAPI volume executor — live PC-side volume/mute the slider tracks"
  - phase: 05-06
    provides: "hub-tile insertion pattern + the current 4-tile kHubTiles registry"
provides:
  - "VolumeSnapshot {value, muted} value-equal read surface + getter on ConnectionService"
  - "VolChangedMsg _onFrame branch (after PongMsg, before driver routing) parking the snapshot + changes ping"
  - "VolumeSliderPolicy — pure clock-injected D-04 finger-wins policy (kSetvolThrottleMs=50)"
  - "VolumeViewState + VolumeNotifier + volumeStateProvider (Riverpod-3, cloned from ConnectionStatusNotifier)"
  - "MediaScreen — transport row (MED-01) + volume block (MED-02) per UI-SPEC"
  - "final 5-tile hub: Trackpad, Media, Power, Presenter, Browser (D-01 complete)"
affects: [07-polish-dashboard]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure clock-injected UI policy (VolumeSliderPolicy) mirroring the modifier_fsm / presenter_timer house style — leading-edge throttle + drop-never-queue, all seams injected"
    - "Value-equal snapshot parked on ConnectionService + changes ping → Riverpod Notifier (VolumeSnapshot follows the ConnectionStatus discipline)"
    - "Server-authoritative render: mute + slider read the pushed snapshot only; no optimistic flip"

key-files:
  created:
    - app/remote_control/lib/media/volume_store.dart
    - app/remote_control/lib/media/media_screen.dart
    - app/remote_control/test/media/volume_store_test.dart
  modified:
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/hub/hub_screen.dart

key-decisions:
  - "VolumeSliderPolicy resets its throttle bookkeeping (lastSent value + time) on dragStart so every fresh drag's first update is a leading-edge send — a recent prior-drag send never suppresses a new drag's start"
  - "dragEnd flushes the final value iff it differs from the last one sent (pending != lastSentValue) — proves both the [10,30] no-duplicate case and the [10,30,45] throttled-tail case at the unit level"
  - "Injected policy seams are PUBLIC fields (required this.nowMillis/isAuthed/send) per the presenter_timer house convention — avoids the prefer_initializing_formals lint the private-field form triggers"
  - "Media screen sends transport + mute through the cached _service / notifier; only the volume DRAG rides the policy — mute is a server-authoritative render off vol.muted with no optimistic flip"

patterns-established:
  - "UI-side throttle+gate policy as a pure testable class (fake clock, recording send, toggleable authed) — the D-04 contract is proven without a widget or a socket"

requirements-completed: [MED-01, MED-02]

# Metrics
duration: ~20min
completed: 2026-07-11
---

# Phase 5 Plan 07: Media / Volume Client Vertical Summary

**The volume/media loop is closed on the client: incoming `vol.changed` pushes park a value-equal `VolumeSnapshot` on ConnectionService (branch after PongMsg, before driver routing) that the D-04 `VolumeSliderPolicy` reflects into the Media screen's slider + server-authoritative mute; dragging the slider emits leading-edge 50ms-throttled `setvol` with the finger always winning over incoming pushes and dropping (never queuing) while unauthed; the hub reaches its final 5-tile UI-SPEC order Trackpad, Media, Power, Presenter, Browser.**

## Performance

- **Duration:** ~20 min
- **Completed:** 2026-07-11T03:11Z
- **Tasks:** 2 (Task 1 TDD RED + GREEN, Task 2 screen + hub tile)
- **Files:** 3 created, 2 modified

## Accomplishments

- **VolumeSliderPolicy (D-04, MED-02):** pure clock-injected policy with state {value 0-100, muted, hasSnapshot, dragging}. A push while not dragging is authoritative (value + mute + hasSnapshot latch); a push during a drag is ignored WHOLE (finger wins). Dragging emits a leading-edge `setvol`, then at most one send per `kSetvolThrottleMs = 50`, with the final value flushed on release iff it differs from the last sent value. Unauthed → zero sends, nothing queued (Pitfall 12). Incoming values clamped 0..100. 13 deterministic unit tests (fake clock, recording send, toggleable authed).
- **vol.changed wiring:** value-equal `VolumeSnapshot { value, muted }` (==/hashCode) parked in a private field with a public getter on ConnectionService; the `VolChangedMsg` branch sits in `_onFrame` after the PongMsg branch and before driver routing, calls `_notify()`, and returns — S→C only, never routed to the driver, no payload logged (SPEC §12).
- **Riverpod layer:** `VolumeViewState` (value-equal over value/muted/hasSnapshot/dragging) + `VolumeNotifier extends Notifier` cloned from `ConnectionStatusNotifier` — subscribes to `service.changes`, ingests the parked snapshot into the policy, and publishes the view; drag callbacks delegate to the policy wired with the system clock, `() => service.isAuthed`, and `(v) => service.sendReliable(MediaMsg(action: 'setvol', value: v))`. `volumeStateProvider` exposed for the screen.
- **MediaScreen (MED-01/02):** app bar "Media" + header chip + reconnecting banner (D-02); xl-top-padded body with a centered transport row (Prev 48 / Play-Pause 64 primary / Next 48 circular buttons — press-down accent flash + haptic tick, sending `media {prev|playpause|next}`; the play/pause glyph is a neutral `Icons.play_arrow` but always sends `playpause`), an lg gap, then the volume block (mute icon-button + Material slider + fixed-width tabular % readout). Mute renders the Phase-4 locked-chip solid pattern when engaged and follows the pushed snapshot with no optimistic flip; the slider drives `volumeStateProvider` (onChangeStart→dragStart, onChanged→dragUpdate(round), onChangeEnd→dragEnd). Pre-snapshot or disconnected: slider + mute inert at `#6B7280`, readout "--".
- **Hub complete:** Media tile (`Icons.music_note`) inserted ahead of Power → final registry order Trackpad, Media, Power, Presenter, Browser (D-01 done at 5 tiles).

## Task Commits

1. **Task 1 RED — failing D-04 VolumeSliderPolicy tests** — `de3d90f` (test)
2. **Task 1 GREEN — VolumeSliderPolicy + vol.changed wiring** — `a01f784` (feat)
3. **Task 2 — MediaScreen + final 5-tile hub** — `d9d12a9` (feat)

## TDD Gate Compliance

RED commit `de3d90f` (test failed to load — `VolumeSliderPolicy` undefined, `lib/media/volume_store.dart` absent) precedes GREEN commit `a01f784` (13 policy tests pass, full suite 280 green). No refactor commit needed. Task 2 is screen + composition (no new unit-testable behavior beyond the widget tree — verification is the full suite + analyze).

## Verification Evidence

- `flutter test test/media/volume_store_test.dart` — 13 policy cases pass (drag-ignore, 50ms leading-edge throttle send sequence [10,30] and throttled-tail [10,30,45], release-authoritative, unauthed drop-never-queue, 0..100 clamp).
- `flutter test` — 280 tests pass (13 new).
- `flutter analyze --no-pub` — No issues found.
- Acceptance greps: `kSetvolThrottleMs` = 4 in volume_store.dart (≥2); `VolChangedMsg` = 1 in connection_service.dart, branch before driver routing (source inspection); `VolumeSnapshot` implements == and hashCode (both present); `playpause\|'next'\|'prev'` = 6 in media_screen.dart (≥3); `MediaScreen` = 1 in hub_screen.dart; hub order Trackpad, Media, Power, Presenter, Browser (source inspection); media_screen.dart = 341 lines (≥120); mute rendering reads only `vol.muted` (no optimistic flip — source inspection).
- On-device MED acceptance (play/pause/next/prev vs Spotify + YouTube; slider drives live PC volume with finger winning; PC-side volume moves the app slider within ~250ms; mute reflects PC state): deferred to the end-of-phase on-device gate (05-VALIDATION Manual-Only, SC1) per the plan's `<human-check>`.

## Decisions Made

- **Fresh-drag leading edge:** `dragStart` clears the throttle's last-sent value + timestamp so a new drag's first `dragUpdate` always sends, regardless of how recent the previous drag's last send was. Added a dedicated unit test for this.
- **Public injected seams:** the policy's clock/auth/send are public `final` fields with `required this.x` (presenter_timer convention), not private fields assigned in the initializer list — the private form trips `prefer_initializing_formals`, which counts against the "analyze clean" acceptance.
- **Mute is render-only:** the mute button passes `muted: vol.muted` straight from the pushed snapshot and calls `notifier.toggleMute()` (which only sends `media {mute}`); there is no local mute state to flip, structurally guaranteeing the "no optimistic flip" contract.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Missing `remote_protocol` import in media_screen.dart**
- **Found during:** Task 2 (first `flutter analyze`)
- **Issue:** `MediaScreen` constructs `MediaMsg` for the transport sends but the file did not import `package:remote_protocol/remote_protocol.dart` — three `creation_with_non_type` errors.
- **Fix:** Added the import (same one trackpad/presenter screens use for their wire types).
- **Files modified:** app/remote_control/lib/media/media_screen.dart
- **Verification:** `flutter analyze --no-pub` clean; full suite green.
- **Committed in:** d9d12a9

**2. [Rule 3 - Blocking] `prefer_initializing_formals` lint on the policy's injected seams**
- **Found during:** Task 2 (`flutter analyze`)
- **Issue:** The initial `VolumeSliderPolicy` assigned its three function-typed ctor params to private fields in the initializer list, which the analyzer flags (3 info-level issues) — leaving `analyze` non-clean.
- **Fix:** Converted the seams to public `final` fields with `required this.nowMillis/isAuthed/send` (the presenter_timer house convention); updated internal references. Tests unchanged (they already passed the params by name).
- **Files modified:** app/remote_control/lib/media/volume_store.dart
- **Verification:** `flutter analyze --no-pub` clean; policy + full suite green.
- **Committed in:** d9d12a9

---

**Total deviations:** 2 auto-fixed (both blocking build/lint). No architectural changes; no scope creep; no new packages (T-05-SC accept).

## Threat Surface

Both mitigations in the plan's `<threat_model>` implemented as designed:
- **T-05-15 (setvol flood DoS, mitigate):** `kSetvolThrottleMs = 50` leading-edge throttle, unit-tested send sequence; sends ride the existing bounded reliable FIFO (≤10); the server router already drops setvol > 100.
- **T-05-16 (stale state replay, mitigate):** the policy DROPS (never queues) `setvol` while unauthed — unit-tested with a re-auth + push that produces zero replayed sends.
- **T-05-17 (client trust of push, accept) / T-05-SC (supply chain, accept):** honored — pushes arrive only over the authed session; incoming values clamped 0..100 in the policy; no new packages.

No new endpoints, auth paths, or trust-boundary surface introduced beyond the accepted `vol.changed` consumption.

## Known Stubs

None — the vertical is wired end-to-end: live `vol.changed` pushes from the 05-05 WASAPI executor flow through the 05-03 push seam into the store and screen, and the slider's `setvol` drives real audio. No placeholder data or unwired components.

## Issues Encountered

None beyond the two documented lint/build deviations. Pre-existing untracked `app/remote_control/test/presenter/` (a 05-04 artifact never staged) and `graphify-out/` were left untouched — out of this plan's scope.

## User Setup Required

None — no external service configuration.

## Next Phase Readiness

- **Phase 05 is feature-complete on both sides.** Every phase feature (media, power, presenter, browser) is now user-reachable from the 5-tile hub, and the MED-02 acceptance test (change volume on the PC, slider follows) is executable on device.
- The remaining work for phase close is the end-of-phase on-device manual gate (05-VALIDATION Manual-Only: SC1 media + volume-follow, SC2 sleep-suspends, SC3 restart/shutdown two-gesture, SC4 PowerPoint + timer, SC5 browser macros incl. zoom).
- Phase 7 grows the hub in place (8-tile dashboard); the ordered `kHubTiles` registry needs no structural change.

---
*Phase: 05-media-power-presenter-browser*
*Completed: 2026-07-11*

## Self-Check: PASSED

All three created files (volume_store.dart, media_screen.dart, volume_store_test.dart) exist on disk; all three task commits (de3d90f, a01f784, d9d12a9) present in git history.
