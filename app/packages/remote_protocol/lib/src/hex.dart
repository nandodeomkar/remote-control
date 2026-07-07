/// Lowercase hex encode/decode helpers.
///
/// All protocol hex (nonce, mac, token, binary fixture wires) is lowercase,
/// always — no decoder may require case normalization (fixtures README).
/// Hand-rolled per RESEARCH (no dependency needed for ~8 lines).
library;

const String _digits = '0123456789abcdef';

/// Encode [bytes] as a lowercase hex string.
String hexEncode(List<int> bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb
      ..write(_digits[(b >> 4) & 0xf])
      ..write(_digits[b & 0xf]);
  }
  return sb.toString();
}

/// Decode a hex string into bytes. Throws [FormatException] on odd length
/// or non-hex characters.
List<int> hexDecode(String hex) {
  if (hex.length.isOdd) {
    throw FormatException('hex string must have even length: ${hex.length}');
  }
  final out = <int>[];
  for (var i = 0; i < hex.length; i += 2) {
    final byte = int.tryParse(hex.substring(i, i + 2), radix: 16);
    if (byte == null) {
      throw FormatException('invalid hex byte at offset $i', hex, i);
    }
    out.add(byte);
  }
  return out;
}
