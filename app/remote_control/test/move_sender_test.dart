// Wave 0 unit test: pointer deltas produce the EXACT byte frames that
// remote_protocol's encoders produce (proving the codec is wired, never
// re-implemented — T-02-CT), one fire-and-forget sink.add per delta.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/trackpad/move_sender.dart';
import 'package:remote_protocol/remote_protocol.dart';

/// Fake WebSocket sink recording every added frame.
class _RecordingSink implements StreamSink<dynamic> {
  final List<Object?> added = [];

  @override
  void add(dynamic event) => added.add(event);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('MoveSender.sendMove', () {
    test('emits the exact encodeMove byte frame for a pointer delta', () {
      final sink = _RecordingSink();
      final sender = MoveSender(sink);

      sender.sendMove(3.5, -2.25);

      expect(sink.added, hasLength(1));
      expect(sink.added.single, equals(encodeMove(3.5, -2.25)),
          reason: 'frame must be byte-for-byte the remote_protocol encoding');
    });

    test('is fire-and-forget: exactly one add per delta, in order', () {
      final sink = _RecordingSink();
      final sender = MoveSender(sink);

      sender.sendMove(1.0, 1.0);
      sender.sendMove(0.4, 0.4);
      sender.sendMove(-5.0, 12.5);

      expect(sink.added, hasLength(3),
          reason: 'no batching, no buffering — one add per delta');
      expect(sink.added[0], equals(encodeMove(1.0, 1.0)));
      expect(sink.added[1], equals(encodeMove(0.4, 0.4)));
      expect(sink.added[2], equals(encodeMove(-5.0, 12.5)));
    });

    test('forwards a zero delta (sender is a pure pass-through)', () {
      final sink = _RecordingSink();
      final sender = MoveSender(sink);

      sender.sendMove(0.0, 0.0);

      expect(sink.added, hasLength(1),
          reason: 'the trackpad, not the sender, decides whether to emit');
      expect(sink.added.single, equals(encodeMove(0.0, 0.0)));
    });
  });

  group('MoveSender.sendScroll', () {
    test('emits the exact encodeScroll byte frame', () {
      final sink = _RecordingSink();
      final sender = MoveSender(sink);

      sender.sendScroll(0.0, -3.0);

      expect(sink.added, hasLength(1));
      expect(sink.added.single, equals(encodeScroll(0.0, -3.0)));
    });
  });
}
