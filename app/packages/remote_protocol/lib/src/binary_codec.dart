/// Binary mouse-frame codec (SPEC section 9).
///
/// Binary WebSocket frames are exactly 9 bytes:
/// `[opcode u8][dx f32 LE][dy f32 LE]`.
///
/// Strict decode rules: length != 9, unknown opcode, or non-finite f32 are
/// all decode errors ([FormatException]).
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

/// Encode a move frame: `[0x01][dx f32 LE][dy f32 LE]`.
Uint8List encodeMove(double dx, double dy) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}

/// Encode a scroll frame: `[0x02][dx f32 LE][dy f32 LE]`.
Uint8List encodeScroll(double dx, double dy) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}

/// Decode a 9-byte mouse frame.
///
/// Throws [FormatException] when the frame is not exactly 9 bytes, carries
/// a non-finite f32, or has an unknown opcode (SPEC section 9 strictness).
MouseFrame decodeMouseFrame(Uint8List bytes) {
  throw UnimplementedError('implemented by 01-08 Task 2');
}
