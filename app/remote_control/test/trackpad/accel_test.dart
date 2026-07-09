// Task 2 (TDD, Wave 0) — accelGain: the velocity acceleration curve with a
// linear sensitivity multiplier (PAD-01, D-05). Pure, stateless, and
// deterministic — the exact scalar the driver multiplies raw deltas by
// before sendMove; slow deltas stay ~1:1 so the server's sub-pixel
// accumulator (D-02) keeps its fidelity end-to-end.
//
// All coefficients come from tuning.dart (D-06) — retuning the curve on
// device never touches this file.

import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/trackpad/accel.dart';
import 'package:remote_control/trackpad/tuning.dart';

void main() {
  group('accelGain — velocity acceleration curve (PAD-01, D-05)', () {
    test('slow ~1:1: at speed -> 0 the gain is kAccelMinGain * sensitivity',
        () {
      expect(accelGain(0, 0, 1.0), kAccelMinGain);
      expect(accelGain(0, 0, 1.5), kAccelMinGain * 1.5);
      // A tiny delta stays within a hair of the floor.
      expect(accelGain(0.01, 0, 1.0), closeTo(kAccelMinGain, 0.01));
    });

    test('monotonic: gain never decreases as speed grows, saturating at '
        'kAccelMaxGain * sensitivity from kAccelRefSpeedPx onward', () {
      var prev = double.negativeInfinity;
      for (var speed = 0.0; speed <= kAccelRefSpeedPx * 2; speed += 0.5) {
        final g = accelGain(speed, 0, 1.0);
        expect(g, greaterThanOrEqualTo(prev),
            reason: 'gain dipped at speed $speed');
        prev = g;
      }
      expect(accelGain(kAccelRefSpeedPx, 0, 1.0), kAccelMaxGain);
      expect(accelGain(kAccelRefSpeedPx * 4, 0, 1.0), kAccelMaxGain,
          reason: 'beyond the reference speed the curve saturates');
      expect(accelGain(kAccelRefSpeedPx * 4, 0, 2.0), kAccelMaxGain * 2.0);
    });

    test('sensitivity scales linearly: g(d, d, 2s) == 2 * g(d, d, s)', () {
      for (final d in [0.5, 2.0, 8.0, 20.0, 100.0]) {
        expect(accelGain(d, d, 2.0), accelGain(d, d, 1.0) * 2,
            reason: 'sensitivity must be a pure linear multiplier at d=$d');
      }
    });

    test('speed is the euclidean magnitude of (dx, dy)', () {
      // (3, 4) has speed 5 — same gain as (5, 0) and (0, 5).
      expect(accelGain(3, 4, 1.0), accelGain(5, 0, 1.0));
      expect(accelGain(3, 4, 1.0), accelGain(0, 5, 1.0));
      expect(accelGain(-3, -4, 1.0), accelGain(5, 0, 1.0),
          reason: 'direction never matters, only magnitude');
    });

    test('deterministic and stateless: same inputs -> same output, '
        'call order irrelevant', () {
      final first = accelGain(7.3, -2.1, 1.4);
      accelGain(100, 100, 2.0); // interleave an unrelated call
      accelGain(0, 0, 0.5);
      expect(accelGain(7.3, -2.1, 1.4), first);
      // And the curve is the documented closed form.
      final speed = math.sqrt(7.3 * 7.3 + 2.1 * 2.1);
      final t = math.min(1.0, speed / kAccelRefSpeedPx);
      expect(first, 1.4 * (kAccelMinGain + (kAccelMaxGain - kAccelMinGain) * t));
    });
  });
}
