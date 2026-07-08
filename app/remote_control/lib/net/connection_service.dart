/// TCP_NODELAY WebSocket construction (PAD-05 criterion 3, client side).
///
/// `web_socket_channel` exposes no socket-option hook, and `dart:io` sockets
/// default to Nagle ON — the exact bug that produces 40-200ms cursor hitches
/// on real WiFi. The fix: an [HttpClient] whose `connectionFactory` sets
/// [SocketOption.tcpNoDelay] on the socket the WebSocket upgrade rides over,
/// passed as `customClient:` to [IOWebSocketChannel.connect].
///
/// NOTE (A1): the unit tests here prove the FACTORY LOGIC, not the on-wire
/// effect. The true A1 confirmation is the EMPIRICAL hitch test — real WiFi,
/// slow diagonal drag, HUD p95 tail — at the Plan 04 manual gate. If that
/// gate shows 40-200ms hitches despite this construction, the roadmap's
/// UDP-channel reconsideration triggers before Phase 3.
library;

import 'dart:io';

import 'package:web_socket_channel/io.dart';

/// Sets TCP_NODELAY on a connected [socket] and returns the same socket.
///
/// This is the separately-callable unit-test seam: the connection factory
/// MUST route its socket through here so tests can prove the option is set
/// without opening a real connection.
Socket setTcpNoDelay(Socket socket) {
  throw UnimplementedError('02-02 Task 2 GREEN implements this');
}

/// Wraps a [ConnectionTask] so its resolved socket has TCP_NODELAY set,
/// preserving the original cancel path (the WebSocket upgrade rides the
/// returned task's socket).
ConnectionTask<Socket> noDelayTask(ConnectionTask<Socket> task) {
  throw UnimplementedError('02-02 Task 2 GREEN implements this');
}

/// [HttpClient.connectionFactory]-shaped callback: connects a plain TCP
/// socket to `uri` and applies TCP_NODELAY via [noDelayTask].
Future<ConnectionTask<Socket>> noDelayConnectionFactory(
  Uri uri,
  String? proxyHost,
  int? proxyPort,
) {
  throw UnimplementedError('02-02 Task 2 GREEN implements this');
}

/// Builds the [HttpClient] whose connections all carry TCP_NODELAY.
HttpClient buildNoDelayHttpClient() {
  throw UnimplementedError('02-02 Task 2 GREEN implements this');
}

/// Connects a WebSocket channel to [wsUri] over a TCP_NODELAY socket.
///
/// Phase 3 grows this into the full reconnect-FSM ConnectionService; the
/// construction path (customClient + connectionFactory) is permanent.
Future<IOWebSocketChannel> connectNoDelay(Uri wsUri) {
  throw UnimplementedError('02-02 Task 2 GREEN implements this');
}
