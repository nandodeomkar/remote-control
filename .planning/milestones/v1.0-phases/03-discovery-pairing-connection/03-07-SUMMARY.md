---
phase: 03-discovery-pairing-connection
plan: 07
subsystem: client-connection-ui
tags: [flutter, dart, riverpod, applifecyclelistener, header-chip, reconnect-banner, e2e, hardware-verified]

# Dependency graph
requires:
  - phase: 03-discovery-pairing-connection
    provides: "03-05 ConnectionService (chipStatus, probe, retryNow, connectTo, onAppResumed, sendMove) + providers; 03-06 DeviceListScreen home, pairing sheet, connection_copy"
  - phase: 02-end-to-end-cursor-spike
    provides: "latency_hud.dart throttled-read pattern (copied then deleted), trackpad hot-path Listener, wakelock"
provides:
  - "ConnectionHeaderChip: status dot + word + p50 on a kHudReadThrottle (500ms) poll — never rebuilt from the hot move path (CONN-06, D-08)"
  - "ReconnectingBanner + ReconnectingBannerSlot: non-blocking drop strip with Retry now, 150ms slide-in, shown only while reconnecting (D-04)"
  - "main.dart launch flow (D-01): home = DeviceListScreen; post-first-frame silent auto-reconnect to DeviceStore.lastDeviceKey; AppLifecycleListener onResume -> onAppResumed (D-06)"
  - "Slimmed trackpad_screen.dart: pure ConnectionService consumer (sendMove hot path, isAuthed hint swap) — all connect/PIN/HUD scaffolding removed"
  - "Debug latency HUD deleted (D-08); probe engine in latency_probe.dart survives as the header source"
  - "PHASE 3 E2E: all five roadmap success criteria demonstrated on the Xiaomi 25080RABDI + Windows 11 pair"
affects: [phase-4 control-center screens (mount the header + consume ConnectionService), phase-7 settings/persistence (token persistence closes the single-pair-per-run gap)]

# Tech tracking
tech-stack:
  added: []
  patterns: ["throttled-read UI: chip/banner poll their own Timer.periodic(kHudReadThrottle) — decoupled from the hot move path (Pitfall 9)", "launch kick after first frame in a ConsumerState initState + addPostFrameCallback, non-blocking, no nav on success (D-01)", "transition-gated sheet open: device-list watches service.changes for needPin / needPairing edges, never reopens on unrelated pings"]

key-files:
  created:
    - app/remote_control/lib/widgets/connection_header.dart
    - app/remote_control/test/connection_header_test.dart
  modified:
    - app/remote_control/lib/main.dart
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/lib/screens/device_list_screen.dart
    - app/remote_control/lib/screens/connection_copy.dart
    - app/remote_control/lib/store/device_list_store.dart
    - app/remote_control/test/widget_test.dart
  deleted:
    - app/remote_control/lib/hud/latency_hud.dart

key-decisions:
  - "device_list_store.dart wires service.attachBeacons(listener.stream) — the D-06 beacon short-circuit becomes live (without it 03-05's attachBeacons was dead code); an integration edit outside the plan's declared files_modified"
  - "connection_copy.dart gained kTrackpadHintAuthed / kTrackpadHintNotConnected (UI-SPEC copywriting rows) — trackpad hint strings centralized, not inline"
  - "SizeTransition axisAlignment -> alignment(Alignment(-1,-1)) for the Flutter 3.44 deprecation (SDK-documented vertical-axis equivalence)"

patterns-established:
  - "Header chip is the single latency/status surface for every connected-capable screen (device list app-bar + trackpad overlay)"

requirements-completed: [CONN-04, CONN-06]

# Metrics
duration: ~40min execution across two sessions + orchestrator recovery + human E2E
completed: 2026-07-09
---

# Phase 3 Plan 07: Header, Launch Wiring & Phase E2E Summary

**The phase's UX loop closed: live status/latency header chip + non-blocking reconnect banner, D-01 silent-launch auto-reconnect with the device list as home, AppLifecycleListener resume trigger, a trackpad slimmed to a pure ConnectionService consumer, debug HUD retired — and all five roadmap success criteria demonstrated on the real Xiaomi + Windows 11 pair**

## Performance

- **Duration:** ~40 min across two sessions (Task 1 the first session; Task 2 + orchestrator recovery the second) + human E2E
- **Started:** 2026-07-09T01:25:49+05:30 (Task 1 RED)
- **Completed:** 2026-07-09 (E2E owner-approved)
- **Tasks:** 3 (2 auto/TDD, 1 checkpoint:human-verify)
- **Files modified:** 8 (1 deleted)

## Accomplishments

- **CONN-06 header** — ConnectionHeaderChip: 8px dot + status word + `· {p50} ms`, colors per the UI-SPEC states table (connected #4C8DFF, reconnecting #E8A33D, disconnected #6B7280), 200ms color-only ease, latency shown only when connected. Reads on a `kHudReadThrottle` (500ms) poll — proven decoupled from the move path
- **D-04 recovery UX** — ReconnectingBanner: #16181D strip with hairlines, amber wifi-off, `Reconnecting…`, trailing `Retry now` (≥48px), 150ms slide-in, never modal; ReconnectingBannerSlot owns visibility
- **D-01 launch** — home is the device list; a post-first-frame kick reads DeviceStore.lastDeviceKey and silently reconnects (no nav on success); AppLifecycleListener onResume → onAppResumed for instant retry (D-06)
- **D-08 cleanup** — trackpad slimmed to a ConnectionService consumer (sendMove hot path, isAuthed hint swap); the debug latency HUD file deleted while the probe engine survives
- **Phase E2E PASSED (owner-verified, Xiaomi 25080RABDI / Android 16 + Windows 11):** all 7 script steps — discovery ≤4s, PIN pairing with error copy, silent reconnect, WiFi-drop recovery, revoked-token re-pair, manual IP (valid/unreachable/non-private), live latency without hot-path hitching

## Task Commits

1. **Task 1 (RED): failing header chip + banner suite** — `30cd2e5` (test)
2. **Task 1 (GREEN): ConnectionHeaderChip + ReconnectingBanner** — `0f40d56` (feat)
3. **Task 2: launch wiring, trackpad slimming, HUD deletion** — `654e335` (feat)
4. **Task 3: phase E2E** — no commit (human-verify gate, owner-approved with the 7-step evidence above)

_Task 2 was completed during orchestrator recovery after the executor hit a provider limit mid-task; the uncommitted work was verified (analyze/test/APK), two Flutter-3.44 lint fixes folded in, then committed as `654e335`._

## Files Created/Modified

- `app/remote_control/lib/widgets/connection_header.dart` — ConnectionHeaderChip (+ `.forService` factory) and ReconnectingBanner / ReconnectingBannerSlot; throttled-read poll, UI-SPEC palette
- `app/remote_control/lib/main.dart` — home = DeviceListScreen; D-01 launch kick; AppLifecycleListener resume wiring
- `app/remote_control/lib/trackpad/trackpad_screen.dart` — slimmed consumer: connect/PIN/HUD/local-channel plumbing removed; sendMove hot path; isAuthed hint swap
- `app/remote_control/lib/screens/device_list_screen.dart` — header chip in the app bar, banner slot, row-tap navigation
- `app/remote_control/lib/screens/connection_copy.dart` — kTrackpadHintAuthed / kTrackpadHintNotConnected
- `app/remote_control/lib/store/device_list_store.dart` — attachBeacons wiring (live D-06 short-circuit)
- `app/remote_control/lib/hud/latency_hud.dart` — DELETED (D-08)
- `app/remote_control/test/connection_header_test.dart` — chip states + throttle + banner suite
- `app/remote_control/test/widget_test.dart` — new app shell (home = device list) smoke test

## Decisions Made

- attachBeacons wired into DeviceListNotifier so the D-06 beacon short-circuit is live end-to-end (integration edit outside declared files_modified — noted)
- Trackpad hint strings centralized in connection_copy.dart per the UI-SPEC copywriting contract (no inline copy)
- SizeTransition deprecation fixed with the SDK-documented `alignment: Alignment(-1,-1)` vertical-axis equivalence

## Deviations from Plan

Two integration edits outside the plan's declared `files_modified` (both necessary, both committed with Task 2):
- `device_list_store.dart` — `attachBeacons(listener.stream)` (D-06 short-circuit had no live caller otherwise)
- `connection_copy.dart` — trackpad hint constants (UI-SPEC copywriting rows)

Plus two lint fixes to keep `flutter analyze` clean under Flutter 3.44 (SizeTransition alignment; unused import in widget_test.dart).

## Issues Encountered

- **Executor interruption:** the Task-2 executor hit a provider usage limit mid-task; recovery verified the uncommitted work (analyze clean, 145/145 tests, APK builds) and committed it rather than re-running.
- **E2E blocker — stale server process:** the first `cargo run` after Ctrl+C failed with `bind 0.0.0.0:17777 (os error 10048)` — Ctrl+C on `cargo run` orphaned the child `server-windows.exe`, which kept the socket bound. Killed the orphan (PID) to free the port.
- **E2E surprise — `noPairing` on re-pair:** entering a PIN returned "This PC no longer recognizes this phone — pair again". Root cause: the server supports ONE pairing per process run (the PIN-refresh loop breaks on `is_paired()` and a completed pair clears the active window), so a second pair attempt hits `PinOutcome::NoPairing`. Restarting the server (fresh unpaired AuthManager + new PIN window) resolved it. This is the expected Phase-3 behavior noted in the plan (token persistence lands in Phase 7). Two rough edges captured as pending todos.

## User Setup Required

None — no external service configuration. Field note: after `Ctrl+C` on `cargo run`, confirm the port is free before restarting (`Get-NetTCPConnection -LocalPort 17777`); the child exe can outlive cargo.

## Next Phase Readiness

- Phase 3 goal met and hardware-proven: connectivity is a solved problem for later screens — they mount ConnectionHeaderChip and consume ConnectionService directly
- Two pending todos carried forward (see STATE): overloaded `noPairing` copy (pairing-window-absent vs revoked-token), and one-pairing-per-server-run until Phase 7 persistence
- Debug HUD gone; trackpad hot-path invariants intact and E2E-confirmed (no new hitching under continuous drag)

## Verification Results

- `flutter analyze` — no issues
- `flutter test` — 145/145 green (new header suite + all prior suites)
- `flutter build apk --debug` — builds
- `cargo test --workspace` — green (server regression)
- Acceptance greps: single header source; `latency_hud` gone from lib (only doc-comment mentions); main.dart AppLifecycleListener + onAppResumed present; trackpad has no controllers/stream.listen/HUD
- Human E2E (Task 3): APPROVED — all 7 steps on the Xiaomi + Windows 11 pair

## Self-Check: PASSED

- `app/remote_control/lib/widgets/connection_header.dart` — FOUND
- `app/remote_control/test/connection_header_test.dart` — FOUND
- `app/remote_control/lib/hud/latency_hud.dart` — DELETED (confirmed)
- Commit `30cd2e5` — FOUND
- Commit `0f40d56` — FOUND
- Commit `654e335` — FOUND

---
*Phase: 03-discovery-pairing-connection*
*Completed: 2026-07-09*
