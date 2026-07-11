// Task 1 (TDD) — pure client handshake FSM transition coverage.
//
// The FSM MUST mirror server/server-core/src/transport/session.rs EXACTLY:
// on a valid `hello` the server ALWAYS replies `challenge` first; ONLY THEN
// does the client branch — `pin` path when unpaired (no in-memory token),
// `auth` path (authProof over the nonce) when paired. `pairOk`/`authOk` ->
// Authed; `authFail`/`err versionMismatch` -> Failed.
//
// No IO here: the FSM is fed decoded RemoteMessage inputs and returns the
// next RemoteMessage to emit plus a lightweight effect. Crypto is reused
// from remote_protocol (authProof/hexDecode) — no new crypto.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/handshake_fsm.dart';
import 'package:remote_protocol/remote_protocol.dart';

void main() {
  // A fixed 64-hex token + nonce so the auth-path mac assertion is
  // deterministic (reuses the remote_protocol construction; no new crypto).
  const token =
      '00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff';
  const nonce64 =
      'aabbccddeeff00112233445566778899aabbccddeeff00112233445566778899';

  group('HandshakeFsm — start', () {
    test('start emits hello(current protoVersion, device) and awaits challenge',
        () {
      final fsm = HandshakeFsm();
      final out = fsm.start('Pixel');

      expect(out.emit, isA<HelloMsg>());
      final hello = out.emit! as HelloMsg;
      // The CURRENT protocol version the client sends in hello — must track
      // the remote_protocol constant, never a pinned literal (Pitfall 10).
      expect(hello.protoVersion, protoVersion);
      expect(hello.device, 'Pixel');
      expect(fsm.state, HandshakeState.awaitingChallenge);
      expect(out.effect, isNull);
    });
  });

  group('HandshakeFsm — pair path (unpaired)', () {
    test('challenge while unpaired requests a PIN and awaits it', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');

      final out = fsm.receive(const ChallengeMsg(nonce: nonce64));

      expect(out.emit, isNull, reason: 'no message until the PIN is entered');
      expect(out.effect, isA<NeedPinEffect>());
      expect(fsm.state, HandshakeState.awaitingPin);
    });

    test('feedPin emits pin as a zero-padded string and awaits the result',
        () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));

      final out = fsm.feedPin('012345');

      expect(out.emit, isA<PinMsg>());
      expect((out.emit! as PinMsg).pin, '012345',
          reason: 'leading zeros are significant (SPEC 5)');
      expect(fsm.state, HandshakeState.awaitingAuthResult);
    });

    test('pairOk stores the token in-memory, exposes it, becomes Authed', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));
      fsm.feedPin('012345');

      final out = fsm.receive(const PairOkMsg(token: token));

      expect(fsm.state, HandshakeState.authed);
      expect(out.effect, isA<PairedEffect>());
      expect((out.effect! as PairedEffect).token, token);
      expect(fsm.token, token);
    });
  });

  group('HandshakeFsm — reconnect path (paired token preset, D-01)', () {
    test('challenge while paired emits auth(mac) with NO PIN prompt', () {
      final fsm = HandshakeFsm(token: token);
      fsm.start('Pixel');

      final out = fsm.receive(const ChallengeMsg(nonce: nonce64));

      expect(out.emit, isA<AuthMsg>());
      expect(out.effect, isNull, reason: 'no PIN prompt on the reconnect path');
      expect(fsm.state, HandshakeState.awaitingAuthResult);
    });

    test('the emitted auth mac equals authProof(hexDecode token, nonce)', () {
      final fsm = HandshakeFsm(token: token);
      fsm.start('Pixel');

      final out = fsm.receive(const ChallengeMsg(nonce: nonce64));

      final expected = authProof(hexDecode(token), hexDecode(nonce64));
      expect((out.emit! as AuthMsg).mac, expected,
          reason: 'reuse the remote_protocol construction, no new crypto');
    });

    test('authOk becomes Authed', () {
      final fsm = HandshakeFsm(token: token);
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));

      final out = fsm.receive(const AuthOkMsg());

      expect(fsm.state, HandshakeState.authed);
      expect(out.effect, isNull);
    });

    test('authFail(badMac) on the auth path fails carrying reason badMac', () {
      final fsm = HandshakeFsm(token: token);
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));

      final out = fsm.receive(const AuthFailMsg(reason: 'badMac'));

      expect(fsm.state, HandshakeState.failed);
      expect(out.effect, isA<FailedEffect>());
      expect((out.effect! as FailedEffect).reason, 'badMac');
    });
  });

  group('HandshakeFsm — auth failures carry extras (SPEC 5)', () {
    test('pinInvalid carries attemptsRemaining', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));
      fsm.feedPin('000000');

      final out = fsm.receive(
        const AuthFailMsg(reason: 'pinInvalid', attemptsRemaining: 4),
      );

      expect(fsm.state, HandshakeState.failed);
      final f = out.effect! as FailedEffect;
      expect(f.reason, 'pinInvalid');
      expect(f.attemptsRemaining, 4);
    });

    test('lockedOut carries retryAfterSecs', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));
      fsm.feedPin('000000');

      final out = fsm.receive(
        const AuthFailMsg(reason: 'lockedOut', retryAfterSecs: 30),
      );

      final f = out.effect! as FailedEffect;
      expect(f.reason, 'lockedOut');
      expect(f.retryAfterSecs, 30);
    });

    test('pinExpired fails carrying its reason', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));
      fsm.feedPin('000000');

      final out = fsm.receive(const AuthFailMsg(reason: 'pinExpired'));

      expect(fsm.state, HandshakeState.failed);
      expect((out.effect! as FailedEffect).reason, 'pinExpired');
    });

    test('noPairing fails carrying its reason', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));
      fsm.feedPin('000000');

      final out = fsm.receive(const AuthFailMsg(reason: 'noPairing'));

      expect(fsm.state, HandshakeState.failed);
      expect((out.effect! as FailedEffect).reason, 'noPairing');
    });
  });

  group('HandshakeFsm — versionMismatch err', () {
    test('err(versionMismatch) fails with a versionMismatch failure', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');

      // '1.0' here pins HISTORICAL wire bytes of a hypothetical mismatched
      // server's err payload — NOT the current client version (Pitfall 10).
      final out = fsm.receive(const ErrMsg(
        code: 'versionMismatch',
        msg: 'server speaks 1.0; client sent 2.0',
        serverVersion: '1.0',
        clientVersion: '2.0',
      ));

      expect(fsm.state, HandshakeState.failed);
      expect((out.effect! as FailedEffect).reason, 'versionMismatch');
    });
  });

  group('HandshakeFsm — guards', () {
    test('feedPin outside AwaitingPin does not emit a pin', () {
      final fsm = HandshakeFsm();
      fsm.start('Pixel');
      // Still AwaitingChallenge — feeding a PIN here is invalid.
      final out = fsm.feedPin('123456');
      expect(out.emit, isNull);
      expect(fsm.state, HandshakeState.awaitingChallenge);
    });

    test('a stray challenge in Authed is ignored (no crash, no emit)', () {
      final fsm = HandshakeFsm(token: token);
      fsm.start('Pixel');
      fsm.receive(const ChallengeMsg(nonce: nonce64));
      fsm.receive(const AuthOkMsg());
      expect(fsm.state, HandshakeState.authed);

      final out = fsm.receive(const ChallengeMsg(nonce: nonce64));
      expect(out.emit, isNull);
      expect(fsm.state, HandshakeState.authed);
    });
  });
}
