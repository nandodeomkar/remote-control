---
phase: 05-media-power-presenter-browser
plan: 01
subsystem: protocol
tags: [websocket, json, serde, dart, golden-fixtures, vol-changed, protoversion]

# Dependency graph
requires:
  - phase: 01-protocol-server-core
    provides: golden-fixture harnesses (Rust fixtures.rs, Dart fixture_test.dart), two-step envelope codecs, router S-to-C ignore arm pattern
provides:
  - vol.changed S-to-C wire contract (D-03, protoVersion 1.1) locked by 3 golden fixtures
  - VolChangedPayload/Msg::VolChanged in Rust codec with router silent-ignore arm
  - VolChangedMsg in Dart codec + decodeText registry entry
  - protoVersion '1.1' / protoMinor 1 constants (Dart advertises 1.1 in hello)
affects: [05-03 server volume push, 05-07 volume slider UI, media, protocol]

# Tech tracking
tech-stack:
  added: []
  patterns: [fixture-family-first amendment (schema + fixtures + both codecs + SPEC note), version constant referenced from lib instead of literal]

key-files:
  created:
    - protocol/fixtures/volume/01-vol-changed.json
    - protocol/fixtures/volume/02-vol-changed-muted.json
    - protocol/fixtures/volume/03-vol-changed-missing-muted.json
  modified:
    - protocol/SPEC.md
    - protocol/schema/messages.schema.json
    - server/server-core/src/codec/json.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/tests/fixtures.rs
    - app/packages/remote_protocol/lib/src/json_codec.dart
    - app/packages/remote_protocol/lib/src/version.dart
    - app/packages/remote_protocol/test/fixture_test.dart
    - app/remote_control/lib/net/handshake_fsm.dart
    - app/remote_control/test/handshake_fsm_test.dart
    - app/remote_control/test/connection_service_test.dart

key-decisions:
  - "VolChangedPayload uses u64 value + bool muted with NO Option — serde missing-field is the hard decode error fixture 03 demands"
  - "clientProtoVersion in handshake_fsm.dart now references the remote_protocol protoVersion constant so future minor bumps cannot leave a stale lib literal"
  - "Remaining '1.0' test literals are historical wire pins (mismatched-server err payload, 1.0 beacon must still parse) — each commented as such per Pitfall 10"

patterns-established:
  - "Minor protocol bump recipe: fixtures RED in both harnesses -> codec arms GREEN -> SPEC section 2 addition note + section 7 row -> version constants last"

requirements-completed: [MED-02]

# Metrics
duration: ~7min (this session; Task 1 artifacts carried from a prior interrupted session)
completed: 2026-07-11
---

# Phase 5 Plan 01: vol.changed Wire Contract Summary

**S-to-C vol.changed {value 0-100, muted} push landed as protoVersion 1.1 (D-03): 3 golden fixtures pass byte-identically in both the Rust and Dart codecs, missing `muted` is a hard decode error on both sides, and a client-sent vol.changed is silently ignored by the router**

## Performance

- **Duration:** ~7 min (2026-07-11T01:30:46Z → 2026-07-11T01:37:53Z); Task 1 file contents pre-existed from a prior interrupted session and were verified against the plan spec before committing
- **Tasks:** 3 (Task 2 and 3 TDD: RED + GREEN commits each)
- **Files modified:** 14

## Accomplishments
- MED-02 wire contract locked: `protocol/fixtures/volume/` family (positive round-trip with unknown-field tolerance, muted-at-zero, missing-muted hard error) is the executable cross-language contract
- Rust: `VolChangedPayload { value: u64, muted: bool }`, `Msg::VolChanged`, decode/encode arms; router groups it with the S-to-C-only ignore arm (no executor call, no reply — T-05-02 mitigated); `is_executor_bound` stays a positive list so it is pause-gate exempt
- Dart: `VolChangedMsg` with `_req<int>`/`_req<bool>` (missing field throws — T-05-01 mitigated), `decodeText` registry entry, `protoVersion = '1.1'` / `protoMinor = 1`
- Full verification green: cargo test -p server-core (91 unit + 5 fixture + 10 integration), remote_protocol flutter test (9), app/remote_control flutter test (238)

## Task Commits

Each task was committed atomically:

1. **Task 1: Golden fixtures + schema + SPEC amendment** - `e966447` (feat)
2. **Task 2: Rust codec + router (TDD)** - `7d81011` (test, RED) + `0157312` (feat, GREEN)
3. **Task 3: Dart codec + 1.1 bump (TDD)** - `841d278` (test, RED) + `e2f17b8` (feat, GREEN)

## Files Created/Modified
- `protocol/fixtures/volume/*.json` - 3 golden fixtures (contract source of truth)
- `protocol/schema/messages.schema.json` - `volChanged` $defs entry + t-dispatch allOf hook
- `protocol/SPEC.md` - protoVersion 1.1, section 2 addition note, section 7 vol.changed row
- `server/server-core/src/codec/json.rs` - payload struct, enum variant, decode/encode arms
- `server/server-core/src/dispatch/router.rs` - `Msg::VolChanged(_)` in the S-to-C-only silent-ignore arm
- `server/server-core/tests/fixtures.rs` - `codec_fixtures_volume` family test fn
- `app/packages/remote_protocol/lib/src/json_codec.dart` - `VolChangedMsg` + decodeText entry
- `app/packages/remote_protocol/lib/src/version.dart` - '1.1' / protoMinor 1
- `app/packages/remote_protocol/test/fixture_test.dart` - 'volume fixtures' group
- `app/remote_control/lib/net/handshake_fsm.dart` - clientProtoVersion references the constant
- `app/remote_control/test/handshake_fsm_test.dart` - asserts constant; historical pins commented
- `app/remote_control/test/connection_service_test.dart` - historical '1.0' beacon pin commented

## Decisions Made
- `VolChangedPayload.value` is `u64` per plan (schema constrains 0-100; router/executor own range semantics, codec stays value-lenient per the Phase-1 split)
- TDD RED for Task 2 confirmed via `Msg::Unknown` fallthrough (encode produced `p: {}` mismatch on fixture 01 and no-throw on fixture 03), exactly as the plan predicted
- `beacon_test.dart` audited and left untouched: its `proto: '1.0'` is a historical beacon wire pin (a 1.0 beacon must still parse — minor mismatch accepted per SPEC section 2)

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 2 - Missing Critical] clientProtoVersion lib literal updated to reference the protoVersion constant**
- **Found during:** Task 3 (stale-literal ripple audit)
- **Issue:** `app/remote_control/lib/net/handshake_fsm.dart` (not in the plan's files_modified list) hard-coded `clientProtoVersion = '1.0'` — the value actually sent in `hello`. Bumping only version.dart would leave the client advertising 1.0, violating the success criterion "Dart advertises protoVersion 1.1"
- **Fix:** `const String clientProtoVersion = protoVersion;` (remote_protocol was already imported)
- **Files modified:** app/remote_control/lib/net/handshake_fsm.dart
- **Verification:** handshake_fsm_test asserts `hello.protoVersion == protoVersion`; full app suite green (238 tests)
- **Committed in:** e2f17b8 (Task 3 commit)

---

**Total deviations:** 1 auto-fixed (1 missing critical)
**Impact on plan:** Required for the plan's own success criterion; no scope creep.

## Pre-existing Work Handling

Task 1's file contents (SPEC/schema edits + 3 fixtures) existed uncommitted from a prior interrupted session. They were verified line-by-line against the plan's action spec and acceptance criteria (fixture bodies match the RESEARCH shapes verbatim; schema volChanged requires both fields; SPEC has the section 2 note and section 7 row) and committed unchanged as the Task 1 atomic commit.

## Issues Encountered
None

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- Wave-1 wire contract complete: 05-03 (server-side volume executor + push) and 05-07 (slider UI) can build against `Msg::VolChanged` / `VolChangedMsg` with the fixtures as the drift guard
- Server-side proto version constant (SERVER_PROTO_VERSION, currently "1.0") intentionally NOT bumped here — the plan scoped the bump to the Dart side; the server bump belongs with the server push work (minor mismatch is accepted either way per SPEC section 2)

---
*Phase: 05-media-power-presenter-browser*
*Completed: 2026-07-11*

## Self-Check: PASSED

All created files exist on disk and all 5 task commits (e966447, 7d81011, 0157312, 841d278, e2f17b8) are present in git history.
