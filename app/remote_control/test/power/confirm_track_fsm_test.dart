/// ConfirmTrackFsm unit tests (05-06 Task 1, PWR-01..03, D-05/D-06).
///
/// The slide-to-confirm safety contract (T-05-12 — the no-single-action-path
/// invariant) proven at the FSM level, IO-free and deterministic:
///
/// - A power action fires ONLY from a completed slide (progress ≥ 0.9 at
///   dragEnd). Below threshold → [SpringBack], nothing sent (D-05/D-06).
/// - Lock / Sleep completion = ONE gesture, TWO wire effects in strict order:
///   [SendPower(action), SendConfirm(action)] (D-05).
/// - Restart / Shut down completion = [SendPower(action), OpenCountdown(action)]
///   — NO SendConfirm anywhere in the FSM for those actions; the dialog button
///   (in the screen) is the sole confirm sender (D-06, PWR-03).
///
/// The FSM is pure Dart: effects are plain sealed classes carrying the action
/// string; the screen maps them onto PowerMsg/ConfirmMsg. No Flutter, no
/// timers, no wire types here.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/power/confirm_track_fsm.dart';

/// A completed slide: start, drag to (or past) the threshold, release.
List<ConfirmTrackEffect> _completeSlide(ConfirmTrackFsm fsm) {
  fsm.dragStart();
  fsm.dragUpdate(1.0);
  return fsm.dragEnd();
}

void main() {
  group('lock/sleep (safe pair) — one gesture, two wire effects (D-05)', () {
    for (final action in ['lock', 'sleep']) {
      test('$action completion → [SendPower, SendConfirm] in that order', () {
        final fsm = ConfirmTrackFsm(action: action);
        expect(fsm.state, ConfirmTrackState.idle);

        final effects = _completeSlide(fsm);

        expect(effects, hasLength(2));
        expect(effects[0], isA<SendPower>());
        expect(effects[1], isA<SendConfirm>());
        expect((effects[0] as SendPower).action, action);
        expect((effects[1] as SendConfirm).action, action);
        expect(fsm.state, ConfirmTrackState.completed);

        // No countdown for the safe pair.
        expect(effects.whereType<OpenCountdown>(), isEmpty);
      });
    }
  });

  group('restart/shutdown (destructive pair) — power + dialog only (D-06)', () {
    for (final action in ['restart', 'shutdown']) {
      test('$action completion → [SendPower, OpenCountdown], NO SendConfirm',
          () {
        final fsm = ConfirmTrackFsm(action: action);

        final effects = _completeSlide(fsm);

        expect(effects, hasLength(2));
        expect(effects[0], isA<SendPower>());
        expect(effects[1], isA<OpenCountdown>());
        expect((effects[0] as SendPower).action, action);
        expect((effects[1] as OpenCountdown).action, action);
        expect(fsm.state, ConfirmTrackState.completed);

        // T-05-12 / PWR-03: the FSM NEVER yields a confirm for the
        // destructive pair — the dialog button owns that send.
        expect(effects.whereType<SendConfirm>(), isEmpty,
            reason: 'restart/shutdown must never auto-confirm — the countdown '
                'dialog button is the only confirm sender (D-06)');
      });
    }
  });

  group('SendPower strictly precedes the second effect (order invariant)', () {
    for (final action in ['lock', 'sleep', 'restart', 'shutdown']) {
      test('$action: effect[0] is always SendPower', () {
        final fsm = ConfirmTrackFsm(action: action);
        final effects = _completeSlide(fsm);
        expect(effects.first, isA<SendPower>(),
            reason: 'power always fires before confirm/countdown');
      });
    }
  });

  group('early release springs back — nothing sent (T-05-13)', () {
    for (final progress in [0.0, 0.5, 0.89]) {
      test('release at $progress → [SpringBack], no send effects, idle', () {
        final fsm = ConfirmTrackFsm(action: 'shutdown');
        fsm.dragStart();
        fsm.dragUpdate(progress);
        final effects = fsm.dragEnd();

        expect(effects, hasLength(1));
        expect(effects.single, isA<SpringBack>());
        expect(effects.whereType<SendPower>(), isEmpty);
        expect(effects.whereType<SendConfirm>(), isEmpty);
        expect(effects.whereType<OpenCountdown>(), isEmpty);
        expect(fsm.state, ConfirmTrackState.idle);
      });
    }
  });

  test('exactly 0.9 is a completion (threshold is inclusive)', () {
    final fsm = ConfirmTrackFsm(action: 'lock');
    fsm.dragStart();
    fsm.dragUpdate(0.9);
    final effects = fsm.dragEnd();
    expect(effects, hasLength(2));
    expect(effects.first, isA<SendPower>());
  });

  test('dragUpdate clamps progress into 0.0..1.0', () {
    final fsm = ConfirmTrackFsm(action: 'lock');
    fsm.dragStart();

    fsm.dragUpdate(1.5);
    expect(fsm.progress, 1.0, reason: 'above 1.0 clamps to 1.0');

    fsm.dragUpdate(-0.3);
    expect(fsm.progress, 0.0, reason: 'below 0.0 clamps to 0.0');
  });

  test('dragUpdate without dragStart is a no-op (stays idle, progress 0)', () {
    final fsm = ConfirmTrackFsm(action: 'sleep');
    fsm.dragUpdate(0.95);
    expect(fsm.state, ConfirmTrackState.idle);
    expect(fsm.progress, 0.0);
  });

  test('dragEnd without an active drag yields no effects', () {
    final fsm = ConfirmTrackFsm(action: 'sleep');
    expect(fsm.dragEnd(), isEmpty);
    expect(fsm.state, ConfirmTrackState.idle);
  });

  test('dragStart while completed begins a fresh drag (completed-resetting)',
      () {
    final fsm = ConfirmTrackFsm(action: 'lock');
    _completeSlide(fsm);
    expect(fsm.state, ConfirmTrackState.completed);

    fsm.dragStart();
    expect(fsm.state, ConfirmTrackState.dragging);
    expect(fsm.progress, 0.0, reason: 'a fresh gesture starts at 0');
  });

  test('progress is exposed while dragging and tracks dragUpdate', () {
    final fsm = ConfirmTrackFsm(action: 'restart');
    fsm.dragStart();
    fsm.dragUpdate(0.42);
    expect(fsm.state, ConfirmTrackState.dragging);
    expect(fsm.progress, closeTo(0.42, 1e-9));
  });

  test('isDestructive is derived from the action (safe vs two-stage pair)', () {
    expect(ConfirmTrackFsm(action: 'lock').isDestructive, isFalse);
    expect(ConfirmTrackFsm(action: 'sleep').isDestructive, isFalse);
    expect(ConfirmTrackFsm(action: 'restart').isDestructive, isTrue);
    expect(ConfirmTrackFsm(action: 'shutdown').isDestructive, isTrue);
  });
}
