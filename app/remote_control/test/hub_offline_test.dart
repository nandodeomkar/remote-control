// Task 1 (07-13) — offline-disabled tiles (D-08 / 07-UI-SPEC §2).
//
// When the PC is offline (ChipStatus.disconnected — a fresh ConnectionService
// over fake stores starts there), every tool tile renders DISABLED (InkWell
// onTap null, no navigation) while the app-bar settings gear stays tappable
// and opens SettingsScreen (D-11: reachable offline).
//
// House pattern (settings_screen_test.dart): ProviderScope overrides give the
// screen an in-memory fake-KV-backed service (no platform channels, no
// sockets); deviceListProvider is stubbed (no BeaconListener bind) because
// the pushed SettingsScreen watches it. NO pumpAndSettle anywhere — the
// header chip polls on a periodic timer, so settle would never converge.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/hub/hub_screen.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/settings/settings_screen.dart';
import 'package:remote_control/store/device_list_store.dart';
import 'package:remote_control/store/device_store.dart';

class _FakeSecureKv implements SecureKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> read(String key) async => backing[key];

  @override
  Future<void> write(String key, String value) async => backing[key] = value;

  @override
  Future<void> delete(String key) async => backing.remove(key);
}

class _FakePrefsKv implements PrefsKv {
  final Map<String, String> backing = {};

  @override
  Future<String?> getString(String key) async => backing[key];

  @override
  Future<void> setString(String key, String value) async {
    backing[key] = value;
  }
}

/// Empty device list with NO side effects (no beacon socket, no timers).
class _StubDeviceList extends DeviceListNotifier {
  @override
  List<DeviceListEntry> build() => const [];
}

Widget _host(DeviceStore store) => ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(store: store),
        ),
        deviceListProvider.overrideWith(_StubDeviceList.new),
      ],
      child: const MaterialApp(home: HubScreen()),
    );

void main() {
  late DeviceStore store;

  setUp(() {
    // The pushed SettingsScreen watches sensitivity/scroll/haptics providers
    // (each backed by SharedPreferencesAsync) — the in-memory platform keeps
    // the bare test environment off the real plugin channel.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv());
  });

  testWidgets('offline: every tool tile is disabled (onTap null, no ripple, '
      'no navigation)', (t) async {
    t.view.physicalSize = const Size(800, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(_host(store));
    await t.pump();

    // A fresh service over fake stores is disconnected — offline.
    for (final tile in kHubTiles) {
      final inkWell = t.widget<InkWell>(
        find
            .ancestor(
              of: find.text(tile.label),
              matching: find.byType(InkWell),
            )
            .first,
      );
      expect(
        inkWell.onTap,
        isNull,
        reason: 'offline must disable the "${tile.label}" tile (D-08)',
      );
    }

    // Tapping a disabled tile navigates nowhere — still on the dashboard.
    await t.tap(find.text('Media'), warnIfMissed: false);
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
    expect(find.byType(HubScreen), findsOneWidget);
    expect(find.text('Media'), findsOneWidget);
  });

  testWidgets('offline: the settings gear stays tappable and opens '
      'SettingsScreen', (t) async {
    t.view.physicalSize = const Size(800, 1600);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(_host(store));
    await t.pump();

    expect(find.byIcon(Symbols.settings_rounded), findsOneWidget);
    await t.tap(find.byIcon(Symbols.settings_rounded));
    // Push transition (no pumpAndSettle — the header chip polls forever).
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));

    expect(find.byType(SettingsScreen), findsOneWidget);
  });
}
