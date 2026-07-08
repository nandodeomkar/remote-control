/// Handshake driver: wires the pure [HandshakeFsm] to a live WebSocket
/// channel (PAD-05, D-01/D-02).
///
/// Owns the in-memory token, decodes inbound text frames via `decodeText`,
/// feeds decoded handshake messages into the FSM, and `encodeMessage`s the
/// FSM's outbound messages onto the sink. Exposes the resolved channel plus a
/// status stream so the trackpad screen (Task 3) can react to
/// Connecting/Pairing/Authed/Failed.
///
/// This driver does NOT own the channel's stream subscription — the trackpad
/// screen has a SINGLE listener that routes handshake frames here (via
/// [onMessage]) and `pong` frames to the latency probe, so there is never a
/// double-subscribe. Secrets (pin/mac/token) are never logged.
library;

import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:remote_protocol/remote_protocol.dart';

import 'handshake_fsm.dart';

/// Coarse connection status for the HUD status line (D-05/D-06/D-07).
enum HandshakeStatus {
  /// Socket opening / `hello` sent, awaiting `challenge`.
  connecting,

  /// Unpaired: awaiting the user's PIN.
  needPin,

  /// `pin`/`auth` sent, awaiting the server's result.
  authenticating,

  /// Fully authenticated — move frames may flow.
  authed,

  /// Terminal failure; [HandshakeDriver.failure] carries the reason.
  failed,
}

/// The driver wiring the FSM to a channel.
class HandshakeDriver {
  /// The live channel the handshake rides.
  final WebSocketChannel channel;

  final HandshakeFsm _fsm;
  HandshakeStatus _status = HandshakeStatus.connecting;
  FailedEffect? _failure;

  /// Creates a driver over [channel]. Pass [token] to take the paired
  /// reconnect path (no PIN prompt); omit it for first-connect pairing.
  HandshakeDriver(this.channel, {String? token})
      : _fsm = HandshakeFsm(token: token);

  /// The current status.
  HandshakeStatus get status => _status;

  /// The terminal failure, once [status] is [HandshakeStatus.failed].
  FailedEffect? get failure => _failure;

  /// The in-memory token (captured from `pairOk` or the preset), or `null`.
  String? get token => _fsm.token;

  /// Whether the handshake reached [HandshakeStatus.authed].
  bool get isAuthed => _status == HandshakeStatus.authed;

  /// Begin the handshake: send `hello` and await `challenge`.
  void start(String device) {
    _status = HandshakeStatus.connecting;
    _apply(_fsm.start(device));
  }

  /// Feed the user-entered PIN (only acts while [HandshakeStatus.needPin]).
  void feedPin(String pin) => _apply(_fsm.feedPin(pin));

  /// Route ONE decoded handshake message from the shared channel listener.
  ///
  /// The caller decodes each text frame once (`decodeText`) and dispatches
  /// handshake families here; `pong` goes to the latency probe instead. A
  /// message that is not a handshake input is a harmless no-op.
  void onMessage(RemoteMessage msg) => _apply(_fsm.receive(msg));

  void _apply(HandshakeStep step) {
    final emit = step.emit;
    if (emit != null) {
      channel.sink.add(encodeMessage(emit));
    }
    final effect = step.effect;
    switch (effect) {
      case NeedPinEffect():
        _status = HandshakeStatus.needPin;
      case PairedEffect():
        _status = HandshakeStatus.authed;
      case FailedEffect():
        _failure = effect;
        _status = HandshakeStatus.failed;
      case null:
        // No effect: derive coarse status from the FSM state so the HUD
        // reflects hello-sent (connecting) and authOk (authed) transitions.
        switch (_fsm.state) {
          case HandshakeState.awaitingChallenge:
            _status = HandshakeStatus.connecting;
          case HandshakeState.awaitingPin:
            _status = HandshakeStatus.needPin;
          case HandshakeState.awaitingAuthResult:
            _status = HandshakeStatus.authenticating;
          case HandshakeState.authed:
            _status = HandshakeStatus.authed;
          case HandshakeState.failed:
            _status = HandshakeStatus.failed;
        }
    }
  }
}
