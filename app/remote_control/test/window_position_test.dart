// Task 2 (08-01, TDD) — window_position.dart store + notifier (D8-03).
// Proves the two-half house pattern (mirror of bubble_position_test.dart) for
// the floating window's (x, y) position with an UNSET sentinel default:
//   1. round-trips a set (0.2, 0.5),
//   2. defaults to the unset sentinel (isSet=false) when unset,
//   3. degrades a corrupt stored value to the unset sentinel (never throws),
//   4. clamps stored fractions outside [0,1] into [0,1] when set,
//   5. the notifier seeds the unset sentinel synchronously and set() updates.
//
// The window store is fully independent of the bubble store (SC4: two
// independent persisted positions) — no shared key, no cross-reference.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/settings/window_position.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferencesAsync prefs;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    prefs = SharedPreferencesAsync();
  });

  group('WindowPositionStore', () {
    test('round-trips a set (0.2, 0.5)', () async {
      final store = WindowPositionStore();
      await store.save(const WindowPosition.at(0.2, 0.5));

      final loaded = await store.load();

      expect(loaded.isSet, isTrue);
      expect(loaded.xFraction, 0.2);
      expect(loaded.yFraction, 0.5);
    });

    test('defaults to the unset sentinel when unset', () async {
      final loaded = await WindowPositionStore().load();

      expect(loaded.isSet, isFalse);
      expect(loaded, const WindowPosition.unset());
    });

    test('degrades a corrupt (bad JSON) stored value to the unset sentinel',
        () async {
      await prefs.setString(kWindowPositionPrefsKey, 'not json {{{');

      final loaded = await WindowPositionStore().load();

      expect(loaded, const WindowPosition.unset());
    });

    test('degrades a wrong-type stored value to the unset sentinel', () async {
      await prefs.setString(
        kWindowPositionPrefsKey,
        jsonEncode({'x': 'left', 'y': 0.5}),
      );

      final loaded = await WindowPositionStore().load();

      expect(loaded, const WindowPosition.unset());
    });

    test('clamps stored fractions above 1 into [0,1] when set', () async {
      await prefs.setString(
        kWindowPositionPrefsKey,
        jsonEncode({'x': 1.7, 'y': 2.0}),
      );

      final loaded = await WindowPositionStore().load();

      expect(loaded.isSet, isTrue);
      expect(loaded.xFraction, 1.0);
      expect(loaded.yFraction, 1.0);
    });

    test('clamps stored fractions below 0 into [0,1] when set', () async {
      await prefs.setString(
        kWindowPositionPrefsKey,
        jsonEncode({'x': -0.3, 'y': -1.0}),
      );

      final loaded = await WindowPositionStore().load();

      expect(loaded.isSet, isTrue);
      expect(loaded.xFraction, 0.0);
      expect(loaded.yFraction, 0.0);
    });

    test('clamps fractions on write too', () async {
      final store = WindowPositionStore();
      await store.save(const WindowPosition.at(2.0, -1.0));

      final loaded = await store.load();

      expect(loaded, const WindowPosition.at(1.0, 0.0));
    });

    test('uses a different prefs key than the bubble store', () {
      expect(kWindowPositionPrefsKey, isNot('bubble.position'));
    });
  });

  group('WindowPositionNotifier', () {
    test('build() seeds the unset sentinel synchronously', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      final seeded = container.read(windowPositionProvider);
      expect(seeded.isSet, isFalse);
      expect(seeded, const WindowPosition.unset());
    });

    test('set() updates state immediately', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container
          .read(windowPositionProvider.notifier)
          .set(const WindowPosition.at(0.3, 0.6));

      expect(
        container.read(windowPositionProvider),
        const WindowPosition.at(0.3, 0.6),
      );
    });
  });

  group('WindowPosition value equality', () {
    test('equal fields compare equal with matching hashCode', () {
      const a = WindowPosition.at(0.5, 0.5);
      const b = WindowPosition.at(0.5, 0.5);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a set position never equals the unset sentinel', () {
      const set = WindowPosition.at(0.0, 0.0);

      expect(set, isNot(const WindowPosition.unset()));
    });
  });
}
