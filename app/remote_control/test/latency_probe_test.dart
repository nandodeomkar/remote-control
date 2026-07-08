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

    test('reaching missedPongLimit fires onDead EXACTLY once (latched)', () {
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

      probe.onIdleTick(); // awaited 1
      expect(deadCount, 0);
      clock.advance(2000);
      probe.onIdleTick(); // awaited 2
      expect(deadCount, 0);
      clock.advance(2000);
      probe.onIdleTick(); // awaited 3 -> dead
      expect(deadCount, 1);

      // Further unanswered pings do NOT re-fire until reset (latch).
      clock.advance(2000);
      probe.onIdleTick();
      clock.advance(2000);
      probe.onIdleTick();
      expect(deadCount, 1);
    });

    test('move-driven pings count toward the missed-pong limit too '
        '(one shared awaited counter)', () {
      final clock = _FakeClock();
      final sink = _RecordingSink();
      var deadCount = 0;
      final probe = LatencyProbe(
        nowMillis: clock.call,
        send: sink.add,
        movesPerPing: 1,
        missedPongLimit: 3,
        onDead: () => deadCount++,
      );

      clock.now = 0;
      probe.onMove(); // ping 1
      clock.now = 300;
      probe.onMove(); // ping 2
      clock.now = 600;
      probe.onMove(); // ping 3 -> dead
      expect(probe.pingsAwaited, 3);
      expect(deadCount, 1);
    });

    test('reset clears pingsAwaited and re-arms onDead', () {
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

      for (var i = 0; i < 3; i++) {
        probe.onIdleTick();
        clock.advance(2000);
      }
      expect(deadCount, 1);

      probe.reset();
      expect(probe.pingsAwaited, 0);

      // A fresh dead episode fires again after reset (re-armed latch).
      for (var i = 0; i < 3; i++) {
        probe.onIdleTick();
        clock.advance(2000);
      }
      expect(deadCount, 2);
    });
  });
}
