/// Per-message-class send policy (design spec §8, 03-RESEARCH Pattern 6).
///
/// Message classes and who owns them:
/// - **volatile** — binary move/scroll frames: dropped unless authed, NEVER
///   queued (queued deltas teleport the cursor on reconnect). The check is
///   a plain boolean read — allocation-free, it sits on the pointer-move
///   hot path.
/// - **reliable** — `click`, `drag`, `key`, `text`, `media`, `power`,
///   `confirm`, `clip.*`, `browser`, `present`: queued (bounded, FIFO) while a
///   socket is up but not yet authed, flushed on auth, dropped with
///   [onOverflow] past [maxQueue]. Phase 3 ships this seam; later phases
///   consume it.
///
///   **Reliable does NOT mean durable across a disconnect (260812-uge).** With
///   no socket the frame is DROPPED, not held: it used to be queued with
///   nothing bounding how long it waited, so anything sent during an outage
///   was delivered late into whatever window happened to be focused when the
///   phone re-authed. That was reported for typed text at the 04 UAT, but
///   `power` + `confirm` ride this same queue as a back-to-back pair, as do
///   `tabs.close` and `bm.remove` against ids that may have moved on.
///   The queue's remaining job is the socket-open → auth-complete handshake
///   window, which is milliseconds.
/// - **internal** — handshake family + `ping`: owned by the driver/probe,
///   never routed through SendPolicy.
///
/// Pure and synchronous — no IO, no async; the driver supplies the actual
/// `send` callbacks.
library;

/// Bounded send policy: volatile drop-if-not-authed, reliable queue ≤[maxQueue].
class SendPolicy {
  /// Whether the session is authed (set by the driver on authedOk/loss).
  bool authed = false;

  /// Whether a socket is currently installed (set by the driver when a channel
  /// is established and cleared at teardown).
  ///
  /// This is the gate that makes a disconnect drop rather than accumulate. It
  /// cannot be inferred from [authed]: the harmful window — backoff, between a
  /// teardown and the next successful dial — has `authed == false` exactly like
  /// the benign handshake window does, and only the presence of a socket tells
  /// them apart.
  bool channelUp = false;

  /// Maximum reliable frames queued while not authed (design spec §8: 10).
  final int maxQueue;

  /// Called once per reliable frame dropped due to a full queue.
  final void Function()? onOverflow;

  /// Reliable frames buffered during a blip, oldest first.
  final List<Object> _queue = <Object>[];

  /// Creates a send policy.
  SendPolicy({this.maxQueue = 10, this.onOverflow});

  /// Whether a volatile frame may be sent right now (never queued —
  /// a plain boolean read, allocation-free on the pointer-move hot path).
  bool shouldSendVolatile() => authed;

  /// Send [frame] via [send] when authed; queue it (bounded) during the
  /// handshake window; DROP it outright when no socket is up.
  ///
  /// Past [maxQueue] the frame is dropped and [onOverflow] fires once.
  /// [onOverflow] does NOT fire for a no-socket drop: it is documented as the
  /// full-queue signal, and overloading it would make its one meaning
  /// ambiguous for whoever wires it up.
  void enqueueOrSendReliable(Object frame, void Function(Object) send) {
    if (authed) {
      send(frame);
      return;
    }
    // No socket — disconnected, or backing off between dials. Dropped, never
    // held: a queued frame here would be replayed into whatever window is
    // focused whenever the phone next auths (260812-uge).
    if (!channelUp) {
      return;
    }
    if (_queue.length >= maxQueue) {
      onOverflow?.call();
      return;
    }
    _queue.add(frame);
  }

  /// Deliver queued frames FIFO via [send], then empty the queue.
  void flushOnAuthed(void Function(Object) send) {
    if (_queue.isEmpty) {
      return;
    }
    final pending = List<Object>.of(_queue);
    _queue.clear();
    for (final frame in pending) {
      send(frame);
    }
  }

  /// Empty the queue without sending (e.g. target switched / auth-stop).
  void clear() => _queue.clear();
}
