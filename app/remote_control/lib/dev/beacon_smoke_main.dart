/// DEV TOOL — not a product screen.
///
/// Standalone beacon-reception smoke entrypoint for the on-device
/// checkpoint (RESEARCH Pitfall 2: emulators cannot receive LAN broadcast;
/// OEM filtering is device-dependent — test on the real Xiaomi FIRST).
/// Kept permanently as a field-diagnostic tool:
///
///   flutter run -t lib/dev/beacon_smoke_main.dart
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../net/beacon.dart';
import '../net/beacon_listener.dart';
import '../theme/tokens.dart';

void main() {
  runApp(const MaterialApp(
    debugShowCheckedModeBanner: false,
    home: _BeaconSmokeScreen(),
  ));
}

class _BeaconSmokeScreen extends StatefulWidget {
  const _BeaconSmokeScreen();

  @override
  State<_BeaconSmokeScreen> createState() => _BeaconSmokeScreenState();
}

class _BeaconSmokeScreenState extends State<_BeaconSmokeScreen> {
  final BeaconListener _listener = BeaconListener();
  final Map<String, (Beacon, int)> _seen = {}; // guid -> (latest, count)
  StreamSubscription<Beacon>? _sub;

  @override
  void initState() {
    super.initState();
    _sub = _listener.stream.listen((b) {
      setState(() => _seen[b.guid] = (b, (_seen[b.guid]?.$2 ?? 0) + 1));
    });
    _listener.start();
  }

  @override
  void dispose() {
    _sub?.cancel();
    _listener.stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        foregroundColor: Colors.white70,
        title: Text('Beacon smoke — UDP :$kBeaconPort'),
      ),
      body: _seen.isEmpty
          ? const Center(
              child: Text(
                'Waiting for beacons…\n(server broadcasts every 2s)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white54),
              ),
            )
          : ListView(
              children: [
                for (final (beacon, count) in _seen.values)
                  ListTile(
                    title: Text(
                      beacon.name,
                      style: const TextStyle(color: Colors.white),
                    ),
                    subtitle: Text(
                      '${beacon.host}:${beacon.port}\nguid=${beacon.guid}',
                      style: const TextStyle(color: Colors.white54),
                    ),
                    trailing: Text(
                      'seen x$count',
                      style: const TextStyle(color: kAccent),
                    ),
                  ),
              ],
            ),
    );
  }
}
