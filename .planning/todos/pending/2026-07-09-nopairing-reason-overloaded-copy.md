---
created: 2026-07-09T00:00:00Z
title: Split the overloaded `noPairing` authFail reason so pairing-window-absent gets its own copy
area: server-protocol
files:
  - server/server-core/src/auth/pin.rs:113
  - server/server-core/src/transport/session.rs:269
  - app/remote_control/lib/screens/connection_copy.dart:124
---

## Problem

Found during the Phase-03 on-device E2E (03-VERIFICATION.md). The server returns
`authFail{noPairing}` for TWO distinct situations:

1. **Reconnect path (auth):** a client presents a token the server does not
   recognize → `verify_auth` fails → `badMac` (and revoked/unknown tokens land
   here). This genuinely means "this PC no longer recognizes this phone."
2. **Pairing path (pin):** a client submits a PIN when there is NO active pairing
   window (`self.active == None`, e.g. the server already paired this run and the
   PIN-refresh loop stopped) → `PinOutcome::NoPairing` → `authFail{noPairing}`.

The Dart client maps `noPairing` (and `badMac`) to the single revoked copy
`This PC no longer recognizes this phone — pair again`
([connection_copy.dart:124](../../../app/remote_control/lib/screens/connection_copy.dart)).
In case 2 that copy is misleading — the real problem is "no PIN window right now,"
so the user should be told to get a fresh PIN from the PC (or that the server needs
a restart until Phase-7 persistence lands).

## Impact

Confusing UX: a re-pair attempt shows "no longer recognizes this phone" when the
truth is "the PC isn't offering a PIN right now." Low severity — pairing still
works after a server restart — but the copy actively points the user the wrong way.

## Fix sketch

- Add a distinct wire reason (e.g. `noPinWindow`) for the `PinOutcome::NoPairing`
  branch in [session.rs:269](../../../server/server-core/src/transport/session.rs),
  keeping `noPairing`/`badMac` for the auth/token path only.
- Add the reason to `pairingErrorCopy` with copy like
  "Your PC isn't showing a PIN right now — start/restart the server, then pair."
- Update the protocol fixtures + the client authFail decoder if the reason set is
  enumerated anywhere.

Consider bundling with the one-pairing-per-run todo — both are the same
pairing-lifecycle gap and both properly close with Phase-7 token persistence.
