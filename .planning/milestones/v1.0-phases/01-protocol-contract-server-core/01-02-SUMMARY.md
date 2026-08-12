---
phase: 01-protocol-contract-server-core
plan: 02
subsystem: server-core
tags: [rust, cargo-workspace, tokio, tokio-tungstenite, api-contracts, walking-skeleton, golden-fixtures, tdd-red]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    plan: 01
    provides: "protocol/SPEC.md wire contract + 19 golden fixtures + fixtures README loader contract"
provides:
  - "Compiling cargo workspace server/ (resolver 3, edition 2024, rust-version 1.85) with server-core as sole member"
  - "COMPLETE server-core public API surface with todo!() bodies: CodecError, codec::{binary,json}, auth::{AuthManager,pin,token,challenge}, dispatch::{AuthState,HeldInput,router}, executors (5 traits + Button/KeyCode/Modifier/WindowInfo + Executors bundle + recording mocks), transport::{ServerDeps,run}"
  - "RED walking-skeleton E2E test (tests/integration.rs::walking_skeleton_pair_auth_input): connect -> hello -> challenge -> pin -> pairOk -> click -> mock recording"
  - "RED golden-fixture harness (tests/fixtures.rs): codec_fixtures_mouse_binary, codec_fixtures_handshake, codec_fixtures_text, auth_proof_fixture"
affects: [01-03, 01-04, 01-05, 01-06, server-windows, phase-02]

# Tech tracking
tech-stack:
  added:
    - "tokio 1.52 (rt-multi-thread, net, sync, time, macros)"
    - "tokio-tungstenite 0.29"
    - "futures-util 0.3"
    - "serde 1 + serde_json 1"
    - "sha2 0.11 + hmac 0.13 (digest 0.11 majors)"
    - "rand 0.10"
    - "subtle 2.6"
    - "thiserror 2"
    - "hex 0.4"
  patterns:
    - "Interface-first waves: full type/trait/signature contracts with todo!() bodies so Wave 3 plans (03/04/05) implement in parallel with zero file overlap"
    - "Two-step envelope parse contract: Msg enum is NOT serde-tagged; decode_text/encode_msg own the {t, seq?, p} envelope (D-05/D-06/D-07)"
    - "Enum-valued wire fields decode as plain String: codec is value-lenient; semantic validation is the router's job"
    - "Dispatcher-owned held-input tracking (CONN-07): HeldInput lives in dispatch, executor-impl-agnostic"
    - "Sync executor traits (&self, Send + Sync, Arc<dyn Trait>): dispatch stays inline in the read task"
    - "Fixture root via concat!(env!(CARGO_MANIFEST_DIR), \"/../../protocol/fixtures\") — cwd-immune, no copies (D-09)"

key-files:
  created:
    - server/Cargo.toml
    - server/Cargo.lock
    - server/server-core/Cargo.toml
    - server/server-core/src/lib.rs
    - server/server-core/src/error.rs
    - server/server-core/src/codec/mod.rs
    - server/server-core/src/codec/binary.rs
    - server/server-core/src/codec/json.rs
    - server/server-core/src/auth/mod.rs
    - server/server-core/src/auth/pin.rs
    - server/server-core/src/auth/token.rs
    - server/server-core/src/auth/challenge.rs
    - server/server-core/src/dispatch/mod.rs
    - server/server-core/src/dispatch/held.rs
    - server/server-core/src/dispatch/router.rs
    - server/server-core/src/executors/mod.rs
    - server/server-core/src/executors/mock.rs
    - server/server-core/src/transport/mod.rs
    - server/server-core/src/transport/listener.rs
    - server/server-core/src/transport/session.rs
    - server/server-core/tests/integration.rs
    - server/server-core/tests/fixtures.rs
  modified:
    - .gitignore

key-decisions:
  - "Enum-valued wire fields (button/action/reason) are plain Strings in payload structs: keeps the codec value-lenient per SPEC (version-2 hello must DECODE fine), semantic validation lives in the router"
  - "All Option payload fields carry skip_serializing_if so encode_msg emits the canonical form (authFail badMac serializes reason only, matching fixture expect)"
  - "WindowInfo defined once in executors/mod.rs with serde derives and reused by codec::json apps payloads — one type, no duplication"
  - "09-auth-missing-mac assertion strengthened to matches!(err, CodecError::MissingField(_)) per plan parenthetical (not just is_err)"
  - "listener.rs/session.rs are doc-comment-only internal modules: transport's public API is exactly ServerDeps + run; internals belong to Plan 06"

patterns-established:
  - "Every todo!() carries the owning plan: todo!(\"implemented in plan 01-0N (...)\") — Wave 3 executors grep their own plan number"
  - "Integration recv discipline: every ws.next() and the connect wrapped in tokio::time::timeout(2s)"
  - "tungstenite 0.29 API: Message::Text(t) -> t.as_str(), Message::text(String) constructor (Pitfall 2)"

requirements-completed: [CONN-07]

# Metrics
duration: 10min
completed: 2026-07-07
---

# Phase 01 Plan 02: Rust Workspace Scaffold & Red Test Suites Summary

**Compiling server-core workspace with the ENTIRE public API defined as todo!() contracts, plus the red walking-skeleton E2E test and the red 4-test golden-fixture harness that define "green" for Waves 3-4**

## Performance

- **Duration:** ~10 min
- **Started:** 2026-07-07T14:44:30Z
- **Completed:** 2026-07-07T14:54:00Z
- **Tasks:** 2
- **Files modified:** 23 created, 1 modified

## Accomplishments

- `cargo build -p server-core` compiles cleanly (warnings only — unused params in todo!() skeletons) with the FULL API surface: 6-variant `CodecError`, binary codec consts/enum/decode/encode, 28-variant `Msg` enum with per-family payload structs mirroring SPEC §7 field-for-field, `AuthManager` + PIN outcome/constants + token/challenge helpers, `AuthState`/`HeldInput`/`SessionCtx`/`route`/`route_binary`/`MAX_BS`, five sync executor traits + `Executors` bundle + unconditionally compiled recording mocks, and `ServerDeps` + `run()` re-exported at crate root
- Walking-skeleton E2E test compiles and fails RED (panic at the first todo!(), not a compile error): real TCP on 127.0.0.1:0, real tokio-tungstenite client, every recv timeout-wrapped, asserting hello→challenge (64-lowercase-hex nonce), pin→pairOk (64-hex token), click→`Call::Click(Button::Left)` in the mock log
- Golden-fixture harness compiles and fails RED on all three families: runtime directory enumeration (19 fixtures picked up automatically), strict binary negatives + exact-f32 round-trip, order-insensitive canonical `encode(decode(wire))` Value comparison proving D-05 unknown-field dropping, versionMismatch decode-succeeds carve-out (D-06 rejection is the server's job), MissingField-specific assertion for 09-auth-missing-mac, and the .NET-computed auth-proof byte-identity anchor
- Zero Windows dependencies verified: no windows/winapi crates, no cfg(windows), no deny_unknown_fields anywhere

## Task Commits

Each task was committed atomically:

1. **Task 1: Workspace scaffold, full API contracts, failing walking-skeleton E2E test** - `4a6c600` (feat)
2. **Task 2: Golden-fixture test harness (red)** - `e1ca7e2` (test)

## Files Created/Modified

- `server/Cargo.toml` - Workspace root: resolver 3, edition 2024, rust-version 1.85, members = [server-core]
- `server/server-core/Cargo.toml` - All 11 crates per RESEARCH Standard Stack (tokio 1.52 … hex 0.4); no server-windows stub (deferred to Phase 2)
- `src/error.rs` - `CodecError`: BadLength/UnknownOpcode/NonFinite/BadJson/MissingField/BadHex (thiserror 2)
- `src/codec/binary.rs` - OP_MOVE/OP_SCROLL, `MouseFrame`, `decode`/`encode` signatures (SPEC §9 strict rules documented)
- `src/codec/json.rs` - `Decoded`, 27 payload structs + `Msg` with `Unknown{t}`, `decode_text`/`encode_msg`; optional fields Option<T> + serde default + skip_serializing_if
- `src/auth/` - `AuthManager` (new/begin_pairing/verify_pin/complete_pairing/issue_challenge/verify_auth), `PinOutcome` + PIN_TTL_SECS/PIN_MAX_ATTEMPTS/LOCKOUT_SECS/GLOBAL_FAIL_CAP, `IssuedToken`/issue_token/hash_token, new_nonce/auth_proof/verify_mac
- `src/dispatch/` - `AuthState`, `HeldInput` (note_*/release_all/is_empty), `SessionCtx`/route/route_binary/MAX_BS=10000
- `src/executors/` - Button/KeyCode/Modifier/WindowInfo + MouseKeys/Media/Power/Apps/Clipboard traits + `Executors`; mock.rs: 17-variant `Call`, `CallLog` (calls/wait_for), `MockExecutors::recording()`
- `src/transport/` - `ServerDeps{executors, auth: Arc<Mutex<AuthManager>>, pause: watch::Receiver<bool>}` + `run()`; listener.rs/session.rs internal placeholders for Plan 06
- `tests/integration.rs` - `spawn_test_server` helper + `walking_skeleton_pair_auth_input` (RED)
- `tests/fixtures.rs` - 4 fixture tests loading via CARGO_MANIFEST_DIR (RED)
- `.gitignore` - added /server/target/, **/.dart_tool/, app/packages/remote_protocol/build/

## Decisions Made

- **String-typed enum wire fields:** `button`/`action`/`reason` payload fields are `String`, not Rust enums — the codec must decode any value (e.g. protoVersion "2.0" hello decodes fine per D-06); the router owns semantic validation. Locking this now prevents Wave 3 codec/dispatch plans from renegotiating.
- **Canonical-form serde attributes locked in Wave 2:** every optional payload field carries `skip_serializing_if` so the encode side of the fixture round-trip can pass without struct changes in Plan 03.
- **WindowInfo shared between executors and codec:** single serde-derived struct in executors/mod.rs, imported by codec::json — avoids a parallel payload type.
- **Strengthened 09-auth-missing-mac assertion** to require `CodecError::MissingField(_)` specifically (plan said "must fail on MissingField").
- **todo!() messages name the implementing plan** (01-03/01-04/01-05/01-06) so red-test panics tell the next executor exactly whose body is missing.

## Deviations from Plan

None - plan executed exactly as written. (One doc comment in codec/json.rs was reworded to avoid the literal string `deny_unknown_fields` so the acceptance-criterion grep returns zero matches — cosmetic, no API impact.)

## Known Stubs

All function bodies in `server/server-core/src/` are intentional `todo!()` stubs — that IS this plan's deliverable (interface-first contracts, MVP red tests). Each stub names its resolving plan:

- codec bodies → Plan 01-03 (codec wave)
- auth bodies → Plan 01-04 (auth wave)
- dispatch + mock bodies → Plan 01-05 (dispatch wave)
- transport `run()` → Plan 01-06 (transport wave, turns the walking skeleton green)

No stubs ship past Phase 1: the phase gate is both test files green.

## Issues Encountered

None. Build and both red test runs behaved exactly as the plan predicted (panics at todo!(), zero compile errors).

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Wave 3 plans (01-03 codecs, 01-04 auth, 01-05 dispatch) can implement purely inside their own module files: every signature, type, field, and constant they need is final and compiling
- Wave 4 (01-06) has a pre-agreed `run(listener, deps)` signature and a precise green-line: `walking_skeleton_pair_auth_input` passing
- The 4 fixture-test names are stable cargo test filters for later plans' verification steps
- Dart-side plans still gated on the Flutter SDK checkpoint (Plan 01-07), unchanged

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*

## Self-Check: PASSED

All 23 created files verified on disk (spot-checked 7 key artifacts); both task commits (4a6c600, e1ca7e2) present in git log.
