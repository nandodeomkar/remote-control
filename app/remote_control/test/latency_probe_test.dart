// Task 2 (TDD) — interleaved-ping latency probe: percentile math, empty
// safety, pong->RTT flow, and the every-K-moves / ~250ms cadence.
//
// The probe measures round-trip-UNDER-MOVE-LOAD (criterion 2 intent), NOT
// idle ping RTT: pings are stamped while dragging so the RTT is the faithful
// proxy for one-way move-frame delivery+processing (moves have no per-frame
// ack). Clock + sink are injected so cadence is asserted deterministically.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/hud/latency_probe.dart';
import 'package:remote_protocol/remote_protocol.dart';

/// A controllable fake clock.
class _FakeClock {
  int _now = 0;
  int call() => _now;
  void advance(int millis) => _now += millis;
  set now(int millis) => _now = millis;
}

/// Records every frame added to the sink and decodes the pings.
class _RecordingSink {
  final List<Object?> added = [];
  void add(Object? frame) => added.add(frame);

  List<PingMsg> get pings => added
      .whereType<String>()
      .map((f) => decodeText(f).msg)
      .whereType<PingMsg>()
      .toList();
}

void main() {
  group('LatencyProbe — percentile math (nearest-rank)', () {
    test('p50 ~= 50 and p95 ~= 95 on the sample {1..100}', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        windowSize: 200,
      );

      // Feed 1..100 as RTT samples: stamp ts, echo pong at ts+rtt.
      for (var rtt = 1; rtt <= 100; rtt++) {
        clock.now = 0;
        probe.recordPingTs(0);
        clock.now = rtt;
        probe.onPong(const PongMsg(ts: 0));
      }

      expect(probe.p50, 50);
      expect(probe.p95, 95);
    });

    test('odd and even small samples resolve by nearest-rank', () {
      final clock = _FakeClock();
      final probe = LatencyProbe(nowMillis: clock.call, send: (_) {});

      // Samples {10, 20, 30} — p50 nearest-rank = rank ceil(.5*3)=2 -> 20.
      for (final rtt in [10, 20, 30]) {
        clock.now = 0;
        probe.recordPingTs(0);
        clock.now = rtt;
        probe.onPong(const PongMsg(ts: 0));
      }
      expect(probe.p50, 20);
    });

    test('empty sample yields null, never throws', () {
      final clock = _FakeClock();
      final probe = LatencyProbe(nowMillis: clock.call, send: (_) {});
      expect(probe.p50, isNull);
      expect(probe.p95, isNull);
    });
  });

  group('LatencyProbe — pong -> RTT sample flow', () {
    test('onPong records (now - ts) into the rolling window', () {
      final clock = _FakeClock();
      final probe = LatencyProbe(nowMillis: clock.call, send: (_) {});

      clock.now = 1000;
      probe.recordPingTs(1000);
      clock.now = 1042; // 42ms round trip
      probe.onPong(const PongMsg(ts: 1000));

      expect(probe.p50, 42);
      expect(probe.sampleCount, 1);
    });

    test('the rolling window is bounded to windowSize', () {
      final clock = _FakeClock();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: (_) {},
        windowSize: 3,
      );

      for (var i = 0; i < 10; i++) {
        clock.now = 0;
        probe.recordPingTs(0);
        clock.now = i + 1;
        probe.onPong(const PongMsg(ts: 0));
      }

      expect(probe.sampleCount, 3, reason: 'window bounded to last 3 samples');
    });
  });

  group('LatencyProbe — interleave cadence (every K moves / ~250ms)', () {
    test('emits one ping every K moves via the injected sink', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 5,
        pingIntervalMillis: 100000, // effectively disable the time trigger
      );

      // 12 moves with no time advance -> pings at move 5 and move 10 => 2.
      for (var i = 0; i < 12; i++) {
        probe.onMove();
      }

      expect(sink.pings, hasLength(2));
    });

    test('emits a ping when ~250ms elapse even before K moves', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 1000, // effectively disable the move-count trigger
        pingIntervalMillis: 250,
      );

      probe.onMove(); // t=0: first move always primes a ping baseline
      final afterFirst = sink.pings.length;

      clock.advance(300); // > 250ms since the last ping
      probe.onMove();

      expect(sink.pings.length, greaterThan(afterFirst),
          reason: 'the ~250ms time trigger fires the interleaved ping');
    });

    test('each emitted ping stamps ts = nowMillis (round-trip under load)', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 1,
      );

      clock.now = 777;
      probe.onMove();

      expect(sink.pings, isNotEmpty);
      expect(sink.pings.first.ts, 777);
    });
  });

  group('LatencyProbe — idle-ping liveness (D-08 / CONN-06)', () {
    test('onIdleTick emits only when >= idlePingIntervalMillis elapsed', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        idlePingIntervalMillis: 2000,
      );

      // No prior ping at all: the first idle tick emits immediately (an
      // authed-idle session must start measuring, not wait a full interval).
      probe.onIdleTick();
      expect(sink.pings, hasLength(1));

      // Repeated ticks with no time elapsed emit nothing.
      probe.onIdleTick();
      probe.onIdleTick();
      expect(sink.pings, hasLength(1));

      // Just short of the interval: still nothing.
      clock.advance(1999);
      probe.onIdleTick();
      expect(sink.pings, hasLength(1));

      // At the interval boundary: the idle ping fires.
      clock.advance(1);
      probe.onIdleTick();
      expect(sink.pings, hasLength(2));
    });

    test('a recent move-ping suppresses the idle ping (interleave)', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 1, // every move emits a ping
        idlePingIntervalMillis: 2000,
      );

      clock.now = 1000;
      probe.onMove(); // move-driven ping at t=1000
      expect(sink.pings, hasLength(1));

      // Idle tick 500ms after the move-ping: suppressed (shared baseline).
      clock.now = 1500;
      probe.onIdleTick();
      expect(sink.pings, hasLength(1));

      // Idle tick a full interval after the move-ping: fires.
      clock.now = 3000;
      probe.onIdleTick();
      expect(sink.pings, hasLength(2));
    });

    test('pingsAwaited counts unanswered pings; onPong zeroes it AND still '
        'records the RTT sample', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        idlePingIntervalMillis: 2000,
      );

      probe.onIdleTick(); // ping #1 at t=0
      clock.advance(2000);
      probe.onIdleTick(); // ping #2 at t=2000
      expect(probe.pingsAwaited, 2);

      clock.advance(10); // pong for ping #2: RTT 10ms
      probe.onPong(const PongMsg(ts: 2000));
      expect(probe.pingsAwaited, 0);
      expect(probe.p50, 10, reason: 'RTT recording is unchanged by liveness');
      expect(probe.sampleCount, 1);
    });

    test('onDead fires once after the full silence window elapses (latched)',
        () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      var deadCount = 0;
      // Dead window = missedPongLimit(3) * idlePingIntervalMillis(2000) = 6000ms.
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        idlePingIntervalMillis: 2000,
        missedPongLimit: 3,
        onDead: () => deadCount++,
      );

      probe.onIdleTick(); // t=0: silence streak anchored here
      clock.advance(2000);
      probe.onIdleTick(); // t=2000, silence 2000 < 6000
      clock.advance(2000);
      probe.onIdleTick(); // t=4000, silence 4000 < 6000
      expect(deadCount, 0);
      clock.advance(2000);
      probe.onIdleTick(); // t=6000, silence 6000 >= 6000 -> dead
      expect(deadCount, 1);

      // Further unanswered pings do NOT re-fire until reset (latch).
      clock.advance(2000);
      probe.onIdleTick();
      clock.advance(2000);
      probe.onIdleTick();
      expect(deadCount, 1);
    });

    test('CR-01: fast move-driven pings do NOT declare dead within the '
        'silence window — only true wall-clock silence does', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      var deadCount = 0;
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 1, // every move emits a ping (worst case)
        idlePingIntervalMillis: 2000,
        missedPongLimit: 3, // dead window 6000ms
        onDead: () => deadCount++,
      );

      // A congested-WiFi drag: many pings emitted fast with no pong yet (an
      // RTT spike). Old count-based logic tripped onDead at 3 pings (~sub-second);
      // time-based must not, because only ~3s of wall clock has passed.
      for (var t = 0; t <= 3000; t += 100) {
        clock.now = t;
        probe.onMove();
      }
      expect(probe.pingsAwaited, greaterThan(missedPongLimitDefault),
          reason: 'far more than 3 unanswered pings were emitted');
      expect(deadCount, 0,
          reason: 'a live-but-laggy drag must NOT be torn down (CR-01)');

      // Sustained silence past the window (finger lifted; idle ticks continue)
      // still declares dead — liveness is preserved, just decoupled from count.
      clock.now = 6000;
      probe.onIdleTick();
      expect(deadCount, 1);
    });

    test('a pong during a fast drag clears the silence streak', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      var deadCount = 0;
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 1,
        idlePingIntervalMillis: 2000,
        missedPongLimit: 3,
        onDead: () => deadCount++,
      );

      // Drag with healthy pongs: each move-ping is answered, so the silence
      // anchor keeps resetting and dead never fires no matter how long the drag.
      for (var t = 0; t <= 20000; t += 100) {
        clock.now = t;
        probe.onMove();
        probe.onPong(PongMsg(ts: t)); // ~0ms RTT, answered immediately
      }
      expect(deadCount, 0);
    });

    test('reset clears pingsAwaited, the silence anchor, and re-arms onDead',
        () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      var deadCount = 0;
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        idlePingIntervalMillis: 2000,
        missedPongLimit: 3,
        onDead: () => deadCount++,
      );

      // Silence from t=0 to t=6000 -> dead.
      for (var t = 0; t <= 6000; t += 2000) {
        clock.now = t;
        probe.onIdleTick();
      }
      expect(deadCount, 1);

      probe.reset();
      expect(probe.pingsAwaited, 0);

      // A fresh silence streak anchors at the post-reset clock and fires again.
      for (var t = 100000; t <= 106000; t += 2000) {
        clock.now = t;
        probe.onIdleTick();
      }
      expect(deadCount, 2);
    });

    test('WR-03: onPong rejects implausible RTT (negative / clock jump) but '
        'still proves liveness', () {
      final clock = _FakeClock();
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: (_) {},
        idlePingIntervalMillis: 2000,
      );

      clock.now = 1000;
      probe.onIdleTick(); // one unanswered ping
      expect(probe.pingsAwaited, 1);

      // Negative RTT: pong ts in the future (1000 - 5000 = -4000). Rejected as
      // a sample, but the pong still zeroes the liveness counter.
      probe.onPong(const PongMsg(ts: 5000));
      expect(probe.sampleCount, 0);
      expect(probe.p50, isNull);
      expect(probe.pingsAwaited, 0, reason: 'a pong of any kind proves alive');

      // Absurdly large RTT: ts far in the past (> 60s ceiling) — also rejected.
      probe.onPong(const PongMsg(ts: -100000));
      expect(probe.sampleCount, 0);

      // A plausible sample IS recorded.
      clock.now = 1042;
      probe.onPong(const PongMsg(ts: 1000));
      expect(probe.p50, 42);
      expect(probe.sampleCount, 1);
    });
  });
}

/// The default [LatencyProbe.missedPongLimit] used across the liveness tests.
const int missedPongLimitDefault = 3;
