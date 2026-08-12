---
phase: 07-server-shell-dashboard-polish
plan: 02
subsystem: api
tags: [protocol, codec, serde, dart, golden-fixtures, input.blocked, proto-1.3, uipi]

# Dependency graph
requires:
  - phase: 05-01
    provides: the vol.changed (proto 1.1) golden-fixture precedent cloned here
  - phase: 06-01
    provides: apps.changed/clip.changed (proto 1.2) additive-push seam and no-snapshot discipline
provides:
  - InputBlockedPayload + Msg::InputBlocked + encode/decode arms (server-core codec, proto 1.3)
  - InputBlockedMsg + decodeText arm (Dart remote_protocol codec)
  - protocol/fixtures/input_blocked/01-input-blocked.json (shared golden fixture, unknown-field-dropped)
  - byte-identical Rust+Dart decode of the shared fixture, proven by both fixture harnesses
affects: [07-04, 07-05, 07-11]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "SHARED-A minor protocol amendment: payload struct + enum arm + decode/encode arm + round-trip test + shared golden fixture, cloned for input.blocked (proto 1.3)"
    - "New fixture family requires a matching test function in BOTH hard-coded harnesses (Rust fixtures.rs + Dart fixture_test.dart) — neither globs family dirs"

key-files:
  created:
    - protocol/fixtures/input_blocked/01-input-blocked.json
  modified:
    - server/server-core/src/codec/json.rs
    - server/server-core/src/dispatch/router.rs
    - app/packages/remote_protocol/lib/src/json_codec.dart
    - app/packages/remote_protocol/test/fixture_test.dart
    - server/server-core/tests/fixtures.rs

key-decisions:
  - "input.blocked is an S→C-only push: routed to the server-authored no-op group in router.rs (alongside vol.changed/clip.changed) — a client that sends it is known-but-invalid-direction, ignored silently"
  - "SERVER_PROTO_VERSION intentionally NOT bumped here (still 1.2) — the version bump + session push land in 07-05 which owns session.rs; this plan is the wire-contract slice only"
  - "Added codec_fixtures_input_blocked to the Rust fixture harness (not in files_modified) so the SAME shared fixture proves byte-identical decode in both languages — the must_have's cross-language guarantee needs a Rust consumer of the fixture, not just an inline unit test"

patterns-established:
  - "Pattern: additive proto minor amendment cloned end-to-end from vol.changed across five touchpoints (struct, enum, decode, encode, fixture) with the router no-op arm as the sixth exhaustive-match touchpoint"

requirements-completed: [SRV-05]

# Metrics
duration: 15min
completed: 2026-07-12
---

# Phase 7 Plan 02: input.blocked (proto 1.3) Wire Contract Summary

**Additive `input.blocked` S→C message (reason string) added to the Rust and Dart codecs plus a shared golden fixture, proving byte-identical decode across both languages via both fixture harnesses — the UIPI-block wire contract locked before its server push (07-05) and client banner (07-11).**

## Performance

- **Duration:** ~15 min
- **Started:** 2026-07-12
- **Completed:** 2026-07-12
- **Tasks:** 2
- **Files modified:** 6 (1 created, 5 modified)

## Accomplishments
- `InputBlockedPayload { reason }` + `Msg::InputBlocked` + `"input.blocked"` encode/decode arms in the Rust codec, additive (proto 1.3), with a green `round_trip_input_blocked` test.
- `InputBlockedMsg` + `decodeText` arm in the Dart `remote_protocol` codec, mirroring `VolChangedMsg`.
- Shared golden fixture `protocol/fixtures/input_blocked/01-input-blocked.json` carrying the unknown-`future`-field-dropped discipline (ASVS V5 forward-compat, T-07-04).
- The shared fixture is exercised by BOTH harnesses (`codec_fixtures_input_blocked` in Rust, `input_blocked fixtures` in Dart) — the byte-identity anchor for the cross-language contract.

## Task Commits

Each task was committed atomically:

1. **Task 1: Rust codec — InputBlockedPayload + Msg::InputBlocked + encode/decode + round-trip test** - `31729f8` (feat)
2. **Task 2: Shared golden fixture + Dart InputBlockedMsg + decodeText arm + fixture tests** - `7972096` (feat)

**Plan metadata:** (this commit) (docs: complete plan)

## Files Created/Modified
- `protocol/fixtures/input_blocked/01-input-blocked.json` - Shared golden fixture; `reason:"elevated"` with an unknown `future` field dropped on decode.
- `server/server-core/src/codec/json.rs` - `InputBlockedPayload`, `Msg::InputBlocked`, decode/encode arms, `round_trip_input_blocked` test.
- `server/server-core/src/dispatch/router.rs` - `Msg::InputBlocked(_)` added to the S→C-only no-op group (exhaustive-match fix).
- `app/packages/remote_protocol/lib/src/json_codec.dart` - `InputBlockedMsg` class + `'input.blocked'` decodeText arm.
- `app/packages/remote_protocol/test/fixture_test.dart` - `input_blocked` fixture group.
- `server/server-core/tests/fixtures.rs` - `codec_fixtures_input_blocked` family test.

## Decisions Made
- **No version bump here.** `SERVER_PROTO_VERSION` stays `1.2`; the 1.3 bump and the session push branch are 07-05's job (it owns `session.rs`). This plan deliberately ships only the wire shape so consumers build against a fixed contract.
- **input.blocked is S→C-only.** In the router it joins the `vol.changed`/`clip.changed` no-op group: a client sending it is known-but-invalid-direction and ignored silently (no `unknownType`, no execution).
- **`reason` is a fixed vocabulary** (`"elevated"`) — never a window title/exe path/PII (T-07-05), documented in both codecs.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 3 - Blocking] Added `Msg::InputBlocked(_)` arm to router.rs exhaustive matches**
- **Found during:** Task 1 (Rust codec)
- **Issue:** Adding the enum variant broke two non-exhaustive `match` sites (`router.rs` GATE-3 routing + a compile error surfaced by cargo). `files_modified` did not list `router.rs`.
- **Fix:** Added `Msg::InputBlocked(_)` to the S→C-only no-op group (`| Msg::ClipChanged(_) | Msg::VolChanged(_) | ...`) — the semantically correct home for a server-authored push.
- **Files modified:** server/server-core/src/dispatch/router.rs
- **Verification:** `cargo test -p server-core` — 99+7+19 tests green, no regressions.
- **Committed in:** `31729f8` (Task 1 commit)

**2. [Rule 2 - Missing Critical] Added `codec_fixtures_input_blocked` to the Rust fixture harness**
- **Found during:** Task 2 (fixture + Dart)
- **Issue:** The Rust fixture harness (`fixtures.rs`) enumerates families via a hard-coded list of test functions, not directory globbing — so a new fixture dir is invisible to it. The plan's must_have ("the same golden fixture decodes identically in the Rust and Dart codecs") and key_link (Rust decode ↔ Dart decodeText via the shared fixture) require a Rust consumer of the SHARED fixture, not just the inline `round_trip_input_blocked` unit test. `files_modified` did not list `fixtures.rs`.
- **Fix:** Added `codec_fixtures_input_blocked()` calling `run_json_family("input_blocked")`, mirroring the Dart `input_blocked` group.
- **Files modified:** server/server-core/tests/fixtures.rs
- **Verification:** `cargo test -p server-core --test fixtures` — 7 tests green including `codec_fixtures_input_blocked`; `dart test` — `input_blocked fixtures all scenarios` green.
- **Committed in:** `7972096` (Task 2 commit)

---

**Total deviations:** 2 auto-fixed (1 blocking, 1 missing critical)
**Impact on plan:** Both auto-fixes were necessary — the router arm to compile, the Rust fixture test to actually satisfy the plan's cross-language byte-identity guarantee. No scope creep; both stay within the wire-contract slice.

## Issues Encountered
None beyond the exhaustive-match compile error, resolved via Rule 3 above.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- The `input.blocked` (proto 1.3) wire contract is fixed and test-locked in both codecs.
- **07-05** can now bump `SERVER_PROTO_VERSION` to `1.3` and add the authed-gated session push branch (`input_blocked_frame(reason)`) against this frozen shape.
- **07-04** can wire the input-thread UIPI detection (foreground integrity-level check) to advance the `blocked` watch epoch.
- **07-11** can add the client `InputBlockedMsg` `_onFrame` arm + transient banner against `InputBlockedMsg`.

## Self-Check: PASSED

- FOUND: protocol/fixtures/input_blocked/01-input-blocked.json
- FOUND: .planning/phases/07-server-shell-dashboard-polish/07-02-SUMMARY.md
- FOUND commit: 31729f8 (Task 1)
- FOUND commit: 7972096 (Task 2)

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-12*
