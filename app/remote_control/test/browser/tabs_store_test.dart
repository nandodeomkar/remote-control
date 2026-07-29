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
        groups: [
          GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: false),
        ],
      );
      const b = TabsViewState(
        connected: true,
        tabs: [
          TabInfo(id: 7, title: 'GitHub', active: true, icon: 'AA=='),
          TabInfo(id: 9, title: 'Docs', active: false),
        ],
        groups: [
          GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: false),
        ],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing active flag makes them unequal', () {
      const a = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
        groups: [],
      );
      const b = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: false)],
        groups: [],
      );
      expect(a, isNot(b));
    });

    test('a differing group collapsed flag makes them unequal (1.5)', () {
      const a = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1)],
        groups: [
          GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: false),
        ],
      );
      const b = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1)],
        groups: [
          GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: true),
        ],
      );
      expect(a, isNot(b));
    });

    test('a differing connected flag makes them unequal', () {
      const a = TabsViewState(connected: true, tabs: [], groups: []);
      const b = TabsViewState(connected: false, tabs: [], groups: []);
      expect(a, isNot(b));
    });

    test('a differing optimistic star overlay makes them unequal (D-12)', () {
      const a = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
        groups: [],
        optimisticStars: {},
      );
      const b = TabsViewState(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
        groups: [],
        optimisticStars: {7: true},
      );
      expect(a, isNot(b), reason: 'a flip must rebuild the screen');
      expect(b, isNot(a));
      expect(
        b,
        const TabsViewState(
          connected: true,
          tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
          groups: [],
          optimisticStars: {7: true},
        ),
      );
      expect(
        b.hashCode,
        const TabsViewState(
          connected: true,
          tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
          groups: [],
          optimisticStars: {7: true},
        ).hashCode,
      );
    });

    test('bookmarkedFor preserves the tri-state when no overlay entry exists',
        () {
      const state = TabsViewState(
        connected: true,
        tabs: [
          TabInfo(id: 1, title: 'Starred', active: false, bookmarked: true),
          TabInfo(id: 2, title: 'Plain', active: false, bookmarked: false),
          TabInfo(id: 3, title: 'Unknown', active: false),
        ],
        groups: [],
      );
      expect(state.bookmarkedFor(state.tabs[0]), isTrue);
      expect(state.bookmarkedFor(state.tabs[1]), isFalse);
      expect(state.bookmarkedFor(state.tabs[2]), isNull,
          reason: 'UNKNOWN must stay null — the row renders NO star (D-11)');
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
        const TabsViewState(connected: false, tabs: [], groups: []),
      );
    });

    test('a changes ping re-snapshots the parked TabsSnapshot', () async {
      // Build the notifier (installs the changes listener).
      container.read(tabsStateProvider);

      service.parked = const TabsSnapshot(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true, groupId: 1)],
        groups: [
          GroupInfo(id: 1, title: 'Work', color: 'blue', collapsed: false),
        ],
      );
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(tabsStateProvider);
      expect(state.connected, isTrue);
      expect(state.tabs.single.id, 7);
      expect(state.tabs.single.active, isTrue);
      expect(state.tabs.single.groupId, 1,
          reason: 'groupId must map through to the view (1.5)');
      expect(state.groups.single.color, 'blue',
          reason: 'groups must map through to the view (1.5)');
    });

    test('a snapshot with empty groups yields the flat view (1.5)', () async {
      container.read(tabsStateProvider);

      service.parked = const TabsSnapshot(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
        groups: [],
      );
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(tabsStateProvider);
      expect(state.groups, isEmpty);
      expect(state.tabs.single.groupId, isNull);
    });

    test('extension disconnect (connected:false push) flips to hint state',
        () async {
      container.read(tabsStateProvider);

      service.parked = const TabsSnapshot(
        connected: true,
        tabs: [TabInfo(id: 7, title: 'GitHub', active: true)],
        groups: [],
      );
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      service.parked = const TabsSnapshot(connected: false, tabs: [], groups: []);
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      expect(
        container.read(tabsStateProvider),
        const TabsViewState(connected: false, tabs: [], groups: []),
      );
    });
  });

  group('TabsNotifier — optimistic star overlay (D-12)', () {
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

    /// Parks a BRAND-NEW snapshot object (what ConnectionService does on every
    /// tabs.changed / tabs.list reply) and pings.
    Future<void> pushTab({required bool? bookmarked}) async {
      service.parked = TabsSnapshot(
        connected: true,
        tabs: [
          TabInfo(id: 7, title: 'GitHub', active: true, bookmarked: bookmarked),
        ],
        groups: const [],
      );
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);
    }

    test('star(7) flips the rendered state instantly and sends BmStarMsg',
        () async {
      container.read(tabsStateProvider);
      await pushTab(bookmarked: false);

      container.read(tabsStateProvider.notifier).star(7);

      final state = container.read(tabsStateProvider);
      expect(state.bookmarkedFor(state.tabs.single), isTrue,
          reason: 'no snapshot needed — the flip renders immediately');
      expect(service.reliable, hasLength(1));
      expect((service.reliable.single as BmStarMsg).tabId, 7);
    });

    test('unstar(7) flips it off instantly and sends BmUnstarMsg', () async {
      container.read(tabsStateProvider);
      await pushTab(bookmarked: true);

      container.read(tabsStateProvider.notifier).unstar(7);

      final state = container.read(tabsStateProvider);
      expect(state.bookmarkedFor(state.tabs.single), isFalse);
      expect(service.reliable, hasLength(1));
      expect((service.reliable.single as BmUnstarMsg).tabId, 7);
    });

    test('a new snapshot is authoritative even when it DISAGREES', () async {
      container.read(tabsStateProvider);
      await pushTab(bookmarked: false);
      container.read(tabsStateProvider.notifier).star(7);

      // The PC pushes again and still says false (the star did not land, or
      // this snapshot predates it). The pushed value wins.
      await pushTab(bookmarked: false);

      final state = container.read(tabsStateProvider);
      expect(state.bookmarkedFor(state.tabs.single), isFalse);
      expect(state.optimisticStars, isEmpty);
    });

    test('an unrelated changes ping does NOT clear the overlay', () async {
      container.read(tabsStateProvider);
      await pushTab(bookmarked: false);
      container.read(tabsStateProvider.notifier).star(7);

      // A volume / apps / clipboard ping: the SAME parked snapshot object.
      service.pings.add(null);
      await Future<void>.delayed(Duration.zero);

      final state = container.read(tabsStateProvider);
      expect(state.bookmarkedFor(state.tabs.single), isTrue,
          reason: 'only a NEW snapshot identity reconciles (D-12)');
      expect(service.reliable, hasLength(1));
    });

    test('an UNKNOWN tab keeps null until the user flips it', () async {
      container.read(tabsStateProvider);
      await pushTab(bookmarked: null);

      var state = container.read(tabsStateProvider);
      expect(state.bookmarkedFor(state.tabs.single), isNull);

      container.read(tabsStateProvider.notifier).star(7);
      state = container.read(tabsStateProvider);
      expect(state.bookmarkedFor(state.tabs.single), isTrue);
    });

    test('the overlay never aliases the notifier map (state stays immutable)',
        () async {
      container.read(tabsStateProvider);
      await pushTab(bookmarked: false);

      container.read(tabsStateProvider.notifier).star(7);
      final before = container.read(tabsStateProvider);

      container.read(tabsStateProvider.notifier).unstar(7);
      final after = container.read(tabsStateProvider);

      expect(before.optimisticStars[7], isTrue,
          reason: 'the earlier state value must not have mutated under us');
      expect(after.optimisticStars[7], isFalse);
      expect(before, isNot(after));
    });
  });
}
