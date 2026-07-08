// Wave 0 unit test (PAD-05 criterion 3, client side): the connection-factory
// logic sets SocketOption.tcpNoDelay on the socket the WebSocket rides over,
// and the ConnectionTask cancel path survives the wrap.
//
// The server side of criterion 3 is already proven in Phase 1
// (set_nodelay(true) in server-core's accept path). The EMPIRICAL A1
// confirmation (real WiFi, slow diagonal, HUD p95 tail) happens at the
// Plan 04 manual gate — this test proves the factory logic only.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/connection_service.dart';

/// Fake socket that records setOption calls. Everything else is unused by
/// the factory logic and routed through noSuchMethod.
class _RecordingSocket implements Socket {
  final List<(SocketOption, bool)> setOptionCalls = [];

  @override
  bool setOption(SocketOption option, bool enabled) {
    setOptionCalls.add((option, enabled));
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('setTcpNoDelay (test seam)', () {
    test('sets SocketOption.tcpNoDelay=true exactly once and returns the same socket', () {
      final fake = _RecordingSocket();

      final returned = setTcpNoDelay(fake);

      expect(identical(returned, fake), isTrue,
          reason: 'the same socket must ride the WebSocket upgrade');
      expect(fake.setOptionCalls, [(SocketOption.tcpNoDelay, true)],
          reason: 'tcpNoDelay must be set to true exactly once');
    });
  });

  group('noDelayTask (factory wrap)', () {
    test('resolved socket has tcpNoDelay set exactly once', () async {
      final fake = _RecordingSocket();
      final task = ConnectionTask.fromSocket(Future<Socket>.value(fake), () {});

      final wrapped = noDelayTask(task);
      final socket = await wrapped.socket;

      expect(identical(socket, fake), isTrue);
      expect(fake.setOptionCalls, [(SocketOption.tcpNoDelay, true)]);
    });

    test('preserves the cancel path so the WebSocket upgrade can still abort', () {
      final fake = _RecordingSocket();
      var cancelled = false;
      final task = ConnectionTask.fromSocket(
        Future<Socket>.value(fake),
        () => cancelled = true,
      );

      final wrapped = noDelayTask(task);
      wrapped.cancel();

      expect(cancelled, isTrue,
          reason: 'wrapping must forward cancel to the original task');
    });
  });
}
