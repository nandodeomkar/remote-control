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
