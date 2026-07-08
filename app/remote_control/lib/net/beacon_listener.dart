/// UDP beacon listener: RawDatagramSocket wrapper exposing `Stream<Beacon>`.
///
/// Binds 0.0.0.0:[kBeaconPort] (SDK primitive — the stale `udp` package is
/// forbidden by the stack doc), routes every datagram through the strict
/// total-parse [Beacon.tryParse] (null = silent drop), and pairs a
/// [MulticastLock] with the socket lifecycle: acquired before bind,
/// released with the socket (Pitfall 8 — never held while the app sits
/// authed off the device-list screen).
library;

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../platform/multicast_lock.dart';
import 'beacon.dart';

/// Shape of `RawDatagramSocket.bind` — injectable seam so unit tests can
/// substitute a fake socket factory without touching the network.
typedef BeaconSocketBind = Future<RawDatagramSocket> Function(
  dynamic host,
  int port, {
  bool reuseAddress,
});

Future<RawDatagramSocket> _defaultBind(
  dynamic host,
  int port, {
  bool reuseAddress = true,
}) =>
    RawDatagramSocket.bind(host, port, reuseAddress: reuseAddress);

class BeaconListener {
  /// Production default: real socket bind + real platform MulticastLock.
  /// Tests may inject fakes for both seams.
  BeaconListener({BeaconSocketBind? bind, MulticastLock? lock})
      : _bind = bind ?? _defaultBind,
        _lock = lock ?? MulticastLock();

  final BeaconSocketBind _bind;
  final MulticastLock _lock;

  final StreamController<Beacon> _controller =
      StreamController<Beacon>.broadcast();

  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _sub;
  bool _running = false;

  /// Validated beacons, one event per accepted datagram. Broadcast: the
  /// stream survives start/stop cycles and multiple subscribers.
  Stream<Beacon> get stream => _controller.stream;

  /// Acquire the multicast lock, then bind and listen. Idempotent:
  /// double-start is a no-op. If the bind fails the lock is released and
  /// the error propagates (a later start() may retry).
  Future<void> start() async {
    if (_running) return;
    _running = true;
    // Lock BEFORE bind: OEM filters must already be off when the first
    // datagram can arrive (RESEARCH Pattern 4 ordering).
    await _lock.acquire();
    try {
      final socket = await _bind(
        InternetAddress.anyIPv4,
        kBeaconPort,
        reuseAddress: true,
      );
      _socket = socket;
      _sub = socket.listen(
        (event) => _onEvent(socket, event),
        // Socket errors must never crash the app off untrusted input;
        // a dead socket simply stops producing beacons.
        onError: (Object _) {},
      );
    } catch (_) {
      // Bind failed: paired lifecycle means the lock goes too.
      _running = false;
      await _lock.release();
      rethrow;
    }
  }

  /// Close the socket and release the lock (paired lifecycle). Idempotent:
  /// double-stop is a no-op. The beacon stream itself stays open so the
  /// listener can be started again.
  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    await _sub?.cancel();
    _sub = null;
    _socket?.close();
    _socket = null;
    await _lock.release();
  }

  void _onEvent(RawDatagramSocket socket, RawSocketEvent event) {
    if (event != RawSocketEvent.read) return;
    final datagram = socket.receive();
    if (datagram == null) return;
    final beacon = Beacon.tryParse(datagram.data, datagram.address);
    if (beacon == null) return; // silent drop — untrusted input
    if (kDebugMode) {
      // On-device smoke signal + field diagnosis. Decoded fields only —
      // NEVER raw datagram bytes.
      debugPrint(
        'beacon: ${beacon.name} ${beacon.host}:${beacon.port} '
        'guid=${beacon.guid}',
      );
    }
    _controller.add(beacon);
  }
}
