/// KeyRows widget tests (04-06 Task 2, KEY-02/KEY-04, D-09/D-11).
///
/// The contract under test:
/// (a) every code any cap emits is in kClientKeyCodes — the byte-for-byte
///     mirror of keymap.rs CLIENT_KEY_CODES (unknown codes are dropped
///     SILENTLY server-side, so a stray string is a dead key);
/// (b) press-and-release with no armed mods is a down/up pair in order
///     (the KEY-04 hold path — Windows autorepeats between them);
/// (c) with armed mods pending at press-down, release fires exactly one
///     tap+mods and ZERO down/up (the D-10 combo path);
/// (d) the group switcher persists the selection under 'keyboard.rowGroup';
/// plus the 48px touch-target floor on a representative cap.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/key_rows.dart';
import 'package:remote_control/store/device_store.dart';

/// In-memory [PrefsKv] (device_store test house pattern) — the persistence
/// seam for the row-group store.
class _FakePrefsKv implements PrefsKv {
  final Map<String, String> map = {};

  @override
  Future<String?> getString(String key) async => map[key];

  @override
  Future<void> setString(String key, String value) async {
    map[key] = value;
  }
}

void main() {
  test('every cap code across all three groups is in kClientKeyCodes '
      '(KEY-02 vocabulary gate)', () {
    for (final group in KeyRowGroup.values) {
      for (final def in capsForGroup(group)) {
        expect(
          kClientKeyCodes,
          contains(def.code),
          reason: '${group.name} cap ${def.code} must be in the locked '
              'keymap.rs vocabulary or the server drops it silently',
        );
      }
    }
  });

  group('key-cap emission model', () {
    late List<String> events;
    late bool armed;

    setUp(() {
      events = <String>[];
      armed = false;
    });

    Widget host({KeyRowGroup group = KeyRowGroup.nav, bool enabled = true}) =>
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: KeyRows(
                group: group,
                enabled: enabled,
                onKeyDown: (code) => events.add('down:$code'),
                onKeyUp: (code) => events.add('up:$code'),
                onKeyTapWithMods: (code) => events.add('tapMods:$code'),
                hasArmedMods: () => armed,
                onPressHaptic: () => events.add('haptic'),
              ),
            ),
          ),
        );

    Finder rightArrowCap() => find.ancestor(
          of: find.byIcon(Icons.arrow_forward),
          matching: find.byType(GestureDetector),
        );

    testWidgets(
        'press-and-release on Right with no armed mods: down then up in order '
        '(KEY-04 hold path)', (tester) async {
      await tester.pumpWidget(host());

      final gesture =
          await tester.startGesture(tester.getCenter(rightArrowCap()));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(events, ['haptic', 'down:Right', 'up:Right']);
    });

    testWidgets(
        'with armed mods at press-down: release fires exactly one tap+mods '
        'and zero down/up (D-10 combo path)', (tester) async {
      armed = true;
      await tester.pumpWidget(host());

      final gesture =
          await tester.startGesture(tester.getCenter(rightArrowCap()));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(events, ['haptic', 'tapMods:Right']);
    });

    testWidgets('disabled rows are inert (gated state)', (tester) async {
      await tester.pumpWidget(host(enabled: false));

      final gesture =
          await tester.startGesture(tester.getCenter(rightArrowCap()));
      await tester.pump();
      await gesture.up();
      await tester.pump();

      expect(events, isEmpty);
    });

    testWidgets('caps meet the 48px touch-target floor', (tester) async {
      await tester.pumpWidget(host());

      final escSize = tester.getSize(find.ancestor(
        of: find.text('Esc'),
        matching: find.byType(GestureDetector),
      ));
      expect(escSize.width, greaterThanOrEqualTo(48));
      expect(escSize.height, greaterThanOrEqualTo(48));
    });

    testWidgets('fn and num groups render their full cap sets',
        (tester) async {
      await tester.pumpWidget(host(group: KeyRowGroup.fn));
      expect(find.text('F1'), findsOneWidget);
      expect(find.text('F12'), findsOneWidget);

      await tester.pumpWidget(host(group: KeyRowGroup.num));
      expect(find.text('7'), findsOneWidget);
      expect(find.text('0'), findsOneWidget);
      expect(find.text('Enter'), findsOneWidget);
      expect(find.text('.'), findsOneWidget);
    });
  });

  group('group switcher + persistence', () {
    testWidgets(
        "switching to Fn persists 'fn' under keyboard.rowGroup (D-09)",
        (tester) async {
      final prefs = _FakePrefsKv();
      final store = KeyRowGroupStore(prefs: prefs);
      KeyRowGroup? selected;

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: KeyRowGroupSwitcher(
            group: KeyRowGroup.nav,
            onChanged: (group) {
              selected = group;
              store.save(group);
            },
          ),
        ),
      ));

      await tester.tap(find.text('Fn'));
      await tester.pump();

      expect(selected, KeyRowGroup.fn);
      expect(prefs.map[kKeyRowGroupPrefsKey], 'fn');
    });

    test('store defaults to nav when unset or corrupt', () async {
      final prefs = _FakePrefsKv();
      final store = KeyRowGroupStore(prefs: prefs);
      expect(await store.load(), KeyRowGroup.nav);

      prefs.map[kKeyRowGroupPrefsKey] = 'garbage';
      expect(await store.load(), KeyRowGroup.nav);

      prefs.map[kKeyRowGroupPrefsKey] = 'num';
      expect(await store.load(), KeyRowGroup.num);
    });
  });
}
