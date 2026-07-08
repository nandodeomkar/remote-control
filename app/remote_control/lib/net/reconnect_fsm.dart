/// Pure connection-lifecycle FSM (CONN-03/CONN-04, D-04/D-05/D-06) — no IO.
///
/// Wraps AROUND `HandshakeFsm` by composition only: this FSM owns the socket
/// lifecycle (dial / backoff / auth-stop policy) while `HandshakeFsm` keeps
/// owning hello/challenge/pin/auth — pin/auth states are NEVER duplicated
/// here (drift against `session.rs` is the failure mode). The driver that
/// does IO is ConnectionService (plan 03-05): timers, sockets, and storage
/// are all driver effects — this class holds no `Timer`, no channel, and
/// imports nothing from Flutter or `dart:io`.
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

/// Pure connection-lifecycle state machine. All methods are implemented in
/// plan 03-02 Task 2 (GREEN); this stub only fixes the API surface so the
/// policy-table suites compile and fail red.
class ReconnectFsm {
  // Injected jitter source — consumed by delayFor in Task 2 (GREEN).
  // ignore: unused_field
  final double Function()? _random;

  /// Creates an FSM. Inject [random] (returning 0.0..1.0) for deterministic
  /// jitter in tests; defaults to a real PRNG in Task 2.
  ReconnectFsm({double Function()? random}) : _random = random;

  /// The current lifecycle state.
  ReconnectState get state =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The current dial target, or `null` when idle.
  DeviceTarget? get target =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// Consecutive transport-failure count (reset on auth / short-circuits).
  int get attempt => throw UnimplementedError('implemented in 03-02 Task 2');

  /// The needPairing explanation copy, or `null` (D-05).
  String? get explanation =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The jittered backoff delay for a 1-based [attempt].
  Duration delayFor(int attempt) =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// User/driver asks to connect to [target].
  ReconnectStep connectRequested(DeviceTarget target) =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The socket came up; the driver starts the handshake.
  ReconnectStep socketConnected() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// Socket connect failed / stream closed / pong timeout.
  ReconnectStep transportFailed() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The driver's backoff timer fired.
  ReconnectStep backoffElapsed() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The app returned to the foreground (D-06 short-circuit).
  ReconnectStep appResumed() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The user tapped "Retry now" (D-04 affordance, D-06 short-circuit).
  ReconnectStep retryNowPressed() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// A beacon for [guid] was sighted at [host]:[port] (D-06 short-circuit;
  /// handles PC IP changes). Ignored unless [guid] matches the target key.
  ReconnectStep beaconSighted(String guid, String host, int port) =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The handshake reported `pairOk`/`authOk`.
  ReconnectStep authedOk() =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// The handshake reported a definitive `authFail` (or versionMismatch) —
  /// auth-stop, NEVER a retry (D-05).
  ReconnectStep authRejected(
    String reason, {
    int? attemptsRemaining,
    int? retryAfterSecs,
  }) =>
      throw UnimplementedError('implemented in 03-02 Task 2');

  /// User/driver asks to drop the connection.
  ReconnectStep disconnectRequested() =>
      throw UnimplementedError('implemented in 03-02 Task 2');
}
