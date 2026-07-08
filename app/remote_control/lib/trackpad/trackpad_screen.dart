/// The runnable end-to-end trackpad screen (PAD-05 composition point).
///
/// Wires the already-shipped pieces into a live vertical:
///   connect UI -> `connectNoDelay` (02-02, TCP_NODELAY)
///   handshake  -> `HandshakeDriver`/`HandshakeFsm` (Task 1)
///   trackpad   -> `Listener.onPointerMove` -> `MoveSender.sendMove` (02-02)
///                 gated on Authed (pre-auth frames are dropped server-side —
///                 do not even send them; D-03 raw 1:1, no sensitivity)
///   latency    -> `LatencyProbe` interleaved pings + `LatencyHud` (Task 2)
///
/// A SINGLE channel-stream listener decodes each text frame once and routes:
/// handshake families -> the driver, `pong` -> the probe, everything else
/// ignored. No double-subscribe. A `wakelock_plus` lock is held while the
/// screen is mounted and released on dispose so the screen never dims
/// mid-measurement. Discovery + secure token persistence are Phase 3 — this
/// is manual IP:port entry with an in-memory token only (spike scope).
library;

import 'package:flutter/material.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:web_socket_channel/web_socket_channel.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../hud/latency_hud.dart';
import '../hud/latency_probe.dart';
import '../net/connection_service.dart';
import '../net/handshake.dart';
import 'move_sender.dart';

/// The trackpad + connect/PIN screen.
class TrackpadScreen extends StatefulWidget {
  /// Creates the trackpad screen.
  const TrackpadScreen({super.key});

  @override
  State<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends State<TrackpadScreen> {
  final TextEditingController _ipCtrl = TextEditingController();
  final TextEditingController _portCtrl =
      TextEditingController(text: '17777');
  final TextEditingController _pinCtrl = TextEditingController();

  WebSocketChannel? _channel;
  HandshakeDriver? _driver;
  MoveSender? _sender;
  LatencyProbe? _probe;

  String? _connectError;
  bool _connecting = false;

  @override
  void initState() {
    super.initState();
    // Keep the screen awake so it never dims mid-measurement.
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    // Release the wakelock and tear down the socket on exit.
    WakelockPlus.disable();
    _channel?.sink.close();
    _ipCtrl.dispose();
    _portCtrl.dispose();
    _pinCtrl.dispose();
    super.dispose();
  }

  Future<void> _connect() async {
    final host = _ipCtrl.text.trim();
    final port = int.tryParse(_portCtrl.text.trim());
    if (host.isEmpty || port == null) {
      setState(() => _connectError = 'Enter a valid IP and port');
      return;
    }

    setState(() {
      _connecting = true;
      _connectError = null;
    });

    try {
      final channel = await connectNoDelay(Uri.parse('ws://$host:$port'));
      final driver = HandshakeDriver(channel);
      final probe = LatencyProbe(
        nowMillis: () => DateTime.now().millisecondsSinceEpoch,
        send: channel.sink.add,
      );

      // SINGLE listener: decode once, route handshake -> driver, pong ->
      // probe, everything else ignored. No double-subscribe.
      channel.stream.listen(
        (frame) => _onFrame(frame, driver, probe),
        onError: (_) => _onDisconnected(),
        onDone: _onDisconnected,
      );

      setState(() {
        _channel = channel;
        _driver = driver;
        _sender = MoveSender(channel.sink);
        _probe = probe;
        _connecting = false;
      });

      driver.start('Remote Control (Android)');
      setState(() {}); // reflect the connecting/hello status
    } catch (e) {
      setState(() {
        _connecting = false;
        _connectError = 'Connect failed: $e';
      });
    }
  }

  void _onFrame(Object? frame, HandshakeDriver driver, LatencyProbe probe) {
    if (frame is! String) {
      // Binary frames from the server are not part of this spike's inbound
      // surface; ignore them.
      return;
    }
    final RemoteMessage msg;
    try {
      msg = decodeText(frame).msg;
    } on FormatException {
      return; // malformed inbound frame — ignore (never crash the UI)
    }
    if (msg is PongMsg) {
      probe.onPong(msg);
      return;
    }
    // Handshake families (challenge/pairOk/authOk/authFail/err) drive the FSM.
    driver.onMessage(msg);
    if (mounted) setState(() {}); // status line + PIN prompt visibility
  }

  void _onDisconnected() {
    if (!mounted) return;
    setState(() {
      _channel = null;
      _driver = null;
      _sender = null;
      _probe = null;
    });
  }

  void _submitPin() {
    _driver?.feedPin(_pinCtrl.text.trim());
    setState(() {});
  }

  // Hot path: raw 1:1 pointer delta -> MoveSender, gated on Authed. No
  // sensitivity/acceleration multiplier (D-03). Ticks the latency probe's
  // interleave cadence so RTT is measured UNDER move load.
  void _onPointerMove(PointerMoveEvent event) {
    final driver = _driver;
    final sender = _sender;
    if (driver == null || sender == null || !driver.isAuthed) {
      return; // pre-auth frames are dropped server-side — do not send them
    }
    sender.sendMove(event.delta.dx, event.delta.dy);
    _probe?.onMove();
  }

  String _statusLine() {
    final driver = _driver;
    if (driver == null) return 'Disconnected';
    switch (driver.status) {
      case HandshakeStatus.connecting:
        return 'Connecting';
      case HandshakeStatus.needPin:
        return 'Pairing — enter PIN';
      case HandshakeStatus.authenticating:
        return 'Authenticating';
      case HandshakeStatus.authed:
        return 'Authed';
      case HandshakeStatus.failed:
        final f = driver.failure;
        final extra = f?.attemptsRemaining != null
            ? ' (${f!.attemptsRemaining} left)'
            : f?.retryAfterSecs != null
                ? ' (retry in ${f!.retryAfterSecs}s)'
                : '';
        return 'Failed: ${f?.reason ?? 'unknown'}$extra';
    }
  }

  @override
  Widget build(BuildContext context) {
    final driver = _driver;
    final connected = driver != null;
    final needPin = driver?.status == HandshakeStatus.needPin;
    final authed = driver?.isAuthed ?? false;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      body: SafeArea(
        child: Stack(
          children: [
            // The full-bleed trackpad surface uses Listener (a raw pointer
            // route with zero gesture arena / rebuild on the hot path).
            Positioned.fill(
              child: Listener(
                onPointerMove: _onPointerMove,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  color: const Color(0xFF0E0F12),
                  alignment: Alignment.center,
                  child: authed
                      ? const Text(
                          'Drag to move the cursor',
                          style: TextStyle(color: Color(0xFF6B7280)),
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),

            // Connect / PIN controls (hidden once Authed to free the surface).
            if (!authed)
              Positioned(
                left: 16,
                right: 16,
                top: 16,
                child: _controls(connected: connected, needPin: needPin),
              ),

            // Live latency + status overlay.
            if (_probe != null)
              Positioned(
                right: 16,
                bottom: 16,
                child: LatencyHud(probe: _probe!, status: _statusLine()),
              ),
          ],
        ),
      ),
    );
  }

  Widget _controls({required bool connected, required bool needPin}) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!connected) ...[
          Row(
            children: [
              Expanded(
                flex: 3,
                child: TextField(
                  controller: _ipCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Color(0xFFE6E8EB)),
                  decoration: const InputDecoration(
                    labelText: 'Server IP',
                    hintText: '192.168.1.x',
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: TextField(
                  controller: _portCtrl,
                  keyboardType: TextInputType.number,
                  style: const TextStyle(color: Color(0xFFE6E8EB)),
                  decoration: const InputDecoration(labelText: 'Port'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _connecting ? null : _connect,
            child: Text(_connecting ? 'Connecting…' : 'Connect'),
          ),
        ],
        if (needPin) ...[
          const SizedBox(height: 8),
          TextField(
            controller: _pinCtrl,
            keyboardType: TextInputType.number,
            maxLength: 6,
            style: const TextStyle(color: Color(0xFFE6E8EB)),
            decoration: const InputDecoration(
              labelText: 'Console PIN',
              hintText: '6 digits',
            ),
          ),
          FilledButton(onPressed: _submitPin, child: const Text('Pair')),
        ],
        if (_connectError != null) ...[
          const SizedBox(height: 8),
          Text(
            _connectError!,
            style: const TextStyle(color: Color(0xFFFF6B6B)),
          ),
        ],
        if (connected && driverStatusFailed) ...[
          const SizedBox(height: 8),
          Text(
            _statusLine(),
            style: const TextStyle(color: Color(0xFFFF6B6B)),
          ),
        ],
      ],
    );
  }

  bool get driverStatusFailed =>
      _driver?.status == HandshakeStatus.failed;
}
