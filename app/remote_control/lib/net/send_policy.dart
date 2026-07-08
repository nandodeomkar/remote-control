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
/// Methods are implemented in plan 03-02 Task 2 (GREEN); this stub only
/// fixes the API surface so the suite compiles and fails red.
class SendPolicy {
  /// Whether the session is authed (set by the driver on authedOk/loss).
  bool authed = false;

  /// Maximum reliable frames queued while not authed (design spec §8: 10).
  final int maxQueue;

  /// Called once per reliable frame dropped due to a full queue.
  final void Function()? onOverflow;

  /// Creates a send policy.
  SendPolicy({this.maxQueue = 10, this.onOverflow});

  /// Whether a volatile frame may be sent right now (never queued).
  bool shouldSendVolatile() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// Send [frame] via [send] when authed; queue it (bounded) otherwise.
  void enqueueOrSendReliable(Object frame, void Function(Object) send) =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// Deliver queued frames FIFO via [send], then empty the queue.
  void flushOnAuthed(void Function(Object) send) =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// Empty the queue without sending (e.g. target switched / auth-stop).
  void clear() => throw UnimplementedError('implemented in 03-02 Task 2');
}
