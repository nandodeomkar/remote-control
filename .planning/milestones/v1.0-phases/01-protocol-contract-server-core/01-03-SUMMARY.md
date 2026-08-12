---
phase: 01-protocol-contract-server-core
plan: 03
subsystem: server-core
tags: [rust, serde, codec, golden-fixtures, wire-protocol, tdd-green]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    plan: 01
    provides: "protocol/SPEC.md wire contract + 19 golden fixtures"
  - phase: 01-protocol-contract-server-core
    plan: 02
    provides: "server-core API contracts (CodecError, MouseFrame, Msg + 27 payload structs, decode/encode signatures) and the RED fixture harness"
provides:
  - "GREEN codec::binary::{decode,encode}: strict 9-byte frame codec (length-first, finite-before-opcode, exact LE f32 round-trip)"
  - "GREEN codec::json::{decode_text,encode_msg}: two-step envelope parse covering all 27 SPEC types + Msg::Unknown (D-05/D-06/D-07)"
  - "Green fixture tests: codec_fixtures_mouse_binary, codec_fixtures_handshake, codec_fixtures_text (Rust half of phase success criterion 1)"
  - "33 cfg(test) unit tests: binary error branches + round-trip coverage of every non-fixture JSON family"
affects: [01-04, 01-05, 01-06, 01-08, phase-02]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Two-step envelope parse: private serde Envelope {t, seq?, p?} then serde_json::from_value into the typed family payload"
    - "MissingField extraction: serde_json 'missing field `x`' error string parsed to CodecError::MissingField(x); all other serde errors are BadJson"
    - "encode_msg always emits p (as {} for empty payloads) — canonical fixture expect envelopes carry p unconditionally"
    - "Binary decode order: length check -> parse f32s -> finite check -> opcode dispatch (non-finite rejection is opcode-independent)"

key-files:
  created: []
  modified:
    - server/server-core/src/codec/binary.rs
    - server/server-core/src/codec/json.rs

key-decisions:
  - "encode_msg always emits p, including p:{} for empty payloads — the fixture expect envelopes (03-auth-ok) carry p unconditionally, overriding the plan's omit-empty-p wording"
  - "Envelope-level serde failures (missing t, non-object) map to BadJson; MissingField is reserved for payload-level required fields per the fixture contract"
  - "Non-finite check runs before opcode dispatch: a NaN payload with an unknown opcode reports NonFinite (locked by unit test)"

patterns-established:
  - "payload<T: DeserializeOwned>(Value) helper is the single serde-error-mapping point for all 27 families"
  - "Round-trip test helper: decode_text(encode_msg(msg, seq)) asserts both msg and seq equality"

requirements-completed: [CONN-07]

# Metrics
duration: 6min
completed: 2026-07-07
---

# Phase 01 Plan 03: Rust Codec Implementation Summary

**Strict 9-byte binary mouse codec and two-step JSON envelope codec for all 27 SPEC message types, turning the three codec fixture tests green with 33 supporting unit tests**

## Performance

- **Duration:** ~6 min
- **Started:** 2026-07-07T15:01:44Z
- **Completed:** 2026-07-07T15:07:32Z
- **Tasks:** 2
- **Files modified:** 2

## Accomplishments

- `codec::binary::decode` enforces SPEC §9 strict rules in locked order — length exactly 9 first, LE f32 parse, `is_finite()` rejection BEFORE opcode dispatch, opcode match against `OP_MOVE`/`OP_SCROLL` — and `encode` reproduces the original 9 bytes exactly; all 6 mouse-binary fixtures pass (positive: exact f32 equality + byte-identical round-trip; negative: bad-opcode/short-frame/NaN rejected)
- `codec::json::decode_text` implements the two-step parse (RESEARCH Pattern 3): private `Envelope { t, seq?, p? }` with `p` defaulting to `{}` when absent, then `serde_json::from_value` into the typed payload per family; serde "missing field" errors surface as `CodecError::MissingField(name)` (09-auth-missing-mac passes its strengthened assertion) and unknown `t` decodes to `Msg::Unknown { t }` — never an error (D-07)
- `encode_msg` emits the canonical `{t, seq?, p}` envelope: only spec-defined fields survive (D-05 unknown-field dropping proven by 01-hello-ok), `seq` omitted when `None`, every `Option` extra omitted when `None`, empty `mods` omitted — `encode(decode(wire))` equals every handshake/text fixture expect envelope order-insensitively
- 33 unit tests green in the codec namespaces: 11 binary (all three error variants, both lengths, NaN/±Inf, finite-before-opcode ordering, negative-delta round trip) + 22 JSON (every non-fixture family round-trips, seq echo incl. u64::MAX, ping/pong ts echo, media setvol u8 bounds rejection at 300, apps.list request/reply duality, err/authFail optional extras, opaque protoVersion "2.0" decode)

## Task Commits

Each task was committed atomically:

1. **Task 1: Implement binary mouse-frame codec to green** - `79d1824` (feat)
2. **Task 2: Implement JSON envelope + all family payload codecs to green** - `31a8f9d` (feat)

## Files Created/Modified

- `server/server-core/src/codec/binary.rs` - `decode`/`encode` bodies + 11-test `cfg(test)` module with hand-built byte arrays (fixture-independent)
- `server/server-core/src/codec/json.rs` - private `Envelope` struct, `decode_text` 27-way dispatch + `Msg::Unknown` fallback, `payload()` serde-error mapper, `encode_msg` canonical serializer + 22-test round-trip module

## Decisions Made

- **`p` always emitted on encode:** the plan's action text said to omit `p` when the payload is an empty object, but the canonical fixture expect envelopes carry `p` unconditionally (`03-auth-ok.json` expects `{"t":"authOk","p":{}}`). The fixtures are the locked contract (SPEC status header: "No codec may adjust a fixture to match its own output"), so `encode_msg` always emits `p`.
- **BadJson for envelope-level failures:** a frame missing `t` or a non-object frame is `BadJson`, not `MissingField` — `MissingField` is reserved for payload-required fields, matching what the fixture harness asserts.
- **NonFinite outranks UnknownOpcode:** finite validation runs before opcode dispatch per RESEARCH Code Example 1; a unit test (`nonfinite_beats_unknown_opcode`) locks the ordering.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] encode_msg emits `p:{}` instead of omitting empty payloads**
- **Found during:** Task 2 (reading fixture expect envelopes before implementing)
- **Issue:** Plan action text said to omit `p` "when the payload is empty-object — matching the canonical expect envelopes in fixtures", but fixture 03-auth-ok's expect envelope contains `"p": {}`; omitting `p` would fail the order-insensitive Value comparison
- **Fix:** `encode_msg` always emits `p` (empty object for empty payloads); the plan's own justification ("matching the fixtures") resolves the contradiction in the fixtures' favor
- **Files modified:** server/server-core/src/codec/json.rs
- **Commit:** 31a8f9d

## TDD Gate Compliance

Both tasks carried `tdd="true"`. The RED gate for this plan is the fixture harness committed in Plan 01-02 as `test(01-02)` commit `e1ca7e2` (red by design, interface-first wave split); RED state was re-verified before each task in this session (`codec_fixtures_mouse_binary` FAILED, then `codec_fixtures_handshake`/`codec_fixtures_text` FAILED). GREEN commits: `79d1824`, `31a8f9d`. No refactor pass needed.

## Verification Results

- `cargo test -p server-core --test fixtures`: `codec_fixtures_mouse_binary`, `codec_fixtures_handshake`, `codec_fixtures_text` PASS; `auth_proof_fixture` still red as the plan predicts (auth bodies belong to Plan 01-04)
- `cargo test -p server-core --lib`: 33 passed, 0 failed
- `grep -c deny_unknown_fields src/codec/json.rs` → 0; `grep -c Unknown src/codec/json.rs` → 8 (≥ 2)
- No `unwrap`/`expect` on wire-derived data outside the infallible post-length-check slice conversions

## Known Stubs

None introduced by this plan. The pre-existing `todo!()` stubs in `auth/`, `dispatch/`, `executors/mock.rs`, and `transport/` remain, each naming its owning plan (01-04/01-05/01-06) — tracked in the Plan 01-02 SUMMARY.

## Issues Encountered

- `cargo test` rejects two positional test filters (`codec_fixtures_handshake codec_fixtures_text`); the plan's verify command needed the `-- filter1 filter2` libtest form. No code impact.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 01-04 (auth wave) can now target `auth_proof_fixture` — the only remaining red fixture test
- Plan 01-05 (dispatch) has fully typed, fixture-proven `Msg` values to route; Plan 01-06 (transport) inherits validated decode entry points for every wire byte
- Plan 01-08 (Dart codec) has a green Rust reference: any Dart/Rust fixture disagreement now indicts the Dart side

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*

## Self-Check: PASSED

Both modified files and the SUMMARY verified on disk; both task commits (79d1824, 31a8f9d) present in git log; must-have `contains` markers verified (from_le_bytes in binary.rs, Envelope + from_value in json.rs).
