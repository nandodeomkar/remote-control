/// Client-side auth proof (SPEC section 4, LOCKED construction).
///
/// `mac = HMAC-SHA256(key = SHA-256(raw token bytes), message = nonce bytes)`
/// encoded as 64 lowercase hex characters. Anchored cross-language by
/// `protocol/fixtures/handshake/05-auth-proof.json` (independently computed
/// by .NET crypto — both codecs must reproduce it byte-identically).
library;

import 'package:crypto/crypto.dart';

/// Compute the auth proof mac for [rawToken] and [nonce], as lowercase hex.
String authProof(List<int> rawToken, List<int> nonce) {
  final key = sha256.convert(rawToken).bytes; // key = SHA-256(token)
  final mac = Hmac(sha256, key).convert(nonce);
  return mac.toString(); // Digest.toString() is lowercase hex
}
