---
phase: 01-protocol-contract-server-core
plan: 04
subsystem: server-core
tags: [rust, auth, hmac, sha256, pin-lockout, constant-time, tdd-green]

# Dependency graph
requires:
  - phase: 01-protocol-contract-server-core
    plan: 01
    provides: "protocol/SPEC.md auth construction (§3, §4) + 05-auth-proof.json cross-language anchor"
  - phase: 01-protocol-contract-server-core
    plan: 02
    provides: "auth module API contracts (AuthManager, PinOutcome, IssuedToken signatures) and the RED auth_proof_fixture harness"
provides:
  - "GREEN auth::pin: 60s TTL / 5 attempts / 300s per-IP lockout / global cap 20, paused-time tested, ConstantTimeEq compare"
  - "GREEN auth::token: CSPRNG 32-byte issue_token + Sha256 hash_token — hash is the only persisted form"
  - "GREEN auth::challenge: auth_proof (key = SHA-256(raw token)) + verify_mac (Mac::verify_slice, defensive hex decode)"
  - "GREEN auth_proof_fixture: Rust HMAC output byte-identical to the .NET-computed macHex (phase success criterion 3)"
affects: [01-05, 01-06, 01-08, phase-04]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Paused-time auth units: #[tokio::test(start_paused = true)] + tokio::time::advance — 21 tests, 0.00s wall clock"
    - "rand 0.10 naming: root re-exports Rng (renamed from rand_core 0.9's RngCore) and RngExt; fill_bytes comes from rand::Rng"
    - "hmac 0.13 (digest 0.11): new_from_slice requires explicit hmac::KeyInit import; Mac trait no longer supplies it"
    - "Lockout state on AuthManager (HashMap<IpAddr, Instant> + global counter), never on session types — survives reconnect"

key-files:
  created: []
  modified:
    - server/server-core/src/auth/pin.rs
    - server/server-core/src/auth/token.rs
    - server/server-core/src/auth/challenge.rs
    - server/server-core/src/auth/mod.rs

key-decisions:
  - "HMAC construction implemented exactly as locked: key = SHA-256(raw token), message = nonce bytes; verify_mac keys from the stored hash directly and never needs the raw token"
  - "Malformed mac hex is a plain false from verify_mac (defensive decode), never a panic — attacker-controlled input"
  - "verify_auth iterates the paired-hash table with Mac::verify_slice per entry; no early-exit shortcuts beyond per-entry constant-time verify"

patterns-established:
  - "Fixture-loading unit tests via env!(\"CARGO_MANIFEST_DIR\") relative path to protocol/fixtures/ (no per-crate fixture copies, D-09)"

requirements-completed: [CONN-07]

# Metrics
duration: 13min
completed: 2026-07-07
---

# Phase 01 Plan 04: Auth Module Implementation Summary

**PIN lifecycle with per-IP and global lockout, SHA-256-only token storage, and the locked HMAC challenge-response construction — auth_proof_fixture green against the .NET-computed cross-language anchor**

## Performance

- **Duration:** ~13 min (split across two sessions; session boundary fell between Task 2 test and feat commits)
- **Started:** 2026-07-07T15:15:18Z
- **Completed:** 2026-07-07T15:28:24Z
- **Tasks:** 2
- **Files modified:** 4

## Accomplishments

- `auth::pin` enforces SPEC §4 exactly under paused tokio time: PIN is 6 zero-padded CSPRNG digits, expires at 60s, allows 5 attempts, locks the source IP for 300s on the 5th failure (correct PIN during lockout still rejected), leaves other IPs unaffected, and a global cap of 20 cumulative failures locks all sources; PIN comparison via `subtle::ConstantTimeEq`, never `==`
- `auth::token::issue_token` fills 32 bytes from ThreadRng (CSPRNG) and returns 64-lowercase-hex raw plus `Sha256::digest` hash; `AuthManager::complete_pairing` pushes only the hash into `paired_hashes` and returns the raw hex transiently — no raw-token field exists on `AuthManager` (grep-verified)
- `auth::challenge::auth_proof` reproduces `05-auth-proof.json`'s `macHex` byte-identically (key = SHA-256(raw token), message = nonce — the LOCKED construction); `verify_mac` keys the HMAC from the stored hash directly, decodes attacker-supplied hex defensively (bad hex → `false`, no panic), and compares only via `Mac::verify_slice` (constant-time)
- 21 auth unit tests green in 0.00s (paused time — no real waits); `auth_proof_fixture` green, making all 4 fixture-harness tests pass

## Task Commits

Each task was committed atomically (TDD red/green pairs):

1. **Task 1: PIN lifecycle with lockout** - `cd2e5f3` (test, red) → `b89c53a` (feat, green)
2. **Task 2: Token hashing + challenge-response** - `cb444fc` (test, red) → `ac8d3c4` (feat, green)

## Files Created/Modified

- `server/server-core/src/auth/pin.rs` - PIN state machine: window struct, per-IP lockout table plumbing, global failure counter, CSPRNG generation, ConstantTimeEq compare, paused-time test module
- `server/server-core/src/auth/token.rs` - `issue_token` / `hash_token` bodies + unit tests
- `server/server-core/src/auth/challenge.rs` - `new_nonce` / `auth_proof` / `verify_mac` bodies + fixture-anchored test module
- `server/server-core/src/auth/mod.rs` - `AuthManager::complete_pairing` / `issue_challenge` / `verify_auth` wiring over the hash table and active nonce

## Decisions Made

- **verify_mac never panics on wire input:** received mac hex is decoded with a `let Ok(..) else return false` guard; `expect` appears only on `new_from_slice`, which is infallible for HMAC (accepts any key length)
- **Session-resume import fixes folded into the feat commit:** rand 0.10 renamed `RngCore` → `Rng` at the root (fill_bytes now comes from `rand::Rng`), and hmac 0.13 requires an explicit `KeyInit` import for `new_from_slice` — both are API-naming drift the plan's RESEARCH snippets (written against older majors) didn't capture

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] rand 0.10 / hmac 0.13 import names differ from RESEARCH Code Example 3**
- **Found during:** Task 2 (resumed session; working tree failed to compile with E0432/E0599)
- **Issue:** `use rand::RngCore` doesn't resolve — rand 0.10 re-exports the trait as `Rng` (rand_core 0.10 renamed it); `Hmac::new_from_slice` needs `hmac::KeyInit` in scope — the `Mac` trait no longer provides it in hmac 0.13/digest 0.11
- **Fix:** `use rand::Rng;` in token.rs and challenge.rs; `use hmac::{Hmac, KeyInit, Mac};` in challenge.rs
- **Files modified:** server/server-core/src/auth/token.rs, server/server-core/src/auth/challenge.rs
- **Commit:** ac8d3c4

## TDD Gate Compliance

Both tasks carried `tdd="true"`. Task 1: red commit `cd2e5f3` (paused-time PIN tests failing on `todo!()`), green commit `b89c53a`. Task 2: red commit `cb444fc` (token/challenge/AuthManager tests failing on `todo!()`), green commit `ac8d3c4`. No refactor pass needed.

## Verification Results

- `cargo test -p server-core --lib auth::` → 21 passed, 0 failed, finished in 0.00s (< 5s criterion: paused time proven)
- `cargo test -p server-core --test fixtures` → 4 passed including `auth_proof_fixture` (Plan 03 already merged, so all four green as the plan predicted)
- `cargo test -p server-core --lib` → 54 passed (33 codec + 21 auth), 0 failed
- challenge.rs contains `verify_slice`; no `==` comparison of mac byte slices
- `grep "raw" auth/mod.rs` → doc comments and transient locals only; no raw-token field on `AuthManager`
- pin.rs: `ConstantTimeEq` present, `rand::rng()` + `random_range` + `{n:06}` zero-padding, lockout `HashMap<IpAddr, Instant>` lives in `PinState` owned by `AuthManager`
- Expected remaining red: `walking_skeleton_pair_auth_input` (integration) panics on `executors/mock.rs` `todo!` — owned by Plan 01-05 (dispatch wave), unchanged by this plan

## Known Stubs

None introduced by this plan. Remaining `todo!()` stubs in `dispatch/`, `executors/mock.rs`, and `transport/` name their owning plans (01-05/01-06) — tracked in the Plan 01-02 SUMMARY.

## Issues Encountered

- Session ended mid-Task-2 with the implementation written but not compiling (import-name drift above); resume session fixed imports, verified green, and committed. No logic changes were needed — the committed construction matched the fixture on first green run.

## User Setup Required

None - no external service configuration required.

## Next Phase Readiness

- Plan 01-05 (dispatch wave) can wire `AuthManager` into session state: pair/auth message routing now has real outcomes to route on
- Plan 01-08 (Dart codec/auth) has a byte-exact target: same fixture, same mac, both sides now proven against the independent .NET computation
- Phase 4 (pairing UX) inherits enforced PIN semantics: 60s/5/300s/global-20 all locked by paused-time tests

---
*Phase: 01-protocol-contract-server-core*
*Completed: 2026-07-07*

## Self-Check: PASSED

All four modified files and the SUMMARY verified on disk; all four task commits (cd2e5f3, b89c53a, cb444fc, ac8d3c4) present in git log; must-have `contains` markers verified (verify_slice in challenge.rs, PIN_TTL_SECS in pin.rs, Sha256 in token.rs).
