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

## Closed — quick 260731-d45 (2026-07-31)

**The "Fix sketch" above was STALE and was deliberately NOT followed.** No
`noPinWindow` wire reason was added, no server change, no fixture change, no
`app/packages/remote_protocol/` change. The fix that shipped is client-only.

**Why the sketch was unnecessary.** The server already distinguishes the two
situations on the wire: `server/server-core/src/transport/session.rs:626` emits
`authFail{noPairing}` from the `PinOutcome::NoPairing` branch ONLY (a PIN
submitted with no active pairing window), and `session.rs:645` emits
`authFail{badMac}` from the `Msg::Auth` token-verification path ONLY. The
collapse was purely the client's doing — `pairingErrorCopy` had `case
'noPairing':` falling through into `case 'badMac':` onto one shared
`return kRevokedExplanation;`. Splitting that one switch arm is the whole fix.

**What shipped.** `connection_copy.dart` gained `kNoPinWindowCopy` =
`Your PC isn't showing a PIN — start pairing on the PC`, returned by the
`noPairing` arm. `badMac` keeps `kRevokedExplanation`
(`This PC no longer recognizes this phone — pair again`), which still has
exactly one definition, in `reconnect_fsm.dart`, imported here and never
re-declared. Two unit tests replace the old collapsed one, and the
`raw reason enums never reach a rendered widget` widget test now expects the
per-reason string.

**Deliberate non-change — still open.** `reconnect_fsm.authRejected`
(`reconnect_fsm.dart:333`) continues to treat `noPairing` as revoked: it emits
`ClearTokenEffect` and stops auth retries. That is arguably wrong for a
PIN-window problem — the stored token is not necessarily bad — but changing it
is a D-05 token-semantics behaviour change with its own test surface
(`reconnect_fsm_test.dart:217-268`) and was out of this task's scope. It does
NOT affect what the user reads: in `pairing_dialog.dart:_errorCopy` a live
`FailedEffect` outranks `widget.explanation`, so a `noPairing` rejection
renders the new copy regardless of what the FSM did to the token.

**Frozen record left unedited.** `03-UI-SPEC.md:160` (row "Error —
revoked/stale token (`noPairing`/`badMac`)") now describes `badMac` only. It is
a frozen phase record and was intentionally not edited; the delta is recorded
here instead.
