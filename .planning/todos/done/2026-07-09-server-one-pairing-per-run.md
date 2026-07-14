---
created: 2026-07-09T00:00:00Z
title: Server supports only one pairing per process run — re-pair needs a restart until Phase-7 persistence
area: server
files:
  - server/server-windows/src/main.rs:77
  - server/server-core/src/auth/pin.rs:113
  - server/server-core/src/transport/session.rs:256
---

## Problem

Found during the Phase-03 on-device E2E (03-VERIFICATION.md). The server pairs at
most ONE device per process run:

- At startup `begin_pairing()` opens a PIN window (60s TTL) and a background loop
  refreshes it every `PIN_TTL_SECS` — but the loop `break`s the moment
  `is_paired()` is true ([main.rs:77-92](../../../server/server-windows/src/main.rs)).
- A correct PIN → `complete_pairing()` marks the server paired AND clears the
  active window (`verify` sets `self.active = None` on `Ok`,
  [pin.rs:126](../../../server/server-core/src/auth/pin.rs)).
- After that, any further `pin` submit hits `self.active == None` →
  `PinOutcome::NoPairing` → the client shows "pair again" and cannot progress.

So once a device has paired (or the client lost the pairOk result — e.g. a
secure-storage write failure on the phone), no new PIN pairing is possible without
restarting the server.

## Impact

During testing / multi-attempt pairing this manifests as an apparent "pair again"
loop that only a server restart clears. Expected for now (the plan's E2E step 5
notes token hashes are in-memory until Phase 7), but it will surprise users and
blocks pairing a second phone.

## Fix

Proper close is **Phase 7 config persistence**: persist the paired token hash(es)
and keep/reopen a PIN window on demand (e.g. a tray "Pair a new device" action that
calls `begin_pairing()` again) rather than tying the PIN lifecycle to a single
process run. Track against the Phase-7 server-shell work; revisit the refresh-loop
`break`-on-`is_paired` condition then.

## Closed — 07-07 (2026-07-14)

Closed by plan 07-07 (commit 354fa13): paired token hashes now persist in
`%APPDATA%/RemoteControl/config.toml` and reload via `AuthManager::from_paired`
at startup (D-01); smart startup opens a PIN window only when zero devices are
paired (D-03); `begin_on_demand_pairing()` reopens a fresh 60s window any time
— the tray/settings "Pair new device" action (07-08) drives it (D-02). The
WR-01 refresh loop is now bounded to the zero-paired startup window only.
