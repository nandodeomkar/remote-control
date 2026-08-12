---
phase: 07-server-shell-dashboard-polish
plan: 01
subsystem: auth
tags: [rust, server-core, auth, tokio-watch, pairing, revoke, sha256]

# Dependency graph
requires:
  - phase: 01-foundation
    provides: AuthManager (PinState, token issue/hash, challenge-response verify_mac)
provides:
  - "PairedDevice { hash, name, paired_at } record type (server-core auth)"
  - "PairingResult { token_hex, hash } return type"
  - "AuthManager::from_paired seed constructor (D-01 restore path)"
  - "AuthManager::complete_pairing_named (D-04 named multi-device pairing)"
  - "AuthManager::revoke (D-05 remove + presence report)"
  - "AuthManager::verify_auth_hash returning the matching hash (D-05 session correlation)"
  - "AuthManager::paired_hashes / paired_records accessors (07-05 / 07-07 / 07-08)"
  - "AuthManager::changes watch::Receiver<u64> change-signal (config re-serialize trigger)"
affects: [07-05 session revoke branch, 07-07 config.toml persistence, 07-08 settings paired list]

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "watch::Sender<u64> version-bump change-signal on every model mutation, subscribed by the composition root"
    - "Additive API growth: existing public signatures preserved, in-memory field reshaped underneath"

key-files:
  created: []
  modified:
    - server/server-core/src/auth/mod.rs

key-decisions:
  - "complete_pairing() preserved as a thin delegate to complete_pairing_named(\"phone\") — zero caller churn in session.rs"
  - "verify_auth() delegates to verify_auth_hash().is_some() so the two paths can never diverge"
  - "now_unix() saturates to 0 before the epoch — a backwards clock never panics the auth path"
  - "changes_tx uses send_modify (bumps even with no live receivers) so pre-subscription mutations still advance the counter"

patterns-established:
  - "Model change-signal: a tokio watch::Sender<u64> bumped on every paired-set mutation; the composition root subscribes via changes() to re-serialize config"
  - "Hash-only storage invariant enforced by a dedicated unit test (no raw-token field ever added)"

requirements-completed: [SRV-03]

# Metrics
duration: 4min
completed: 2026-07-12
---

# Phase 7 Plan 01: AuthManager Paired-Device Store Summary

**AuthManager grown from an in-memory `Vec<[u8;32]>` of hashes into a persistable, revocable, named `Vec<PairedDevice>` store with a `watch::Sender<u64>` change-signal — all existing public signatures preserved, hash-only invariant intact, six new unit tests green.**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-07-12T11:36:59Z
- **Completed:** 2026-07-12T11:40:26Z
- **Tasks:** 2
- **Files modified:** 1

## Accomplishments
- `PairedDevice { hash, name, paired_at }` and `PairingResult { token_hex, hash }` types added; `paired_hashes: Vec<[u8;32]>` field replaced with `paired: Vec<PairedDevice>`.
- Additive API for the Phase-7 persistence/revoke/multi-device seams: `from_paired` (D-01), `complete_pairing_named` (D-04), `revoke` (D-05), `verify_auth_hash` (D-05 session correlation), `paired_hashes`/`paired_records` accessors, and a `changes()` watch subscription.
- Existing `complete_pairing() -> String`, `is_paired() -> bool`, `verify_auth() -> bool` signatures preserved — the whole server workspace (including untouched `server-windows`) still builds green.
- Six new unit tests prove seed, named-record, matching-hash return, revoke presence/removal, dual change-signal advance, and the hash-only round-trip.

## Task Commits

Each task was committed atomically:

1. **Task 1: Grow AuthManager into a named, revocable, observable paired store** - `5d7abb9` (feat)
2. **Task 2: Unit tests — seed, revoke, named-record, matching-hash, change-signal, hash-only** - `9056eb9` (test)

_Note: Task 2 is `tdd="true"`; because Task 1 landed the implementation first (plan-structured this way) and global `tdd_mode` is false, the tests were added as a single verifying commit rather than a separate RED gate. All six assert green against Task 1's implementation._

## Files Created/Modified
- `server/server-core/src/auth/mod.rs` - Added `PairedDevice`/`PairingResult` types, reshaped `AuthManager` internal storage to named records, added the `from_paired`/`complete_pairing_named`/`revoke`/`verify_auth_hash`/`paired_hashes`/`paired_records`/`changes` API + a private `now_unix()`, added six unit tests.

## Decisions Made
- `complete_pairing()` kept as a thin delegate to `complete_pairing_named("phone")` so `session.rs` (untouched this plan) needs no changes.
- `verify_auth()` delegates to `verify_auth_hash().is_some()` — the boolean and hash-returning paths share one implementation and cannot drift.
- `now_unix()` saturates to 0 before the epoch; a backwards system clock is a plain 0 timestamp, never a panic.
- `changes_tx` seeded at 0 via `watch::Sender::new(0)` and advanced with `send_modify` so mutations bump the counter even before any receiver subscribes.

## Deviations from Plan

None - plan executed exactly as written.

## Issues Encountered
None. Both tasks built and tested green on the first pass; the full `server` workspace (`cargo build`) also compiles, confirming the preserved signatures did not break `server-windows`.

## User Setup Required
None - no external service configuration required.

## Next Phase Readiness
- `AuthManager` is now persistence-ready (`from_paired`), revocable (`revoke`), named (`complete_pairing_named`), and observable (`changes`) — the exact seams 07-05 (session revoke branch), 07-07 (config.toml file I/O), and 07-08 (settings paired list) consume.
- File I/O deliberately NOT added here: server-core keeps its zero-Windows-deps invariant; `config.toml` load/save lands in server-windows (07-07).
- No blockers.

## Self-Check: PASSED

- FOUND: `server/server-core/src/auth/mod.rs`
- FOUND commit: `5d7abb9` (Task 1)
- FOUND commit: `9056eb9` (Task 2)
- `cargo build -p server-core` green; `cargo test -p server-core auth` green (35 lib + fixtures + 13 integration all pass); full `cargo build` workspace green.

---
*Phase: 07-server-shell-dashboard-polish*
*Completed: 2026-07-12*
