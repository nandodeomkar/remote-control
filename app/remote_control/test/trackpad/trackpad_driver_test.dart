// Task 1 (TDD, 04-04) — TrackpadDriver: the intent executor that turns
// GestureIntent lists into real side effects (sends, haptics, drag-lock
// notifications) with EVERY seam injected: send callbacks, haptic callback,
// drag-lock callback, sensitivity getter, long-press-elapsed callback, and a
// schedule seam (ConnectionService._schedule idiom) — zero real Timers here.
//
// Covers: MoveIntent -> accelGain-scaled sendMove (PAD-01, D-05), click
// intents -> ClickMsg + haptic (PAD-02), ScrollIntent -> px->wheel-unit
// conversion with kScrollDirection (PAD-03), FlingIntent momentum loop with
// decay + stop threshold + StopFlingIntent instant cancel (PAD-03),
// long-press arm/disarm via generation guard (PAD-04), drag start/end ->
// DragMsg + drag-lock notifications (PAD-04, D-04), and reset()/dispose()
// hygiene (no callbacks after either).

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/trackpad/accel.dart';
import 'package:remote_control/trackpad/gesture_classifier.dart';
import 'package:remote_control/trackpad/trackpad_driver.dart';
import 'package:remote_control/trackpad/tuning.dart';
import 'package:remote_protocol/remote_protocol.dart';

/// Deterministic schedule seam: records (delay, callback) pairs; tests fire
/// them by hand (no real Timers — the ConnectionService test idiom).
class FakeScheduler {
  final List<(Duration, void Function())> tasks = [];

  void call(Duration delay, void Function() fn) => tasks.add((delay, fn));

  /// Fires the oldest pending task (FIFO).
  void runNext() {
    final (_, fn) = tasks.removeAt(0);
    fn();
  }

  /// Fires pending tasks until none remain (each fired task may schedule a
  /// successor). Throws if the chain exceeds [cap] fires (runaway loop).
  int drain({int cap = 1000}) {
    var fired = 0;
    while (tasks.isNotEmpty) {
      if (fired >= cap) {
        throw StateError('schedule chain did not terminate within $cap fires');
      }
      runNext();
      fired++;
    }
    return fired;
  }
}

/// Full recording harness around one driver.
class Harness {
  final FakeScheduler scheduler = FakeScheduler();
  final List<(double, double)> moves = [];
  final List<(double, double)> scrolls = [];
  final List<(double, double)> zooms = [];
  final List<RemoteMessage> reliable = [];
  final List<bool> dragLock = [];
  int haptics = 0;
  int longPressElapsed = 0;
  double sensitivity = 1.0;
  bool scrollReversed = false;

  late final TrackpadDriver driver = TrackpadDriver(
    onSendMove: (dx, dy) => moves.add((dx, dy)),
    onSendScroll: (dx, dy) => scrolls.add((dx, dy)),
    onSendZoom: (dx, dy) => zooms.add((dx, dy)),
    onSendReliable: reliable.add,
    onHaptic: () => haptics++,
    onDragLockChanged: dragLock.add,
    onLongPressElapsed: () => longPressElapsed++,
    sensitivity: () => sensitivity,
    scrollReversed: () => scrollReversed,
    schedule: scheduler.call,
  );
}

void main() {
  group('TrackpadDriver — MoveIntent (PAD-01, D-05)', () {
    test('sends dx*g, dy*g where g = accelGain(dx, dy, sensitivity())', () {
      final h = Harness()..sensitivity = 1.5;
      h.driver.handle(const [MoveIntent(6, -8)]);
      final g = accelGain(6, -8, 1.5);
      expect(h.moves, [(6 * g, -8 * g)]);
      expect(h.haptics, 0, reason: 'moves never tick haptics');
    });

    test('re-reads the sensitivity getter per intent (live slider)', () {
      final h = Harness()..sensitivity = 1.0;
      h.driver.handle(const [MoveIntent(4, 0)]);
      h.sensitivity = 2.0;
      h.driver.handle(const [MoveIntent(4, 0)]);
      final g1 = accelGain(4, 0, 1.0);
      final g2 = accelGain(4, 0, 2.0);
      expect(h.moves, [(4 * g1, 0.0), (4 * g2, 0.0)]);
    });
  });

  group('TrackpadDriver — clicks (PAD-02)', () {
    test('ClickLeftIntent -> ClickMsg(left) + haptic', () {
      final h = Harness();
      h.driver.handle(const [ClickLeftIntent()]);
      expect(h.reliable, hasLength(1));
      final msg = h.reliable.single as ClickMsg;
      expect(msg.button, 'left');
      expect(h.haptics, 1);
    });

    test('ClickRightIntent -> ClickMsg(right) + haptic', () {
      final h = Harness();
      h.driver.handle(const [ClickRightIntent()]);
      final msg = h.reliable.single as ClickMsg;
      expect(msg.button, 'right');
      expect(h.haptics, 1);
    });
  });

  group('TrackpadDriver — ScrollIntent (PAD-03)', () {
    test('converts px to wheel units with kScrollDirection on y only', () {
      final h = Harness();
      h.driver.handle(const [ScrollIntent(10, 20)]);
      expect(h.scrolls, [
        (10 * kScrollUnitPerPx, 20 * kScrollUnitPerPx * kScrollDirection),
      ]);
    });

    test('one send per intent — never queued or batched', () {
      final h = Harness();
      h.driver.handle(const [ScrollIntent(0, 5), ScrollIntent(0, 7)]);
      expect(h.scrolls, hasLength(2));
      expect(h.scheduler.tasks, isEmpty,
          reason: 'plain scrolls never touch the schedule seam');
    });
  });

  group('TrackpadDriver — momentum loop (PAD-03)', () {
    test('FlingIntent starts a kMomentumTickMs tick chain that decays and '
        'stops below kMomentumStopVelocity', () {
      final h = Harness();
      h.driver.handle(const [FlingIntent(0, 2.0)]);
      expect(h.scheduler.tasks, hasLength(1));
      expect(h.scheduler.tasks.single.$1,
          const Duration(milliseconds: kMomentumTickMs));

      h.scheduler.drain();

      expect(h.scrolls, isNotEmpty);
      // First tick: v = 2.0 * decay, converted px->wheel units.
      final expectedFirst =
          2.0 * kMomentumDecay * kMomentumTickMs * kScrollUnitPerPx;
      expect(h.scrolls.first.$1, 0.0);
      expect(h.scrolls.first.$2,
          closeTo(expectedFirst * kScrollDirection, 1e-12));
      // Strictly decaying magnitude.
      for (var i = 1; i < h.scrolls.length; i++) {
        expect(h.scrolls[i].$2.abs(), lessThan(h.scrolls[i - 1].$2.abs()));
      }
      // The loop stopped itself: last sent velocity was still >= threshold,
      // and one more decay would fall below it.
      final lastV = h.scrolls.last.$2.abs() /
          (kMomentumTickMs * kScrollUnitPerPx);
      expect(lastV, greaterThanOrEqualTo(kMomentumStopVelocity));
      expect(lastV * kMomentumDecay, lessThan(kMomentumStopVelocity));
    });

    test('StopFlingIntent cancels the loop instantly — stale tick no-ops',
        () {
      final h = Harness();
      h.driver.handle(const [FlingIntent(0, 2.0)]);
      h.scheduler.runNext(); // tick 1 sends + reschedules
      h.scheduler.runNext(); // tick 2 sends + reschedules
      final sentBefore = h.scrolls.length;
      expect(sentBefore, 2);

      h.driver.handle(const [StopFlingIntent()]);
      h.scheduler.drain();
      expect(h.scrolls, hasLength(sentBefore),
          reason: 'zero further sends after StopFlingIntent');
    });

    test('a new FlingIntent supersedes the previous loop (single chain)', () {
      final h = Harness();
      h.driver.handle(const [FlingIntent(0, 2.0)]);
      h.scheduler.runNext();
      h.driver.handle(const [FlingIntent(4.0, 0)]);
      // The stale chain's pending tick no-ops; only the new chain sends.
      h.scheduler.drain();
      final xSends = h.scrolls.where((s) => s.$1 != 0).length;
      final ySendsAfterRestart =
          h.scrolls.skip(1).where((s) => s.$2 != 0).length;
      expect(xSends, greaterThan(0));
      expect(ySendsAfterRestart, 0,
          reason: 'the y-fling chain died when the x-fling superseded it');
    });
  });

  group('TrackpadDriver — long-press timer (PAD-04)', () {
    test('ArmLongPressIntent schedules a one-shot of delayMs that fires '
        'onLongPressElapsed', () {
      final h = Harness();
      h.driver.handle(const [ArmLongPressIntent(kLongPressMs)]);
      expect(h.scheduler.tasks, hasLength(1));
      expect(h.scheduler.tasks.single.$1,
          const Duration(milliseconds: kLongPressMs));
      h.scheduler.runNext();
      expect(h.longPressElapsed, 1);
    });

    test('DisarmLongPressIntent invalidates the pending one-shot '
        '(generation guard — stale fire is a no-op)', () {
      final h = Harness();
      h.driver.handle(const [ArmLongPressIntent(kLongPressMs)]);
      h.driver.handle(const [DisarmLongPressIntent()]);
      h.scheduler.drain();
      expect(h.longPressElapsed, 0);
    });

    test('re-arm supersedes the previous arm (only the newest fires)', () {
      final h = Harness();
      h.driver.handle(const [ArmLongPressIntent(kLongPressMs)]);
      h.driver.handle(const [DisarmLongPressIntent()]);
      h.driver.handle(const [ArmLongPressIntent(kLongPressMs)]);
      h.scheduler.drain();
      expect(h.longPressElapsed, 1,
          reason: 'the stale one-shot no-ops; the live one fires once');
    });
  });

  group('TrackpadDriver — drag lock (PAD-04, D-04)', () {
    test('DragStartIntent -> DragMsg(start, left) + lock(true) + haptic', () {
      final h = Harness();
      h.driver.handle(const [DragStartIntent()]);
      final msg = h.reliable.single as DragMsg;
      expect(msg.action, 'start');
      expect(msg.button, 'left');
      expect(h.dragLock, [true]);
      expect(h.haptics, 1);
    });

    test('DragEndIntent -> DragMsg(end, left) + lock(false)', () {
      final h = Harness();
      h.driver.handle(const [DragStartIntent()]);
      h.driver.handle(const [DragEndIntent()]);
      expect(h.reliable, hasLength(2));
      final msg = h.reliable.last as DragMsg;
      expect(msg.action, 'end');
      expect(msg.button, 'left');
      expect(h.dragLock, [true, false]);
    });
  });

  group('TrackpadDriver — ZoomIntent (SPEC section 9 opcode 0x03)', () {
    test('sends dx 0.0 (reserved) and dy = dz * kZoomUnitPerPx', () {
      final h = Harness();
      h.driver.handle(const [ZoomIntent(20)]);
      expect(h.zooms, [(0.0, 20 * kZoomUnitPerPx)]);
      expect(h.scrolls, isEmpty, reason: 'zoom never rides the scroll seam');
      expect(h.haptics, 0, reason: 'zoom does not tick haptics');
    });

    test('a negative dz stays negative (zoom out)', () {
      final h = Harness();
      h.driver.handle(const [ZoomIntent(-7)]);
      expect(h.zooms, [(0.0, -7 * kZoomUnitPerPx)]);
    });

    test('scrollReversed flips SCROLL but leaves ZOOM untouched (D-11 is a '
        'scroll preference; pinch-apart is always zoom-in)', () {
      final natural = Harness()..scrollReversed = false;
      natural.driver.handle(const [ScrollIntent(0, 10), ZoomIntent(10)]);

      final reversed = Harness()..scrollReversed = true;
      reversed.driver.handle(const [ScrollIntent(0, 10), ZoomIntent(10)]);

      expect(reversed.scrolls.single.$2, -natural.scrolls.single.$2,
          reason: 'the scroll sign gate still works');
      expect(reversed.zooms, natural.zooms,
          reason: 'zoom is identical under both settings');
    });

    test('zoom schedules nothing — a pinch has no momentum', () {
      final h = Harness();
      h.driver.handle(const [ZoomIntent(50)]);
      expect(h.scheduler.tasks, isEmpty,
          reason: 'no fling loop, no timer, nothing to cancel');
    });
  });

  group('TrackpadDriver — reset() (disconnect hygiene)', () {
    test('clears drag-lock, cancels momentum + long-press, resets the '
        'classifier via the onReset hook', () {
      var classifierResets = 0;
      final h = Harness();
      final driver = TrackpadDriver(
        onSendMove: (dx, dy) => h.moves.add((dx, dy)),
        onSendScroll: (dx, dy) => h.scrolls.add((dx, dy)),
        onSendZoom: (dx, dy) => h.zooms.add((dx, dy)),
        onSendReliable: h.reliable.add,
        onHaptic: () => h.haptics++,
        onDragLockChanged: h.dragLock.add,
        onLongPressElapsed: () => h.longPressElapsed++,
        sensitivity: () => 1.0,
        schedule: h.scheduler.call,
        onReset: () => classifierResets++,
      );

      driver.handle(const [DragStartIntent()]);
      driver.handle(const [FlingIntent(0, 2.0)]);
      driver.handle(const [ArmLongPressIntent(kLongPressMs)]);
      final scrollsBefore = h.scrolls.length;

      driver.reset();

      expect(h.dragLock, [true, false],
          reason: 'reset drops the pill — no phantom drag survives');
      expect(classifierResets, 1);
      // Pending scheduled callbacks are all stale now.
      h.scheduler.drain();
      expect(h.scrolls, hasLength(scrollsBefore));
      expect(h.longPressElapsed, 0);
      // reset never SENDS anything — the server side is CONN-07 release_all.
      expect(h.reliable.whereType<DragMsg>().where((m) => m.action == 'end'),
          isEmpty);
    });

    test('reset with no drag lock engaged emits no lock notification', () {
      final h = Harness();
      h.driver.reset();
      expect(h.dragLock, isEmpty);
    });
  });

  group('TrackpadDriver — dispose()', () {
    test('cancels momentum and pending long-press; nothing fires after', () {
      final h = Harness();
      h.driver.handle(const [FlingIntent(0, 2.0)]);
      h.driver.handle(const [ArmLongPressIntent(kLongPressMs)]);
      h.driver.dispose();
      h.scheduler.drain();
      expect(h.scrolls, isEmpty);
      expect(h.longPressElapsed, 0);
    });

    test('handle() after dispose is a no-op', () {
      final h = Harness();
      h.driver.dispose();
      h.driver.handle(const [
        MoveIntent(5, 5),
        ClickLeftIntent(),
        ScrollIntent(0, 5),
      ]);
      expect(h.moves, isEmpty);
      expect(h.reliable, isEmpty);
      expect(h.scrolls, isEmpty);
      expect(h.haptics, 0);
    });
  });
}
