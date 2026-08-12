/// Per-message-class send policy (design spec §8, 03-RESEARCH Pattern 6).
///
/// Message classes and who owns them:
/// - **volatile** — binary move/scroll frames: dropped unless authed, NEVER
///   queued (queued deltas teleport the cursor on reconnect). The check is
///   a plain boolean read — allocation-free, it sits on the pointer-move
///   hot path.
/// - **reliable** — `click`, `drag`, `key`, `text`, `media`, `power`,
///   `confirm`, `clip.*`, `browser`, `present`: queued (bounded, FIFO) while
///   not authed, flushed on auth, dropped with [onOverflow] past [maxQueue].
///   Phase 3 ships this seam; later phases consume it.
///
///   **Reliable means durable across a blip, not across an outage
///   (260812-uq8).** A queued frame carries the time it was queued and is
///   aged out at [ttl]; only what is younger than that survives to the flush.
///   The queue originally had no bound in time at all, so anything sent
///   during an outage was delivered late into whatever window happened to be
///   focused when the phone re-authed — reported for typed text at the 04
///   UAT, but `power` + `confirm` ride this same queue as a back-to-back
///   pair, as do `tabs.close` and `bm.remove` against ids that may have moved
///   on. 260812-uge first closed that by dropping outright whenever no socket
///   was up; the TTL replaces that rule, restoring blip-tolerance while still
///   making a late replay impossible.
/// - **internal** — handshake family + `ping`: owned by the driver/probe,
///   never routed through SendPolicy.
///
/// Synchronous and IO-free — the driver supplies both the actual `send`
/// callbacks and the [nowMillis] clock.
library;

/// A reliable frame waiting for auth, with the clock reading it was queued at.
class _Pending {
  const _Pending(this.frame, this.queuedAt);

  final Object frame;
  final int queuedAt;
}

/// Bounded send policy: volatile drop-if-not-authed, reliable queue ≤[maxQueue]
/// aged out at [ttl].
class SendPolicy {
  /// Whether the session is authed (set by the driver on authedOk/loss).
  bool authed = false;

  /// Maximum reliable frames queued while not authed (design spec §8: 10).
  final int maxQueue;

  /// How long a reliable frame may wait before it is aged out (260812-uq8).
  ///
  /// Reconnect backoff is 1/2/4/8s ±20% jitter, so a blip that recovers on
  /// redial #1 re-auths ~0.8–1.25s after the drop and one that needs redial #2
  /// at ~2.4–3.6s. 5s covers both and stops short of redial #3 (~5.6–8.4s):
  /// a genuine blip stays lossless, a genuine outage never replays.
  final Duration ttl;

  /// Monotonic-enough clock in millis — the house seam (`LatencyProbe`,
  /// `VolumeStore`, `PresenterTimer`). Required rather than defaulted: a
  /// hidden `DateTime.now()` would make the TTL untestable by accident.
  final int Function() nowMillis;

  /// Called once per reliable frame dropped due to a full queue.
  final void Function()? onOverflow;

  /// Reliable frames buffered during a blip, oldest first.
  final List<_Pending> _queue = <_Pending>[];

  /// Creates a send policy.
  SendPolicy({
    required this.nowMillis,
    this.maxQueue = 10,
    this.ttl = const Duration(seconds: 5),
    this.onOverflow,
  });

  /// Whether a volatile frame may be sent right now (never queued —
  /// a plain boolean read, allocation-free on the pointer-move hot path).
  bool shouldSendVolatile() => authed;

  /// Send [frame] via [send] when authed; otherwise queue it (bounded, aged).
  ///
  /// Past [maxQueue] the frame is dropped and [onOverflow] fires once.
  /// [onOverflow] does NOT fire for a TTL expiry: it is documented as the
  /// full-queue signal, and overloading it would make its one meaning
  /// ambiguous for whoever wires it up.
  void enqueueOrSendReliable(Object frame, void Function(Object) send) {
    if (authed) {
      send(frame);
      return;
    }
    // Ageing BEFORE the bound is measured is load-bearing: a long outage
    // otherwise fills the queue with expired frames, and the next live frame
    // overflows against corpses — dropping the one frame still worth sending
    // and firing onOverflow for a queue that is really empty.
    _expire();
    if (_queue.length >= maxQueue) {
      onOverflow?.call();
      return;
    }
    _queue.add(_Pending(frame, nowMillis()));
  }

  /// Deliver queued frames that are still within [ttl] FIFO via [send], then
  /// empty the queue.
  void flushOnAuthed(void Function(Object) send) {
    _expire();
    if (_queue.isEmpty) {
      return;
    }
    final pending = List<_Pending>.of(_queue);
    _queue.clear();
    for (final p in pending) {
      send(p.frame);
    }
  }

  /// Empty the queue without sending (target switched / auth-stop / explicit
  /// disconnect — see `ConnectionService`, which owns those three cases).
  void clear() => _queue.clear();

  /// Drop every frame that has waited [ttl] or longer.
  ///
  /// The boundary is inclusive — a frame exactly [ttl] old is expired — so
  /// "survives 5s" reads as strictly-less-than everywhere.
  void _expire() {
    if (_queue.isEmpty) {
      return;
    }
    final cutoff = nowMillis() - ttl.inMilliseconds;
    _queue.removeWhere((p) => p.queuedAt <= cutoff);
  }
}
