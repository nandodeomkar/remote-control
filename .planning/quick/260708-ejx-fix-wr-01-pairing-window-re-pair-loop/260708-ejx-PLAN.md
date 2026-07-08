---
quick_id: 260708-ejx
description: Fix WR-01 — pairing window one-shot expiry (re-pair loop)
created: 2026-07-08
mode: quick
source: .planning/phases/02-end-to-end-cursor-spike/02-REVIEW.md (WR-01)
---

# Quick Task 260708-ejx: Fix WR-01 pairing window re-pair loop

## Problem

`server-windows` calls `AuthManager::begin_pairing()` exactly once at startup
(`server/server-windows/src/main.rs:57-62`). `PIN_TTL_SECS` is 60
(`server-core/src/auth/pin.rs:13`). Sixty seconds after launch the pairing PIN
expires and no code path re-opens the window — pairing becomes permanently
impossible until process restart, with no console indication the printed PIN is
dead. This trips the Phase 02 manual pairing gate the first time phone setup
takes longer than a minute.

## Tasks

### Task 1 — Add `is_paired()` accessor to AuthManager

- **File:** `server/server-core/src/auth/mod.rs`
- **Action:** Add `pub fn is_paired(&self) -> bool { !self.paired_hashes.is_empty() }`
  so the composition root can stop refreshing once a device pairs. Add a unit
  test asserting false before `complete_pairing()` and true after.
- **Verify:** `cargo test -p server-core`
- **Done:** accessor compiles, test green.

### Task 2 — Spawn PIN refresh loop in composition root

- **File:** `server/server-windows/src/main.rs`
- **Action:** Import `server_core::auth::pin::PIN_TTL_SECS`. After the initial
  `println!("Pairing PIN: {pin}")` and BEFORE `auth` is moved into `ServerDeps`,
  clone the `Arc` and spawn a tokio task that loops: sleep `PIN_TTL_SECS`, lock
  auth, break if `is_paired()`, else `begin_pairing()` + print
  `"Pairing PIN (refreshed): {pin}"`. Guard must be dropped before the print and
  never held across the sleep await.
- **Verify:** `cargo check --workspace` && `cargo test -p server-windows`
- **Done:** builds clean, 3/3 server-windows tests green, pairing PIN refreshes
  every 60s while unpaired.

## Must-haves

- Truth: while the server is unpaired, a fresh valid PIN is printed at least
  once every `PIN_TTL_SECS`.
- Truth: once a device pairs, the refresh loop stops (no further PINs printed).
- Artifact: `AuthManager::is_paired()` public accessor.
- No regression: `cargo check --workspace`, `cargo test -p server-core`,
  `cargo test -p server-windows` all pass.
