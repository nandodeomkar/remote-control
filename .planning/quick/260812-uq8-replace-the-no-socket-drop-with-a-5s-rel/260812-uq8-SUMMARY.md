---
quick_id: 260812-uq8
phase: quick-260812-uq8
plan: 01
status: complete
subsystem: app-client-networking
tags: [send-policy, reliable-queue, ttl, disconnect, phantom-input, v1.0-deferred]

requires:
  - "SendPolicy bounded reliable queue (03-05)"
  - "ConnectionService _teardownChannel / dial path (03-06)"
  - "260812-uge (the decision this one revises)"
provides:
  - "SendPolicy.ttl — the reliable queue is bounded in TIME (5s), not by the socket"
  - "SendPolicy.nowMillis — the clock seam 260812-uge cited as the TTL option's cost"
  - "ConnectionService._queuedForKey — the queue's owner, so it cannot cross targets"
affects:
  - "a blip recovering within ~5s is lossless again (the phase-3 rule, restored)"
  - "SendPolicy.channelUp is GONE — 260812-uge's gate is superseded, not layered on"

commits:
  - 18346b3
---

# The reliable queue is bounded in time, not by the socket

Takes the option `260812-uge` rejected, one commit after it shipped.

## Why swap a decision made the same day

`-uge` closed the phase-04 UAT item correctly but paid for it with the whole
blip case: a reliable frame sent with no socket was dropped, so the phase-3
rule that a sub-second outage is lossless died, and the queue was left doing
nothing but the millisecond-long socket-open → auth-complete window.

The TTL keeps both halves. Backoff is 1/2/4/8s ±20%, so a blip that recovers
on redial #1 re-auths ~0.8–1.25s after the drop, and one that needs redial #2
at ~2.4–3.6s. **5s covers both and stops short of redial #3 (~5.6–8.4s).** The
number is not arbitrary — it is picked off that ladder, and a later change to
the backoff schedule should revisit it.

**Cost, stated before the choice and accepted:** a frame may now be replayed up
to 5s late. Within 5s the user is still holding the phone in the same context;
the minutes-later replay the UAT actually reported is still impossible.

## Things a later plan must not rediscover

- **Removing the teardown `clear()` is NOT the whole change, and the missing
  half is invisible in the tests that existed.** Once the queue outlives a
  teardown it needs an owner. `_teardownChannel` has five call sites; only
  `_onTransportLost` and `_onDeadConnection` are blips. `disconnectRequested()`
  emits `CloseEffect` **alone** — no `AuthStopEffect` rides with it, so nothing
  else would have cleared on an explicit disconnect — and
  `connectRequested(other)` reaches `_dial` → `_teardownChannel`. Without
  `_queuedForKey`, a frame typed at PC A while it was in backoff flushes onto
  **PC B** when the user switches devices inside the TTL: a worse misdelivery
  than the one being bounded. Pinned by `switching targets mid-backoff drops
  the queue`.

- **Expiry must run BEFORE the `maxQueue` comparison.** Check the bound first
  and a long outage fills the queue with 10 corpses, so the next *live* frame
  overflows against them — dropping the one frame still worth sending and
  firing `onOverflow` for a queue that is really empty. Pinned by `expiry runs
  BEFORE the bound, so corpses cannot overflow a live frame`.

- **`channelUp` had to GO, not coexist.** The frames a TTL exists to preserve
  are exactly the no-socket ones, so keeping the gate would make the TTL
  unreachable. `-uge`'s "do not simplify the two flags into one" note was about
  not *inferring* `channelUp` from `authed`; it does not outlive the rule it
  protected.

- **`nowMillis` is `required`, not defaulted.** A defaulted `DateTime.now()`
  would let a test depend on wall time by accident. This matches how
  `LatencyProbe`, `VolumeStore` and `PresenterTimer` all take the seam.

- **The TTL boundary is inclusive** (`age >= ttl` expires), pinned by its own
  test so "survives 5s" reads as strictly-less-than everywhere.

- **`_policy` is `late final`** — a plain field initializer cannot read
  `_nowMillis`, which the constructor's initializer list sets.

## Verification

- The reconnect scenario is now a **pair** over an identical setup — same 12
  sends, replayed or not depending only on how far the clock moved. The
  within-TTL half was **observed RED** against the pre-change tree
  (`Expected: ['b0'..'b9'] / Actual: []`), with the other two new tests passing
  there, which is correct: they assert behaviour `-uge` also had.
- 5 new tests. `flutter test` — **882 passed** (was 877).
- `flutter analyze` — clean.

## Not closed here

- **Not observed on hardware.** The clock is faked in every test; nothing here
  was exercised against a real router blip. The 5s figure is derived from the
  backoff ladder, not measured end to end.
- `protocol/SPEC.md` still says nothing about the client's queue-vs-drop
  policy, so as with `-uge` no spec amendment was needed. The behaviour is
  client-side only; the server sees fewer frames, never different ones.
