---
phase: 07-server-shell-dashboard-polish
plan: 05
subsystem: transport
tags: [rust, server-core, tokio-watch, session, revoke, conn-count, input-blocked, proto-1.3]

# Dependency graph
requires:
  - phase: 07-01
    provides: "AuthManager.verify_auth_hash / complete_pairing_named / paired_hashes / revoke (the API this plan calls into)"
  - phase: 07-02
    provides: "input.blocked (proto 1.3) wire contract — InputBlockedPayload + Msg::InputBlocked in both codecs, frozen ahead of this plan's session push"
provides:
  - "ServerDeps.conn_count (Arc<watch::Sender<usize>>) — the tray tooltip source (SRV-01)"
  - "ServerDeps.revoke (watch::Receiver<u64>) — the settings-driven force-disconnect seam (D-05)"
  - "ServerDeps.blocked (watch::Receiver<u64>) — the input-thread UIPI push seam (SRV-05)"
  - "session::input_blocked_frame encoder"
  - "SERVER_PROTO_VERSION = \"1.3\""
affects: [07-06 (tray tooltip reader + real conn_count/blocked producers), 07-07 (config persistence), 07-08 (settings revoke sender)]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SHARED-B clone: revoke is a sibling (non-authed-gated) select! arm; input.blocked is an authed-gated arm with NO after-auth snapshot (mirrors apps/clip, not volume)"
    - "SHARED-C clone: ServerDeps field -> listener.rs destructure/clone/pass -> run_session param, threaded through with interim main.rs producers (06-01 precedent) so the workspace stays green ahead of the real producers (07-06)"

key-files:
  created: []
  modified:
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/src/transport/session.rs
    - server/server-windows/src/main.rs
    - server/server-core/tests/integration.rs
    - protocol/fixtures/beacon/01-valid.json

key-decisions:
  - "handle_text's return signature grew a third element (Option<[u8;32]>) — the stored hash that authed the session on a pin-Ok/auth-Ok transition, captured at the SAME was_authed/newly-Authed guard site as the existing D-03 vol.changed snapshot, so conn_count/authed_hash bookkeeping needed zero new transition-detection logic"
  - "The revoke select! arm is NOT authed-gated (a pre-auth session has no authed_hash yet); the `if let Some(h) = authed_hash` guard inside the arm is what actually filters — matches the plan's must_have wording literally"
  - "hello.device is captured into a local hello_device: Option<String> (mirrors session_nonce's existing pattern) rather than added to SessionCtx, keeping router.rs (dispatch module, out of this plan's files_modified) untouched"
  - "The shared beacon golden fixture (protocol/fixtures/beacon/01-valid.json) bumped its proto literal 1.2 -> 1.3 in lockstep with SERVER_PROTO_VERSION — the established 06-01 'D-09 single source of truth' precedent, not a new decision"

patterns-established:
  - "Task 1 (ServerDeps plumbing/signatures) and Task 2 (session.rs behaviors) landed in ONE commit: listener.rs's call site and session.rs's run_session signature are mutually dependent for `cargo build --workspace` to pass, so splitting them would leave an uncompilable intermediate commit"

requirements-completed: [SRV-01, SRV-03, SRV-05]

# Metrics
duration: ~12min
completed: 2026-07-12
---

# Phase 7 Plan 05: conn_count / revoke / input.blocked Transport Seams Summary

**Three new `ServerDeps` watch seams (a live device-count sender, a revocation epoch, and an input-blocked epoch) threaded end-to-end through `listener.rs` into `session.rs`, cloning the existing authed-gated `select!` push discipline byte-for-byte — proto bumped to 1.3, six new integration tests prove the conn_count/revoke/input.blocked contracts, workspace stays green via interim `main.rs` producers.**

## Performance

- **Duration:** ~12 min
- **Completed:** 2026-07-12
- **Tasks:** 3 (Task 1+2 landed in one commit — see Decisions Made)
- **Files modified:** 6 (5 source + 1 shared fixture)

## Accomplishments
- `ServerDeps` grew `conn_count: Arc<watch::Sender<usize>>`, `revoke: watch::Receiver<u64>`, `blocked: watch::Receiver<u64>` — destructured/cloned in `listener.rs`, threaded into `run_session`.
- `session.rs`: `conn_count` increments exactly once per Authed session (both the pin-Ok and auth-Ok transitions, captured at the same guard as the existing D-03 vol.changed snapshot) and decrements exactly once in the CONN-07 cleanup.
- A sibling `revoke` `select!` arm force-disconnects a LIVE authed session whose stored hash is no longer in `AuthManager::paired_hashes()` — landing on the existing straight-line CONN-07 cleanup, zero new teardown code.
- An authed-gated `input.blocked` push (mirrors apps/clip: NO after-auth snapshot) fires on a blocked-epoch transition, carrying `reason: "elevated"`.
- `AuthManager::verify_auth_hash` (not the plain bool `verify_auth`) and `complete_pairing_named` (fed the phone's `hello.device` name) now correlate each session with the stored hash that authed it — the D-05 revoke check's prerequisite.
- `SERVER_PROTO_VERSION` bumped `"1.2"` -> `"1.3"` (additive minor; 1.0-1.2 clients still accepted).
- `main.rs` supplies interim watch-channel producers for the three new fields (06-01 precedent) so `server-windows` keeps compiling ahead of the real producers (07-06 tray, 07-08 settings revoke, 07-04's UIPI detection wired to `blocked`).
- Six new `tests/integration.rs` tests: conn_count 0->1->0, the D-05 revoke headline (live-session drop + reconnect authFail), and the input.blocked authed gate (pre-auth silence, pending-delivery-post-auth, single post-auth push).

## Task Commits

Each task was committed atomically, with Tasks 1+2 combined (see Deviations):

1. **Task 1 + Task 2: ServerDeps/listener/run_session plumbing + session.rs behaviors (conn_count, revoke, input.blocked, proto 1.3)** - `9f33e82` (feat)
2. **Task 3: Integration tests — conn_count, revoke-drops-live-session, input.blocked authed-gate** - `d68f93e` (test)

## Files Created/Modified
- `server/server-core/src/transport/mod.rs` - `ServerDeps.conn_count`/`revoke`/`blocked` fields with apps/clip-style doc comments.
- `server/server-core/src/transport/listener.rs` - destructure/clone-per-connection/pass the three new fields into `run_session`.
- `server/server-core/src/transport/session.rs` - `run_session` signature extended; `conn_count`/`revoke`/`blocked` local state + `select!` arms; `handle_text` grew a third return element (`Option<[u8;32]>` newly-authed hash); `hello_device` capture; `input_blocked_frame` encoder; `SERVER_PROTO_VERSION` -> `"1.3"`.
- `server/server-windows/src/main.rs` - interim `conn_count`/`revoke`/`blocked` watch-channel producers wired into `ServerDeps`.
- `server/server-core/tests/integration.rs` - `Harness` extended with `conn_count`/`revoke_tx`/`blocked_tx`; both `ServerDeps` construction sites updated; six new tests.
- `protocol/fixtures/beacon/01-valid.json` - `proto` literal `"1.2"` -> `"1.3"` (Rule 1 auto-fix, direct consequence of the version bump — see Deviations).

## Decisions Made
- `handle_text`'s return type grew a third element (`Option<[u8;32]>`) carrying the stored hash on a fresh Authed transition, captured at the SAME `!was_authed && ctx.auth_state == AuthState::Authed` guard the existing D-03 vol.changed snapshot already uses — zero new transition-detection logic needed for conn_count/authed_hash bookkeeping.
- The revoke `select!` arm is intentionally NOT authed-gated in its `if` guard (a pre-auth session has no `authed_hash` yet to check); the `if let Some(h) = authed_hash` guard INSIDE the arm body is what filters — matches the plan's must_have wording exactly ("revoked hash no longer in paired_hashes()").
- `hello.device` is captured into a local `hello_device: Option<String>` in `run_session`, mirroring the existing `session_nonce` pattern, rather than added as a `SessionCtx` field — keeps `router.rs` (a dispatch-module file, not in this plan's `files_modified`) untouched.
- Task 1 (ServerDeps/listener/signature plumbing) and Task 2 (session.rs behaviors) landed in ONE commit: `listener.rs`'s call site passes `conn_count`/`revoke`/`blocked` and `run_session`'s signature must accept them for `cargo build --workspace` (Task 1's own verify command) to pass — splitting them would leave an intermediate commit that does not compile. Task 3 (tests) landed as its own commit, unaffected.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Bumped the shared beacon golden fixture's `proto` literal in lockstep with `SERVER_PROTO_VERSION`**
- **Found during:** Task 2 verification (`cargo test -p server-core`)
- **Issue:** `transport::beacon::tests::encode_beacon_matches_valid_fixture_wire` failed — the beacon encoder emits `SERVER_PROTO_VERSION` (now `"1.3"`) but `protocol/fixtures/beacon/01-valid.json` still pinned `"1.2"`. This is the exact same-lockstep contract 06-01's SUMMARY documented as "D-09 single source of truth" when it bumped 1.1->1.2.
- **Fix:** Updated both the `wire` and `expect` `proto` fields in the fixture to `"1.3"`.
- **Files modified:** `protocol/fixtures/beacon/01-valid.json`
- **Verification:** `cargo test -p server-core` — 99 lib + 7 fixture + 22 integration tests all green.
- **Committed in:** `9f33e82` (Task 1+2 commit, alongside the proto bump that caused it)

---

**Total deviations:** 1 auto-fixed (bug, direct consequence of the mandated proto bump)
**Impact on plan:** No scope creep — the fixture bump is the same discipline the plan itself specifies for `SERVER_PROTO_VERSION`, just applied to the one other file that embeds the literal.

## Issues Encountered
None beyond the beacon fixture lockstep above, resolved via Rule 1.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The three transport seams (`conn_count`, `revoke`, `blocked`) are threaded end-to-end and integration-tested; `07-06` (shell/tray thread) can now subscribe `conn_count` for the tooltip, `07-08` (settings) can drive `revoke_tx`, and `07-04`'s UIPI detection (already landed) can be wired to `blocked` — `main.rs`'s interim producers are the explicit hand-off points, each named in a comment.
- `SERVER_PROTO_VERSION` is `1.3`; the shared beacon fixture and the `input.blocked` wire contract (07-02) are both frozen ahead of this plan's push and consistent with it.
- No blockers.

## Self-Check: PASSED

- FOUND: `server/server-core/src/transport/mod.rs`
- FOUND: `server/server-core/src/transport/listener.rs`
- FOUND: `server/server-core/src/transport/session.rs`
- FOUND: `server/server-windows/src/main.rs`
- FOUND: `server/server-core/tests/integration.rs`
- FOUND: `protocol/fixtures/beacon/01-valid.json`
- FOUND commit: `9f33e82` (Task 1+2)
- FOUND commit: `d68f93e` (Task 3)
- `cargo build --workspace` green; `cargo test -p server-core` — 99 lib + 7 fixture + 22 integration tests green; `cargo test -p server-windows` — 25 passed, 2 ignored (on-device-only) green.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-12*
