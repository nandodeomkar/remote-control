// Task 1 (10-02) — Shortcut catalog integrity + vocabulary membership +
// ShortcutButton press/gating (the house press-down + muted-not-red pattern).
//
// The catalog is the single ordered source of truth: this suite iterates
// kShortcutCatalog, cross-checks every code against the locked kClientKeyCodes
// vocabulary (keymap.rs mirror — drift fails the build, T-10-03), asserts the
// section counts (7/3/9/6 = 25), and proves the excluded combos never render
// (Alt+Tab, Win+L lock, Ctrl+Alt+Del — user-locked exclusions).
//
// ShortcutButton is the _TransportButton press-down twin: enabled fires exactly
// one onPress on tap-DOWN; gated (enabled:false) fires nothing and renders
// muted-not-red.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/key_rows.dart' show kClientKeyCodes;
import 'package:remote_control/shortcuts/shortcuts_screen.dart';

/// The wire modifier vocabulary (modifier_fsm _kWireMods).
const Set<String> _kWireMods = {'ctrl', 'alt', 'shift', 'win'};

void main() {
  group('kShortcutCatalog integrity', () {
    test('has exactly 4 sections with counts 7/3/9/6 (25 total)', () {
      expect(kShortcutCatalog.length, 4);
      expect(
        kShortcutCatalog.map((s) => s.items.length).toList(),
        [7, 3, 9, 6],
      );
      final total =
          kShortcutCatalog.fold<int>(0, (a, s) => a + s.items.length);
      expect(total, 25);
    });

    test('section headers are the locked copy in order', () {
      expect(
        kShortcutCatalog.map((s) => s.header).toList(),
        ['Windows & Desktop', 'Screenshot', 'Browser & App', 'Editing'],
      );
    });

    test('every code is in the locked kClientKeyCodes vocabulary', () {
      for (final section in kShortcutCatalog) {
        for (final s in section.items) {
          expect(
            kClientKeyCodes,
            contains(s.code),
            reason: '${s.label} code "${s.code}" must be in keymap.rs vocab',
          );
        }
      }
    });

    test('every mods entry is one of ctrl/alt/shift/win', () {
      for (final section in kShortcutCatalog) {
        for (final s in section.items) {
          for (final m in s.mods) {
            expect(_kWireMods, contains(m),
                reason: '${s.label} mod "$m" is not a wire modifier');
          }
        }
      }
    });

    test('no excluded combo renders (Alt+Tab, Win+L lock, Ctrl+Alt+Del)', () {
      for (final section in kShortcutCatalog) {
        for (final s in section.items) {
          // Alt+Tab (Apps remote covers this).
          expect(
            s.code == 'Tab' && s.mods.contains('alt'),
            isFalse,
            reason: 'Alt+Tab is user-excluded',
          );
          // Win+L lock — no L code, no lock chord.
          expect(
            s.code == 'L' && s.mods.contains('win'),
            isFalse,
            reason: 'Win+L lock is user-excluded',
          );
          // Ctrl+Alt+Del — uninjectable secure attention sequence.
          final ctrlAltDel = s.mods.contains('ctrl') &&
              s.mods.contains('alt') &&
              (s.code == 'Del' || s.code == 'Delete');
          expect(ctrlAltDel, isFalse, reason: 'Ctrl+Alt+Del is user-excluded');
        }
      }
    });

    test('the anchor rows carry their locked code/mods', () {
      ShortcutSpec byLabel(String label) => kShortcutCatalog
          .expand((s) => s.items)
          .firstWhere((s) => s.label == label);

      final showDesktop = byLabel('Show desktop');
      expect(showDesktop.code, 'D');
      expect(showDesktop.mods, ['win']);
      expect(showDesktop.combo, 'Win+D');

      final taskMgr = byLabel('Task Manager');
      expect(taskMgr.code, 'Esc');
      expect(taskMgr.mods, ['ctrl', 'shift']);

      final clip = byLabel('Screenshot to clipboard');
      expect(clip.code, 'PrintScreen');
      expect(clip.mods, isEmpty);

      final zoomReset = byLabel('Zoom reset');
      expect(zoomReset.code, '0');
      expect(zoomReset.mods, ['ctrl']);

      final copy = byLabel('Copy');
      expect(copy.code, 'C');
      expect(copy.mods, ['ctrl']);
    });

    test('kShortcutsTitle is "Shortcuts"', () {
      expect(kShortcutsTitle, 'Shortcuts');
    });
  });

  group('ShortcutButton press + gating', () {
    const spec = ShortcutSpec(
      label: 'Show desktop',
      combo: 'Win+D',
      icon: Symbols.desktop_windows_rounded,
      code: 'D',
      mods: ['win'],
    );

    testWidgets('enabled: a press-DOWN fires onPress exactly once', (t) async {
      var fired = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShortcutButton(
            spec: spec,
            enabled: true,
            onPress: () => fired++,
          ),
        ),
      ));

      final gesture = await t.startGesture(
        t.getCenter(find.text('Show desktop')),
      );
      await t.pump();
      expect(fired, 1, reason: 'onPress fires on tap-DOWN, once');

      await gesture.up();
      await t.pump(const Duration(milliseconds: 120));
      expect(fired, 1, reason: 'tap-up does not fire again');
    });

    testWidgets('disabled: a press fires no onPress', (t) async {
      var fired = 0;
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShortcutButton(
            spec: spec,
            enabled: false,
            onPress: () => fired++,
          ),
        ),
      ));

      await t.tap(find.text('Show desktop'));
      await t.pump();
      expect(fired, 0, reason: 'gated button is inert (muted-not-red)');
    });

    testWidgets('renders effect label 14/w600, combo 12/w400, icon size 24',
        (t) async {
      await t.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ShortcutButton(
            spec: spec,
            enabled: true,
            onPress: () {},
          ),
        ),
      ));

      final effect = t.widget<Text>(find.text('Show desktop'));
      expect(effect.style?.fontSize, 14);
      expect(effect.style?.fontWeight, FontWeight.w600);

      final combo = t.widget<Text>(find.text('Win+D'));
      expect(combo.style?.fontSize, 12);
      expect(combo.style?.fontWeight, FontWeight.w400);

      final icon = t.widget<Icon>(find.byType(Icon));
      expect(icon.size, 24);
    });
  });
}
