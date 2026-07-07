/// Binary mouse-frame codec (SPEC section 9).
///
/// Binary WebSocket frames are exactly 9 bytes:
/// `[opcode u8][dx f32 LE][dy f32 LE]`.
///
/// Strict decode rules: length != 9, unknown opcode, or non-finite f32 are
/// all decode errors ([FormatException]). Decode order mirrors the Rust
/// codec exactly: length first, then LE f32 parse, then finite check, then
/// opcode dispatch.
library;

import 'dart:typed_data';

/// Opcode for a relative cursor move frame.
const int opMove = 0x01;

/// Opcode for a relative scroll frame.
const int opScroll = 0x02;

/// A decoded 9-byte mouse frame.
class MouseFrame {
  /// Opcode: [opMove] or [opScroll].
  final int op;

  /// Relative X delta (f32 semantics).
  final double dx;

  /// Relative Y delta (f32 semantics).
  final double dy;

  /// Creates a decoded mouse frame.
  const MouseFrame(this.op, this.dx, this.dy);
}

Uint8List _encode(int op, double dx, double dy) {
  final b = ByteData(9)
    ..setUint8(0, op)
    ..setFloat32(1, dx, Endian.little)
    ..setFloat32(5, dy, Endian.little);
  return b.buffer.asUint8List();
}

/// Encode a move frame: `[0x01][dx f32 LE][dy f32 LE]`.
Uint8List encodeMove(double dx, double dy) => _encode(opMove, dx, dy);

/// Encode a scroll frame: `[0x02][dx f32 LE][dy f32 LE]`.
Uint8List encodeScroll(double dx, double dy) => _encode(opScroll, dx, dy);

/// Decode a 9-byte mouse frame.
///
/// Throws [FormatException] when the frame is not exactly 9 bytes, carries
/// a non-finite f32, or has an unknown opcode (SPEC section 9 strictness).
MouseFrame decodeMouseFrame(Uint8List bytes) {
  if (bytes.length != 9) {
    throw FormatException(
      'mouse frame must be exactly 9 bytes, got ${bytes.length}',
    );
  }
  final b = ByteData.sublistView(bytes);
  final dx = b.getFloat32(1, Endian.little);
  final dy = b.getFloat32(5, Endian.little);
  if (!dx.isFinite || !dy.isFinite) {
    throw const FormatException('non-finite mouse delta (NaN or infinity)');
  }
  final op = bytes[0];
  if (op != opMove && op != opScroll) {
    throw FormatException(
      'unknown mouse-frame opcode: 0x${op.toRadixString(16).padLeft(2, '0')}',
    );
  }
  return MouseFrame(op, dx, dy);
}
