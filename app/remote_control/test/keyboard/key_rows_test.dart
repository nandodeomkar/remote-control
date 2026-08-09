/// key_rows.dart tests — what survives the retirement of the second keyboard
/// (04-06 Task 2 originally; pruned by 260809-ipc Task 4).
///
/// The file once tested a docked-panel-only row widget and its selector. Both
/// are gone: the trackpad-docked panel now mounts the same four pads as the
/// full-screen keyboard, so the vocabulary gate and the whole key-cap emission
/// model are proven on the pads in `pad_widgets_test.dart` (down/up ordering,
/// deferred tap+mods, gated-inert, IN-04 mid-press gate flip, CR-01 dispose
/// release) and in `key_pads_test.dart` (cap-table coverage). Re-testing them
/// here would be duplication, not coverage.
///
/// What is left is what lives NOWHERE else:
/// (a) the 10-01 shortcut vocabulary lockstep with keymap.rs;
/// (b) the 48px touch-target floor on a representative [KeyCap] — the one
///     assertion the deleted group carried that no pad test replaces (the
///     pads size caps by flex, so they can never exercise the floor under
///     LOOSE constraints, which is exactly where it binds).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/key_rows.dart';

void main() {
  test('new shortcut vocabulary codes are mirrored from keymap.rs (10-01)', () {
    // The 18 codes 10-01 added to keymap.rs CLIENT_KEY_CODES: letters for
    // Ctrl/Win chords, the main-row zero, PrintScreen, and the promoted
    // browser/present macro codes. The registry-driven catalog gate lands in
    // 10-02 once kShortcutCatalog exists; this is the byte-for-byte lockstep.
    const newCodes = [
      'A', 'C', 'D', 'E', 'F', 'I', 'R', 'S', 'V', 'X', 'Y', 'Z',
      '0', 'PrintScreen', 'T', 'W', 'Plus', 'Minus',
    ];
    for (final code in newCodes) {
      expect(
        kClientKeyCodes,
        contains(code),
        reason: 'shortcut code $code must mirror keymap.rs CLIENT_KEY_CODES '
            'byte-for-byte or the server drops it silently',
      );
    }
  });

  testWidgets('a KeyCap meets the 48px touch-target floor in BOTH dimensions '
      'under loose constraints', (tester) async {
    // Re-homed here from the deleted row-group suite. It has to be a bare
    // KeyCap under loose constraints: inside a pad every cap sits in an
    // Expanded cell whose tight constraints win via BoxConstraints.enforce,
    // so a pad test can never prove the floor itself.
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: KeyCap(
              def: const KeyCapDef('Esc', label: 'Esc'),
              enabled: true,
              onKeyDown: (_) {},
              onKeyUp: (_) {},
              onKeyTapWithMods: (_) {},
              hasArmedMods: () => false,
            ),
          ),
        ),
      ),
    );

    final size = tester.getSize(find.byKey(const ValueKey('cap-Esc')));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));
  });
}
