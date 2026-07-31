// Task 1 (TDD, Wave 0) — GestureClassifier: the pure IO-free gesture FSM
// (D-04) that turns raw pointer events into GestureIntent lists, proven
// deterministic without a device (reconnect_fsm/handshake_fsm house style).
//
// Covers: single-finger move + tap = left click (PAD-02), two-finger tap =
// right click vs. two-finger scroll disambiguation (PAD-02/03, Pitfall 4),
// fling seeding + instant touch-stop (PAD-03), long-press drag with
// drag-lock and tap-to-drop (PAD-04), and reset/cancel hygiene (D-12-adjacent).
//
// Every threshold referenced here comes from tuning.dart (D-06) — the tests
// stay valid when the on-device feel gate retunes the constants.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/trackpad/gesture_classifier.dart';
import 'package:remote_control/trackpad/tuning.dart';

/// Mutable test clock injected via the `nowMillis` seam (house idiom).
class TestClock {
  int now = 0;
}

(GestureClassifier, TestClock) make() {
  final clock = TestClock();
  return (GestureClassifier(nowMillis: () => clock.now), clock);
}

void main() {
  group('GestureClassifier — tap = left click (PAD-02)', () {
    test('single down emits StopFling FIRST then ArmLongPress(kLongPressMs)',
        () {
      final (c, _) = make();
      final intents = c.onPointerDown(1, 100, 100);
      expect(intents, const [
        StopFlingIntent(),
        ArmLongPressIntent(kLongPressMs),
      ]);
    });

    test('up within kTapMaxMs and under slop -> DisarmLongPress + ClickLeft',
        () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = kTapMaxMs - 50;
      final intents = c.onPointerUp(1);
      expect(intents, const [DisarmLongPressIntent(), ClickLeftIntent()]);
    });

    test('up after kTapMaxMs -> disarm only, NO click', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = kTapMaxMs + 40;
      final intents = c.onPointerUp(1);
      expect(intents, const [DisarmLongPressIntent()],
          reason: 'a slow press is not a tap');
    });
  });

  group('GestureClassifier — single-finger move (PAD-01 logic half)', () {
    test('moves under slop emit nothing (tap still pending)', () {
      final (c, _) = make();
      c.onPointerDown(1, 100, 100);
      final intents = c.onPointerMove(1, 100 + kTapSlopPx / 2, 100);
      expect(intents, isEmpty);
    });

    test('move beyond slop disarms ONCE then streams raw deltas; no click on '
        'up', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);

      final first = c.onPointerMove(1, 120, 100); // travel 20 > slop 10
      expect(first, const [DisarmLongPressIntent(), MoveIntent(20, 0)]);

      final second = c.onPointerMove(1, 125, 103);
      expect(second, const [MoveIntent(5, 3)],
          reason: 'disarm is emitted exactly once, deltas stay raw');

      clock.now = 50;
      expect(c.onPointerUp(1), isEmpty,
          reason: 'a move episode never ends in a click');
    });
  });

  group('GestureClassifier — two-finger tap = right click (PAD-02)', () {
    test('both up within window, under slop -> exactly one ClickRight', () {
      final (c, clock) = make();
      final all = <GestureIntent>[];
      all.addAll(c.onPointerDown(1, 100, 100));
      clock.now = 20;
      all.addAll(c.onPointerDown(2, 140, 100));
      clock.now = 90;
      all.addAll(c.onPointerUp(1));
      clock.now = 110;
      all.addAll(c.onPointerUp(2));

      expect(all.whereType<ClickRightIntent>(), hasLength(1));
      expect(all.whereType<ClickLeftIntent>(), isEmpty);
      // Second down disarms the first finger's pending long-press.
      expect(all.whereType<DisarmLongPressIntent>(), hasLength(1));
    });

    test('both up but slower than kTwoFingerTapWindowMs -> no right click',
        () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = 20;
      c.onPointerDown(2, 140, 100);
      clock.now = kTwoFingerTapWindowMs + 60;
      final upA = c.onPointerUp(1);
      clock.now = kTwoFingerTapWindowMs + 80;
      final upB = c.onPointerUp(2);
      expect([...upA, ...upB].whereType<ClickRightIntent>(), isEmpty);
    });
  });

  group('GestureClassifier — two-finger scroll + fling (PAD-03)', () {
    test('movement beyond slop -> averaged ScrollIntents, NEVER ClickRight',
        () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = 10;
      c.onPointerDown(2, 140, 100);

      clock.now = 20;
      final first = c.onPointerMove(1, 100, 70); // dy -30, travel > slop
      expect(first, const [ScrollIntent(0, -15)],
          reason: 'scroll delta is the average of the two pointers\' deltas');

      clock.now = 30;
      expect(c.onPointerMove(1, 100, 60), const [ScrollIntent(0, -5)]);

      clock.now = 40;
      final upA = c.onPointerUp(1);
      clock.now = 500; // linger: recent-velocity window long gone
      final upB = c.onPointerUp(2);
      expect([...upA, ...upB].whereType<ClickRightIntent>(), isEmpty,
          reason: 'once scrolling, a right click can never fire (Pitfall 4)');
    });

    test('fast two-finger lift seeds FlingIntent from recent samples', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 200);
      clock.now = 10;
      c.onPointerDown(2, 140, 200);

      // Four fast upward swipes: raw dy -24 each -> scroll dy -12 each.
      var y = 200.0;
      for (final t in [20, 30, 40, 50]) {
        clock.now = t;
        y -= 24;
        c.onPointerMove(1, 100, y);
      }

      clock.now = 55;
      expect(c.onPointerUp(1), isEmpty);
      clock.now = 60;
      final intents = c.onPointerUp(2);
      // Samples at t=20..50 sum dy -48 over span 60-20=40ms -> vy = -1.2.
      expect(intents, const [FlingIntent(0, -1.2)]);
    });

    test('slow lift (stale samples) -> no fling', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 200);
      clock.now = 10;
      c.onPointerDown(2, 140, 200);
      clock.now = 20;
      c.onPointerMove(1, 100, 170); // engage scroll
      clock.now = 400;
      c.onPointerUp(1);
      clock.now = 20 + kVelocityWindowMs + 400; // way past the window
      final intents = c.onPointerUp(2);
      expect(intents.whereType<FlingIntent>(), isEmpty);
    });

    test('any new down emits StopFlingIntent FIRST (instant touch-stop)', () {
      final (c, clock) = make();
      // Run a full fling episode first.
      c.onPointerDown(1, 100, 200);
      c.onPointerDown(2, 140, 200);
      clock.now = 20;
      c.onPointerMove(1, 100, 150);
      clock.now = 30;
      c.onPointerUp(1);
      c.onPointerUp(2);

      clock.now = 200; // momentum could still be running in the driver
      final intents = c.onPointerDown(3, 100, 100);
      expect(intents.first, const StopFlingIntent(),
          reason: 'touch-stop must be the FIRST intent of every down');
    });
  });

  group('GestureClassifier — long-press drag with drag-lock (PAD-04)', () {
    test('held-still fire -> DragStart; moves stream; up keeps the lock; '
        'next tap -> DragEnd instead of ClickLeft', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = kLongPressMs;
      expect(c.onLongPressFire(), const [DragStartIntent()]);

      // Moves while dragging stream immediately (no slop re-gate).
      expect(c.onPointerMove(1, 105, 103), const [MoveIntent(5, 3)]);
      expect(c.onPointerMove(1, 107, 104), const [MoveIntent(2, 1)]);

      clock.now = kLongPressMs + 200;
      expect(c.onPointerUp(1), isEmpty,
          reason: 'drag-lock persists across the lift (screen-edge drags)');

      // Tap to drop: the NEXT single-finger tap ends the drag.
      clock.now = 1000;
      c.onPointerDown(1, 200, 200);
      clock.now = 1000 + kTapMaxMs - 80;
      final drop = c.onPointerUp(1);
      expect(drop, const [DisarmLongPressIntent(), DragEndIntent()]);
      expect(drop.whereType<ClickLeftIntent>(), isEmpty);
    });

    test('onLongPressFire after disarm (finger moved) is a no-op', () {
      final (c, _) = make();
      c.onPointerDown(1, 100, 100);
      c.onPointerMove(1, 130, 100); // beyond slop -> disarm
      expect(c.onLongPressFire(), isEmpty,
          reason: 'a stale driver timer must not start a drag');
    });
  });

  group('GestureClassifier — reset & cancel hygiene', () {
    test('reset() clears drag-lock and pointer state', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = kLongPressMs;
      c.onLongPressFire(); // drag-lock engaged
      c.onPointerUp(1);

      c.reset(); // driver calls this on disconnect (D-12-adjacent)

      clock.now = 2000;
      c.onPointerDown(1, 100, 100);
      clock.now = 2050;
      final intents = c.onPointerUp(1);
      expect(intents, const [DisarmLongPressIntent(), ClickLeftIntent()],
          reason: 'after reset a tap is a plain left click, not a drag drop');
    });

    test('reset() drops tracked pointers: later move/up emit nothing', () {
      final (c, _) = make();
      c.onPointerDown(1, 100, 100);
      c.reset();
      expect(c.onPointerMove(1, 130, 100), isEmpty);
      expect(c.onPointerUp(1), isEmpty);
    });

    test('cancel behaves like reset for that pointer: no click, fresh taps '
        'still work', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = 40;
      final cancelled = c.onPointerCancel(1);
      expect(cancelled.whereType<ClickLeftIntent>(), isEmpty);
      expect(cancelled.whereType<ClickRightIntent>(), isEmpty);

      clock.now = 100;
      c.onPointerDown(1, 100, 100);
      clock.now = 150;
      expect(c.onPointerUp(1),
          const [DisarmLongPressIntent(), ClickLeftIntent()]);
    });

    test('cancel of one of two fingers kills the right-click candidate', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = 20;
      c.onPointerDown(2, 140, 100);
      clock.now = 40;
      c.onPointerCancel(1);
      clock.now = 60;
      final intents = c.onPointerUp(2);
      expect(intents.whereType<ClickRightIntent>(), isEmpty);
    });

    test('third concurrent pointer is ignored (treated as the existing '
        'two-finger gesture)', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = 10;
      c.onPointerDown(2, 140, 100);
      clock.now = 15;
      expect(c.onPointerDown(3, 180, 100), const [StopFlingIntent()],
          reason: 'extras only touch-stop; they never arm or reclassify');
      clock.now = 20;
      expect(c.onPointerMove(3, 200, 100), isEmpty);
      // The original two fingers still classify as a two-finger tap.
      clock.now = 90;
      c.onPointerUp(1);
      clock.now = 110;
      final all = c.onPointerUp(2);
      expect(all.whereType<ClickRightIntent>(), hasLength(1));
    });
  });

  group('GestureClassifier — WR-04: post-lift scroll rate (PAD-03)', () {
    test(
        'WR-04: one finger lifts mid-scroll — remaining finger scrolls at '
        'FULL delta (no halving)', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 200);
      clock.now = 10;
      c.onPointerDown(2, 140, 200);

      clock.now = 20;
      expect(c.onPointerMove(1, 100, 170), const [ScrollIntent(0, -15)],
          reason: 'two fingers down: raw dy -30 averages to -15 (n=2) — '
              'byte-identical to the shipped 04-03 behavior');

      clock.now = 30;
      expect(c.onPointerUp(1), isEmpty,
          reason: 'one pointer remains — the phase stays scrolling');

      clock.now = 40;
      expect(c.onPointerMove(2, 140, 176), const [ScrollIntent(0, -24)],
          reason: 'n=1 after the lift: raw dy -24 passes at FULL rate '
              '(the halving bug emitted -12)');
    });

    test('WR-04: fling seeded after a one-finger lift uses full-rate samples',
        () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 200);
      clock.now = 10;
      c.onPointerDown(2, 140, 200);

      clock.now = 20;
      c.onPointerMove(1, 100, 170); // engage scrolling (sample -15 at t=20)

      clock.now = 25;
      expect(c.onPointerUp(1), isEmpty); // one finger remains

      // Four fast single-finger swipes starting past kVelocityWindowMs so
      // the two-finger t=20 sample prunes out of the fling window.
      var y = 200.0;
      for (final t in [200, 210, 220, 230]) {
        clock.now = t;
        y -= 24;
        c.onPointerMove(2, 140, y);
      }

      clock.now = 240;
      // In-window samples: 4 x (-24/1) = -96 over span 240-200 = 40ms ->
      // vy = -2.4 (>= kFlingMinVelocityPxMs) — exactly DOUBLE the -1.2 the
      // halving bug seeded from the same finger travel.
      expect(c.onPointerUp(2), const [FlingIntent(0, -2.4)]);
    });

    test(
        'WR-04: tapPending2 with one finger left — slop-crossing move emits '
        'FULL delta', () {
      final (c, clock) = make();
      c.onPointerDown(1, 100, 100);
      clock.now = 10;
      c.onPointerDown(2, 140, 100);

      clock.now = 20;
      expect(c.onPointerUp(1), isEmpty,
          reason: 'tapPending2 persists — one pointer left, no slop crossed');

      clock.now = 30;
      expect(c.onPointerMove(2, 140, 70), const [ScrollIntent(0, -30)],
          reason: 'raw dy -30 flips tapPending2 -> scrolling with n=1: '
              'FULL -30 (the bug emitted -15)');
    });
  });

  group('GestureClassifier — pinch zoom (SPEC section 9 opcode 0x03)', () {
    /// Lands two fingers 40px apart on the x-axis: 1@(100,100), 2@(140,100).
    /// Distance 40, midpoint (120,100). Nothing is classified yet.
    GestureClassifier twoDown(GestureClassifier c) {
      c.onPointerDown(1, 100, 100);
      c.onPointerDown(2, 140, 100);
      return c;
    }

    test('symmetric spread past slop classifies as pinch and emits ZoomIntent',
        () {
      final (c, _) = make();
      twoDown(c);
      // Four 3px steps, alternating fingers, moving apart. Each step adds 3
      // to spread and 1.5 to translation, so the ratio sits at 2.0 — clear of
      // kPinchDominanceRatio — while combinedTravel climbs 3, 6, 9, 12.
      expect(c.onPointerMove(1, 97, 100), isEmpty, reason: 'travel 3 <= slop');
      expect(c.onPointerMove(2, 143, 100), isEmpty, reason: 'travel 6 <= slop');
      expect(c.onPointerMove(1, 94, 100), isEmpty, reason: 'travel 9 <= slop');

      final intents = c.onPointerMove(2, 146, 100);
      expect(intents, const [ZoomIntent(3)],
          reason: 'travel 12 crosses slop; spread 12 beats 1.5 x trans 6');
    });

    test('fingers together give a NEGATIVE dz (zoom out)', () {
      final (c, _) = make();
      twoDown(c);
      // Same shape, converging: each step shrinks the separation by 3.
      c.onPointerMove(1, 103, 100);
      c.onPointerMove(2, 137, 100);
      c.onPointerMove(1, 106, 100);
      final intents = c.onPointerMove(2, 134, 100);
      expect(intents, const [ZoomIntent(-3)],
          reason: 'converging fingers zoom out');
    });

    test('pinch LOCKS: translating both fingers afterwards still zooms, '
        'never scrolls', () {
      final (c, _) = make();
      twoDown(c);
      c.onPointerMove(1, 97, 100);
      c.onPointerMove(2, 143, 100);
      c.onPointerMove(1, 94, 100);
      expect(c.onPointerMove(2, 146, 100), const [ZoomIntent(3)]);

      // Now drag both fingers down together — pure translation, which in a
      // fresh episode would classify as a scroll.
      final a = c.onPointerMove(1, 94, 140);
      final b = c.onPointerMove(2, 146, 140);
      for (final intents in [a, b]) {
        expect(intents.whereType<ScrollIntent>(), isEmpty,
            reason: 'a locked pinch can never emit a scroll');
        expect(intents.every((i) => i is ZoomIntent), isTrue,
            reason: 'still pinching');
      }
    });

    test('scroll LOCKS: spreading the fingers afterwards still scrolls, '
        'never zooms', () {
      final (c, _) = make();
      twoDown(c);
      // Both fingers translate down together: translation dominates, spread
      // stays near zero, so the slop crossing picks scroll.
      c.onPointerMove(1, 100, 90);
      expect(c.onPointerMove(2, 140, 90), isA<List<GestureIntent>>());
      final crossing = c.onPointerMove(1, 100, 80);
      expect(crossing.whereType<ScrollIntent>(), isNotEmpty,
          reason: 'translation-dominated episode classifies as scroll');

      // Now pull them apart — a fresh episode would zoom.
      final a = c.onPointerMove(1, 60, 80);
      final b = c.onPointerMove(2, 180, 80);
      for (final intents in [a, b]) {
        expect(intents.whereType<ZoomIntent>(), isEmpty,
            reason: 'a locked scroll can never emit a zoom');
      }
    });

    test('rotation about the midpoint scrolls — it must not zoom', () {
      final (c, _) = make();
      twoDown(c);
      // Counter-rotating the two fingers barely changes their separation, so
      // the spread signal never dominates and the episode is not a pinch.
      final a = c.onPointerMove(1, 100, 88);
      final b = c.onPointerMove(2, 140, 112);
      for (final intents in [a, b]) {
        expect(intents.whereType<ZoomIntent>(), isEmpty,
            reason: 'rotation is not a pinch');
      }
    });

    test('two-finger TAP still fires exactly one right click (regression)', () {
      final (c, clock) = make();
      twoDown(c);
      clock.now = kTwoFingerTapWindowMs - 50;
      c.onPointerUp(1);
      expect(c.onPointerUp(2), const [ClickRightIntent()],
          reason: 'under slop no pinch decision is ever reached');
    });

    test('one finger lifting mid-pinch goes quiet — no phantom zoom', () {
      final (c, _) = make();
      twoDown(c);
      c.onPointerMove(1, 97, 100);
      c.onPointerMove(2, 143, 100);
      c.onPointerMove(1, 94, 100);
      expect(c.onPointerMove(2, 146, 100), const [ZoomIntent(3)]);

      expect(c.onPointerUp(1), isEmpty, reason: 'a lift emits nothing');
      expect(c.onPointerMove(2, 200, 100), isEmpty,
          reason: 'one finger cannot define a separation — pinch goes quiet '
              '(deliberately asymmetric with WR-04 scroll behaviour)');
    });

    test('a pinch NEVER seeds a fling, however fast the fingers leave', () {
      final (c, clock) = make();
      twoDown(c);
      clock.now = 10;
      c.onPointerMove(1, 97, 100);
      clock.now = 20;
      c.onPointerMove(2, 143, 100);
      clock.now = 30;
      c.onPointerMove(1, 94, 100);
      clock.now = 40;
      expect(c.onPointerMove(2, 146, 100), const [ZoomIntent(3)]);

      clock.now = 45;
      c.onPointerUp(1);
      expect(c.onPointerUp(2), isEmpty,
          reason: 'zoom has no momentum — _flingFrom is never consulted');
    });

    test('reset() mid-pinch lets the next episode classify from scratch', () {
      final (c, _) = make();
      twoDown(c);
      c.onPointerMove(1, 97, 100);
      c.onPointerMove(2, 143, 100);
      c.onPointerMove(1, 94, 100);
      expect(c.onPointerMove(2, 146, 100), const [ZoomIntent(3)]);

      c.reset();

      // A fresh translation-dominated episode must be free to pick scroll.
      twoDown(c);
      c.onPointerMove(1, 100, 90);
      c.onPointerMove(2, 140, 90);
      final crossing = c.onPointerMove(1, 100, 80);
      expect(crossing.whereType<ScrollIntent>(), isNotEmpty,
          reason: 'stale pinch state would have kept this episode zooming');
    });
  });
}
