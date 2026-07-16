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

    test('save() never writes the docked panel\'s keyboard.rowGroup key',
        () async {
      await store.save(KeyboardPad.fn);
      expect(prefs.map.containsKey(kKeyRowGroupPrefsKey), isFalse);
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
}
