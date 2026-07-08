// Task 1 (TDD) — pure reconnect FSM policy-table coverage (D-04/D-05/D-06).
//
// The FSM under test owns the CONNECTION LIFECYCLE only: dial, backoff,
// auth-stop, short-circuits. It composes with HandshakeFsm (which keeps
// owning hello/challenge/pin/auth) and must never duplicate those states.
// The locked policy table (03-RESEARCH Pattern 6):
// - transport failures retry: backoff 1/2/4/8s, cap 10s (design spec §8),
//   ±20% jitter — deterministic here via an injected `random` closure;
// - auth failures NEVER retry (D-05): noPairing/badMac clear the token and
//   land in needPairing with the exact explanation copy;
// - app resume / "Retry now" / a beacon sighting of the target device
//   short-circuit backoff into an immediate dial (D-06).
//
// No IO here: no dart:io, no timers, no sockets — timers are driver effects
// (StartBackoffEffect) executed by ConnectionService in plan 03-05.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/reconnect_fsm.dart';

void main() {
  // Fixed target so every assertion is deterministic.
  const target = DeviceTarget(
    key: 'guid-1',
    name: 'OMKAR-LAPTOP',
    host: '192.168.1.7',
    port: 17777,
  );

  // Jitter factor is 0.8 + 0.4 * random(); random 0.5 makes it exactly 1.0.
  ReconnectFsm freshFsm({double Function()? random}) =>
      ReconnectFsm(random: random ?? () => 0.5);

  ReconnectFsm connectingFsm({double Function()? random}) {
    final fsm = freshFsm(random: random);
    fsm.connectRequested(target);
    return fsm;
  }

  ReconnectFsm handshakingFsm({double Function()? random}) {
    final fsm = connectingFsm(random: random);
    fsm.socketConnected();
    return fsm;
  }

  ReconnectFsm authedFsm({double Function()? random}) {
    final fsm = handshakingFsm(random: random);
    fsm.authedOk();
    return fsm;
  }

  ReconnectFsm backoffFsm({double Function()? random}) {
    final fsm = connectingFsm(random: random);
    fsm.transportFailed();
    return fsm;
  }

  group('ReconnectFsm — connect', () {
    test('connectRequested from idle dials the target', () {
      final fsm = freshFsm();
      final step = fsm.connectRequested(target);

      expect(fsm.state, ReconnectState.connecting);
      expect(step.effects.whereType<DialEffect>().single.target, target,
          reason: 'the driver dials via connectNoDelay (existing path)');
    });

    test('socketConnected moves to handshaking (HandshakeFsm takes over)', () {
      final fsm = connectingFsm();
      fsm.socketConnected();

      expect(fsm.state, ReconnectState.handshaking,
          reason: 'composition: hello/pin/auth live in HandshakeFsm, '
              'never duplicated here');
    });

    test('authedOk lands in authed and resets the attempt counter', () {
      final fsm = connectingFsm();
      fsm.transportFailed(); // attempt -> 1
      fsm.backoffElapsed(); // redial
      fsm.socketConnected();
      final step = fsm.authedOk();

      expect(fsm.state, ReconnectState.authed);
      expect(fsm.attempt, 0,
          reason: 'a successful auth resets the failure count');
      expect(step.effects.whereType<StartBackoffEffect>(), isEmpty);
    });
  });

  group('ReconnectFsm — backoff (D-06 retry, spec §8 cap)', () {
    test('delays follow 1, 2, 4, 8s then cap at 10s for attempts 1..6+', () {
      final fsm = connectingFsm(random: () => 0.5); // jitter factor 1.0
      final delays = <Duration>[];

      for (var i = 0; i < 6; i++) {
        final step = fsm.transportFailed();
        expect(fsm.state, ReconnectState.backoff);
        final backoff = step.effects.whereType<StartBackoffEffect>().single;
        expect(backoff.attempt, i + 1,
            reason: 'attempt counter increments per consecutive failure');
        delays.add(backoff.delay);
        fsm.backoffElapsed(); // back to connecting for the next failure
      }

      expect(
        delays,
        const [
          Duration(seconds: 1),
          Duration(seconds: 2),
          Duration(seconds: 4),
          Duration(seconds: 8),
          Duration(seconds: 10),
          Duration(seconds: 10),
        ],
        reason: 'design spec §8 cap of 10s wins over D-06\'s '
            'discretionary ~30s (03-RESEARCH Pattern 6)',
      );
    });

    test('random 0.0 gives 0.8x base delay (lower jitter bound, D-06)', () {
      final fsm = connectingFsm(random: () => 0.0);
      final step = fsm.transportFailed();

      final backoff = step.effects.whereType<StartBackoffEffect>().single;
      expect(backoff.delay, const Duration(milliseconds: 800),
          reason: 'jitter factor 0.8 + 0.4*random = 0.8 at the low end');
    });

    test('random 1.0 gives 1.2x base delay (upper jitter bound, D-06)', () {
      final fsm = connectingFsm(random: () => 1.0);
      final step = fsm.transportFailed();

      final backoff = step.effects.whereType<StartBackoffEffect>().single;
      expect(backoff.delay, const Duration(milliseconds: 1200),
          reason: 'jitter factor 0.8 + 0.4*random = 1.2 at the high end');
    });

    test('transportFailed from handshaking enters backoff', () {
      final fsm = handshakingFsm();
      final step = fsm.transportFailed();

      expect(fsm.state, ReconnectState.backoff);
      expect(step.effects.whereType<StartBackoffEffect>(), hasLength(1));
    });

    test('transportFailed from authed enters backoff (dead connection)', () {
      final fsm = authedFsm();
      final step = fsm.transportFailed();

      expect(fsm.state, ReconnectState.backoff,
          reason: 'D-04: drops are non-blocking — silent retry starts');
      expect(step.effects.whereType<StartBackoffEffect>(), hasLength(1));
    });

    test('backoffElapsed redials the same target', () {
      final fsm = backoffFsm();
      final step = fsm.backoffElapsed();

      expect(fsm.state, ReconnectState.connecting);
      final dial = step.effects.whereType<DialEffect>().single;
      expect(dial.target.host, '192.168.1.7',
          reason: 'redial uses the last-known ip:port');
      expect(dial.target.key, 'guid-1');
    });
  });

  group('ReconnectFsm — short-circuits (D-06)', () {
    test('appResumed in backoff resets attempts and dials immediately', () {
      final fsm = backoffFsm();
      final step = fsm.appResumed();

      expect(fsm.state, ReconnectState.connecting);
      expect(fsm.attempt, 0, reason: 'D-06: app resume resets the counter');
      expect(step.effects.whereType<DialEffect>().single.target.key, 'guid-1');
    });

    test('retryNowPressed in backoff resets attempts and dials immediately',
        () {
      final fsm = backoffFsm();
      final step = fsm.retryNowPressed();

      expect(fsm.state, ReconnectState.connecting);
      expect(fsm.attempt, 0,
          reason: 'D-04: manual "Retry now" affordance short-circuits');
      expect(step.effects.whereType<DialEffect>(), hasLength(1));
    });

    test('beaconSighted with the target guid updates host/port and dials', () {
      final fsm = backoffFsm();
      final step = fsm.beaconSighted('guid-1', '192.168.1.42', 17800);

      expect(fsm.state, ReconnectState.connecting);
      expect(fsm.target!.host, '192.168.1.42',
          reason: 'D-06: beacon sighting handles PC IP changes');
      expect(fsm.target!.port, 17800);
      expect(fsm.target!.key, 'guid-1', reason: 'identity is unchanged');
      expect(fsm.attempt, 0, reason: 'a sighting is a fresh start');
      final dial = step.effects.whereType<DialEffect>().single;
      expect(dial.target.host, '192.168.1.42');
      expect(dial.target.port, 17800);
    });

    test('beaconSighted with a non-matching guid is ignored', () {
      final fsm = backoffFsm();
      final step = fsm.beaconSighted('guid-other', '10.0.0.99', 9999);

      expect(step, same(ReconnectStep.none),
          reason: 'T-03-06: only the current target\'s beacon may '
              'redirect a dial');
      expect(fsm.state, ReconnectState.backoff);
      expect(fsm.target!.host, '192.168.1.7',
          reason: 'a foreign beacon never touches the target');
    });
  });

  group('ReconnectFsm — auth-stop (D-05: auth failures NEVER retry)', () {
    for (final reason in ['noPairing', 'badMac']) {
      test('authRejected($reason) clears the token and lands in needPairing',
          () {
        final fsm = handshakingFsm();
        final step = fsm.authRejected(reason);

        expect(fsm.state, ReconnectState.needPairing);
        expect(
            step.effects.whereType<ClearTokenEffect>().single.deviceKey,
            'guid-1',
            reason: 'D-05: revoked/stale token is deleted — no zombie auth');
        final stop = step.effects.whereType<AuthStopEffect>().single;
        expect(stop.reason, reason);
        expect(step.effects.whereType<CloseEffect>(), hasLength(1));
        expect(step.effects.whereType<StartBackoffEffect>(), isEmpty,
            reason: 'D-05: no silent retry loop on auth failures');
        expect(fsm.explanation, kRevokedExplanation,
            reason: 'the exact D-05 copy is carried into needPairing');
      });
    }

    test('NO authRejected reason ever schedules a retry (T-03-05)', () {
      const reasons = [
        'noPairing',
        'badMac',
        'pinInvalid',
        'pinExpired',
        'lockedOut',
        'versionMismatch',
      ];
      for (final reason in reasons) {
        final fsm = handshakingFsm();
        final step = fsm.authRejected(reason);
        expect(step.effects.whereType<StartBackoffEffect>(), isEmpty,
            reason: 'T-03-05: retrying $reason would hammer the server\'s '
                'global lockout counter');
        expect(fsm.state, ReconnectState.needPairing,
            reason: '$reason terminates silent retry (D-05)');
      }
    });

    test('pinInvalid carries attemptsRemaining and keeps the token', () {
      final fsm = handshakingFsm();
      final step = fsm.authRejected('pinInvalid', attemptsRemaining: 3);

      expect(fsm.state, ReconnectState.needPairing);
      final stop = step.effects.whereType<AuthStopEffect>().single;
      expect(stop.reason, 'pinInvalid');
      expect(stop.attemptsRemaining, 3,
          reason: 'SPEC 5 extras surface to the pairing UI');
      expect(step.effects.whereType<ClearTokenEffect>(), isEmpty,
          reason: 'only noPairing/badMac mean a revoked token');
    });

    test('lockedOut carries retryAfterSecs', () {
      final fsm = handshakingFsm();
      final step = fsm.authRejected('lockedOut', retryAfterSecs: 240);

      expect(fsm.state, ReconnectState.needPairing);
      final stop = step.effects.whereType<AuthStopEffect>().single;
      expect(stop.reason, 'lockedOut');
      expect(stop.retryAfterSecs, 240,
          reason: 'user-driven retry only, after the lockout window');
    });

    test('versionMismatch stops without clearing the token', () {
      final fsm = handshakingFsm();
      final step = fsm.authRejected('versionMismatch');

      expect(fsm.state, ReconnectState.needPairing);
      expect(step.effects.whereType<ClearTokenEffect>(), isEmpty,
          reason: 'a version skew is not a revoked pairing');
      expect(step.effects.whereType<StartBackoffEffect>(), isEmpty,
          reason: 'D-05/D-06: reject-by-default, no retry');
      expect(
          step.effects.whereType<AuthStopEffect>().single.reason,
          'versionMismatch');
    });

    test('kRevokedExplanation is the exact D-05 copy', () {
      expect(kRevokedExplanation,
          'This PC no longer recognizes this phone — pair again');
    });
  });

  group('ReconnectFsm — stray inputs (never throw)', () {
    test('backoffElapsed in idle is ignored', () {
      final fsm = freshFsm();
      final step = fsm.backoffElapsed();

      expect(step, same(ReconnectStep.none),
          reason: 'stray-input discipline copied from HandshakeFsm');
      expect(fsm.state, ReconnectState.idle);
    });

    test('transportFailed in needPairing is ignored (auth-stop is sticky)',
        () {
      final fsm = handshakingFsm();
      fsm.authRejected('badMac');

      final step = fsm.transportFailed();

      expect(step, same(ReconnectStep.none),
          reason: 'D-05: nothing restarts retry after an auth-stop except '
              'the user');
      expect(fsm.state, ReconnectState.needPairing);
    });

    test('authedOk in idle is ignored', () {
      final fsm = freshFsm();
      final step = fsm.authedOk();

      expect(step, same(ReconnectStep.none));
      expect(fsm.state, ReconnectState.idle);
    });
  });

  group('ReconnectFsm — disconnect', () {
    test('disconnectRequested from authed closes and returns to idle', () {
      final fsm = authedFsm();
      final step = fsm.disconnectRequested();

      expect(fsm.state, ReconnectState.idle);
      expect(step.effects.whereType<CloseEffect>(), hasLength(1));
      expect(step.effects.whereType<StartBackoffEffect>(), isEmpty,
          reason: 'a user-requested disconnect never triggers retry');
    });
  });
}
