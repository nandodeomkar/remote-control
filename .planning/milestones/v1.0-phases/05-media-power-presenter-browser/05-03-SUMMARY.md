---
phase: 05-media-power-presenter-browser
plan: 03
subsystem: server-transport
tags: [rust, tokio, watch-channel, websocket, vol-changed, proto-1.1, tdd]

# Dependency graph
requires:
  - phase: 05-01
    provides: "VolChangedPayload / Msg::VolChanged codec + vol.changed fixtures + Dart-side protoVersion 1.1"
  - phase: 01 (transport/session)
    provides: "pause watch seam, session FSM, reply-queue write path the volume branch clones"
provides:
  - "VolumeState {value: u8, muted: bool} core-owned in transport/mod.rs (zero OS deps)"
  - "ServerDeps.volume: watch::Receiver<VolumeState> DI seam (05-05 plugs the real audio thread in)"
  - "Authed-gated volume select! branch + D-03 after-auth snapshot in run_session"
  - "SERVER_PROTO_VERSION = 1.1 (pub, re-exported via transport; beacon inherits)"
  - "vol_ integration suite: pre-auth silence, pair/auth snapshots, push-on-change"
affects: [05-05 (audio thread producer), 05-07 (client volume UI), phase-06 push-driven features]

# Tech tracking
tech-stack:
  added: []
  patterns: ["watch<T> seam in ServerDeps cloned per session (pause precedent, now x2)", "was_authed transition capture in the read arm for exactly-once post-auth pushes", "borrow_and_update in branch AND snapshot to prevent duplicate fire"]

key-files:
  created: []
  modified:
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/session.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/tests/integration.rs
    - server/server-windows/src/main.rs
    - protocol/fixtures/beacon/01-valid.json

key-decisions:
  - "SERVER_PROTO_VERSION widened pub(crate) -> pub with a transport re-export so integration tests assert the constant, never a stale literal (Pitfall 10)"
  - "After-auth snapshot hooked in run_session's read arm via was_authed capture — handle_text signature unchanged, both pairOk and authOk transitions covered"
  - "beacon fixture 01-valid.json bumped to proto 1.1: its wire object pins the CURRENT encoder output by its own documented contract, not historical bytes"
  - "vol_ tests drive pushes through a test-owned watch Sender on Harness; authed_client drains the D-03 snapshot so all pre-existing tests keep a clean stream"

patterns-established:
  - "Second watch seam confirms the ServerDeps watch pattern scales: alive-flag + guarded select! branch + Err(_) disable, cloned per session in listener"
  - "S->C push frames ride the same bounded mpsc write queue as replies (ordering + backpressure for free)"

requirements-completed: [MED-02]

# Metrics
duration: 9min
completed: 2026-07-11
---

# Phase 05 Plan 03: vol.changed Push Plumbing Summary

**Authed-gated vol.changed push through a watch<VolumeState> seam in ServerDeps — one snapshot right after pairOk/authOk plus live pushes on every change, proven RED→GREEN by four socket-level tests; server now advertises protoVersion 1.1**

## Performance

- **Duration:** ~9 min
- **Started:** 2026-07-11T02:00:04Z
- **Completed:** 2026-07-11T02:09:00Z
- **Tasks:** 2 (TDD RED + GREEN)
- **Files modified:** 6

## Accomplishments

- Core-owned `VolumeState { value: u8, muted: bool }` (Copy/PartialEq/Eq/Default, zero OS deps) + `ServerDeps.volume` watch receiver — the exact seam 05-05's Windows audio thread plugs into
- `run_session` volume select! branch guarded `volume_alive && ctx.auth_state == AuthState::Authed` (T-05-05 closed) with `Err(_)` disable (T-05-06, never busy-loops)
- D-03 after-auth snapshot at BOTH Authed transitions via `was_authed` capture in the read arm; `borrow_and_update` in both places prevents duplicate fire — the exactly-one property is test-asserted
- Four `vol_` integration tests written RED first, all GREEN: `vol_no_push_preauth` (with positive control), `vol_snapshot_after_pair_auth`, `vol_snapshot_after_token_auth`, `vol_push_on_change_when_authed`
- Rust side bumped to protoVersion "1.1"; beacon `proto` field inherited automatically via the 03-01 constant reference

## Task Commits

Each task was committed atomically:

1. **Task 1: VolumeState + ServerDeps.volume seam + failing vol_ tests (RED)** - `99d297e` (test)
2. **Task 2: Authed-gated select! branch + after-auth snapshot + version 1.1 (GREEN)** - `f1248c2` (feat)

## TDD Gate Compliance

RED commit `99d297e` (4 vol_ tests failing on 2s recv timeout, workspace building) precedes GREEN commit `f1248c2` (all 120 workspace tests passing). No refactor commit needed.

## Files Created/Modified

- `server/server-core/src/transport/mod.rs` - VolumeState struct, ServerDeps.volume field, SERVER_PROTO_VERSION re-export
- `server/server-core/src/transport/session.rs` - volume_alive + gated select! branch, was_authed snapshot hook, vol_changed_frame helper, version "1.1"
- `server/server-core/src/transport/listener.rs` - destructures + clones volume receiver per session (compiler ripple, see deviations)
- `server/server-core/tests/integration.rs` - Harness.volume_tx, recv_vol_changed/assert_no_frame helpers, 4 vol_ tests, constant-referenced serverVersion assertion, commented historical 1.0 pins
- `server/server-windows/src/main.rs` - interim `(_volume_tx, volume_rx)` default channel (named binding kept alive; 05-05 moves the sender to the audio thread)
- `protocol/fixtures/beacon/01-valid.json` - proto "1.0" → "1.1" in wire AND expect (see deviations)

## Decisions Made

- `SERVER_PROTO_VERSION` widened from `pub(crate)` to `pub` with a `transport` re-export — tests asserting "current server version" reference the constant, so future minor bumps cannot strand a literal (Pitfall 10)
- Snapshot seam placed in `run_session`'s read arm (capture `was_authed` before `handle_text`, send after replies) — `handle_text` signature untouched, both transitions covered by one hook
- `authed_client` helper drains the D-03 snapshot so the ten pre-existing socket tests (which recv the "next" frame post-auth) stay valid; the vol_ suite uses `pair_client` directly when the snapshot itself is under test

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] listener.rs compiler ripple from the new ServerDeps field**
- **Found during:** Task 1 (seam addition)
- **Issue:** `accept_loop` destructures ServerDeps exhaustively; the new `volume` field broke compilation. File not in the plan's files_modified list.
- **Fix:** Task 1 held the receiver alive; Task 2 clones it per session and passes it to `run_session` (the intended wiring)
- **Files modified:** server/server-core/src/transport/listener.rs
- **Verification:** `cargo build --workspace` green in both tasks
- **Committed in:** 99d297e, f1248c2

**2. [Rule 1 - Bug] Shared beacon fixture pinned the OLD current version**
- **Found during:** Task 2 (workspace test run)
- **Issue:** `encode_beacon_matches_valid_fixture_wire` failed after the 1.1 bump — `protocol/fixtures/beacon/01-valid.json` carries `proto: "1.0"`, but its own description declares it pins the CURRENT encoder output (not historical bytes), making it a stale current-version literal in fixture form (Pitfall 10's class)
- **Fix:** Bumped `proto` to "1.1" in both the `wire` and `expect` objects; fixtures 02–06 (decode-leniency cases where 1.0 is a valid foreign wire) left untouched
- **Verification:** Rust workspace green AND `flutter test test/beacon_test.dart` green (the Dart test is data-driven from the fixture's expect object — both sides stay in lockstep)
- **Committed in:** f1248c2

---

**Total deviations:** 2 auto-fixed (1 blocking ripple, 1 stale-version bug)
**Impact on plan:** Both required for compilation/correctness of the planned version bump. No scope creep.

## Known Stubs

- `server/server-windows/src/main.rs` step 6a: `(_volume_tx, volume_rx)` default-state channel — INTENTIONAL per the plan's artifacts table ("composition-root stub"); 05-05 replaces the sender with the real WASAPI audio-thread producer. Until then the Windows binary pushes one default snapshot (0, unmuted) after auth and never changes.

## Issues Encountered

None beyond the documented deviations.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- The MED-02 push seam is live and CI-proven: 05-05 only needs to hand its `watch::Sender<VolumeState>` clone... (move) to the audio thread in main.rs step 6a — zero session/transport changes
- 05-07's client volume UI can rely on: exactly one snapshot right after auth (both paths) + a push per state change, never pre-auth
- Both wire ends now advertise 1.1 (Dart bumped in 05-01, Rust here); beacon proto inherited

---
*Phase: 05-media-power-presenter-browser*
*Completed: 2026-07-11*

## Self-Check: PASSED

All modified files exist on disk; task commits 99d297e and f1248c2 present in git log.
