/// Pad cap-table tests (10-03 Task 1, KEY-02/KEY-04).
///
/// The contract under test — the vocabulary-coverage seam for the
/// full-screen keyboard's four pads:
/// (a) every code every pad's caps emit is in kClientKeyCodes, the
///     byte-for-byte mirror of keymap.rs CLIENT_KEY_CODES (a code missing
///     there is dropped SILENTLY server-side, T-04-02 — a dead key);
/// (b) capsForPad covers all four KeyboardPad values with a non-empty set;
/// (c) the pads render the layouts 10-UI-SPEC §Pad layouts names.
///
/// The docked-panel groups (capsForGroup) are a separate surface with its
/// own gate in key_rows_test.dart — this file must not touch them.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/key_pads.dart';
import 'package:remote_control/keyboard/key_rows.dart';

void main() {
  test('every cap code across all four pads is in kClientKeyCodes '
      '(KEY-02 vocabulary gate)', () {
    for (final pad in KeyboardPad.values) {
      for (final def in capsForPad(pad)) {
        expect(
          kClientKeyCodes,
          contains(def.code),
          reason: 'pad ${pad.name} cap "${def.code}" is not in the locked '
              'key.code vocabulary — the server drops it silently',
        );
      }
    }
  });

  test('capsForPad returns a non-empty set for every pad', () {
    for (final pad in KeyboardPad.values) {
      expect(capsForPad(pad), isNotEmpty, reason: 'pad ${pad.name} is empty');
    }
  });

  test('KeyboardPad enumerates exactly type/arrows/numpad/fn in page order',
      () {
    expect(
      KeyboardPad.values.map((p) => p.name),
      ['type', 'arrows', 'numpad', 'fn'],
    );
  });

  group('pad layouts (10-UI-SPEC §Pad layouts)', () {
    test('Type pad is the slim extras row Esc|Tab|←|↑|↓|→|Del', () {
      expect(
        capsForPad(KeyboardPad.type).map((d) => d.code),
        ['Esc', 'Tab', 'Left', 'Up', 'Down', 'Right', 'Del'],
      );
    });

    test('Arrows pad is Home/End/PgUp/PgDn over the inverted-T', () {
      expect(
        capsForPad(KeyboardPad.arrows).map((d) => d.code),
        ['Home', 'End', 'PgUp', 'PgDn', 'Up', 'Left', 'Down', 'Right'],
      );
    });

    test('Numpad pad is the existing kNumCaps (no new numpad codes)', () {
      expect(capsForPad(KeyboardPad.numpad), same(kNumCaps));
    });

    test('Fn pad is Esc over F1..F12', () {
      expect(
        capsForPad(KeyboardPad.fn).map((d) => d.code),
        ['Esc', for (var i = 1; i <= 12; i++) 'F$i'],
      );
    });

    test('arrow caps carry an icon face + tooltip, label caps carry a label',
        () {
      for (final pad in KeyboardPad.values) {
        for (final def in capsForPad(pad)) {
          if (def.icon != null) {
            expect(def.tooltip, isNotNull, reason: '${def.code} icon cap');
          } else {
            expect(def.label, isNotNull, reason: '${def.code} label cap');
          }
        }
      }
    });
  });

  group('panelPadHeight — the docked panel sizing contract (D-93)', () {
    // A column tall enough that no pad is clamped: the reference device
    // (411x891, 24dp status + 24dp gesture-nav insets) leaves 843, whose
    // ceiling is 843 * 0.55 - 121 = 342.65 — above every table value.
    const roomy = 843.0;

    test('each pad returns its table height on an unclamped column', () {
      expect(panelPadHeight(KeyboardPad.type, roomy), 80);
      expect(panelPadHeight(KeyboardPad.arrows, roomy), 272);
      expect(panelPadHeight(KeyboardPad.numpad, roomy), 312);
      expect(panelPadHeight(KeyboardPad.fn, roomy), 304);
    });

    test('Type is the slim strip and Numpad the tallest: type < arrows < fn '
        '< numpad (D-93 order)', () {
      final type = panelPadHeight(KeyboardPad.type, roomy);
      final arrows = panelPadHeight(KeyboardPad.arrows, roomy);
      final fn = panelPadHeight(KeyboardPad.fn, roomy);
      final numpad = panelPadHeight(KeyboardPad.numpad, roomy);
      expect(type, lessThan(arrows));
      expect(arrows, lessThan(fn));
      expect(fn, lessThan(numpad));
    });

    test('kPanelChromeHeight is the hairline + chip row + tab bar (121)', () {
      expect(kPanelChromeHeight, 121);
    });

    test('a short column clamps to the ceiling, and the whole panel still '
        'leaves the trackpad 0.45 x column - 64', () {
      // 577 is the reference device with the IME raised 290dp — the state
      // where the clamp is the only thing protecting the live trackpad.
      const column = 577.0;
      final viewport = panelPadHeight(KeyboardPad.numpad, column);

      expect(viewport, lessThan(kPanelPadHeights[KeyboardPad.numpad]!),
          reason: 'the ceiling must bind here');
      expect(viewport, closeTo(column * kPanelMaxHeightFraction -
          kPanelChromeHeight, 0.001));

      final trackpad = column - (viewport + kPanelChromeHeight);
      expect(trackpad, greaterThanOrEqualTo(0.45 * column - 64),
          reason: 'the live-trackpad guarantee, computed not hard-coded');
    });

    test('the guarantee holds for every pad across a sweep of columns', () {
      for (var column = 320.0; column <= 1000.0; column += 7) {
        for (final pad in KeyboardPad.values) {
          final total = panelPadHeight(pad, column) + kPanelChromeHeight;
          expect(column - total, greaterThanOrEqualTo(0.45 * column - 64),
              reason: '$pad at column $column');
        }
      }
    });

    test('an extreme column floors at kPanelMinPadHeight — the one documented '
        'exception, and the trackpad still keeps column - 281', () {
      const column = 200.0; // ceiling would be -11
      final viewport = panelPadHeight(KeyboardPad.numpad, column);
      expect(viewport, kPanelMinPadHeight);
      expect(viewport + kPanelChromeHeight, 217);
    });

    test('a pad never grows PAST its own request: Type stays the 80px strip '
        'even where the floor exceeds it', () {
      // ceiling here is 209 - 121 = 88, i.e. below the 96px floor. The floor
      // lifts the CEILING, never the pad's request — otherwise the slim Type
      // strip would silently become 96 and D-93's "Type stays a slim strip"
      // would be false on short viewports.
      expect(panelPadHeight(KeyboardPad.type, 380), 80);
      expect(panelPadHeight(KeyboardPad.type, 200), 80);
    });
  });

  test('exposing KeyCap did not disturb the docked panel groups (D-07)', () {
    // capsForGroup stays the docked panel's seam — the pads must not have
    // rewritten it.
    expect(capsForGroup(KeyRowGroup.nav).map((d) => d.code),
        ['Esc', 'Tab', 'Home', 'End', 'PgUp', 'PgDn', 'Del',
         'Up', 'Left', 'Down', 'Right']);
    expect(capsForGroup(KeyRowGroup.num), same(kNumCaps));
    expect(capsForGroup(KeyRowGroup.fn), same(kFnCaps));
  });
}
