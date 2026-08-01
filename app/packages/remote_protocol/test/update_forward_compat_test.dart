/// SC8 — the mixed-version paths around the protocol 1.8 `update.*` family,
/// proven rather than assumed.
///
/// **What "a 1.8 phone" means here.** It means *the phone knows the
/// `update.*` types* — the codec decodes and encodes them. It does NOT mean
/// the phone advertises `"1.8"` in `hello`.
/// `lib/src/version.dart` still declares `protoVersion = '1.1'` and is
/// deliberately left alone by phase 12: SPEC section 2 compares only the
/// major, so the stale minor is harmless, and changing what the client
/// advertises is a handshake-path behaviour change with its own test surface.
/// This file does not touch it.
///
/// Two directions are covered:
///
/// - **Backward (D-13):** a 1.7 server that has never heard of `update.check`
///   answers `err{code: unknownType}`. That reply must decode cleanly with
///   the code intact so 12-15 can map it to the `serverTooOld` row state.
///   A decode error here would break the whole session over a feature the
///   user merely asked about.
/// - **Forward (SPEC section 10, D-07):** a NEWER server may send a `t` this
///   build has never heard of. It decodes to [UnknownMsg] and throws
///   nothing — the session-survives guarantee.
library;

import 'dart:convert';

import 'package:remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

void main() {
  group('backward: a 1.7 server refuses update.check (D-13)', () {
    // The exact frame a 1.7 server emits when the router's registry has no
    // row for `update.check`: an err with the unknownType code, echoing the
    // offending type in the human-readable msg.
    const refusal = '{"t":"err","seq":7,"p":{"code":"unknownType",'
        '"msg":"unknown message type: update.check"}}';

    test('decodes without throwing', () {
      expect(() => decodeText(refusal), returnsNormally);
    });

    test('yields ErrMsg with code unknownType intact', () {
      final decoded = decodeText(refusal);
      final msg = decoded.msg;
      expect(msg, isA<ErrMsg>());
      // Asserting on the CODE, not the msg string: 12-15 maps this exact
      // value to the serverTooOld row state, and the human-readable text is
      // not a contract.
      expect((msg as ErrMsg).code, 'unknownType');
      expect(decoded.seq, 7, reason: 'the seq correlates the refusal to the '
          'update.check the phone sent');
    });

    test('the session is not treated as broken — the frame round-trips', () {
      final decoded = decodeText(refusal);
      final reencoded =
          jsonDecode(encodeMessage(decoded.msg, seq: decoded.seq))
              as Map<String, dynamic>;
      expect(reencoded['t'], 'err');
      expect((reencoded['p'] as Map<String, dynamic>)['code'], 'unknownType');
    });
  });

  group('forward: an unknown newer type (SPEC section 10, SC8)', () {
    const future = '{"t":"update.somethingFromTheFuture","p":{"x":1}}';

    test('decodes to UnknownMsg with t preserved, throwing nothing', () {
      late final ({RemoteMessage msg, int? seq}) decoded;
      expect(() => decoded = decodeText(future), returnsNormally);
      expect(decoded.msg, isA<UnknownMsg>());
      expect(decoded.msg.t, 'update.somethingFromTheFuture');
    });

    test('round-trip is stable and fabricates no payload', () {
      final decoded = decodeText(future);
      final reencoded = jsonDecode(encodeMessage(decoded.msg))
          as Map<String, dynamic>;
      expect(reencoded['t'], 'update.somethingFromTheFuture');
      // `p` is always emitted (canonical form) but MUST be empty: the codec
      // never invents fields for a type it does not know, and never echoes
      // the unparsed body back at the server.
      expect(reencoded['p'], isEmpty);
    });

    test('an unknown type inside a known family is still UnknownMsg', () {
      // Guards the switch: `update.` is a prefix, not a wildcard. A future
      // `update.rollback` must not accidentally dispatch to a sibling
      // decoder and throw on its missing required fields.
      final decoded = decodeText('{"t":"update.rollback","p":{}}');
      expect(decoded.msg, isA<UnknownMsg>());
      expect(decoded.msg.t, 'update.rollback');
    });
  });

  group('the four 1.8 types are known to THIS build', () {
    // The other half of SC8: the forward-compat fallthrough must not be
    // swallowing the types this phase just added. If a switch arm were
    // missing, the tests above would still pass and this one would fail.
    test('none of them fall through to UnknownMsg', () {
      final frames = {
        'update.check': '{"t":"update.check","p":{}}',
        'update.status':
            '{"t":"update.status","p":{"serverVersion":"1.4.0",'
                '"extConnected":false}}',
        'update.apply': '{"t":"update.apply","p":{"target":"1.5.0"}}',
        'update.progress': '{"t":"update.progress","p":{"stage":"checking"}}',
      };
      for (final entry in frames.entries) {
        final msg = decodeText(entry.value).msg;
        expect(msg, isNot(isA<UnknownMsg>()),
            reason: '${entry.key} must have a decodeText switch arm');
        expect(msg.t, entry.key);
      }
    });
  });
}
