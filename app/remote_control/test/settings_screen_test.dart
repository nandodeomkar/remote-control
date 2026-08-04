// Task 2 (07-12) — App Settings screen (D-11, SRV-03 client surface).
//
// House widget-test style (widget_test.dart's ProviderScope-override
// pattern): deviceStoreProvider/connectionServiceProvider get an in-memory
// fake-KV-backed store (no platform channels, no real sockets);
// deviceListProvider is stubbed to a static paired-PC list (no BeaconListener
// bind, no sweep timer — mirrors widget_test.dart's _StubDeviceList).
//
// Covers the plan's three acceptance rows: the six groups render in the
// UI-SPEC §5 order, the Accent swatch is non-interactive (no InkWell/tap
// handler), and tapping "Revoke" opens the destructive confirm dialog whose
// confirm button removes the device + deletes its token.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/settings/app_version.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/screens/connection_copy.dart' show deviceMetaPaired;
import 'package:remote_control/screens/device_list_screen.dart';
import 'package:remote_control/settings/settings_screen.dart';
import 'package:remote_control/store/device_list_store.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/theme/tokens.dart';
import 'package:remote_control/update/update_providers.dart';
import 'package:remote_control/update/updates_screen.dart';

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

/// Pinned so the About row's value is asserted against a known string rather
/// than whatever pubspec happens to say today.
const String _kTestVersion = '9.9.9 (99)';

/// The badge's semantics label as a substring pattern — see the note at its
/// use site for why the whole-label form does not hold.
final RegExp _kBadgeLabelPattern = RegExp(RegExp.escape(kUpdateBadgeSemantic));

Widget _host(DeviceStore store, {bool badge = false}) => ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(store: store),
        ),
        deviceListProvider.overrideWith(_StubPairedList.new),
        // Keeps the About row off the package_info_plus platform channel,
        // which has no registrant under flutter_test (260729-42w).
        appVersionProvider.overrideWith((ref) async => _kTestVersion),
        // 12-15: the badge's truth rule is 12-14's business and is proven
        // there. Here it is an input, so the two placements can be asserted
        // against a value the test sets rather than against a cache it has to
        // arrange.
        updateBadgeProvider.overrideWithValue(badge),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

/// Pumps the screen tall enough that the About group — last of the six — is
/// actually laid out. The `ListView` builds lazily, so on the default 800x600
/// viewport the Updates row would simply not exist to find.
Future<void> _pumpTall(
  WidgetTester t,
  DeviceStore store, {
  bool badge = false,
}) async {
  t.view.physicalSize = const Size(1000, 2400);
  t.view.devicePixelRatio = 1.0;
  addTearDown(t.view.resetPhysicalSize);
  addTearDown(t.view.resetDevicePixelRatio);

  await t.pumpWidget(_host(store, badge: badge));
  await t.pump();
}

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

  testWidgets('renders the six groups in the UI-SPEC §5 order', (t) async {
    // Six groups no longer fit the default 800x600 test viewport, and the
    // ListView builds lazily — the About group would simply not exist to find.
    // The order assertion compares dy across all six at once, so scrolling is
    // not an option: they must be laid out simultaneously.
    t.view.physicalSize = const Size(1000, 2400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(_host(store));
    await t.pump();

    for (final label in [
      kPairedPcsHeading,
      kSensitivityLabel,
      kScrollDirectionLabel,
      kHapticsLabel,
      kAccentLabel,
      kAboutHeading,
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
      kAboutHeading,
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

  // -- 12-15: the Updates entry and the badge ---------------------------------

  group('the Updates entry in the About group (12-15, D-06)', () {
    testWidgets('is the first child of About, above the shipped Version row',
        (t) async {
      await _pumpTall(t, store);

      expect(find.byType(UpdatesNavRow), findsOneWidget);
      expect(find.text(kUpdatesTitle), findsOneWidget);

      final heading = t.getTopLeft(find.text(kAboutHeading)).dy;
      final updates = t.getTopLeft(find.text(kUpdatesTitle)).dy;
      final version = t.getTopLeft(find.text(kVersionLabel)).dy;

      expect(updates, greaterThan(heading),
          reason: 'Updates lives inside the About group, not above it');
      expect(version, greaterThan(updates),
          reason: 'Updates is the FIRST child; Version stays below it');
    });

    testWidgets('leaves the shipped Version row present and unchanged',
        (t) async {
      await _pumpTall(t, store);

      expect(find.text(kVersionLabel), findsOneWidget);
      expect(find.text(_kTestVersion), findsOneWidget,
          reason: 'the About row still renders the package version verbatim');
    });

    testWidgets('shows the badge dot when the badge provider is true',
        (t) async {
      await _pumpTall(t, store, badge: true);

      expect(find.byType(UpdateBadgeDot), findsOneWidget);
    });

    testWidgets('shows no badge dot when the badge provider is false',
        (t) async {
      await _pumpTall(t, store, badge: false);

      expect(find.byType(UpdateBadgeDot), findsNothing,
          reason: 'the dot clears when nothing known is behind');
    });

    testWidgets('the badge carries the "Update available" semantics label',
        (t) async {
      // Disposed inline rather than via addTearDown: the framework's
      // end-of-test handle check runs BEFORE tear-downs, so a deferred dispose
      // fails the test it was meant to clean up after.
      final handle = t.ensureSemantics();

      await _pumpTall(t, store, badge: true);

      // The dot draws no text, so without this label the state would be shown
      // and never announced. Matched as a pattern rather than as a whole
      // label: the row is an `InkWell`, so the dot's node is merged into the
      // row's and the announced string carries the row title too.
      expect(find.bySemanticsLabel(_kBadgeLabelPattern), findsWidgets);

      handle.dispose();
    });

    testWidgets('and that label is absent when the dot is', (t) async {
      final handle = t.ensureSemantics();

      await _pumpTall(t, store, badge: false);

      expect(find.bySemanticsLabel(_kBadgeLabelPattern), findsNothing);

      handle.dispose();
    });
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
