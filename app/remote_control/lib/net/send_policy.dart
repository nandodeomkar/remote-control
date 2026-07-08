/// Per-message-class send policy (design spec §8, 03-RESEARCH Pattern 6).
///
/// Message classes and who owns them:
/// - **volatile** — binary move/scroll frames: dropped unless authed, NEVER
///   queued (queued deltas teleport the cursor on reconnect). The check is
///   a plain boolean read — allocation-free, it sits on the pointer-move
///   hot path.
/// - **reliable** — `click`, `drag`, `key`, `text`, `media`, `power`,
///   `confirm`, `clip.*`, `browser`, `present`: queued (bounded, FIFO)
///   during connection blips, flushed on auth, dropped with [onOverflow]
///   past [maxQueue]. Phase 3 ships this seam; later phases consume it.
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

  /// Send [frame] via [send] when authed; queue it (bounded) otherwise.
  /// Past [maxQueue] the frame is dropped and [onOverflow] fires once.
  void enqueueOrSendReliable(Object frame, void Function(Object) send) {
    if (authed) {
      send(frame);
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
