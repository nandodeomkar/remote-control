// Task 1 (08-01, TDD) — bubble_position.dart store + notifier (D8-02).
// Proves the two-half SensitivityStore/SensitivityNotifier house pattern for
// the bubble's (edge, yFraction) position:
//   1. round-trips (right, 0.70),
//   2. defaults to (right, 0.70) when unset,
//   3. degrades a corrupt/unknown stored value to the default (never throws),
//   4. clamps a stored yFraction outside [0,1] into [0,1],
//   5. the notifier seeds the default synchronously and set() updates state.
//
// Backed by an in-memory SharedPreferencesAsync platform double (mirrors
// settings_screen_test.dart) so the store's default real adapter works with no
// plugin channel; the store signature matches SensitivityStore exactly.

import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/settings/bubble_position.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferencesAsync prefs;

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    prefs = SharedPreferencesAsync();
  });

  group('BubblePositionStore', () {
    test('round-trips (right, 0.70)', () async {
      final store = BubblePositionStore();
      await store.save(const BubblePosition(edge: Edge.right, yFraction: 0.70));

      final loaded = await store.load();

      expect(loaded.edge, Edge.right);
      expect(loaded.yFraction, 0.70);
    });

    test('round-trips a left-edge position', () async {
      final store = BubblePositionStore();
      await store.save(const BubblePosition(edge: Edge.left, yFraction: 0.25));

      final loaded = await store.load();

      expect(loaded, const BubblePosition(edge: Edge.left, yFraction: 0.25));
    });

    test('defaults to (right, 0.70) when unset', () async {
      final loaded = await BubblePositionStore().load();

      expect(loaded, const BubblePosition(edge: Edge.right, yFraction: 0.70));
    });

    test('degrades a corrupt (bad JSON) stored value to the default', () async {
      await prefs.setString(kBubblePositionPrefsKey, 'not json {{{');

      final loaded = await BubblePositionStore().load();

      expect(loaded, const BubblePosition(edge: Edge.right, yFraction: 0.70));
    });

    test('degrades an unknown edge string to the default', () async {
      await prefs.setString(
        kBubblePositionPrefsKey,
        jsonEncode({'edge': 'up', 'yFraction': 0.3}),
      );

      final loaded = await BubblePositionStore().load();

      expect(loaded, const BubblePosition(edge: Edge.right, yFraction: 0.70));
    });

    test('degrades a wrong-type stored value to the default', () async {
      await prefs.setString(
        kBubblePositionPrefsKey,
        jsonEncode({'edge': 'left', 'yFraction': 'high'}),
      );

      final loaded = await BubblePositionStore().load();

      expect(loaded, const BubblePosition(edge: Edge.right, yFraction: 0.70));
    });

    test('clamps a stored yFraction above 1 into [0,1]', () async {
      await prefs.setString(
        kBubblePositionPrefsKey,
        jsonEncode({'edge': 'left', 'yFraction': 1.8}),
      );

      final loaded = await BubblePositionStore().load();

      expect(loaded.edge, Edge.left);
      expect(loaded.yFraction, 1.0);
    });

    test('clamps a stored yFraction below 0 into [0,1]', () async {
      await prefs.setString(
        kBubblePositionPrefsKey,
        jsonEncode({'edge': 'right', 'yFraction': -0.5}),
      );

      final loaded = await BubblePositionStore().load();

      expect(loaded.edge, Edge.right);
      expect(loaded.yFraction, 0.0);
    });

    test('clamps yFraction on write too', () async {
      final store = BubblePositionStore();
      await store.save(const BubblePosition(edge: Edge.left, yFraction: 2.0));

      final loaded = await store.load();

      expect(loaded, const BubblePosition(edge: Edge.left, yFraction: 1.0));
    });
  });

  group('BubblePositionNotifier', () {
    test('build() seeds the default (right, 0.70) synchronously', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      expect(
        container.read(bubblePositionProvider),
        const BubblePosition(edge: Edge.right, yFraction: 0.70),
      );
    });

    test('set() updates state immediately', () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(bubblePositionProvider.notifier).set(
            const BubblePosition(edge: Edge.left, yFraction: 0.4),
          );

      expect(
        container.read(bubblePositionProvider),
        const BubblePosition(edge: Edge.left, yFraction: 0.4),
      );
    });
  });

  group('BubblePosition value equality', () {
    test('equal fields compare equal with matching hashCode', () {
      const a = BubblePosition(edge: Edge.left, yFraction: 0.5);
      const b = BubblePosition(edge: Edge.left, yFraction: 0.5);

      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('differing fields compare unequal', () {
      const a = BubblePosition(edge: Edge.left, yFraction: 0.5);
      const b = BubblePosition(edge: Edge.right, yFraction: 0.5);
      const c = BubblePosition(edge: Edge.left, yFraction: 0.6);

      expect(a, isNot(b));
      expect(a, isNot(c));
    });
  });
}
