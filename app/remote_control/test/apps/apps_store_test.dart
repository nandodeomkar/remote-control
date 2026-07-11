// Task 2 (06-03, TDD) — the favorites PrefsKv store + AppsViewState value
// equality, proven over a fake PrefsKv (no platform, no Riverpod).
//
// Covers (D-01/D-02): a favorite persists and reloads; a UWP window
// (path==null) is non-pinnable (rejected, no-op); consecutive duplicate
// paths are not double-stored (dedupe by path); unpin removes by path. Plus
// the AppsViewState value-equality that lets the notifier skip no-op rebuilds.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/apps/apps_store.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_protocol/remote_protocol.dart';

/// In-memory [PrefsKv] fake — the backing map survives across store instances
/// so "reload" is a fresh store over the same map.
class MemPrefsKv implements PrefsKv {
  final Map<String, String> map = <String, String>{};

  @override
  Future<String?> getString(String key) async => map[key];

  @override
  Future<void> setString(String key, String value) async => map[key] = value;
}

void main() {
  late MemPrefsKv prefs;
  late FavoritesStore store;

  setUp(() {
    prefs = MemPrefsKv();
    store = FavoritesStore(prefs: prefs);
  });

  group('FavoritesStore — pin/persist/reload', () {
    test('pinning a window with a path persists and reloads', () async {
      final ok = await store.pin(const WindowInfo(
        id: 7,
        title: 'Firefox',
        icon: 'AA==',
        path: r'C:\ff.exe',
      ));
      expect(ok, isTrue);

      // Reload over the SAME backing map (a fresh store instance).
      final reloaded = await FavoritesStore(prefs: prefs).load();
      expect(reloaded, hasLength(1));
      expect(reloaded.single.name, 'Firefox');
      expect(reloaded.single.path, r'C:\ff.exe');
      expect(reloaded.single.icon, 'AA==');
    });

    test('a favorite with no icon persists (icon stays null)', () async {
      await store.pin(const WindowInfo(id: 1, title: 'App', path: r'C:\a.exe'));
      final favs = await store.load();
      expect(favs.single.icon, isNull);
    });
  });

  group('FavoritesStore — UWP non-pinnable (D-01/D-02, Flag 1)', () {
    test('pinning a path==null window is rejected and stores nothing',
        () async {
      final ok =
          await store.pin(const WindowInfo(id: 9, title: 'Settings'));
      expect(ok, isFalse, reason: 'UWP (path==null) is non-pinnable');
      expect(await store.load(), isEmpty);
    });
  });

  group('FavoritesStore — dedupe by path', () {
    test('pinning the same path twice does not double-store', () async {
      const w = WindowInfo(id: 2, title: 'Editor', path: r'C:\ed.exe');
      expect(await store.pin(w), isTrue);
      expect(await store.pin(w), isTrue);
      expect(await store.load(), hasLength(1));
    });
  });

  group('FavoritesStore — unpin', () {
    test('unpin removes the favorite by path', () async {
      await store.pin(const WindowInfo(id: 3, title: 'A', path: r'C:\a.exe'));
      await store.pin(const WindowInfo(id: 4, title: 'B', path: r'C:\b.exe'));
      await store.unpin(r'C:\a.exe');

      final favs = await store.load();
      expect(favs, hasLength(1));
      expect(favs.single.path, r'C:\b.exe');
    });
  });

  group('FavoritesStore — corruption tolerance', () {
    test('a corrupt blob degrades to empty (never throws)', () async {
      prefs.map['apps.favorites'] = '{not valid json';
      expect(await store.load(), isEmpty);
    });
  });

  group('AppsViewState — value equality', () {
    test('identical windows + favorites are equal', () {
      const a = AppsViewState(
        windows: [WindowInfo(id: 1, title: 'X')],
        favorites: [Favorite(name: 'X', path: r'C:\x.exe')],
      );
      const b = AppsViewState(
        windows: [WindowInfo(id: 1, title: 'X')],
        favorites: [Favorite(name: 'X', path: r'C:\x.exe')],
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing window makes them unequal', () {
      const a = AppsViewState(
        windows: [WindowInfo(id: 1, title: 'X')],
        favorites: [],
      );
      const b = AppsViewState(
        windows: [WindowInfo(id: 2, title: 'Y')],
        favorites: [],
      );
      expect(a, isNot(b));
    });
  });
}
