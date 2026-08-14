// App-shell smoke test: home is the dashboard (D-08, 07-13), and the
// remote_protocol path dependency resolves and imports.
//
// 13-08 — THIS FILE IS NOW THE BAR-01 END-TO-END ANCHOR.
//
// It is the only test in the suite that pumps `RemoteControlApp` (the real
// `main.dart` entry point), so it is the only place where BAR-01 is proved
// through the production wiring rather than through a harness that builds
// `SummonShell` itself. `test/shell/summon_shell_test.dart` mounts the shell
// at `MaterialApp.builder` by hand and would stay green if `main.dart` stopped
// mounting it at all; this file would not. That is why TEST-MIGRATION.md
// schedules this file's mutation for Phase 13 rather than Phase 16 — and why
// Phase 16's migration pass must RE-RUN it rather than treat it as bubble-era
// collateral.
//
// Storage/beacon seams are overridden with inert fakes so the shell pumps
// without platform plugins or sockets: the launch kick reads the fake store
// (no remembered device -> no dial), the device list notifier is stubbed to an
// empty list (no sweep timer), and the app-scope beaconListenerProvider is a
// fake — the shell's initState now calls bindBeacons(), which would otherwise
// bind a real UDP socket and reach for the platform MulticastLock.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/hub/hub_screen.dart';
import 'package:remote_control/main.dart';
import 'package:remote_control/net/beacon.dart';
import 'package:remote_control/net/beacon_listener.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/shell/summon_bar.dart';
import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
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

/// Inert app-scope beacon listener: no socket, no MulticastLock. Only the
/// three public members are required — BeaconListener's rest are library-
/// private and so are not part of its interface here.
class _FakeBeaconListener implements BeaconListener {
  final StreamController<Beacon> _controller =
      StreamController<Beacon>.broadcast();

  @override
  Stream<Beacon> get stream => _controller.stream;

  @override
  Future<void> start() async {}

  @override
  Future<void> stop() async {}
}

/// Pumps the REAL application widget over the inert seams.
///
/// Extracted (13-08) so the BAR-01 case below pumps byte-identically to the
/// homing case — the two must not drift into testing two different apps.
/// Every line of setup and every comment is the original.
Future<void> _pumpApp(WidgetTester tester) async {
  // 12-15: the dashboard's settings gear now carries the update badge, which
  // reads the update CACHE (shared_preferences) so it is correct offline and
  // before the Updates screen has ever been opened. `SharedPreferencesAsync`
  // throws from its CONSTRUCTOR when no platform instance is registered, so
  // the in-memory platform is required here for the same reason
  // hub_offline_test and settings_screen_test already install it.
  SharedPreferencesAsyncPlatform.instance =
      InMemorySharedPreferencesAsync.empty();
  final store = DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv());
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(store: store),
        ),
        beaconListenerProvider.overrideWithValue(_FakeBeaconListener()),
        deviceListProvider.overrideWith(_StubDeviceList.new),
      ],
      child: const RemoteControlApp(),
    ),
  );
  await tester.pump();
}

void main() {
  testWidgets('app shell homes on the dashboard', (tester) async {
    await _pumpApp(tester);

    // Home is the dashboard (D-08) with the fallback "Remote" title —
    // no remembered device means no connected target name.
    expect(find.byType(HubScreen), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
  });

  testWidgets('BAR-01: the summon bar renders on the hub through the REAL '
      'application widget', (tester) async {
    await _pumpApp(tester);

    expect(
      find.byType(HubScreen),
      findsOneWidget,
      reason: 'the bar claim below is about the HUB specifically — BAR-01 says '
          'the bar is on every screen INCLUDING the dashboard',
    );
    expect(
      find.byKey(kSummonBarKey),
      findsOneWidget,
      reason: 'ONE bar, app-scope. `main.dart` mounts SummonShell at '
          'MaterialApp.builder; if that mount is ever removed or moved below '
          'the Navigator, this is the only test in the suite that notices',
    );
    expect(find.byKey(kSummonTrackpadIconKey), findsOneWidget);
    expect(
      find.byKey(kSummonKeyboardIconKey),
      findsOneWidget,
      reason: 'both slots, located BY KEY — the keyboard glyph collides with '
          'KeyboardTabBar\'s Type tab the moment Phase 15 mounts it',
    );

    expect(
      tester.getRect(find.byKey(kSummonBarKey)).height,
      closeTo(kSummonBarHeight, 0.01),
      reason: 'the RENDERED height, against the declared constant — "a widget '
          'of that type exists somewhere" is not BAR-01',
    );
  });

  test('remote_protocol imports via path dependency', () {
    // Codec is fixture-proven in the package itself; this only asserts the
    // path-dep import surface is reachable from the app.
    expect(encodeMove(1.0, -2.0).length, 9);
  });
}
