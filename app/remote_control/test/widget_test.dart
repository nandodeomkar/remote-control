// App-shell smoke test (03-07): home is the device list (D-02), and the
// remote_protocol path dependency resolves and imports.
//
// Storage/beacon seams are overridden with inert fakes so the shell pumps
// without platform plugins or sockets: the launch kick reads the fake store
// (no remembered device -> no dial), and the device list notifier is stubbed
// to an empty list (no BeaconListener bind, no sweep timer).

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/main.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/screens/device_list_screen.dart';
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

void main() {
  testWidgets('app shell homes on the device list', (tester) async {
    final store = DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv());
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          deviceStoreProvider.overrideWithValue(store),
          connectionServiceProvider.overrideWith(
            (ref) => ConnectionService(store: store),
          ),
          deviceListProvider.overrideWith(_StubDeviceList.new),
        ],
        child: const RemoteControlApp(),
      ),
    );
    await tester.pump();

    // Home is the device list (D-02) with the Devices title rendered.
    expect(find.byType(DeviceListScreen), findsOneWidget);
    expect(find.text(kDevicesTitle), findsOneWidget);

    // The trackpad spike shell is gone from launch.
    expect(find.text('Connect'), findsNothing);
  });

  test('remote_protocol imports via path dependency', () {
    // Codec is fixture-proven in the package itself; this only asserts the
    // path-dep import surface is reachable from the app.
    expect(encodeMove(1.0, -2.0).length, 9);
  });
}
