// Task 2 (06-05, TDD) — the clipboard history PrefsKv store + the send hard-cap
// helper + ClipViewState value equality, proven over a fake PrefsKv (no
// platform, no Riverpod). Mirrors apps_store_test's pure-seam coverage.
//
// Covers (D-06): a history entry persists and reloads; recording an entry that
// already exists moves it to the head (reuse-to-most-recent, consecutive
// duplicates collapse); the list caps at 5 most-recent-first; a corrupt blob
// degrades to empty. Plus the ~48 KiB Send hard-cap predicate (T-06-16b) and
// the ClipViewState value-equality that lets the notifier skip no-op rebuilds.

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/clipboard/clip_store.dart';
import 'package:remote_control/store/device_store.dart';

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
  late HistoryStore store;

  setUp(() {
    prefs = MemPrefsKv();
    store = HistoryStore(prefs: prefs);
  });

  group('HistoryStore — persist/reload', () {
    test('a recorded entry persists and reloads', () async {
      await store.record('hello');
      final reloaded = await HistoryStore(prefs: prefs).all();
      expect(reloaded, ['hello']);
    });
  });

  group('HistoryStore — consecutive dedupe (D-06)', () {
    test('recording the same text twice collapses to a single entry', () async {
      await store.record('a');
      final list = await store.record('a');
      expect(list, ['a']);
      expect(await store.all(), ['a']);
    });
  });

  group('HistoryStore — reuse moves to head (D-06)', () {
    test('recording an existing middle entry promotes it to most-recent',
        () async {
      await store.record('a');
      await store.record('b');
      await store.record('c'); // [c, b, a]
      final list = await store.record('a'); // reuse "a"
      expect(list, ['a', 'c', 'b'],
          reason: 'an existing entry moves to the head, no duplicate');
    });
  });

  group('HistoryStore — cap at 5 most-recent-first', () {
    test('a 6th distinct entry drops the oldest', () async {
      for (final t in ['a', 'b', 'c', 'd', 'e', 'f']) {
        await store.record(t);
      }
      expect(await store.all(), ['f', 'e', 'd', 'c', 'b'],
          reason: 'cap 5, most-recent-first, oldest ("a") dropped');
    });
  });

  group('HistoryStore — corruption tolerance', () {
    test('a corrupt blob degrades to empty (never throws)', () async {
      prefs.map[HistoryStore.prefsKey] = '{not a json list';
      expect(await store.all(), isEmpty);
    });
  });

  group('clipTextTooLarge — Send hard cap (T-06-16b)', () {
    test('text at the cap is allowed; over the cap is refused', () {
      final atCap = 'x' * kClipMaxBytes;
      final overCap = 'x' * (kClipMaxBytes + 1);
      expect(clipTextTooLarge(atCap), isFalse);
      expect(clipTextTooLarge(overCap), isTrue);
    });

    test('the cap is measured in UTF-8 bytes, not code units', () {
      // '€' is 3 UTF-8 bytes: (cap/3 + 1) of them exceeds the byte cap even
      // though the code-unit count is well under it.
      final many = '€' * (kClipMaxBytes ~/ 3 + 1);
      expect(many.length, lessThan(kClipMaxBytes),
          reason: 'code-unit length is under the cap');
      expect(clipTextTooLarge(many), isTrue,
          reason: 'but the UTF-8 byte length is over — refused');
    });
  });

  group('ClipViewState — value equality', () {
    test('identical history + connected are equal', () {
      const a = ClipViewState(history: ['x', 'y'], connected: true);
      const b = ClipViewState(history: ['x', 'y'], connected: true);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('a differing history makes them unequal', () {
      const a = ClipViewState(history: ['x'], connected: true);
      const b = ClipViewState(history: ['y'], connected: true);
      expect(a, isNot(b));
    });

    test('a differing connected flag makes them unequal', () {
      const a = ClipViewState(history: ['x'], connected: true);
      const b = ClipViewState(history: ['x'], connected: false);
      expect(a, isNot(b));
    });

    test('a differing autoSyncOn flag makes them unequal', () {
      const a =
          ClipViewState(history: ['x'], connected: true, autoSyncOn: true);
      const b =
          ClipViewState(history: ['x'], connected: true, autoSyncOn: false);
      expect(a, isNot(b));
    });
  });

  group('AutoSyncStore — default off + persist/reload (D-03)', () {
    test('load returns false when the key is absent (default OFF)', () async {
      final store = AutoSyncStore(prefs: prefs);
      expect(await store.load(), isFalse);
    });

    test('set(true) persists and reloads true across instances', () async {
      await AutoSyncStore(prefs: prefs).set(true);
      expect(await AutoSyncStore(prefs: prefs).load(), isTrue);
    });

    test('set(false) persists and reloads false', () async {
      await AutoSyncStore(prefs: prefs).set(true);
      await AutoSyncStore(prefs: prefs).set(false);
      expect(await AutoSyncStore(prefs: prefs).load(), isFalse);
    });
  });

  group('ClipSyncPolicy — PC→phone apply gate + echo suppression (A4/D-05)', () {
    late List<String> written; // Clipboard.setData targets
    late List<String> recorded; // history records
    late List<String> sent; // clip.set sends
    late ClipSyncPolicy policy;

    ClipSyncPolicy build() => ClipSyncPolicy(
          writeClipboard: (t) async => written.add(t),
          record: (t) async => recorded.add(t),
          send: sent.add,
        );

    setUp(() {
      written = <String>[];
      recorded = <String>[];
      sent = <String>[];
      policy = build();
    });

    test('applyPush with auto-sync ON writes + records + tracks lastSynced',
        () async {
      final applied = await policy.applyPush('hello', autoSyncOn: true);
      expect(applied, isTrue);
      expect(written, ['hello']);
      expect(recorded, ['hello']);
      expect(policy.lastSynced, 'hello');
    });

    test('applyPush with auto-sync OFF is ignored (no write, no record)',
        () async {
      final applied = await policy.applyPush('hello', autoSyncOn: false);
      expect(applied, isFalse);
      expect(written, isEmpty);
      expect(recorded, isEmpty);
      expect(policy.lastSynced, isNull);
    });

    test('applyPush of a null snapshot is ignored', () async {
      final applied = await policy.applyPush(null, autoSyncOn: true);
      expect(applied, isFalse);
      expect(written, isEmpty);
    });

    test('echo suppression: a push equal to lastSynced is ignored (no loop)',
        () async {
      await policy.applyPush('hello', autoSyncOn: true); // lastSynced = hello
      written.clear();
      recorded.clear();
      final applied = await policy.applyPush('hello', autoSyncOn: true);
      expect(applied, isFalse, reason: 'value just applied — echo, not re-applied');
      expect(written, isEmpty);
      expect(recorded, isEmpty);
    });

    test('noteSynced suppresses a later server echo of a value we just sent',
        () async {
      policy.noteSynced('mine'); // the value this device just Sent to the PC
      final applied = await policy.applyPush('mine', autoSyncOn: true);
      expect(applied, isFalse, reason: 'server bounced back our own value');
      expect(written, isEmpty);
    });
  });

  group('ClipSyncPolicy — phone→PC syncOnResume (D-08)', () {
    late List<String> recorded;
    late List<String> sent;
    late ClipSyncPolicy policy;

    ClipSyncPolicy build() => ClipSyncPolicy(
          writeClipboard: (t) async {},
          record: (t) async => recorded.add(t),
          send: sent.add,
        );

    setUp(() {
      recorded = <String>[];
      sent = <String>[];
      policy = build();
    });

    test('syncOnResume ON with a genuine new phone clip sends + records',
        () async {
      final did = await policy.syncOnResume('fresh', autoSyncOn: true);
      expect(did, isTrue);
      expect(sent, ['fresh']);
      expect(recorded, ['fresh']);
      expect(policy.lastSynced, 'fresh');
    });

    test('syncOnResume OFF sends nothing', () async {
      final did = await policy.syncOnResume('fresh', autoSyncOn: false);
      expect(did, isFalse);
      expect(sent, isEmpty);
    });

    test('syncOnResume echo-skips a value equal to lastSynced', () async {
      await policy.applyPush('x', autoSyncOn: true); // lastSynced = x
      final did = await policy.syncOnResume('x', autoSyncOn: true);
      expect(did, isFalse, reason: 'phone still holds what the PC just pushed');
      expect(sent, isEmpty);
    });

    test('syncOnResume with empty/null phone text sends nothing', () async {
      expect(await policy.syncOnResume('', autoSyncOn: true), isFalse);
      expect(await policy.syncOnResume(null, autoSyncOn: true), isFalse);
      expect(sent, isEmpty);
    });
  });
}
