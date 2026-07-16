// Task 2 (07-12) — App Settings screen (D-11, SRV-03 client surface).
//
// House widget-test style (widget_test.dart's ProviderScope-override
// pattern): deviceStoreProvider/connectionServiceProvider get an in-memory
// fake-KV-backed store (no platform channels, no real sockets);
// deviceListProvider is stubbed to a static paired-PC list (no BeaconListener
// bind, no sweep timer — mirrors widget_test.dart's _StubDeviceList).
//
// Covers the plan's three acceptance rows: the five groups render in the
// UI-SPEC §5 order, the Accent swatch is non-interactive (no InkWell/tap
// handler), and tapping "Revoke" opens the destructive confirm dialog whose
// confirm button removes the device + deletes its token.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/screens/connection_copy.dart' show deviceMetaPaired;
import 'package:remote_control/screens/device_list_screen.dart';
import 'package:remote_control/settings/settings_screen.dart';
import 'package:remote_control/store/device_list_store.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/theme/tokens.dart';

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

/// A fixed one-row paired-PC list — NO side effects (no beacon socket, no
/// timers), mirroring widget_test.dart's `_StubDeviceList`.
class _StubPairedList extends DeviceListNotifier {
  @override
  List<DeviceListEntry> build() => const [
        DeviceListEntry(
          key: 'guid-office-pc',
          name: 'Office PC',
          host: '192.168.1.50',
          port: 17777,
          live: false,
          paired: true,
          connected: false,
          lastSeenMillis: 0,
        ),
      ];
}

Widget _host(DeviceStore store) => ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(store: store),
        ),
        deviceListProvider.overrideWith(_StubPairedList.new),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

void main() {
  late DeviceStore store;

  setUp(() async {
    // The screen also watches sensitivityProvider/scrollDirectionProvider/
    // hapticsEnabledProvider (each backed by SharedPreferencesAsync) — an
    // in-memory platform avoids the "platform instance must be set" error a
    // bare flutter_test environment throws on the real plugin channel.
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv());
    await store.upsertDevice(
      const DeviceMeta(
        key: 'guid-office-pc',
        name: 'Office PC',
        host: '192.168.1.50',
        port: 17777,
      ),
    );
    await store.saveToken('guid-office-pc', 'tok-abc123');
  });

  testWidgets('renders the five groups in the UI-SPEC §5 order', (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    for (final label in [
      kPairedPcsHeading,
      kSensitivityLabel,
      kScrollDirectionLabel,
      kHapticsLabel,
      kAccentLabel,
    ]) {
      expect(find.text(label), findsOneWidget, reason: 'missing "$label"');
    }

    // Order check: each label's vertical position is strictly increasing
    // (the groups render top-to-bottom in a single scrollable column).
    final labels = [
      kPairedPcsHeading,
      kSensitivityLabel,
      kScrollDirectionLabel,
      kHapticsLabel,
      kAccentLabel,
    ];
    final positions = [
      for (final label in labels) t.getTopLeft(find.text(label)).dy,
    ];
    for (var i = 1; i < positions.length; i++) {
      expect(
        positions[i],
        greaterThan(positions[i - 1]),
        reason: '"${labels[i]}" must render below "${labels[i - 1]}"',
      );
    }
  });

  testWidgets('the paired-PC row shows name + "ip · paired" meta', (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    expect(find.text('Office PC'), findsOneWidget);
    // Meta line is the shared "ip · paired" copy — exact, from connection_copy.
    expect(find.text(deviceMetaPaired('192.168.1.50')), findsOneWidget);
    expect(find.text('192.168.1.50 · paired'), findsOneWidget);
  });

  testWidgets('the scroll-direction segments accent-mark the selection',
      (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    // Default (Natural) is selected: its label is accent, Reversed is muted.
    final natural = t.widget<Text>(find.text(kScrollNaturalLabel));
    final reversed = t.widget<Text>(find.text(kScrollReversedLabel));
    expect(natural.style?.color, kAccent, reason: 'selected segment is accent');
    expect(reversed.style?.color, kMuted, reason: 'unselected segment is muted');
  });

  testWidgets('the Accent "Blue" chip is an accent fill with kBg text',
      (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    final chipText = t.widget<Text>(find.text(kAccentValueLabel));
    expect(chipText.style?.color, kBg, reason: 'chip label is on-accent kBg');

    final chipFill = t.widget<Container>(
      find.ancestor(
        of: find.text(kAccentValueLabel),
        matching: find.byType(Container),
      ).first,
    );
    final decoration = chipFill.decoration as BoxDecoration;
    expect(decoration.color, kAccent, reason: 'chip fill is the locked accent');
    expect(decoration.borderRadius, BorderRadius.circular(999));
  });

  testWidgets('the Accent swatch is a static, non-interactive chip', (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    expect(find.text(kAccentValueLabel), findsOneWidget);
    // No InkWell/GestureDetector wraps the swatch — display-only by
    // construction (D-12: no picker, ever).
    expect(
      find.ancestor(
        of: find.text(kAccentValueLabel),
        matching: find.byType(InkWell),
      ),
      findsNothing,
    );
    expect(
      find.ancestor(
        of: find.text(kAccentValueLabel),
        matching: find.byType(GestureDetector),
      ),
      findsNothing,
    );
  });

  testWidgets('tapping Revoke opens the destructive confirm dialog; Cancel '
      'leaves the store untouched', (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    expect(find.text('Office PC'), findsOneWidget);

    await t.tap(find.widgetWithText(TextButton, kRevokeLabel));
    await t.pumpAndSettle();

    expect(find.text(kRevokeConfirmTitle), findsOneWidget);
    expect(find.text(kRevokeConfirmBody), findsOneWidget);

    await t.tap(find.text(kRevokeConfirmCancel));
    await t.pumpAndSettle();

    expect(find.text(kRevokeConfirmTitle), findsNothing);
    expect(await store.isPaired('guid-office-pc'), isTrue);
  });

  testWidgets('confirming Revoke removes the device and deletes its token',
      (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    await t.tap(find.widgetWithText(TextButton, kRevokeLabel));
    await t.pumpAndSettle();

    await t.tap(find.widgetWithText(FilledButton, kRevokeConfirmConfirm));
    await t.pumpAndSettle();

    expect(find.text(kRevokeConfirmTitle), findsNothing);
    expect(await store.isPaired('guid-office-pc'), isFalse);
    final devices = await store.loadDevices();
    expect(devices.containsKey('guid-office-pc'), isFalse);
  });

  testWidgets('the add/switch-PC entry pushes the device list screen',
      (t) async {
    await t.pumpWidget(_host(store));
    await t.pump();

    expect(find.text(kAddSwitchPcLabel), findsOneWidget);
    await t.tap(find.text(kAddSwitchPcLabel));
    await t.pumpAndSettle();

    // Pushed the add/switch-PC screen on top.
    expect(find.byType(DeviceListScreen), findsOneWidget);
  });
}
