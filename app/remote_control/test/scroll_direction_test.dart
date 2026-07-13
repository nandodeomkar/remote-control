// Task 1 (07-12, TDD) — scroll_direction.dart pref + trackpad driver
// scroll-sign plumb (D-11). Proves: (1) the hot-path cache defaults to
// Natural and is driven deterministically via debugScrollReversedCached
// (mirrors haptics_gate_test.dart's debugHapticsCached seam — no prefs
// backend or provider container needed), and (2) the TrackpadDriver's
// scroll-sign gate: Reversed flips the y-scroll sign, Natural leaves it
// unchanged, using an INJECTED cached-value getter (never a per-event
// provider lookup) — mirrors trackpad_driver_test.dart's Harness style.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/settings/scroll_direction.dart';
import 'package:remote_control/trackpad/gesture_classifier.dart';
import 'package:remote_control/trackpad/trackpad_driver.dart';
import 'package:remote_control/trackpad/tuning.dart';

void main() {
  tearDown(() {
    debugScrollReversedCached = kScrollReversedDefault;
  });

  group('scroll_direction hot-path cache', () {
    test('default cache is Natural (false)', () {
      expect(kScrollReversedDefault, isFalse);
      expect(debugScrollReversedCached, isFalse);
      expect(scrollReversedCached, isFalse);
    });

    test('debugScrollReversedCached drives the cache deterministically', () {
      debugScrollReversedCached = true;
      expect(scrollReversedCached, isTrue);
      debugScrollReversedCached = false;
      expect(scrollReversedCached, isFalse);
    });
  });

  group('TrackpadDriver scroll-sign gate (D-11)', () {
    TrackpadDriver buildDriver({
      required void Function(double dx, double dy) onSendScroll,
      bool Function()? scrollReversed,
    }) =>
        TrackpadDriver(
          onSendMove: (_, _) {},
          onSendScroll: onSendScroll,
          onSendReliable: (_) {},
          onHaptic: () {},
          onDragLockChanged: (_) {},
          onLongPressElapsed: () {},
          sensitivity: () => 1.0,
          scrollReversed: scrollReversed,
        );

    test('Natural (reversed=false) leaves the y-scroll sign unchanged', () {
      final scrolls = <(double, double)>[];
      final driver = buildDriver(
        onSendScroll: (dx, dy) => scrolls.add((dx, dy)),
        scrollReversed: () => false,
      );

      driver.handle(const [ScrollIntent(10, 20)]);

      expect(scrolls, [
        (10 * kScrollUnitPerPx, 20 * kScrollUnitPerPx * kScrollDirection),
      ]);
    });

    test('Reversed (reversed=true) flips the y-scroll sign', () {
      final scrolls = <(double, double)>[];
      final driver = buildDriver(
        onSendScroll: (dx, dy) => scrolls.add((dx, dy)),
        scrollReversed: () => true,
      );

      driver.handle(const [ScrollIntent(10, 20)]);

      expect(scrolls, [
        (10 * kScrollUnitPerPx, -1 * 20 * kScrollUnitPerPx * kScrollDirection),
      ]);
    });

    test(
        'no scrollReversed seam provided defaults to Natural — existing '
        'callers (trackpad_driver_test.dart) see no behavior change', () {
      final scrolls = <(double, double)>[];
      final driver = buildDriver(
        onSendScroll: (dx, dy) => scrolls.add((dx, dy)),
      );

      driver.handle(const [ScrollIntent(0, 5)]);

      expect(scrolls, [(0.0, 5 * kScrollUnitPerPx * kScrollDirection)]);
    });

    test('re-reads the scrollReversed getter per intent (live toggle)', () {
      final scrolls = <(double, double)>[];
      var reversed = false;
      final driver = buildDriver(
        onSendScroll: (dx, dy) => scrolls.add((dx, dy)),
        scrollReversed: () => reversed,
      );

      driver.handle(const [ScrollIntent(0, 10)]);
      reversed = true;
      driver.handle(const [ScrollIntent(0, 10)]);

      expect(scrolls[0].$2, 10 * kScrollUnitPerPx * kScrollDirection);
      expect(scrolls[1].$2, -1 * 10 * kScrollUnitPerPx * kScrollDirection);
    });

    test('Reversed also flips the momentum loop sign (magnitude untouched)',
        () {
      final scrolls = <(double, double)>[];
      final tasks = <void Function()>[];
      // Fake schedule (Harness idiom from trackpad_driver_test.dart) so the
      // pending tick fires synchronously instead of via a real Timer.
      final driver = TrackpadDriver(
        onSendMove: (_, _) {},
        onSendScroll: (dx, dy) => scrolls.add((dx, dy)),
        onSendReliable: (_) {},
        onHaptic: () {},
        onDragLockChanged: (_) {},
        onLongPressElapsed: () {},
        sensitivity: () => 1.0,
        scrollReversed: () => true,
        schedule: (delay, fn) => tasks.add(fn),
      );

      driver.handle(const [FlingIntent(0, 2.0)]);
      expect(tasks, hasLength(1));
      tasks.removeAt(0)();

      expect(scrolls, hasLength(1));
      final expectedMagnitude =
          2.0 * kMomentumDecay * kMomentumTickMs * kScrollUnitPerPx;
      // Reversed flips the sign relative to the Natural kScrollDirection
      // convention (which is negative on y) — so the reversed magnitude
      // comes out POSITIVE here, same absolute value.
      expect(
        scrolls.single.$2,
        closeTo(expectedMagnitude * kScrollDirection * -1.0, 1e-9),
      );
    });
  });
}
