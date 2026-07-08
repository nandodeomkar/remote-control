/// Pure connection-lifecycle FSM (CONN-03/CONN-04, D-04/D-05/D-06) — no IO.
///
/// Wraps AROUND `HandshakeFsm` by composition only: this FSM owns the socket
/// lifecycle (dial / backoff / auth-stop policy) while `HandshakeFsm` keeps
/// owning hello/challenge/pin/auth — pin/auth states are NEVER duplicated
/// here (drift against `session.rs` is the failure mode). The driver that
/// does IO is ConnectionService (plan 03-05): timers, sockets, and storage
/// are all driver effects — this class holds no timer objects, no channel,
/// and imports nothing from Flutter or the IO libraries.
///
/// Policy table (03-RESEARCH Pattern 6):
/// - Transport failures retry with exponential backoff 1/2/4/8s capped at
///   10s (design spec §8 cap wins over D-06's discretionary ~30s), ±20%
///   jitter via an injectable `random` closure (deterministic in tests).
/// - Auth failures NEVER retry (D-05): `noPairing`/`badMac` clear the stored
///   token and land in `needPairing` with [kRevokedExplanation].
/// - App resume, "Retry now", and a beacon sighting of the target device
///   short-circuit backoff into an immediate dial (D-06).
///
/// Secrets discipline: effects carry key/host/port only — no token field
/// exists anywhere in this file (tokens stay in DeviceStore/driver).
library;

import 'dart:math' as math;

/// The exact D-05 copy shown when the server no longer recognizes this
/// phone (`authFail` noPairing/badMac — revoked or stale token).
const String kRevokedExplanation =
    'This PC no longer recognizes this phone — pair again';

/// Connection-lifecycle states (03-RESEARCH Pattern 6).
enum ReconnectState {
  /// No target; nothing in flight.
  idle,

  /// A dial is in flight ([DialEffect] emitted; driver runs `connectNoDelay`).
  connecting,

  /// Socket is up; the driver is running the `HandshakeFsm` (composition —
  /// hello/pin/auth live THERE, not here).
  handshaking,

  /// Handshake reported `pairOk`/`authOk` — the session is live.
  authed,

  /// A transport failure occurred; waiting out a jittered backoff delay
  /// (the driver owns the actual timer).
  backoff,

  /// Auth-stop (D-05): a definitive `authFail` ended silent retry; the user
  /// must re-pair (or update, for versionMismatch). See [ReconnectFsm.explanation].
  needPairing,
}

/// The device this FSM dials: GUID key, display name, last-known address.
class DeviceTarget {
  /// Machine GUID — the stable identity beacons are matched against.
  final String key;

  /// Display name (e.g. `OMKAR-LAPTOP`); diagnostics/UI only.
  final String name;

  /// Last-known host (updated by beacon sightings — PC IP change recovery).
  final String host;

  /// Last-known WebSocket port.
  final int port;

  /// Creates a device target.
  const DeviceTarget({
    required this.key,
    required this.name,
    required this.host,
    required this.port,
  });
}

/// A side effect the FSM asks the driver to perform.
sealed class ReconnectEffect {
  const ReconnectEffect();
}

/// Dial [target] now (driver: `connectNoDelay` + run the handshake).
final class DialEffect extends ReconnectEffect {
  /// The device to dial.
  final DeviceTarget target;

  /// Creates a dial effect.
  const DialEffect(this.target);
}

/// Start a backoff timer for [delay]; fire `backoffElapsed` when it ends.
final class StartBackoffEffect extends ReconnectEffect {
  /// The jittered delay to wait before redialing.
  final Duration delay;

  /// The failure attempt number this delay corresponds to (1-based).
  final int attempt;

  /// Creates a start-backoff effect.
  const StartBackoffEffect(this.delay, this.attempt);
}

/// Delete the stored token for [deviceKey] (D-05 revoked/stale token).
final class ClearTokenEffect extends ReconnectEffect {
  /// GUID key of the device whose token must be cleared.
  final String deviceKey;

  /// Creates a clear-token effect.
  const ClearTokenEffect(this.deviceKey);
}

/// Auth-stop (D-05): surface [reason] (+ extras) to the pairing UI —
/// silent retry has ended.
final class AuthStopEffect extends ReconnectEffect {
  /// `authFail` reason (`noPairing`/`badMac`/`pinInvalid`/`pinExpired`/
  /// `lockedOut`) or `versionMismatch`.
  final String reason;

  /// Attempts left before lockout (present for `pinInvalid`).
  final int? attemptsRemaining;

  /// Seconds until retry allowed (present for `lockedOut`).
  final int? retryAfterSecs;

  /// Creates an auth-stop effect.
  const AuthStopEffect(
    this.reason, {
    this.attemptsRemaining,
    this.retryAfterSecs,
  });
}

/// Close the socket (if any).
final class CloseEffect extends ReconnectEffect {
  /// Creates a close effect.
  const CloseEffect();
}

/// The result of feeding one input: an ordered list of driver effects.
class ReconnectStep {
  /// Effects for the driver to execute, in order. May be empty.
  final List<ReconnectEffect> effects;

  /// Creates a step.
  const ReconnectStep({this.effects = const []});

  /// A no-op step (stray/ignored input).
  static const ReconnectStep none = ReconnectStep();
}

/// Pure connection-lifecycle state machine.
class ReconnectFsm {
  ReconnectState _state = ReconnectState.idle;

  /// The device being dialed; carried through backoff so redials reuse the
  /// last-known ip:port. Never holds a token (secrets stay driver-side).
  DeviceTarget? _target;

  /// Consecutive transport-failure count (1-based per failure).
  int _attempt = 0;

  /// The needPairing copy (kRevokedExplanation for noPairing/badMac).
  String? _explanation;

  /// Jitter source returning 0.0..1.0 — injectable for deterministic tests.
  final double Function() _random;

  /// Base backoff delays in seconds: 1, 2, 4, 8, then cap 10 (design
  /// spec §8 cap wins over D-06's discretionary ~30s).
  static const List<int> _baseDelaySecs = [1, 2, 4, 8, 10];

  /// Creates an FSM. Inject [random] (returning 0.0..1.0) for deterministic
  /// jitter in tests; defaults to `math.Random().nextDouble`.
  ReconnectFsm({double Function()? random})
      : _random = random ?? math.Random().nextDouble;

  /// The current lifecycle state.
  ReconnectState get state => _state;

  /// The current dial target, or `null` when idle.
  DeviceTarget? get target => _target;

  /// Consecutive transport-failure count (reset on auth / short-circuits).
  int get attempt => _attempt;

  /// The needPairing explanation copy, or `null` (D-05).
  String? get explanation => _explanation;

  /// The jittered backoff delay for a 1-based [attempt]: base 1/2/4/8s
  /// capped at 10s, multiplied by a 0.8..1.2 jitter factor (±20%, D-06).
  Duration delayFor(int attempt) {
    final idx = math.min(math.max(attempt - 1, 0), _baseDelaySecs.length - 1);
    final factor = 0.8 + 0.4 * _random();
    return Duration(
      milliseconds: (_baseDelaySecs[idx] * 1000 * factor).round(),
    );
  }

  /// User/driver asks to connect to [target] (any non-authed state).
  ReconnectStep connectRequested(DeviceTarget target) {
    switch (_state) {
      case ReconnectState.authed:
        // Already live — the caller must disconnect first.
        return ReconnectStep.none;
      case ReconnectState.idle:
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.backoff:
      case ReconnectState.needPairing:
        _target = target;
        _attempt = 0;
        _explanation = null;
        return _dialNow();
    }
  }

  /// The socket came up; the driver starts the `HandshakeFsm` (composition —
  /// no handshake state is mirrored here). No driver effects.
  ReconnectStep socketConnected() {
    switch (_state) {
      case ReconnectState.connecting:
        _state = ReconnectState.handshaking;
        return ReconnectStep.none;
      case ReconnectState.idle:
      case ReconnectState.handshaking:
      case ReconnectState.authed:
      case ReconnectState.backoff:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// Socket connect failed / stream closed / pong timeout — enter a
  /// jittered backoff (D-06). Transport failures ALWAYS retry; only auth
  /// failures stop (D-05). Stray in needPairing: auth-stop is sticky.
  ReconnectStep transportFailed() {
    switch (_state) {
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.authed:
        _attempt += 1;
        _state = ReconnectState.backoff;
        return ReconnectStep(
          effects: [StartBackoffEffect(delayFor(_attempt), _attempt)],
        );
      case ReconnectState.idle:
      case ReconnectState.backoff:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// The driver's backoff timer fired — redial the same target.
  ReconnectStep backoffElapsed() {
    switch (_state) {
      case ReconnectState.backoff:
        return _dialNow();
      case ReconnectState.idle:
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.authed:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// The app returned to the foreground (D-06 short-circuit): reset the
  /// attempt counter and dial immediately.
  ReconnectStep appResumed() => _shortCircuit();

  /// The user tapped "Retry now" (D-04 affordance) — same D-06 semantics
  /// as [appResumed].
  ReconnectStep retryNowPressed() => _shortCircuit();

  /// A beacon for [guid] was sighted at [host]:[port] (D-06 short-circuit):
  /// update the target's last-known address (PC IP change recovery) and
  /// dial immediately. Ignored unless [guid] matches the current target —
  /// a foreign beacon may never redirect a dial (T-03-06); even a matching
  /// spoof only redirects a CONNECT ATTEMPT into challenge-response.
  ReconnectStep beaconSighted(String guid, String host, int port) {
    final current = _target;
    if (current == null || guid != current.key) {
      return ReconnectStep.none;
    }
    switch (_state) {
      case ReconnectState.backoff:
        _target = DeviceTarget(
          key: current.key,
          name: current.name,
          host: host,
          port: port,
        );
        _attempt = 0;
        return _dialNow();
      case ReconnectState.idle:
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.authed:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// The handshake reported `pairOk`/`authOk` — the session is live and the
  /// failure counter resets.
  ReconnectStep authedOk() {
    switch (_state) {
      case ReconnectState.handshaking:
        _attempt = 0;
        _state = ReconnectState.authed;
        return ReconnectStep.none;
      case ReconnectState.idle:
      case ReconnectState.connecting:
      case ReconnectState.authed:
      case ReconnectState.backoff:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// The handshake reported a definitive `authFail` (or versionMismatch) —
  /// auth-stop (D-05): NEVER a retry for ANY reason (retrying badMac would
  /// hammer the server's global lockout counter, T-03-05). Only
  /// noPairing/badMac mean a revoked/stale token, so only they clear it.
  ReconnectStep authRejected(
    String reason, {
    int? attemptsRemaining,
    int? retryAfterSecs,
  }) {
    switch (_state) {
      case ReconnectState.handshaking:
        final revoked = reason == 'noPairing' || reason == 'badMac';
        _explanation = revoked ? kRevokedExplanation : null;
        _state = ReconnectState.needPairing;
        final key = _target?.key;
        return ReconnectStep(effects: [
          if (revoked && key != null) ClearTokenEffect(key),
          AuthStopEffect(
            reason,
            attemptsRemaining: attemptsRemaining,
            retryAfterSecs: retryAfterSecs,
          ),
          const CloseEffect(),
        ]);
      case ReconnectState.idle:
      case ReconnectState.connecting:
      case ReconnectState.authed:
      case ReconnectState.backoff:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// User/driver asks to drop the connection — back to idle, never a retry.
  ReconnectStep disconnectRequested() {
    switch (_state) {
      case ReconnectState.idle:
        return ReconnectStep.none;
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.authed:
      case ReconnectState.backoff:
      case ReconnectState.needPairing:
        _state = ReconnectState.idle;
        _target = null;
        _attempt = 0;
        _explanation = null;
        return const ReconnectStep(effects: [CloseEffect()]);
    }
  }

  /// Backoff short-circuit shared by [appResumed]/[retryNowPressed]:
  /// reset the counter and dial immediately (D-06). Stray elsewhere.
  ReconnectStep _shortCircuit() {
    switch (_state) {
      case ReconnectState.backoff:
        _attempt = 0;
        return _dialNow();
      case ReconnectState.idle:
      case ReconnectState.connecting:
      case ReconnectState.handshaking:
      case ReconnectState.authed:
      case ReconnectState.needPairing:
        return ReconnectStep.none;
    }
  }

  /// Enter connecting and ask the driver to dial the current target.
  ReconnectStep _dialNow() {
    _state = ReconnectState.connecting;
    return ReconnectStep(effects: [DialEffect(_target!)]);
  }
}
