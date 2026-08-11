// CONN-04 regression: the discovery beacon feed is bound at APP START, by ONE
// app-scope BeaconListener that both the ConnectionService and the device list
// consume.
//
// Why these two tests exist, and why neither mounts the device-list screen:
//
// Before this fix, `ConnectionService.attachBeacons` had exactly one caller —
// `DeviceListNotifier.build()` — which runs only when `deviceListProvider` is
// watched (the device-list screen and Settings). `HubScreen` watches neither.
// So a cold start that landed on the hub and never opened either screen had NO
// beacon stream attached, and the D-06 short-circuit in `reconnect_fsm`
// (the half of CONN-04 that recovers from a router-assigned IP change) could
// never fire. A test that mounts the device-list screen would pass on the
// pre-fix tree and prove nothing; these deliberately do not.
//
// Test 2 is also the single-instance proof: two `BeaconListener`s would share
// ONE un-refcounted native MulticastLock (`MainActivity.kt` calls
// `setReferenceCounted(false)`), so whichever stopped first would drop the lock
// out from under the other. A device list that built its own listener would
// never see a beacon emitted on the app-scope one.

import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/main.dart';
import 'package:remote_control/net/beacon.dart';
import 'package:remote_control/net/beacon_listener.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/store/device_list_store.dart';
import 'package:remote_control/store/device_store.dart';

/// Inert stand-in for the real listener: no socket, no MulticastLock.
///
/// Only `stream`, `start` and `stop` are implemented — [BeaconListener]'s other
/// members are private to its library and so are not part of the interface
/// here, which is why no `noSuchMethod` is needed.
class _FakeBeaconListener implements BeaconListener {
  late final StreamController<Beacon> _controller =
      StreamController<Beacon>.broadcast(onListen: () => subscribed = true);

  /// True once [start] was called (the app-start binding did its job).
  bool started = false;

  /// True once ANYTHING subscribed to [stream].
  bool subscribed = false;

  @override
  Stream<Beacon> get stream => _controller.stream;

  @override
  Future<void> start() async {
    started = true;
  }

  @override
  Future<void> stop() async {}

  /// Pushes one beacon to every subscriber.
  void emit(Beacon beacon) => _controller.add(beacon);
}

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

/// Empty device list with NO side effects — nothing screen-scoped can attach
/// beacons on the app's behalf while this override is installed.
class _StubDeviceList extends DeviceListNotifier {
  @override
  List<DeviceListEntry> build() => const [];
}

void main() {
  late _FakeBeaconListener beacons;
  late DeviceStore store;

  setUp(() {
    // The hub's settings gear reads the update cache, whose
    // `SharedPreferencesAsync` throws from its CONSTRUCTOR with no platform
    // instance registered (same reason widget_test installs this).
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    beacons = _FakeBeaconListener();
    store = DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv());
  });

  testWidgets('beacons attach with no screen mounted', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceStoreProvider.overrideWithValue(store),
          connectionServiceProvider.overrideWith(
            (ref) => ConnectionService(store: store),
          ),
          beaconListenerProvider.overrideWithValue(beacons),
          // The device list is inert: it cannot start a listener, cannot
          // subscribe, and cannot attach anything to the service.
          deviceListProvider.overrideWith(_StubDeviceList.new),
        ],
        child: const RemoteControlApp(),
      ),
    );
    await tester.pump();

    expect(
      beacons.started,
      isTrue,
      reason: 'the app-start binding must start the listener on a cold start '
          'that never leaves the hub (CONN-04)',
    );
    expect(
      beacons.subscribed,
      isTrue,
      reason: 'the ConnectionService must be subscribed, or the D-06 '
          'beacon short-circuit is unreachable',
    );

    // Unmount so the header chip ticker and any provider timers are cancelled
    // before the pending-timer check.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('one shared listener feeds both consumers', (tester) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceStoreProvider.overrideWithValue(store),
          connectionServiceProvider.overrideWith(
            (ref) => ConnectionService(store: store),
          ),
          beaconListenerProvider.overrideWithValue(beacons),
          // NO deviceListProvider override: the REAL DeviceListNotifier builds.
        ],
        child: const RemoteControlApp(),
      ),
    );
    await tester.pump();

    final container = ProviderScope.containerOf(
      tester.element(find.byType(RemoteControlApp)),
    );
    // Force the real notifier to build. No screen here watches it.
    expect(container.read(deviceListProvider), isEmpty);

    beacons.emit(
      Beacon(
        guid: 'guid-shared',
        name: 'Shared PC',
        port: 17777,
        proto: '1.8',
        source: InternetAddress('192.168.1.50'),
      ),
    );
    await tester.pump();

    final entries = container.read(deviceListProvider);
    expect(
      entries,
      hasLength(1),
      reason: 'a device list that built its OWN BeaconListener would never see '
          'a beacon emitted on the app-scope instance',
    );
    expect(entries.single.key, 'guid-shared');
    expect(entries.single.name, 'Shared PC');
    expect(entries.single.host, '192.168.1.50');
    expect(entries.single.live, isTrue);

    // Teardown ownership (the provider's `ref.onDispose` -> `stop()`) is NOT
    // asserted here: `overrideWithValue` replaces the provider body outright,
    // so the real onDispose registration never runs under any override. A test
    // that re-registered it in the override would prove only the override.
    await tester.pumpWidget(const SizedBox());
  });
}
