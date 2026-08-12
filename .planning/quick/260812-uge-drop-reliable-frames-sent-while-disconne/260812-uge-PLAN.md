---
quick_id: 260812-uge
phase: quick-260812-uge
plan: 01
type: execute
wave: 1
depends_on: []
files_modified:
  - app/remote_control/lib/net/send_policy.dart
  - app/remote_control/lib/net/connection_service.dart
  - app/remote_control/test/send_policy_test.dart
  - app/remote_control/test/connection_service_test.dart
---

# Drop reliable frames sent while disconnected

Closes the last undecided item from the 2026-07-10 phase-04 UAT, carried into
`.planning/STATE.md` `## Deferred Items` at the v1.0 close.

## The defect

`SendPolicy.enqueueOrSendReliable` queues whenever `!authed`, with nothing
bounding how long a frame waits. `_teardownChannel`
(`connection_service.dart:1154`) keeps the queue on purpose — "so frames sent
during a blip flush after the redial auths" — and only the auth-stop path
(`:801`) clears it.

So anything sent during a disconnect is delivered late, into whatever window
happens to be focused when the phone re-auths. The UAT reported this for typed
text. It is broader than that: `power` + `confirm` ride the same queue as a
back-to-back pair, and so do `tabs.close` and `bm.remove` against ids that may
no longer mean the same thing.

## The decision, recorded

**Clear the queue on disconnect — nothing sent during a gap is ever replayed.**
Chosen by the owner 2026-08-12 from three options.

Rejected: ageing the queue out with a TTL (keeps blip-tolerance, needs a clock
seam) and dropping by message class (surgical, but a hand-maintained list every
future family must remember to join).

**Stated cost, accepted:** this retires the blip-tolerance SPEC §12's reliable
class and the `:1154` comment describe. The queue's remaining job is only the
socket-open → auth-complete handshake window.

## Task 1 — the policy learns whether a socket exists

`lib/net/send_policy.dart`

The naive fix — clearing in `_teardownChannel` — does NOT work, and the existing
test at `connection_service_test.dart:473` proves why: the frames that matter
are enqueued AFTER teardown, while the FSM sits in backoff with no channel at
all. Clearing at teardown empties an already-empty queue and changes nothing.

So the queue must refuse to accept them in the first place. Add a `channelUp`
flag beside `authed`:

```
if (authed) { send(frame); return; }
if (!channelUp) return;   // disconnected: dropped, never queued
... existing bounded-queue path ...
```

- `authed && channelUp` — send now.
- `channelUp && !authed` — the handshake window (milliseconds). Queue, as today.
  This is the queue's whole remaining purpose and it stays intact.
- `!channelUp` — disconnected or backing off. **Drop.**

`onOverflow` is NOT fired for a disconnect drop. It is documented as the
full-queue signal, has no caller in `lib/` today, and overloading it would make
its one meaning ambiguous the moment someone wires it up.

## Task 2 — the service sets the flag

`lib/net/connection_service.dart`

- `channelUp = true` beside `_channel = channel` (`:862`).
- `_teardownChannel` (`:1140`) sets `channelUp = false` and clears the queue —
  belt and braces, so a partial handshake's frames never outlive their socket.
- Rewrite the `:1153-1154` comment, which currently documents the opposite rule.

## Task 3 — tests

1. `send_policy_test.dart` — unit: a reliable frame sent with `channelUp` false
   is dropped, not queued, and does not appear on a later flush; the handshake
   window (`channelUp` true, `authed` false) still queues and flushes FIFO;
   `onOverflow` does NOT fire for a disconnect drop.
2. `connection_service_test.dart:473` — **this test asserts the behaviour being
   removed** and must be rewritten, not deleted: same setup (drop → backoff →
   12 reliable sends → redial → re-auth), now asserting that ZERO of them
   arrive. Keep a companion asserting the handshake window still flushes, so
   the rewrite cannot silently retire the queue entirely.

## Gates

- `flutter test` — 872 passing today; the rewritten test observed failing
  against the old assertion first.
- `flutter analyze` clean.
