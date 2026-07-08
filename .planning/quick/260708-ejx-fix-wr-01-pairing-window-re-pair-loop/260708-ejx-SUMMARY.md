---
quick_id: 260708-ejx
description: Fix WR-01 — pairing window one-shot expiry (re-pair loop)
date: 2026-07-08
status: complete
source: .planning/phases/02-end-to-end-cursor-spike/02-REVIEW.md (WR-01)
---

# Quick Task 260708-ejx: Fix WR-01 pairing window re-pair loop — SUMMARY

## Outcome

The one-shot 60-second pairing window is fixed. The `server-windows`
composition root now keeps a valid pairing PIN available for as long as the
server is unpaired, and stops the moment a phone pairs.

## Changes

**`server/server-core/src/auth/mod.rs`**
- Added `pub fn is_paired(&self) -> bool` — true once at least one token hash is
  stored (i.e. a device has completed pairing).
- Added unit test `auth::tests::is_paired_flips_after_complete_pairing`
  (false at construction, true after `complete_pairing()`).

**`server/server-windows/src/main.rs`**
- Imported `server_core::auth::pin::PIN_TTL_SECS`.
- After the initial `println!("Pairing PIN: …")`, clone the auth `Arc` (before
  it is moved into `ServerDeps`) and spawn a tokio task that loops: sleep
  `PIN_TTL_SECS`, lock auth, `break` if `is_paired()`, else `begin_pairing()`
  and print `"Pairing PIN (refreshed): {pin}"`. The `MutexGuard` is dropped
  before the print and is never held across the sleep await.

## Verification

- `cargo check --workspace` — clean
- `cargo test -p server-core --lib` — 87 passed (incl. new `is_paired` test)
- `cargo test -p server-core` (integration) — 8 passed
- `cargo test -p server-windows` — 3 passed

## Notes

- Refresh cadence equals the TTL (60s), matching the review's suggested fix.
  There is a sub-frame gap between old-PIN expiry and new-PIN issue; acceptable
  for the interactive spike. Phase 7's tray UI replaces the console PIN path
  entirely (see IN-04).
- Only WR-01 addressed. WR-02..WR-07 and IN-01..IN-04 from 02-REVIEW.md remain
  open.
