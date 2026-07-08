import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'trackpad/trackpad_screen.dart';

void main() {
  runApp(const ProviderScope(child: RemoteControlApp()));
}

/// The cursor-spike app shell: routes straight to the trackpad screen.
///
/// Plan 02-03 wires the runnable end-to-end vertical (connect -> pair/auth ->
/// move cursor -> live latency). The dashboard home and richer dark-minimal
/// theme (blue accent, persistent quick-bar) are built out in later phases;
/// the #0E0F12 background is kept here.
class RemoteControlApp extends StatelessWidget {
  const RemoteControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF0E0F12),
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF4C8DFF),
          brightness: Brightness.dark,
        ),
      ),
      home: const TrackpadScreen(),
    );
  }
}
