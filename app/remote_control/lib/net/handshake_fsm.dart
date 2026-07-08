/// Pure client handshake FSM (PAD-05, D-01/D-02) — no IO.
///
/// Mirrors `server/server-core/src/transport/session.rs` EXACTLY: on `start`
/// the client emits `hello`; the server ALWAYS replies `challenge` before any
/// auth branch, so the FSM branches on the presence of an in-memory token —
/// paired -> `auth` (authProof over the nonce, D-01 reconnect path); unpaired
/// -> request a PIN, then `pin` (D-02 pair path). `pairOk`/`authOk` -> Authed;
/// `authFail`/`err versionMismatch` -> Failed carrying the reason + extras.
///
/// No crypto is hand-rolled here: the `auth` mac is built with
/// `authProof(hexDecode(token), hexDecode(nonce))` from `remote_protocol`
/// (SPEC section 4, fixture-anchored). Secrets (pin, mac, token) are never
/// logged. Token lives in a field only — secure persistence is Phase 3
/// (spike scope). This class is IO-free and unit-tested in isolation; the
/// `handshake.dart` driver wires it to a live WebSocket channel.
library;

import 'package:remote_protocol/remote_protocol.dart';

/// The client protocol version (SPEC section 2); only MAJOR is compared
/// server-side.
const String clientProtoVersion = '1.0';

/// Handshake FSM states (SPEC section 3, client mirror of the server FSM).
enum HandshakeState {
  /// `hello` emitted; waiting for the server `challenge`.
  awaitingChallenge,

  /// Unpaired: challenge received; waiting for the user to enter the PIN.
  awaitingPin,

  /// `pin` or `auth` emitted; waiting for `pairOk`/`authOk`/`authFail`.
  awaitingAuthResult,

  /// `pairOk` or `authOk` received — the session is authenticated.
  authed,

  /// A terminal failure (`authFail` reason or `err versionMismatch`).
  failed,
}

/// A side effect the FSM asks the driver/UI to perform. `null` means none.
sealed class HandshakeEffect {
  const HandshakeEffect();
}

/// Prompt the user for the console PIN (unpaired first connect).
final class NeedPinEffect extends HandshakeEffect {
  /// Creates a need-PIN effect.
  const NeedPinEffect();
}

/// Pairing completed — expose the freshly issued raw [token] to the caller so
/// it can be held in memory for the reconnect path.
final class PairedEffect extends HandshakeEffect {
  /// The raw 64-hex token issued by `pairOk`.
  final String token;

  /// Creates a paired effect.
  const PairedEffect(this.token);
}

/// A terminal failure carrying the SPEC section 5 reason and its extras.
final class FailedEffect extends HandshakeEffect {
  /// Failure reason (`pinInvalid`/`pinExpired`/`lockedOut`/`noPairing`/
  /// `badMac`/`versionMismatch`).
  final String reason;

  /// Attempts left before lockout (present for `pinInvalid`).
  final int? attemptsRemaining;

  /// Seconds until retry allowed (present for `lockedOut`).
  final int? retryAfterSecs;

  /// Creates a failure effect.
  const FailedEffect(
    this.reason, {
    this.attemptsRemaining,
    this.retryAfterSecs,
  });
}

/// The result of feeding one input to the FSM: the message to emit onto the
/// wire (if any) plus a side effect (if any). Both may be `null`.
class HandshakeStep {
  /// The next [RemoteMessage] to encode and send, or `null`.
  final RemoteMessage? emit;

  /// A side effect for the driver/UI, or `null`.
  final HandshakeEffect? effect;

  /// Creates a step.
  const HandshakeStep({this.emit, this.effect});

  /// A no-op step (stray/ignored input).
  static const HandshakeStep none = HandshakeStep();
}

/// Pure client handshake state machine.
class HandshakeFsm {
  HandshakeState _state = HandshakeState.awaitingChallenge;

  /// The in-memory token: preset for the reconnect path, or captured from
  /// `pairOk`. Never persisted (spike scope; Phase 3 adds secure storage).
  String? _token;

  /// The device name sent in `hello`; retained only for diagnostics.
  String _device = '';

  /// Creates an FSM. Pass a token to take the paired reconnect path (no PIN
  /// prompt); omit it for the first-connect pair path.
  HandshakeFsm({String? token}) : _token = token; // ignore: prefer_initializing_formals

  /// The current FSM state.
  HandshakeState get state => _state;

  /// The in-memory token (preset or captured from `pairOk`), or `null`.
  String? get token => _token;

  /// Whether a token is held (the reconnect/auth branch is taken).
  bool get isPaired => _token != null;

  /// Begin the handshake: emit `hello` and await the server `challenge`.
  HandshakeStep start(String device) {
    _device = device;
    _state = HandshakeState.awaitingChallenge;
    return HandshakeStep(
      emit: HelloMsg(protoVersion: clientProtoVersion, device: _device),
    );
  }

  /// Feed one decoded [RemoteMessage] and advance the FSM.
  HandshakeStep receive(RemoteMessage msg) {
    switch (_state) {
      case HandshakeState.awaitingChallenge:
        if (msg is ChallengeMsg) {
          return _onChallenge(msg);
        }
        if (msg is ErrMsg && msg.code == 'versionMismatch') {
          return _fail('versionMismatch');
        }
        return HandshakeStep.none;

      case HandshakeState.awaitingPin:
        // Waiting on the local user, not the wire. An early err still fails.
        if (msg is ErrMsg && msg.code == 'versionMismatch') {
          return _fail('versionMismatch');
        }
        return HandshakeStep.none;

      case HandshakeState.awaitingAuthResult:
        if (msg is PairOkMsg) {
          _token = msg.token;
          _state = HandshakeState.authed;
          return HandshakeStep(effect: PairedEffect(msg.token));
        }
        if (msg is AuthOkMsg) {
          _state = HandshakeState.authed;
          return HandshakeStep.none;
        }
        if (msg is AuthFailMsg) {
          return _fail(
            msg.reason,
            attemptsRemaining: msg.attemptsRemaining,
            retryAfterSecs: msg.retryAfterSecs,
          );
        }
        if (msg is ErrMsg && msg.code == 'versionMismatch') {
          return _fail('versionMismatch');
        }
        return HandshakeStep.none;

      case HandshakeState.authed:
      case HandshakeState.failed:
        // Terminal-ish: stray handshake replays are ignored (no crash).
        return HandshakeStep.none;
    }
  }

  /// Feed the user-entered PIN (only valid in [HandshakeState.awaitingPin]).
  ///
  /// Emits `pin` as the zero-padded 6-digit STRING verbatim (leading zeros
  /// significant, SPEC 5) and awaits the result. A no-op outside AwaitingPin.
  HandshakeStep feedPin(String pin) {
    if (_state != HandshakeState.awaitingPin) {
      return HandshakeStep.none;
    }
    _state = HandshakeState.awaitingAuthResult;
    return HandshakeStep(emit: PinMsg(pin: pin));
  }

  HandshakeStep _onChallenge(ChallengeMsg challenge) {
    final token = _token;
    if (token != null) {
      // Reconnect/paired path (D-01): auth via authProof over the nonce —
      // NEVER hand-roll the HMAC.
      final mac = authProof(hexDecode(token), hexDecode(challenge.nonce));
      _state = HandshakeState.awaitingAuthResult;
      return HandshakeStep(emit: AuthMsg(mac: mac));
    }
    // First-connect/pair path (D-02): prompt for the console PIN.
    _state = HandshakeState.awaitingPin;
    return const HandshakeStep(effect: NeedPinEffect());
  }

  HandshakeStep _fail(
    String reason, {
    int? attemptsRemaining,
    int? retryAfterSecs,
  }) {
    _state = HandshakeState.failed;
    return HandshakeStep(
      effect: FailedEffect(
        reason,
        attemptsRemaining: attemptsRemaining,
        retryAfterSecs: retryAfterSecs,
      ),
    );
  }
}
