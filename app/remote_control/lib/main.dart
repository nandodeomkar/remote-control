/// App shell: the dashboard ([HubScreen]) as home (D-08, 07-13), the D-01
/// silent launch kick, and the D-06 resume trigger.
///
/// Launch (D-01): after the first frame, read the last-connected device
/// pointer and — if a remembered device exists — fire a silent, non-blocking
/// [ConnectionService.connectTo]. NO navigation on success (the chip flips
/// Connected; the user stays on the dashboard, which is home). No remembered
/// device, or any storage failure, degrades to the offline dashboard
/// (T-03-26: the launch path never crashes on credential reads); the former
/// device list is the add/switch-PC screen reached via Settings.
///
/// Resume (D-06): an [AppLifecycleListener] forwards onResume to
/// [ConnectionService.onAppResumed] — instant retry, no waiting out backoff.
///
/// Discovery (CONN-04): [bindBeacons] attaches the app-scope beacon stream to
/// the service at app start, BEFORE any screen exists. Beacon attachment used
/// to belong to the device-list notifier, so a cold start that landed here and
/// never opened Settings had no beacon feed at all and the D-06 short-circuit
/// was unreachable — a PC that changed IP could not be recovered. One binding,
/// no new machinery.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'hub/hub_screen.dart';
import 'net/connection_providers.dart';
import 'net/reconnect_fsm.dart';
import 'settings/haptics.dart';
import 'store/device_list_store.dart';
import 'theme/tokens.dart';

void main() {
  runApp(const ProviderScope(child: RemoteControlApp()));
}

/// The app shell: dark-minimal theme, dashboard home, launch/resume wiring.
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
    // CONN-04: attach the one app-scope beacon listener to the service now, so
    // the D-06 IP-change short-circuit is live on a cold start that never
    // leaves the dashboard. Must precede the launch kick below — that dial is
    // what later lands in backoff, and backoff is the only state the
    // short-circuit acts in.
    bindBeacons(ref);
    // D-06: app returns to the foreground -> instant retry (backoff reset).
    _lifecycle = AppLifecycleListener(
      onResume: () => ref.read(connectionServiceProvider).onAppResumed(),
    );
    // D-01: the silent launch kick runs after the first frame so the
    // dashboard is on screen immediately — no splash spinner takeover.
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
  /// no navigation on success; every failure path lands back on the
  /// dashboard, which is already home.
  Future<void> _launchKick() async {
    try {
      final store = ref.read(deviceStoreProvider);
      final lastKey = await store.lastDeviceKey();
      if (lastKey == null) return; // nothing remembered — the hub is home
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
      // the dashboard renders offline and pairing (via Settings ->
      // add/switch PC) takes over. Never crash here.
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Remote Control',
      debugShowCheckedModeBanner: false,
      theme: buildAppTheme(),
      home: const HubScreen(),
    );
  }
}
