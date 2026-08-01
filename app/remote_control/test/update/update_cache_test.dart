/// The D-07 24-hour check cache: TTL predicate + degrading prefs reads.
///
/// The whole file runs against an in-memory [PrefsKv] — no plugin, no
/// platform channel, no real clock. `isStale` takes an injected `now`, so
/// every TTL boundary is asserted exactly rather than approximated by waiting.
///
/// The two behaviours that matter most here are negative ones: a corrupt
/// stored value must load as "never checked" and throw NOTHING, and a prefs
/// backend that throws must do the same. A broken cache costs one extra feed
/// check; a cache that throws would take the Updates screen (and the badge)
/// down with it.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/store/device_store.dart';
import 'package:remote_control/update/update_cache.dart';

/// In-memory [PrefsKv] — the seam's whole point.
class FakePrefsKv implements PrefsKv {
  final Map<String, String> values = <String, String>{};

  @override
  Future<String?> getString(String key) async => values[key];

  @override
  Future<void> setString(String key, String value) async {
    values[key] = value;
  }
}

/// A [PrefsKv] whose reads always throw, standing in for a platform failure.
class ThrowingPrefsKv implements PrefsKv {
  @override
  Future<String?> getString(String key) async =>
      throw PlatformException(code: 'boom');

  @override
  Future<void> setString(String key, String value) async =>
      throw PlatformException(code: 'boom');
}

/// A fixed reference instant so every TTL case reads as arithmetic.
final DateTime kNow = DateTime.utc(2026, 8, 1, 12);

/// A cache entry last checked [ago] before [kNow].
UpdateCacheState checkedAgo(Duration ago, {String? version = '1.4.0'}) =>
    UpdateCacheState(
      lastCheckAtMillis: kNow.subtract(ago).millisecondsSinceEpoch,
      lastSeenVersion: version,
    );

void main() {
  group('isStale (injected clock — no DateTime.now anywhere)', () {
    test('a 23h59m old check is still fresh', () {
      expect(
        isStale(checkedAgo(const Duration(hours: 23, minutes: 59)), now: kNow),
        isFalse,
      );
    });

    test('a 24h01m old check is stale', () {
      expect(
        isStale(checkedAgo(const Duration(hours: 24, minutes: 1)), now: kNow),
        isTrue,
      );
    });

    test('exactly 24h is already stale (the boundary is inclusive)', () {
      expect(
        isStale(checkedAgo(const Duration(hours: 24)), now: kNow),
        isTrue,
      );
    });

    test('an absent cache is stale', () {
      expect(
        isStale(const UpdateCacheState.neverChecked(), now: kNow),
        isTrue,
      );
    });

    test('a check timestamped in the future is stale, not pinned fresh', () {
      // A timezone change, an NTP correction, or a tampered entry must never
      // stop the app from ever checking again.
      expect(
        isStale(checkedAgo(const Duration(days: -30)), now: kNow),
        isTrue,
      );
    });

    test('the TTL constant is the D-07 24 hours', () {
      expect(kUpdateCheckTtl, const Duration(hours: 24));
    });
  });

  group('UpdateCacheStore.load degrades, never throws', () {
    test('an empty backend loads as never-checked', () async {
      final store = UpdateCacheStore(prefs: FakePrefsKv());
      expect(await store.load(), const UpdateCacheState.neverChecked());
    });

    test('a corrupt timestamp loads as the default and throws nothing',
        () async {
      final prefs = FakePrefsKv()
        ..values[kUpdateLastCheckAtPrefsKey] = 'not-a-number'
        ..values[kUpdateLastSeenVersionPrefsKey] = '1.5.0';
      final store = UpdateCacheStore(prefs: prefs);

      await expectLater(store.load(), completes);
      final state = await store.load();
      expect(state, const UpdateCacheState.neverChecked());
      expect(state.isNeverChecked, isTrue);
      expect(state.lastSeenVersion, isNull);
    });

    test('a negative epoch is treated as corrupt, not as a very old check',
        () async {
      final prefs = FakePrefsKv()
        ..values[kUpdateLastCheckAtPrefsKey] = '-1000';
      final store = UpdateCacheStore(prefs: prefs);
      expect(await store.load(), const UpdateCacheState.neverChecked());
    });

    test('an empty stored version reads back as unknown, not as ""', () async {
      final prefs = FakePrefsKv()
        ..values[kUpdateLastCheckAtPrefsKey] =
            '${kNow.millisecondsSinceEpoch}'
        ..values[kUpdateLastSeenVersionPrefsKey] = '';
      final state = await UpdateCacheStore(prefs: prefs).load();
      expect(state.lastCheckAtMillis, kNow.millisecondsSinceEpoch);
      expect(state.lastSeenVersion, isNull);
    });

    test('a throwing prefs backend loads as the default and throws nothing',
        () async {
      final store = UpdateCacheStore(prefs: ThrowingPrefsKv());
      await expectLater(store.load(), completes);
      expect(await store.load(), const UpdateCacheState.neverChecked());
    });
  });

  group('UpdateCacheStore.save', () {
    test('save-then-load round-trips the version and the timestamp', () async {
      final store = UpdateCacheStore(prefs: FakePrefsKv());
      final saved = checkedAgo(const Duration(hours: 2), version: '1.5.0');

      await store.save(saved);
      final loaded = await store.load();

      expect(loaded, saved);
      expect(loaded.lastSeenVersion, '1.5.0');
      expect(isStale(loaded, now: kNow), isFalse);
    });

    test('a saved entry becomes stale once 24h have passed', () async {
      final store = UpdateCacheStore(prefs: FakePrefsKv());
      await store.save(checkedAgo(Duration.zero, version: '1.5.0'));
      final loaded = await store.load();

      expect(isStale(loaded, now: kNow), isFalse);
      expect(
        isStale(loaded, now: kNow.add(const Duration(hours: 24, minutes: 1))),
        isTrue,
      );
    });

    test('the keys are namespaced under update.', () async {
      final prefs = FakePrefsKv();
      await UpdateCacheStore(prefs: prefs)
          .save(checkedAgo(Duration.zero, version: '1.5.0'));

      expect(prefs.values.keys, everyElement(startsWith('update.')));
      expect(prefs.values.containsKey(kUpdateLastCheckAtPrefsKey), isTrue);
      expect(prefs.values.containsKey(kUpdateLastSeenVersionPrefsKey), isTrue);
    });
  });
}
