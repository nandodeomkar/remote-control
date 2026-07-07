/// Wire-protocol codecs for Remote Control (pure Dart, no Flutter — D-03).
///
/// Owns the binary mouse-frame codec, JSON codecs for every message family,
/// protoVersion constants, the authProof helper, and grapheme-correct
/// diff-ops (D-04). Proven against the shared golden fixtures in
/// `protocol/fixtures/` — the same files the Rust suite consumes (D-09).
library;

export 'src/auth_proof.dart';
export 'src/binary_codec.dart';
export 'src/diff_ops.dart';
export 'src/hex.dart';
export 'src/json_codec.dart';
export 'src/version.dart';
