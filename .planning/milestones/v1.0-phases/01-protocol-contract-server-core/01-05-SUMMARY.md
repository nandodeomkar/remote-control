---
phase: 01-protocol-contract-server-core
plan: 05
subsystem: dispatch
tags: [rust, tokio, notify, dispatch, mock-executors, conn-07]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core (plan 02)
    provides: executor trait contracts, dispatch stubs (SessionCtx, route/route_binary signatures, MAX_BS), Call enum
  - phase: 01-protocol-contract-server-core (plan 03)
    provides: JSON envelope codec (Decoded, Msg, payload structs) the router matches on
provides:
  - Recording mock executors: one shared Arc sink behind all five traits, CallLog::calls() + notify-driven wait_for
  - HeldInput state map with drain-based release_all (CONN-07 core mechanism, idempotent)
  - route()/route_binary() with gate ordering auth -> pause -> family routing
  - Pending-power confirm map (tokio::time::Instant, 10s window, single-shot)
  - Browser/present key-macro tables (Phase 1 minimal mapping)
affects: [01-06 session/transport wiring, phase-2 enigo executors, phase-5 macro refinement]

# Tech tracking
tech-stack:
  added: []
  patterns: [notify-before-predicate wait_for (no lost-wake race), dispatcher-owned held state, single-shot confirm map via Option::take]

key-files:
  created: []
  modified:
    - server/server-core/src/executors/mock.rs
    - server/server-core/src/dispatch/held.rs
    - server/server-core/src/dispatch/router.rs

key-decisions:
  - "pending_power uses tokio::time::Instant (not std) so start_paused tests drive the 10s confirm window deterministically"
  - "Mismatched confirm clears the pending power action (single-shot take()) — suspicious traffic restarts the two-step sequence"
  - "Invalid enum values post-auth (bad button/action/mod, setvol > 100) are silently dropped: codec is value-lenient, router owns semantics, no invented err codes"
  - "S->C-direction types arriving FROM a client are known-but-invalid direction: ignored silently, never unknownType, never routed"
  - "apps.list and clip.get stay served while paused: SPEC 11's drop list is exhaustive and names only executor-bound families"

patterns-established:
  - "Notify-before-check wait_for: register Notified + enable() BEFORE the predicate check under lock — closes the lost-notification race with zero polling"
  - "Held-state updates precede the trait call on down, clear on up (RESEARCH Pattern 4): tracking never lags execution"
  - "route() debug_asserts handshake messages never reach it — the session FSM (Plan 06) owns hello/pin/auth"

requirements-completed: [CONN-07]

# Metrics
duration: 12min
completed: 2026-07-07
---

# Phase 1 Plan 05: Dispatch & Mock Executors Summary

**Auth->pause->route dispatch gates with dispatcher-owned held-input release (CONN-07), pending-power confirm map on tokio paused-clock time, and notify-driven recording mocks — 32 new unit tests, all green**

## Performance

- **Duration:** ~12 min
- **Started:** 2026-07-07T15:33:15Z
- **Completed:** 2026-07-07T15:45:30Z
- **Tasks:** 2 (both TDD: RED + GREEN commits each)
- **Files modified:** 3

## Accomplishments

- Recording mocks: all five executor traits share one `Arc<Mutex<Vec<Call>>>` + `tokio::sync::Notify` sink; `wait_for` registers the `Notified` future before the predicate check (no lost-wake race, no polling loop)
- CONN-07 mechanism complete and unit-proven: `HeldInput::release_all` drains both sets emitting exactly one compensating up per held input, then `is_empty()`; a second call emits nothing (idempotent). Plan 06 only needs to call it unconditionally after the read loop
- Gate ordering proven by tests: pre-auth drops EVERYTHING non-handshake (including ping and binary frames) with zero reply AND zero executor calls; paused drops the full SPEC §11 executor-bound list while ping still pongs
- Power double-confirm: `power` alone never touches the Power trait; matching `confirm` within 10s executes; no-pending/mismatch/expiry all reply `err{noPendingAction}` — expiry proven with `start_paused` + `tokio::time::advance`
- `text.bs > 10000` rejected with `bsTooLarge` before any executor call; diff-ops execute Backspace-then-TypeText in order; unknown `t` post-auth errs with `unknownType` and the session provably continues (D-07)

## Task Commits

Each task was committed atomically (TDD: test then feat):

1. **Task 1: Recording mock executors** — `a343619` (test, RED) + `8245705` (feat, GREEN)
2. **Task 2: Dispatch gates, routing, held-input, confirm map** — `d259423` (test, RED) + `cea353d` (feat, GREEN)

## Files Created/Modified

- `server/server-core/src/executors/mock.rs` — shared recording sink, CallLog (calls/wait_for), fixed `apps.list` windows (ids 1,2) and `clip.get` "mock-clip", 6 unit tests
- `server/server-core/src/dispatch/held.rs` — HeldInput note_*/release_all/is_empty (pure state, no async)
- `server/server-core/src/dispatch/router.rs` — route()/route_binary() gates + family routing + macro tables + confirm map, 26 unit tests

Note: `server/server-core/src/dispatch/mod.rs` was listed in the plan's files but needed no change — `AuthState` was already complete from Plan 02.

## Decisions Made

- **tokio::time::Instant for pending_power** (plan-mandated, replacing the Plan 02 stub's `std::time::Instant` import): lets `#[tokio::test(start_paused = true)]` + `advance()` prove the 10s window without real sleeps
- **Mismatched confirm clears the pending action**: `Option::take()` makes the slot single-shot; a wrong confirm forces the client to restart from `power` (safer under threat T-01-23)
- **Semantic-invalid values dropped silently**: unknown button/action strings, unknown mods, and `setvol` values > 100 produce no call and no reply — SPEC defines no err code for bad enum values, and inventing one would create a probing surface
- **`route()` param renamed `_auth`**: the AuthManager handle is unused until Plan 06 wires the handshake FSM; signature unchanged from the Plan 02 contract

## Deviations from Plan

None - plan executed exactly as written. (The `std::time::Instant` -> `tokio::time::Instant` switch in SessionCtx was explicitly directed by the plan's Task 2 action text.)

## Issues Encountered

- Test-helper compile error in the RED step: `assert_single_err` returning a borrow from a two-reference signature needed an explicit lifetime (`<'a>`). Fixed before the RED commit.

## Known Stubs

- `server/server-core/src/transport/mod.rs` — `run()` and `ServerDeps` wiring remain `todo!()` by design; implemented in Plan 01-06. Consequence: the walking-skeleton integration test `walking_skeleton_pair_auth_input` stays red, exactly as the plan documents. `cargo build --tests` compiles clean against this plan's implemented APIs.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 01-06 (session/transport) has everything it needs: `MockExecutors::recording()` + `wait_for` serve the walking skeleton unchanged; `route()`/`route_binary()` are drop-in for the read loop; `held.release_all(&*exec.mouse_keys)` is the one unconditional teardown call
- Phase success criterion 2's gate halves (pre-auth drop, paused drop) are proven at unit level with both no-reply and no-executor-call assertions — ready for socket-level proof in Plan 06

## Self-Check: PASSED

- FOUND: server/server-core/src/executors/mock.rs (contains `wait_for`, `Notify`)
- FOUND: server/server-core/src/dispatch/held.rs (contains `release_all`)
- FOUND: server/server-core/src/dispatch/router.rs (contains `AuthState`, `MAX_BS`, `bsTooLarge`)
- FOUND commits: a343619, 8245705, d259423, cea353d
- Tests: 86 lib tests pass (26 dispatch::, 6 executors::mock::); zero `#[cfg(windows)]` / OS-type imports in dispatch/ and executors/

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*
