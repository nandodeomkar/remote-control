/// Lowercase hex encode/decode helpers.
///
/// All protocol hex (nonce, mac, token, binary fixture wires) is lowercase,
/// always — no decoder may require case normalization (fixtures README).
library;

/// Encode [bytes] as a lowercase hex string.
String hexEncode(List<int> bytes) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}

/// Decode a hex string into bytes. Throws [FormatException] on odd length
/// or non-hex characters.
List<int> hexDecode(String hex) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}
