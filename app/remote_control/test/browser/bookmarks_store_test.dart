// Plan 11-08 task 2 — BookmarksNotifier local folder navigation over the flat
// bm.* node list (BROW, protoVersion 1.6).
//
// The notifier is proven over the house fake ConnectionService seam (the
// tabs_store_test pattern: a subclass over fake KV stores that records
// sendReliable) inside a bare ProviderContainer — no widgets, no platform.
//
// Every navigation behaviour here is LOCAL (D-06): drilling in and backing out
// must send NOTHING on the wire, and a pushed snapshot must not move the user
// (D-04).

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/browser/bookmarks_store.dart';
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

/// Recording fake: parks a mutable [BookmarksSnapshot], exposes a test-driven
/// `changes` stream, and records every [sendReliable] message.
class _FakeService extends ConnectionService {
  _FakeService()
      : super(
          store: DeviceStore(secure: _FakeSecureKv(), prefs: _FakePrefsKv()),
        );

  final List<RemoteMessage> reliable = [];
  final StreamController<void> pings = StreamController<void>.broadcast();
  BookmarksSnapshot? parked;

  @override
  BookmarksSnapshot? get bookmarksSnapshot => parked;

  @override
  Stream<void> get changes => pings.stream;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

/// Two Chrome roots (their parentId is the virtual root "0" — D-08), with
/// folder "1" holding two links THEN a subfolder in wire order, so the
/// folders-first partition is observable.
const _tree = <BmNode>[
  BmNode(id: '1', parentId: '0', title: 'Bookmarks bar', folder: true, count: 3),
  BmNode(id: '2', parentId: '0', title: 'Other bookmarks', folder: true, count: 0),
  BmNode(id: '10', parentId: '1', title: 'GitHub'),
  BmNode(id: '11', parentId: '1', title: 'Docs'),
  BmNode(id: '12', parentId: '1', title: 'Reading', folder: true, count: 0),
];

void main() {
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

  /// Parks [nodes] and pings, so the notifier re-snapshots.
  Future<void> push(
    List<BmNode> nodes, {
    bool connected = true,
    bool truncated = false,
  }) async {
    service.parked = BookmarksSnapshot(
      connected: connected,
      nodes: nodes,
      truncated: truncated,
    );
    service.pings.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  group('BookmarksNotifier — root level (D-08 virtual root)', () {
    test('the top level lists exactly the nodes whose parentId is "0"',
        () async {
      container.read(bookmarksStateProvider);
      await push(_tree);

      final state = container.read(bookmarksStateProvider);
      expect(state.connected, isTrue);
      expect(state.currentFolderId, '0');
      expect(state.depth, 0);
      expect(state.currentFolderTitle, isNull,
          reason: 'depth 0 renders no folder bar');
      expect(
        state.currentChildren.map((n) => n.id).toList(),
        ['1', '2'],
        reason: 'both roots, in wire order — nothing is unreachable',
      );
    });

    test('connected:false yields the hint state with no children', () async {
      container.read(bookmarksStateProvider);
      await push(const [], connected: false);

      final state = container.read(bookmarksStateProvider);
      expect(state.connected, isFalse);
      expect(state.currentChildren, isEmpty);
    });
  });

  group('BookmarksNotifier — folders-first ordering', () {
    test('a folder emitted after two links still sorts ahead of them, and the '
        'links keep their relative wire order', () async {
      container.read(bookmarksStateProvider);
      await push(_tree);

      container.read(bookmarksStateProvider.notifier).enterFolder('1');

      expect(
        container.read(bookmarksStateProvider).currentChildren
            .map((n) => n.id)
            .toList(),
        ['12', '10', '11'],
      );
    });
  });

  group('BookmarksNotifier — local navigation (D-06)', () {
    test('enterFolder drills in: children, title and depth all follow',
        () async {
      container.read(bookmarksStateProvider);
      await push(_tree);

      container.read(bookmarksStateProvider.notifier).enterFolder('1');

      final state = container.read(bookmarksStateProvider);
      expect(state.currentFolderId, '1');
      expect(state.currentFolderTitle, 'Bookmarks bar');
      expect(state.depth, 1);
      expect(state.currentChildren, hasLength(3));
      expect(service.reliable, isEmpty,
          reason: 'drilling in sends NOTHING on the wire (D-06)');
    });

    test('goBack pops one level; at the root it returns false and changes '
        'nothing', () async {
      container.read(bookmarksStateProvider);
      await push(_tree);
      final notifier = container.read(bookmarksStateProvider.notifier);
      notifier.enterFolder('1');

      expect(notifier.goBack(), isTrue);
      var state = container.read(bookmarksStateProvider);
      expect(state.currentFolderId, '0');
      expect(state.depth, 0);
      expect(state.currentChildren.map((n) => n.id).toList(), ['1', '2']);

      expect(notifier.goBack(), isFalse,
          reason: 'at depth 0 the screen lets PopScope leave the route');
      state = container.read(bookmarksStateProvider);
      expect(state.currentFolderId, '0');
      expect(state.depth, 0);
      expect(service.reliable, isEmpty);
    });

    test('the folder position survives a pushed snapshot (D-04)', () async {
      container.read(bookmarksStateProvider);
      await push(_tree);
      container.read(bookmarksStateProvider.notifier).enterFolder('1');

      // A brand-new snapshot lands (a bookmark was added on the PC) while the
      // user is standing inside folder "1".
      await push([
        ..._tree,
        const BmNode(id: '13', parentId: '1', title: 'Fresh'),
      ]);

      final state = container.read(bookmarksStateProvider);
      expect(state.currentFolderId, '1',
          reason: 'a push must never move the user');
      expect(state.depth, 1);
      expect(state.currentChildren.map((n) => n.id).toList(),
          ['12', '10', '11', '13']);
    });

    test('a vanished current folder self-heals to the root, silently',
        () async {
      container.read(bookmarksStateProvider);
      await push(_tree);
      container.read(bookmarksStateProvider.notifier).enterFolder('1');

      // Folder "1" and its whole subtree are gone from the new snapshot.
      await push(const [
        BmNode(id: '2', parentId: '0', title: 'Other bookmarks', folder: true, count: 0),
      ]);

      final state = container.read(bookmarksStateProvider);
      expect(state.currentFolderId, '0');
      expect(state.depth, 0);
      expect(state.currentChildren.map((n) => n.id).toList(), ['2']);
      expect(service.reliable, isEmpty,
          reason: 'the self-heal is silent — nothing sent, no toast');
    });
  });

  group('BookmarksNotifier — commands', () {
    test('primeList sends the const bm.list request (no payload fields)',
        () async {
      container.read(bookmarksStateProvider.notifier).primeList();

      expect(service.reliable, hasLength(1));
      final msg = service.reliable.single as BmListMsg;
      expect(msg.connected, isNull, reason: 'a request carries no fields');
      expect(msg.nodes, isNull);
    });

    test('open sends BmOpenMsg and leaves the folder position alone (D-04)',
        () async {
      container.read(bookmarksStateProvider);
      await push(_tree);
      final notifier = container.read(bookmarksStateProvider.notifier);
      notifier.enterFolder('1');

      notifier.open('10');
      notifier.open('11');

      expect(service.reliable, hasLength(2));
      expect((service.reliable[0] as BmOpenMsg).nodeId, '10');
      expect((service.reliable[1] as BmOpenMsg).nodeId, '11');
      expect(container.read(bookmarksStateProvider).currentFolderId, '1');
      expect(container.read(bookmarksStateProvider).depth, 1);
    });

    test('remove sends exactly one BmRemoveMsg with that nodeId', () {
      container.read(bookmarksStateProvider.notifier).remove('12');

      expect(service.reliable, hasLength(1));
      expect((service.reliable.single as BmRemoveMsg).nodeId, '12');
    });
  });

  group('BookmarksNotifier — delete affordance gate (D-13/D-14)', () {
    test('a non-empty subfolder and a locked link offer nothing; a plain link '
        'flips the hint on', () async {
      container.read(bookmarksStateProvider);
      await push(const [
        BmNode(id: '2', parentId: '0', title: 'Other bookmarks', folder: true, count: 2),
        BmNode(id: '20', parentId: '2', title: 'Work', folder: true, count: 4),
        BmNode(id: '21', parentId: '2', title: 'Managed', locked: true),
      ]);
      container.read(bookmarksStateProvider.notifier).enterFolder('2');

      expect(container.read(bookmarksStateProvider).hasDeletableChild, isFalse);

      await push(const [
        BmNode(id: '2', parentId: '0', title: 'Other bookmarks', folder: true, count: 3),
        BmNode(id: '20', parentId: '2', title: 'Work', folder: true, count: 4),
        BmNode(id: '21', parentId: '2', title: 'Managed', locked: true),
        BmNode(id: '22', parentId: '2', title: 'Plain link'),
      ]);

      expect(container.read(bookmarksStateProvider).hasDeletableChild, isTrue);
    });
  });

  group('BookmarksViewState — truncation flags are distinct', () {
    test('the snapshot flag and the per-folder flag are read separately',
        () async {
      container.read(bookmarksStateProvider);
      await push(const [
        BmNode(id: '1', parentId: '0', title: 'Bookmarks bar', folder: true, count: 1, truncated: true),
        BmNode(id: '10', parentId: '1', title: 'GitHub'),
      ], truncated: true);

      var state = container.read(bookmarksStateProvider);
      expect(state.truncated, isTrue, reason: 'snapshot-level');
      expect(state.currentFolderTruncated, isFalse,
          reason: 'the virtual root is not a real node');

      container.read(bookmarksStateProvider.notifier).enterFolder('1');
      state = container.read(bookmarksStateProvider);
      expect(state.currentFolderTruncated, isTrue, reason: 'per-folder');
    });
  });
}
