---
phase: 02-end-to-end-cursor-spike
plan: 03
subsystem: ui
tags: [flutter, riverpod, websocket, handshake-fsm, latency, wakelock, android-manifest]

# Dependency graph
requires:
  - phase: 01
    provides: remote_protocol codecs (encodeMessage/decodeText/authProof/hexDecode, HelloMsg/PinMsg/PairOkMsg/ChallengeMsg/AuthMsg/AuthOkMsg/AuthFailMsg/ErrMsg/PingMsg/PongMsg) + server session FSM (session.rs) as the wire contract to mirror
  - phase: 02-01
    provides: server-windows binary — the live pair->challenge->auth->move endpoint the client connects to
  - phase: 02-02
    provides: connectNoDelay (TCP_NODELAY WebSocket) + MoveSender (9-byte binary mouse frames)
provides:
  - Pure client handshake FSM mirroring the server session FSM (pair + reconnect + all failure branches)
  - Handshake driver wiring the FSM to a live WebSocketChannel with an in-memory token
  - Interleaved-ping latency probe (round-trip-under-move-load, p50/p95) + dark-minimal HUD overlay
  - Listener-based trackpad screen: onPointerMove -> MoveSender gated on Authed, connect/PIN UI, wakelock
  - main.dart routed to the trackpad screen (placeholder removed) + AndroidManifest INTERNET/cleartext for ws:// LAN
affects: [02-04, phase-03]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Pure IO-free FSM (HandshakeFsm) unit-tested in isolation; a thin driver (HandshakeDriver) does all IO"
    - "Single channel-stream listener decodes each frame once and routes by family (handshake -> driver, pong -> probe); no double-subscribe"
    - "Injected clock + sink make timing/cadence and percentile math deterministic in tests"
    - "Hot move path never triggers a widget rebuild; the HUD timer-polls the probe on a throttle"

key-files:
  created:
    - app/remote_control/lib/net/handshake_fsm.dart
    - app/remote_control/lib/net/handshake.dart
    - app/remote_control/lib/hud/latency_probe.dart
    - app/remote_control/lib/hud/latency_hud.dart
    - app/remote_control/lib/trackpad/trackpad_screen.dart
    - app/remote_control/test/handshake_fsm_test.dart
    - app/remote_control/test/latency_probe_test.dart
  modified:
    - app/remote_control/lib/main.dart
    - app/remote_control/android/app/src/main/AndroidManifest.xml
    - app/remote_control/test/widget_test.dart

key-decisions:
  - "FSM mirrors session.rs exactly: hello -> server ALWAYS replies challenge -> branch on in-memory token (paired=auth via authProof, unpaired=needPin then pin)"
  - "Nearest-rank percentile (rank = ceil(p/100 * N), 1-indexed, clamped) — documented in the probe header; p50/p95 on {1..100} yield 50/95"
  - "First move of a drag primes the ping-interval baseline WITHOUT emitting, so the every-K-moves and ~250ms triggers coexist cleanly"
  - "prefer_initializing_formals suppressed on two non-final/named-param constructors (HandshakeFsm._token, LatencyProbe._send) — the field name differs from the public param"
  - "Token is in-memory only (spike scope); secure persistence, discovery, and scoped network-security-config are Phase 3"

patterns-established:
  - "Pure FSM + thin driver: transitions are proven without IO; the driver only encodes/sends and derives coarse status"
  - "Effect objects (NeedPin/Paired/Failed) carry FSM decisions to the UI without the FSM importing Flutter"
  - "Latency measured round-trip-UNDER-move-load (not idle RTT) as the faithful proxy for ack-less move-frame delivery"

requirements-completed: [PAD-05]

# Metrics
duration: 11min
completed: 2026-07-08
---

# Phase 2 Plan 3: Wire the Flutter Client Cursor Vertical Summary

**The two shipped halves (server FSM + client seams) are now a runnable end-to-end app: connect to a manual IP:port over a TCP_NODELAY WebSocket, complete the real pair/reconnect handshake, move the Windows cursor from finger drags once Authed, and watch live p50/p95 round-trip-under-load — all four PAD-05 hard-gate criteria are now exercisable on real hardware.**

## Performance

- **Duration:** 11 min
- **Started:** 2026-07-08T05:42:59Z
- **Completed:** 2026-07-08T05:54:06Z
- **Tasks:** 3 of 3
- **Files modified:** 10 (7 created, 3 modified)

## Accomplishments
- Client handshake FSM mirrors `session.rs` exactly (hello -> always-challenge -> pin|auth), including the reconnect/auth path whose `auth` mac reuses `authProof(hexDecode(token), hexDecode(nonce))` with no new crypto, and every failure branch (pinInvalid/pinExpired/lockedOut/noPairing/badMac/versionMismatch) carrying its extras.
- Interleaved-ping latency probe stamps a ping every K moves OR ~250ms so RTT is measured under active move load (the ack-less move frame's faithful proxy), with tested nearest-rank p50/p95 and a bounded rolling window; the HUD renders it live in the dark-minimal theme without ever rebuilding on the hot path.
- Full-bleed `Listener.onPointerMove` feeds raw 1:1 pointer deltas to `MoveSender.sendMove` gated on Authed (no sensitivity/acceleration), with connect + PIN pairing UI, a wakelock held while mounted, and a single channel listener routing handshake vs pong.
- AndroidManifest gained `android.permission.INTERNET` + `usesCleartextTraffic="true"` so the ws:// LAN socket can actually connect.

## Task Commits

1. **Task 1: Client handshake FSM + driver** (TDD) — `3712a9f` (test RED) → `99f31b1` (feat GREEN)
2. **Task 2: Interleaved-ping latency probe + HUD** (TDD) — `9682676` (test RED) → `79b96c7` (feat GREEN)
3. **Task 3: Trackpad screen assembly + Android manifest** — `9244a06` (feat)

_TDD tasks 1 and 2 each have the mandatory test(RED) -> feat(GREEN) commit pair._

## Files Created/Modified
- `lib/net/handshake_fsm.dart` — pure IO-free FSM: states, effects (NeedPin/Paired/Failed), pair + reconnect + failure transitions
- `lib/net/handshake.dart` — driver wiring the FSM to a WebSocketChannel, in-memory token, coarse HandshakeStatus for the HUD
- `lib/hud/latency_probe.dart` — interleave-cadence ping stamping, pong->RTT, bounded window, nearest-rank p50/p95
- `lib/hud/latency_hud.dart` — throttled p50/p95 + status overlay (dark-minimal, no hot-path rebuild)
- `lib/trackpad/trackpad_screen.dart` — composition point: Listener trackpad + connect/PIN UI + wakelock + single-listener routing
- `lib/main.dart` — routes to TrackpadScreen (placeholder removed), keeps ProviderScope + #0E0F12
- `android/app/src/main/AndroidManifest.xml` — INTERNET permission + cleartext for ws:// LAN
- `test/handshake_fsm_test.dart` — 15 FSM transition tests (pair, reconnect w/ mac assertion, all failures, guards)
- `test/latency_probe_test.dart` — 8 tests: percentile math, empty safety, pong->RTT, cadence via injected clock/sink
- `test/widget_test.dart` — updated for the new shell (asserts TrackpadScreen + Connect, placeholder gone)

## Verification Results
- `flutter analyze` — No issues found.
- `flutter test` — All 32 tests passed (15 FSM + 8 probe + 4 move_sender + 3 nodelay + 2 widget).
- Grep gates: AndroidManifest has `android.permission.INTERNET` (1) + `usesCleartextTraffic` (1); trackpad uses `onPointerMove` (3) with zero `GestureDetector` (0); `sendMove(event.delta.dx, event.delta.dy)` is raw 1:1 (no multiplier); `WakelockPlus.enable`/`disable` present; `main.dart` no longer contains the placeholder text (0).
- Handshake ordering asserted by the FSM tests: `hello` then always `challenge`, then `pin` (unpaired) or `auth` (paired).
- The physical <30ms numeric pass remains the MANUAL on-device gate (02-04), deliberately NOT an agent criterion here.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Updated widget_test.dart for the removed placeholder**
- **Found during:** Task 3
- **Issue:** The existing `test/widget_test.dart` asserted `find.text('Remote Control — cursor spike')`, which Task 3 removes when `main.dart` routes to the trackpad screen — leaving the full suite failing.
- **Fix:** Rewrote the smoke test to assert `TrackpadScreen` + the `Connect` button are present and the placeholder is gone; kept the remote_protocol path-dep import assertion.
- **Files modified:** `app/remote_control/test/widget_test.dart`
- **Commit:** `9244a06`

## Known Stubs

None. Every piece is wired to a real data source: the FSM drives real messages, the probe consumes real pong echoes, the trackpad feeds real pointer deltas. The only intentional spike-scope limits (documented in the plan/objective, resolved in Phase 3, not stubs) are: in-memory token (no secure persistence), manual IP:port entry (no discovery), and app-wide cleartext (no scoped network-security-config). The latency HUD + PIN shortcut are the spike-only, removable-once-the-gate-passes pieces (D-09).

## Self-Check: PASSED
- FOUND: app/remote_control/lib/net/handshake_fsm.dart
- FOUND: app/remote_control/lib/net/handshake.dart
- FOUND: app/remote_control/lib/hud/latency_probe.dart
- FOUND: app/remote_control/lib/hud/latency_hud.dart
- FOUND: app/remote_control/lib/trackpad/trackpad_screen.dart
- FOUND: app/remote_control/test/handshake_fsm_test.dart
- FOUND: app/remote_control/test/latency_probe_test.dart
- FOUND commits: 3712a9f, 99f31b1, 9682676, 79b96c7, 9244a06
