/// App shell (03-07): device list as home (D-02), the D-01 silent launch
/// kick, and the D-06 resume trigger.
///
/// Launch (D-01): after the first frame, read the last-connected device
/// pointer and — if a remembered device exists — fire a silent, non-blocking
/// [ConnectionService.connectTo]. NO navigation on success (the chip flips
/// Connected; the user stays on the device list, which is home). No
/// remembered device, or any storage failure, degrades to the plain device
/// list (T-03-26: the launch path never crashes on credential reads).
///
/// Resume (D-06): an [AppLifecycleListener] forwards onResume to
/// [ConnectionService.onAppResumed] — instant retry, no waiting out backoff.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'net/connection_providers.dart';
import 'net/reconnect_fsm.dart';
import 'screens/device_list_screen.dart';
import 'settings/haptics.dart';
import 'store/device_list_store.dart';
import 'theme/tokens.dart';

void main() {
  runApp(const ProviderScope(child: RemoteControlApp()));
}

/// The app shell: dark-minimal theme, device-list home, launch/resume wiring.
class RemoteControlApp extends ConsumerStatefulWidget {
  /// Creates the app shell.
  const RemoteControlApp({super.key});

  @override
  ConsumerState<RemoteControlApp> createState() => _RemoteControlAppState();
}

class _RemoteControlAppState extends ConsumerState<RemoteControlApp> {
  AppLifecycleListener? _lifecycle;

  @override
  void initState() {
    super.initState();
    // D-13: install the haptics hot-path cache ONCE at app start, before any
    // tap can fire — mirrors the trackpad sensitivity-cache seam
    // (listenManual, fireImmediately) so hapticTick()/hapticTickMedium() are
    // gated correctly from the very first frame.
    bindHapticsCache(ref);
    // D-06: app returns to the foreground -> instant retry (backoff reset).
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(connectionServiceProvider).onAppResumed(),
    );
    // D-01: the silent launch kick runs after the first frame so the device
    // list is on screen immediately — no splash spinner takeover.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_launchKick());
    });
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    _lifecycle = null;
    super.dispose();
  }

  /// Silent auto-reconnect to the last-connected PC (D-01). Non-blocking,
  /// no navigation on success; every failure path lands back on the device
  /// list, which is already home.
  Future<void> _launchKick() async {
    try {
      final store = ref.read(deviceStoreProvider);
      final lastKey = await store.lastDeviceKey();
      if (lastKey == null) return; // nothing remembered — the list is home
      final devices = await store.loadDevices();
      final meta = devices[lastKey];
      if (meta == null) return; // dangling pointer — degrade silently
      if (!mounted) return;
      await ref.read(connectionServiceProvider).connectTo(
            DeviceTarget(
              key: meta.key,
              name: meta.name,
              host: meta.host,
              port: meta.port,
            ),
          );
    } catch (_) {
      // T-03-26: storage failures at launch degrade to unpaired/no-target —
      // the device list renders and pairing takes over. Never crash here.
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Control',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const DeviceListScreen(),
    );
  }
}
