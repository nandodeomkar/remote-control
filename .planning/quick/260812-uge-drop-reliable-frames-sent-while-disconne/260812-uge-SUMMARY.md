---
quick_id: 260812-uge
phase: quick-260812-uge
plan: 01
status: complete
subsystem: app-client-networking
tags: [send-policy, reliable-queue, disconnect, phantom-input, v1.0-deferred]

requires:
  - "SendPolicy bounded reliable queue (03-05)"
  - "ConnectionService _teardownChannel / dial path (03-06)"
provides:
  - "SendPolicy.channelUp — the socket-present gate that separates the handshake window from an outage"
affects:
  - "reliable frames sent while disconnected are dropped, not deferred"
  - "closes the last undecided item from the 2026-07-10 phase-04 UAT"

commits:
  - 991860f
---

# Reliable frames sent while disconnected are dropped

Closes the phase-04 UAT's third gap, the one item on `.planning/STATE.md`
`## Deferred Items` that was an open product decision rather than doc debt.

## What was wrong

`enqueueOrSendReliable` queued whenever `!authed`, and nothing bounded how long
a frame waited. `_teardownChannel` kept the queue deliberately — its comment
said "the reliable queue is KEPT so frames sent during a blip flush after the
redial auths" — and only the auth-stop path cleared it.

Anything sent during an outage was therefore delivered late, into whatever
window happened to be focused when the phone next authed. **It was never only
about typed text**, which is all the UAT reported: `power` + `confirm` ride the
same queue and flush as a valid back-to-back pair, and `tabs.close` /
`bm.remove` flush against ids that may have moved on.

## The decision, recorded

**Clear on disconnect — nothing sent during a gap is ever replayed.** Owner's
choice, 2026-08-12, from three options.

Rejected: (a) ageing the queue out with a TTL, which keeps blip-tolerance and
covers every class but needs a clock seam; (b) dropping by message class, which
is surgical but is a hand-maintained list every future family must remember to
join — the same shape as the ungated keymap lockstep.

**The cost was stated before the choice and is accepted:** a sub-second blip is
no longer lossless. That reverses the phase-3 rule the `:1154` comment defended.

## Things a later plan must not rediscover

- **Clearing the queue at teardown does NOT fix this, and the old test proves
  why.** The frames that matter are enqueued AFTER the teardown, while the FSM
  sits in backoff with no channel at all — so a clear at teardown empties an
  already-empty queue and changes nothing observable. The gate has to be at
  *enqueue* time.

- **`channelUp` cannot be inferred from `authed`.** The harmful window (backoff,
  between a teardown and the next dial) and the benign one (socket up, auth
  pending) both have `authed == false`. Only the presence of a socket separates
  them. Do not "simplify" the two flags into one.

- **`onOverflow` is deliberately NOT fired for a no-socket drop.** It is
  documented as the queue-is-full signal and has no caller in `lib/` yet;
  overloading it now would make its one meaning ambiguous for whoever wires it
  to a UI hint later. Pinned by a test.

- **The queue is not dead code and a test says so.** Socket-open →
  auth-complete still defers and flushes FIFO. A future change that drops that
  window too should fail `the handshake window still queues`, deliberately.

- **`connection_service_test.dart`'s reconnect test was REVERSED, not
  deleted** — same setup, opposite assertion — so the diff reads as the
  behaviour change it is rather than as lost coverage.

## Verification

- 5 new tests. The reversed reconnect test was **observed RED** against the
  pre-fix tree (`Expected: empty / Actual: WhereTypeIterable<ClickMsg>:[...]`).
- `flutter test` — **877 passed** (was 872).
- `flutter analyze` — clean.

## Not closed here

`protocol/SPEC.md` does not document the client's queue-vs-drop policy — it
describes `click` as riding the reliable path and says nothing about buffering
— so no spec amendment was needed and none was made. The behaviour is
client-side only; the server sees fewer frames, never different ones.
