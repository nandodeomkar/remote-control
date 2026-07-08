---
phase: 02-end-to-end-cursor-spike
plan: 02
subsystem: client
tags: [flutter, dart, websocket, tcp-nodelay, riverpod, remote-protocol, tdd]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    provides: "remote_protocol Dart package: encodeMove/encodeScroll 9-byte binary codec, fixture-proven byte-identical to the Rust decoder"
provides:
  - "Flutter app scaffold at app/remote_control (Android, Flutter 3.44.5) importing remote_protocol via path dependency"
  - "connectNoDelay: IOWebSocketChannel construction whose connectionFactory sets SocketOption.tcpNoDelay on the underlying socket (PAD-05 crit 3, client side)"
  - "setTcpNoDelay / noDelayTask: extracted, unit-tested factory seams (A1 logic proven; empirical confirmation at Plan 04 gate)"
  - "MoveSender: pointer delta -> remote_protocol.encodeMove/encodeScroll -> fire-and-forget sink.add (D-03 raw 1:1)"
affects: [02-03, 02-04, phase-3-connect-pair-discover]

# Tech tracking
tech-stack:
  added: [Flutter app scaffold, flutter_riverpod ^3.3.2, web_socket_channel ^3.0.3, wakelock_plus ^1.6.1, "remote_protocol (path dep)"]
  patterns:
    - "TCP_NODELAY via HttpClient.connectionFactory routed through a named seam function (setTcpNoDelay) so tests reach setOption without a real connection"
    - "ConnectionTask.fromSocket re-wrap preserving the original cancel path"
    - "Hot-path sender is a pure pass-through: one sink.add per delta, codec imported, never re-implemented"

key-files:
  created:
    - app/remote_control/pubspec.yaml
    - app/remote_control/lib/main.dart
    - app/remote_control/lib/net/connection_service.dart
    - app/remote_control/lib/trackpad/move_sender.dart
    - app/remote_control/test/nodelay_factory_test.dart
    - app/remote_control/test/move_sender_test.dart
    - app/remote_control/test/widget_test.dart
  modified: []

key-decisions:
  - "A2 resolved: ConnectionTask.fromSocket is public in Dart 3.12.2 — RESEARCH snippet used verbatim, no fallback idiom needed"
  - "connectNoDelay awaits channel.ready so connect failures surface at the call site instead of only on the stream"
  - "MoveSender.sink typed StreamSink<dynamic> so IOWebSocketChannel.sink is accepted directly with no cast"
  - "minSdk stays at Flutter 3.44 default (24 >= 23); no override written into build.gradle.kts"

patterns-established:
  - "Factory seams are named top-level functions (setTcpNoDelay, noDelayTask, noDelayConnectionFactory) — never bury testable steps in anonymous closures"
  - "App-side codec use is import-only from remote_protocol; MouseFrame/decodeMouseFrame remain test-only"

requirements-completed: [PAD-05]

# Metrics
duration: 28min
completed: 2026-07-08
---

# Phase 2 Plan 02: Flutter Client Cursor Vertical Summary

**Flutter app scaffold with a TCP_NODELAY WebSocket connector (HttpClient.connectionFactory seam, unit-tested) and a codec-reusing fire-and-forget move sender — the client half of the cursor spike, both Wave 0 suites green**

## Performance

- **Duration:** 28 min
- **Started:** 2026-07-08T04:08:26Z
- **Completed:** 2026-07-08T04:36:03Z
- **Tasks:** 3 (Tasks 2 and 3 TDD: RED + GREEN commits each)
- **Files modified:** 31 (27 scaffold + 4 net/trackpad source and test files)

## Accomplishments

- Flutter app scaffold (Android-only, Flutter 3.44.5) resolves `remote_protocol` as a path dependency; smoke test proves `encodeMove` is reachable from the app; no go_router/freezed added per CLAUDE.md deferral
- `connectNoDelay` builds `IOWebSocketChannel.connect(customClient:)` over an `HttpClient` whose `connectionFactory` routes every socket through `setTcpNoDelay` — the A1 make-or-break construction, with the `setOption(SocketOption.tcpNoDelay, true)` step extracted as a test-reachable seam
- `noDelayTask` preserves the `ConnectionTask` cancel path through the wrap (`fromSocket` confirmed public in the installed SDK — assumption A2 resolved, no fallback needed)
- `MoveSender.sendMove/sendScroll` emit byte-for-byte `remote_protocol` frames, one fire-and-forget `sink.add` per delta, zero batching (D-03 / T-02-CT: codec imported, never re-implemented)
- Full app suite green: 9 tests (3 nodelay factory, 4 move sender, 2 scaffold smoke); `flutter analyze` clean

## Task Commits

Each task was committed atomically:

1. **Task 1: Flutter app scaffold + remote_protocol path dep** - `b3bdbe0` (feat)
2. **Task 2 (RED): failing nodelay factory tests** - `0cd9c4f` (test)
3. **Task 2 (GREEN): TCP_NODELAY connection service** - `c356e0b` (feat)
4. **Task 3 (RED): failing move sender tests** - `cd32a5b` (test)
5. **Task 3 (GREEN): move sender via remote_protocol encoders** - `419e816` (feat)

_Tasks 2 and 3 were TDD; no refactor commits were needed (GREEN implementations were already clean)._

## Files Created/Modified

- `app/remote_control/pubspec.yaml` - locked deps (flutter_riverpod ^3.3.2, web_socket_channel ^3.0.3, wakelock_plus ^1.6.1) + `remote_protocol: {path: ../packages/remote_protocol}`
- `app/remote_control/lib/main.dart` - minimal dark shell (#0E0F12); Plan 03 wires the trackpad screen
- `app/remote_control/lib/net/connection_service.dart` - `connectNoDelay` + named factory seams; code comment flags the empirical A1 hitch test as the Plan 04 manual gate
- `app/remote_control/lib/trackpad/move_sender.dart` - `MoveSender` fire-and-forget pass-through over the channel sink
- `app/remote_control/test/nodelay_factory_test.dart` - Wave 0: tcpNoDelay set exactly once on the resolved socket; cancel path preserved (fake recording Socket)
- `app/remote_control/test/move_sender_test.dart` - Wave 0: byte-identity vs encodeMove/encodeScroll, single add per delta, zero delta forwarded
- `app/remote_control/test/widget_test.dart` - scaffold smoke + path-dep import proof (replaces generated counter test)
- plus 24 generated scaffold files (android/, .gitignore, analysis_options.yaml, pubspec.lock, ...)

## Decisions Made

- **A2 resolved — `ConnectionTask.fromSocket` is public** in Dart 3.12.2 (`socket.dart` L590): the RESEARCH construction was used verbatim and the documented fallback idiom was not needed. Tests also use `fromSocket` to build fake tasks.
- **`connectNoDelay` awaits `channel.ready`** — without it, connect failures only surface as stream errors; awaiting ready makes the Plan 03/04 handshake wiring fail fast at the call site.
- **`MoveSender.sink` is `StreamSink<dynamic>`** — `IOWebSocketChannel.sink` is a `WebSocketSink implements StreamSink<dynamic>`, so the real channel sink plugs in directly with no cast while tests substitute a recording fake.
- **minSdk left at the Flutter 3.44 default (24)** — satisfies the >= 23 requirement without editing build.gradle.kts; flutter_secure_storage's minSdk-23 need (Phase 3) is already covered.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Replaced generated widget_test.dart counter test**
- **Found during:** Task 1 (scaffold)
- **Issue:** `flutter create` generates a counter-demo test referencing `MyApp`; after minimizing `main.dart` per the plan, that test no longer compiles and `flutter test` (later verify steps) would fail
- **Fix:** Rewrote it as a two-test smoke suite: the shell builds, and `package:remote_protocol` imports via the path dependency (which also evidences Task 1's done criterion)
- **Files modified:** app/remote_control/test/widget_test.dart
- **Verification:** `flutter test` — 9/9 green
- **Committed in:** `b3bdbe0` (Task 1 commit)

---

**Total deviations:** 1 auto-fixed (1 blocking)
**Impact on plan:** Kept the scaffold's own test suite compiling. No scope creep.

## Known Stubs

| Stub | File | Resolved by |
|------|------|-------------|
| Minimal shell `main.dart` (static placeholder text, no trackpad wiring) | app/remote_control/lib/main.dart | Plan 02-03 (trackpad screen + HUD wiring) — intentional per Task 1 action ("keep main.dart minimal for now") |

No stubs block this plan's goal: the connection service and move sender are fully real and unit-verified.

## Threat Model Compliance

- **T-02-CT (mitigate):** `MoveSender` imports `encodeMove`/`encodeScroll` from `remote_protocol` — no hand-rolled encoder exists in the app; byte-identity asserted in tests.
- **T-02-CD / T-02-SC (accept):** no action required; all pub installs were spec-locked and resolved cleanly (no failed installs, no substitutions).

No new security surface beyond the plan's threat model was introduced.

## Issues Encountered

None — `flutter pub add` pinned exact versions which were hand-relaxed to the plan's caret constraints; everything else matched RESEARCH assumptions exactly.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 02-03 can wire `connectNoDelay` + `MoveSender` to a `Listener`-based trackpad screen and the handshake/HUD (the server from 02-01 is runnable: `cargo run -p server-windows`)
- The empirical A1 confirmation (real WiFi, slow diagonal, HUD p95 tail, off-charger) remains the Plan 04 manual gate — flagged in a code comment in connection_service.dart
- Phase 3 grows `connectNoDelay` into the full reconnect-FSM ConnectionService; the customClient/connectionFactory construction is the permanent path

## Self-Check: PASSED

- All 7 key created files exist on disk
- Commits `b3bdbe0`, `0cd9c4f`, `c356e0b`, `cd32a5b`, `419e816` present in git log
- `flutter test`: 9 passed, 0 failed; `flutter analyze`: no issues

---
*Phase: 02-end-to-end-cursor-spike*
*Completed: 2026-07-08*
