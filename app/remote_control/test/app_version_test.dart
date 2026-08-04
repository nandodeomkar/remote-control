// Settings > About version row (260729-42w).
//
// The row exists because every APK from v1.0.0 through v1.3.0-rc1 reported
// itself as "1.0.0" — pubspec was never bumped — so "which version are you
// running?" had no answer. These tests pin the two behaviours that make the
// row trustworthy: it shows what the package reports, and a lookup failure
// costs the version only, never the Settings screen itself (which is also the
// only route to Revoke).
//
// Same ProviderScope-override host as settings_screen_test.dart, so nothing
// here reaches the package_info_plus platform channel — flutter_test has no
// plugin registrant.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/settings/app_version.dart';
import 'package:remote_control/settings/settings_screen.dart';
import 'package:remote_control/store/device_list_store.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/update/version.dart';

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

/// Empty paired list — these tests care about the About group only, and an
/// empty list still renders the Paired PCs heading used as the
/// "screen survived" probe.
class _StubEmptyList extends DeviceListNotifier {
  @override
  List<DeviceListEntry> build() => const [];
}

/// [version] supplies whatever the provider should resolve to — a value, a
/// throw, or a future the test completes by hand.
Widget _host(DeviceStore store, Future<String> Function() version) =>
    ProviderScope(
      overrides: [
        deviceStoreProvider.overrideWithValue(store),
        connectionServiceProvider.overrideWith(
          (ref) => ConnectionService(store: store),
        ),
        deviceListProvider.overrideWith(_StubEmptyList.new),
        appVersionProvider.overrideWith((ref) => version()),
      ],
      child: const MaterialApp(home: SettingsScreen()),
    );

void main() {
  late DeviceStore store;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    store = DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv());
  });

  // -- The 12-14 split: one lookup, two renderings -------------------------

  test('the bare provider returns exactly PackageInfo.version', () async {
    final c = ProviderContainer(overrides: [
      packageInfoProvider.overrideWith(
        (ref) async =>
            const PackageVersion(version: '1.4.0', buildNumber: '8'),
      ),
    ]);
    addTearDown(c.dispose);

    expect(await c.read(appBareVersionProvider.future), '1.4.0');
  });

  test('the bare version parses as a SemVer — the display string does not',
      () async {
    final c = ProviderContainer(overrides: [
      packageInfoProvider.overrideWith(
        (ref) async =>
            const PackageVersion(version: '1.4.0', buildNumber: '8'),
      ),
    ]);
    addTearDown(c.dispose);

    final bare = await c.read(appBareVersionProvider.future);
    expect(SemVer.tryParse(bare), isNotNull,
        reason: 'this is the whole reason the split exists (D-05/D-26)');

    // And the reason it could not simply reuse the display string:
    final display = await c.read(appVersionProvider.future);
    expect(SemVer.tryParse(display), isNull);
  });

  test('the formatted display string is UNCHANGED by the split', () async {
    final c = ProviderContainer(overrides: [
      packageInfoProvider.overrideWith(
        (ref) async =>
            const PackageVersion(version: '1.3.0', buildNumber: '4'),
      ),
    ]);
    addTearDown(c.dispose);

    // Byte-identical to what the About row shipped before this plan.
    expect(await c.read(appVersionProvider.future), '1.3.0 (4)');
  });

  test('one override fixes BOTH renderings — they cannot disagree', () async {
    final c = ProviderContainer(overrides: [
      packageInfoProvider.overrideWith(
        (ref) async =>
            const PackageVersion(version: '9.9.9', buildNumber: '99'),
      ),
    ]);
    addTearDown(c.dispose);

    final bare = await c.read(appBareVersionProvider.future);
    final display = await c.read(appVersionProvider.future);
    expect(display, startsWith(bare));
    expect(display, '9.9.9 (99)');
  });

  test('a package lookup failure reaches both providers as an error',
      () async {
    final c = ProviderContainer(overrides: [
      packageInfoProvider.overrideWith(
        (ref) async => throw Exception('no plugin registrant'),
      ),
    ]);
    addTearDown(c.dispose);

    await expectLater(c.read(appBareVersionProvider.future), throwsException);
    await expectLater(c.read(appVersionProvider.future), throwsException);
  });

  test('formatAppVersion pairs the name with the build number', () {
    // versionName is what people quote; versionCode is what orders upgrades.
    // Both are shown because for four releases they disagreed.
    expect(
      formatAppVersion(version: '1.3.0', buildNumber: '4'),
      '1.3.0 (4)',
    );
  });

  testWidgets('About row shows the version the package reports', (t) async {
    await t.pumpWidget(_host(store, () async => '1.3.0 (4)'));
    await t.pumpAndSettle();

    expect(find.text(kVersionLabel), findsOneWidget);
    expect(find.text('1.3.0 (4)'), findsOneWidget);
  });

  testWidgets('a failed lookup degrades to Unavailable, screen intact',
      (t) async {
    await t.pumpWidget(
      _host(store, () async => throw Exception('no plugin registrant')),
    );
    await t.pumpAndSettle();

    expect(find.text(kVersionUnavailable), findsOneWidget);
    // The rest of Settings must still be there — Revoke lives on this screen.
    expect(find.text(kPairedPcsHeading), findsOneWidget);
    expect(find.text(kAccentLabel), findsOneWidget);
  });

  testWidgets('shows no placeholder text while the lookup is in flight',
      (t) async {
    final gate = Completer<String>();
    await t.pumpWidget(_host(store, () => gate.future));
    await t.pump();

    // Loading renders an empty value, never "Unavailable" — an in-flight
    // lookup must not be mistaken for a failed one.
    expect(find.text(kVersionUnavailable), findsNothing);
    expect(find.text(kVersionLabel), findsOneWidget);

    gate.complete('1.3.0 (4)');
    await t.pumpAndSettle();
    expect(find.text('1.3.0 (4)'), findsOneWidget);
  });
}
