/// Interleaved-ping latency probe (PAD-05 criterion 2, D-06/D-09).
///
/// Measures ROUND-TRIP-UNDER-MOVE-LOAD, explicitly NOT idle ping RTT: pings
/// are stamped WHILE dragging (every K move frames OR every ~250ms), so the
/// measured RTT is the faithful proxy for one-way move-frame delivery +
/// processing latency — move frames are fire-and-forget with no per-frame ack
/// (02-RESEARCH Open Question 2 / finding 4; 02-VERIFICATION criterion 2).
///
/// Reuses `ping`/`pong` from `remote_protocol` — no new opcode, no server
/// change (the server echoes `ts` verbatim, router.rs `Msg::Ping => Pong{ts}`).
/// The clock and sink are injected so cadence and percentile math are
/// deterministic in tests. The probe is the PERMANENT engine behind the
/// header's live latency display AND dead-connection detection (D-08,
/// CONN-06): [onIdleTick] keeps a ~2s ping cadence flowing while authed+idle,
/// and [LatencyProbe.onDead] fires once when NO pong has returned for a
/// wall-clock window ([LatencyProbe.missedPongLimit] × [idlePingIntervalMillis]
/// ≈ 6s of true silence) so ConnectionService can declare the socket dead.
/// Dead-detection is TIME-based, not ping-count based: fast move-driven pings
/// under a drag emit far more than `missedPongLimit` pings per second, so a
/// counter would false-positive on a live-but-laggy connection and tear it
/// down mid-drag — only unbroken silence for the window fires [onDead]. The
/// probe holds NO timers — ConnectionService owns the periodic tick; the probe
/// stays clock-injected and test-deterministic.
///
/// Percentile rule: NEAREST-RANK on the ascending-sorted window. For a window
/// of N samples, the p-th percentile is the value at 1-indexed rank
/// `ceil(p/100 * N)` (clamped to [1, N]). On {1..100}: p50 -> rank 50 -> 50,
/// p95 -> rank 95 -> 95.
library;

import 'package:remote_protocol/remote_protocol.dart';

/// Collects interleaved-ping RTT samples and exposes p50/p95.
class LatencyProbe {
  /// Returns the current time in milliseconds (injected for determinism).
  final int Function() nowMillis;

  /// Sends an encoded frame onto the channel sink (injected).
  final void Function(Object frame) _send;

  /// Emit a ping after this many move frames since the last ping.
  final int movesPerPing;

  /// Emit a ping when at least this many millis elapsed since the last ping.
  final int pingIntervalMillis;

  /// Bounded rolling window length so long drags stay O(1) in memory and p95
  /// reflects RECENT behavior.
  final int windowSize;

  /// Emit an idle ping when at least this many millis elapsed since the last
  /// ping of ANY kind (move-driven pings share the baseline, so a recent
  /// move-ping suppresses the idle ping).
  final int idlePingIntervalMillis;

  /// Number of idle intervals of unbroken silence before [onDead] fires: the
  /// dead window is `missedPongLimit × idlePingIntervalMillis` of wall-clock
  /// time with no pong (~6s at the defaults — CONN-06 liveness).
  final int missedPongLimit;

  /// Fired EXACTLY once per dead episode when no pong returns for the dead
  /// window (see [missedPongLimit]); latched until [reset].
  final void Function()? onDead;

  /// RTT samples above this (or below zero) are rejected as implausible — an
  /// echoed/hostile `ts` or a clock jump must not poison the percentile window
  /// (WR-03). Generous vs. the ~6s dead window: a real pong always precedes it.
  static const int _maxPlausibleRttMillis = 60000;

  final List<int> _window = <int>[];
  int _movesSincePing = 0;
  int? _lastPingAtMillis;
  int _pingsAwaited = 0;
  bool _deadFired = false;

  /// Wall-clock anchor for the current unanswered-silence streak: set at the
  /// first unanswered ping, cleared by any pong. Dead-detection measures
  /// `now - _silenceSinceMillis` against the dead window (CR-01).
  int? _silenceSinceMillis;

  /// Creates a probe.
  ///
  /// [movesPerPing] and [pingIntervalMillis] set the interleave cadence
  /// (fire on whichever triggers first). [windowSize] bounds the RTT window.
  /// [idlePingIntervalMillis]/[missedPongLimit]/[onDead] configure the
  /// idle-ping liveness engine driven via [onIdleTick].
  LatencyProbe({
    required this.nowMillis,
    required void Function(Object frame) send,
    this.movesPerPing = 8,
    this.pingIntervalMillis = 250,
    this.windowSize = 120,
    this.idlePingIntervalMillis = 2000,
    this.missedPongLimit = 3,
    this.onDead,
  }) : _send = send; // ignore: prefer_initializing_formals

  /// Number of RTT samples currently in the rolling window.
  int get sampleCount => _window.length;

  /// Pings emitted with no matching [onPong] yet (liveness counter).
  int get pingsAwaited => _pingsAwaited;

  /// The 50th-percentile RTT in millis, or `null` when no samples yet.
  int? get p50 => _percentile(50);

  /// The 95th-percentile RTT in millis, or `null` when no samples yet.
  int? get p95 => _percentile(95);

  /// Called from `onPointerMove` on the hot path: ticks the interleave
  /// cadence and stamps+sends a `ping` when either trigger fires.
  ///
  /// Cheap and allocation-free on the no-ping path (just a counter bump).
  void onMove() {
    _movesSincePing++;
    final now = nowMillis();

    // First move of a drag: prime the interval baseline WITHOUT emitting, so
    // the time trigger measures elapsed-since-last-ping rather than firing
    // immediately (the move-count trigger still governs the first burst).
    if (_lastPingAtMillis == null) {
      _lastPingAtMillis = now;
      if (_movesSincePing < movesPerPing) {
        return;
      }
    }

    final elapsed = now - _lastPingAtMillis!;
    final moveTrigger = _movesSincePing >= movesPerPing;
    final timeTrigger = elapsed >= pingIntervalMillis;

    if (moveTrigger || timeTrigger) {
      _emitPing(now);
    }
  }

  /// Periodic liveness tick (called ~every [idlePingIntervalMillis] by
  /// ConnectionService while authed — the probe itself holds NO timer).
  ///
  /// Emits a ping when at least [idlePingIntervalMillis] elapsed since the
  /// last ping of any kind; with no prior ping it emits immediately so an
  /// authed-idle session starts measuring at once. Move-driven pings share
  /// the same baseline, so recent move traffic suppresses the idle ping.
  void onIdleTick() {
    final now = nowMillis();
    final last = _lastPingAtMillis;
    if (last == null || now - last >= idlePingIntervalMillis) {
      _emitPing(now);
    }
  }

  /// Feed a decoded `pong`: record `now - ts` as one RTT sample into the
  /// bounded rolling window, and clear the liveness silence (the connection
  /// just proved alive — the counter zeroing is unconditional even if the
  /// sample itself is rejected).
  void onPong(PongMsg pong) {
    _pingsAwaited = 0;
    _silenceSinceMillis = null; // a pong of any kind ends the silence streak
    final rtt = nowMillis() - pong.ts;
    // WR-03: reject implausible samples (echoed/hostile ts, clock jump) so a
    // single garbage reading can't skew p50/p95 for up to windowSize reads.
    if (rtt < 0 || rtt > _maxPlausibleRttMillis) return;
    _window.add(rtt);
    if (_window.length > windowSize) {
      _window.removeAt(0);
    }
  }

  /// Clears the liveness state: [pingsAwaited], the silence anchor, and the
  /// dead-fired latch.
  ///
  /// The RTT window and the ping-cadence baseline are deliberately KEPT —
  /// the probe is per-connection in ConnectionService, and keeping the
  /// window lets the header show the last-known latency during a brief
  /// teardown instead of flashing empty.
  void reset() {
    _pingsAwaited = 0;
    _silenceSinceMillis = null;
    _deadFired = false;
  }

  /// Test/diagnostic seam: note that a ping with timestamp [ts] was sent, so a
  /// later [onPong] with the same `ts` yields the intended RTT. The live path
  /// uses [onMove] which stamps and records internally.
  void recordPingTs(int ts) {
    _lastPingAtMillis = ts;
  }

  void _emitPing(int now) {
    _movesSincePing = 0;
    _lastPingAtMillis = now;
    _send(encodeMessage(PingMsg(ts: now)));
    // Liveness: BOTH move-driven and idle pings route through here. The
    // unanswered counter is exposed for diagnostics, but dead-detection is
    // TIME-based (CR-01): anchor the silence streak at the first unanswered
    // ping and declare dead only after the full wall-clock window of true
    // silence — fast move-pings advance the count, never the clock.
    _pingsAwaited++;
    _silenceSinceMillis ??= now;
    final deadAfterMillis = missedPongLimit * idlePingIntervalMillis;
    if (now - _silenceSinceMillis! >= deadAfterMillis && !_deadFired) {
      _deadFired = true;
      onDead?.call();
    }
  }

  int? _percentile(int p) {
    if (_window.isEmpty) return null;
    final sorted = List<int>.of(_window)..sort();
    final n = sorted.length;
    // Nearest-rank: rank = ceil(p/100 * n), 1-indexed, clamped to [1, n].
    final rank = (p / 100 * n).ceil().clamp(1, n);
    return sorted[rank - 1];
  }
}

/// The HUD read throttle: the overlay reads p50/p95 at most this often so the
/// hot move path NEVER triggers a widget rebuild (see [latency_probe]).
const Duration kHudReadThrottle = Duration(milliseconds: 500);
