/// Auth-proof fixture test — the Dart half of the cross-language anchor.
///
/// `protocol/fixtures/handshake/05-auth-proof.json` carries a fixed token,
/// a fixed nonce, and the expected mac computed by an independent third
/// implementation (.NET System.Security.Cryptography). The Rust suite
/// already reproduces it byte-identically (`auth_proof_fixture`); this test
/// closes the anchor on the Dart side.
library;

import 'dart:convert';
import 'dart:io';

import 'package:remote_protocol/remote_protocol.dart';
import 'package:test/test.dart';

const String fixturePath =
    '../../../protocol/fixtures/handshake/05-auth-proof.json';

void main() {
  test('authProof reproduces the independently computed macHex', () {
    final file = File(fixturePath);
    if (!file.existsSync()) {
      fail(
        'Fixture not found at $fixturePath (cwd: ${Directory.current.path}). '
        'The canonical invocation is: cd app/packages/remote_protocol && dart test',
      );
    }
    final fixture = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final input = fixture['input'] as Map<String, dynamic>;
    final expected = fixture['expect'] as Map<String, dynamic>;

    final token = hexDecode(input['tokenHex'] as String);
    final nonce = hexDecode(input['nonceHex'] as String);

    expect(
      authProof(token, nonce),
      expected['macHex'],
      reason: 'authProof must reproduce the independently computed mac '
          'byte-identically (SPEC section 4 locked construction)',
    );
  });
}
