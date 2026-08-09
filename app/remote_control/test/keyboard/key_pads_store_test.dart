/// keyboard.pad persistence tests (10-03 Task 2, TDD).
///
/// The contract under test (10-UI-SPEC §Pad persistence): the last-open pad
/// persists under a NEW prefs key, defaults to Type when unset, and degrades
/// to Type on a corrupt/unknown read — a broken pref must never take the
/// keyboard down (T-10-04).
///
/// The trackpad-docked panel's `keyboard.rowGroup` key is a SEPARATE store
/// (D-07, out of scope) — the distinctness of the two keys is asserted here.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/key_rows.dart';
import 'package:remote_control/store/device_store.dart';

/// In-memory [PrefsKv] (device_store test house pattern) — the backing map
/// survives across store instances, so "reload" is a fresh store over it.
class _FakePrefsKv implements PrefsKv {
  final Map<String, String> map = {};

  @override
  Future<String?> getString(String key) async => map[key];

  @override
  Future<void> setString(String key, String value) async {
    map[key] = value;
  }
}

/// A [PrefsKv] whose reads throw — the platform-failure path.
class _ThrowingPrefsKv implements PrefsKv {
  @override
  Future<String?> getString(String key) async => throw StateError('no plugin');

  @override
  Future<void> setString(String key, String value) async =>
      throw StateError('no plugin');
}

void main() {
  test('kKeyboardPadPrefsKey is "keyboard.pad", distinct from the docked '
      "panel's keyboard.rowGroup (D-07 untouched)", () {
    expect(kKeyboardPadPrefsKey, 'keyboard.pad');
    expect(kKeyRowGroupPrefsKey, 'keyboard.rowGroup');
    expect(kKeyboardPadPrefsKey, isNot(kKeyRowGroupPrefsKey));
  });

  group('KeyboardPadStore', () {
    late _FakePrefsKv prefs;
    late KeyboardPadStore store;

    setUp(() {
      prefs = _FakePrefsKv();
      store = KeyboardPadStore(prefs: prefs);
    });

    test('load() with no stored value is KeyboardPad.type (the default)',
        () async {
      expect(await store.load(), KeyboardPad.type);
    });

    test('load() with an unknown string degrades to KeyboardPad.type',
        () async {
      prefs.map[kKeyboardPadPrefsKey] = 'not-a-pad';
      expect(await store.load(), KeyboardPad.type);
    });

    test('load() with a corrupt (empty) string degrades to KeyboardPad.type',
        () async {
      prefs.map[kKeyboardPadPrefsKey] = '';
      expect(await store.load(), KeyboardPad.type);
    });

    test('load() degrades to KeyboardPad.type when the platform read throws '
        '(a broken pref never takes the keyboard down — T-10-04)', () async {
      expect(await KeyboardPadStore(prefs: _ThrowingPrefsKv()).load(),
          KeyboardPad.type);
    });

    test('save(pad) writes pad.name under keyboard.pad', () async {
      await store.save(KeyboardPad.numpad);
      expect(prefs.map[kKeyboardPadPrefsKey], 'numpad');
    });

    test("save() never writes the docked panel's key", () async {
      await store.save(KeyboardPad.fn);
      expect(prefs.map.containsKey(kPanelPadPrefsKey), isFalse);
      expect(prefs.map.keys, [kKeyboardPadPrefsKey]);
    });

    for (final pad in KeyboardPad.values) {
      test('save/load roundtrips ${pad.name}', () async {
        await store.save(pad);
        // A fresh store over the same map = a restart.
        expect(await KeyboardPadStore(prefs: prefs).load(), pad);
      });
    }
  });

  // ── The docked panel's mount-point key + its one-time migration ──────────
  //
  // 260809-ipc, D-94: ONE model (KeyboardPad), TWO keys. The retired
  // docked-panel preference is migrated on the panel store's first load, not
  // orphaned — and the legacy key is spelled BY HAND here so the migration
  // cannot drift away from what shipped installs actually wrote.
  group('the docked panel store (kPanelPadPrefsKey)', () {
    /// The retired preference, pinned by hand — never imported.
    const retiredKey = 'keyboard.rowGroup';

    late _FakePrefsKv prefs;
    late KeyboardPadStore panel;

    setUp(() {
      prefs = _FakePrefsKv();
      panel = KeyboardPadStore(
        prefs: prefs,
        key: kPanelPadPrefsKey,
        migrateRetiredPanelKey: true,
      );
    });

    test('kPanelPadPrefsKey is "keyboard.panelPad", distinct from the '
        'full-screen keyboard\'s key', () {
      expect(kPanelPadPrefsKey, 'keyboard.panelPad');
      expect(kPanelPadPrefsKey, isNot(kKeyboardPadPrefsKey));
    });

    test('no keys at all: KeyboardPad.type (the default)', () async {
      expect(await panel.load(), KeyboardPad.type);
    });

    const migrations = {
      'num': KeyboardPad.numpad,
      'fn': KeyboardPad.fn,
      'nav': KeyboardPad.type,
      'not-a-group': KeyboardPad.type,
      '': KeyboardPad.type,
    };

    for (final entry in migrations.entries) {
      test('a retired "${entry.key}" migrates to ${entry.value.name} and is '
          'written straight back under the panel key', () async {
        prefs.map[retiredKey] = entry.key;

        expect(await panel.load(), entry.value);
        expect(prefs.map[kPanelPadPrefsKey], entry.value.name,
            reason: 'the migration must persist immediately, so the legacy '
                'read never happens a second time');

        // The second load reads the panel key only — remove the legacy value
        // and the answer is unchanged.
        prefs.map.remove(retiredKey);
        expect(await panel.load(), entry.value);
      });
    }

    test('both keys present: the panel key wins and the legacy value is '
        'ignored', () async {
      prefs.map[retiredKey] = 'fn';
      prefs.map[kPanelPadPrefsKey] = 'arrows';

      expect(await panel.load(), KeyboardPad.arrows);
      expect(prefs.map[kPanelPadPrefsKey], 'arrows');
    });

    test('a throwing platform read degrades to KeyboardPad.type — a broken '
        'pref never takes the keyboard down (T-10-04)', () async {
      final throwing = KeyboardPadStore(
        prefs: _ThrowingPrefsKv(),
        key: kPanelPadPrefsKey,
        migrateRetiredPanelKey: true,
      );
      expect(await throwing.load(), KeyboardPad.type);
    });

    test('save/load roundtrips every pad under the panel key, and never '
        'touches the full-screen key', () async {
      for (final pad in KeyboardPad.values) {
        await panel.save(pad);
        expect(prefs.map[kPanelPadPrefsKey], pad.name);
        expect(prefs.map.containsKey(kKeyboardPadPrefsKey), isFalse);
        expect(await panel.load(), pad);
      }
    });

    test('the migration is OFF by default — a plain store ignores the retired '
        'key entirely', () async {
      prefs.map[retiredKey] = 'fn';
      final plain = KeyboardPadStore(prefs: prefs, key: kPanelPadPrefsKey);

      expect(await plain.load(), KeyboardPad.type);
      expect(prefs.map.containsKey(kPanelPadPrefsKey), isFalse);
    });
  });
}
