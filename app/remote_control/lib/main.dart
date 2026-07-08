import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

void main() {
  runApp(const ProviderScope(child: RemoteControlApp()));
}

/// Minimal shell for the cursor spike.
///
/// Plan 02-03 wires this to the trackpad screen; the dashboard home and
/// dark-minimal theme (#0E0F12, blue accent) are built out in later phases.
class RemoteControlApp extends StatelessWidget {
  const RemoteControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Control',
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E0F12),
      ),
      home: const Scaffold(
        body: Center(
          child: Text('Remote Control — cursor spike'),
        ),
      ),
    );
  }
}
