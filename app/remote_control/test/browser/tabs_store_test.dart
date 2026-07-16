// Task 4 (260716-oi2) — TabsViewState value equality + TabsNotifier command
// wiring (BROW-01, proto 1.4).
//
// The notifier is proven over the house fake ConnectionService seam (the
// media_screen_test pattern: a subclass over fake KV stores that records
// sendReliable) inside a bare ProviderContainer — no widgets, no platform.

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/browser/tabs_store.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
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

/// Recording fake: parks a mutable [TabsSnapshot], exposes a test-driven
/// `changes` stream, and records every [sendReliable] message.
class _FakeService extends ConnectionService {
  _FakeService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<RemoteMessage> reliable = [];
  final StreamController<void> pings = StreamController<void>.broadcast();
  TabsSnapshot? parked;

  @override
  TabsSnapshot? get tabsSnapshot => parked;

  @override
  Stream<void> get changes => pings.stream;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

void main() {
  group('TabsViewState — value equality', () {
    test('identical connected + tab lists are equal (== and hashCode)', () {
      const a = TabsViewState(
        connected: true,
        tabs: [
          TabInfo(id: 7, title: 'GitHub', active: true, icon: 'AA=='),
          TabInfo(id: 9, title: 'Docs', active: false),
        ],
      );
      const b = TabsViewState(
        connected: true,
        tabs: [
          TabInfo(id: 7, title: 'GitHub', active: true, icon: 'AA=='),
          TabInfo(id: 9, title: 'Docs', active: false),
        ],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing active flag makes them unequal', () {
      const a = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
      );
      const b = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: false)],
      );
      expect(a, isNot(b));
    });

    test('a differing connected flag makes them unequal', () {
      const a = TabsViewState(connected: true, tabs: []);
      const b = TabsViewState(connected: false, tabs: []);
      expect(a, isNot(b));
    });
  });

  group('TabsNotifier — command wiring over the fake service', () {
    late _FakeService service;
    late ProviderContainer container;

    setUp(() {
      service = _FakeService();
      container = ProviderContainer(
        overrides: [
          connectionServiceProvider.overrideWith((ref) => service),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.pings.close);
    });

    test('primeList sends the const tabs.list request (no payload fields)',
        () {
      container.read(tabsStateProvider.notifier).primeList();

      expect(service.reliable, hasLength(1));
      final msg = service.reliable.single as TabsListMsg;
      expect(msg.connected, isNull, reason: 'a request carries no fields');
      expect(msg.tabs, isNull);
    });

    test('activate(7) sends TabsActivateMsg with that id', () {
      container.read(tabsStateProvider.notifier).activate(7);

      expect(service.reliable, hasLength(1));
      final msg = service.reliable.single as TabsActivateMsg;
      expect(msg.id, 7);
    });

    test('close(9) sends TabsCloseMsg with that id', () {
      container.read(tabsStateProvider.notifier).close(9);

      expect(service.reliable, hasLength(1));
      final msg = service.reliable.single as TabsCloseMsg;
      expect(msg.id, 9);
    });
  });

  group('TabsNotifier — view snapshots', () {
    late _FakeService service;
    late ProviderContainer container;

    setUp(() {
      service = _FakeService();
      container = ProviderContainer(
        overrides: [
          connectionServiceProvider.overrideWith((ref) => service),
        ],
      );
      addTearDown(container.dispose);
      addTearDown(service.pings.close);
    });

    test('defaults to the connected:false hint state before any snapshot',
        () {
      expect(
        container.read(tabsStateProvider),
        const TabsViewState(connected: false, tabs: []),
      );
    });

    test('a changes ping re-snapshots the parked TabsSnapshot', () async {
      // Build the notifier (installs the changes listener).
      container.read(tabsStateProvider);

      service.parked = const TabsSnapshot(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
      );
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(tabsStateProvider);
      expect(state.connected, isTrue);
      expect(state.tabs.single.id, 7);
      expect(state.tabs.single.active, isTrue);
    });

    test('extension disconnect (connected:false push) flips to hint state',
        () async {
      container.read(tabsStateProvider);

      service.parked = const TabsSnapshot(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
      );
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      service.parked = const TabsSnapshot(connected: false, tabs: []);
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(tabsStateProvider),
        const TabsViewState(connected: false, tabs: []),
      );
    });
  });
}
