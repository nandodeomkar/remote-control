/// ModifierFsm unit tests (04-06 Task 1, KEY-03, D-10/D-12).
///
/// The contract under test — the armed-vs-locked two-level model RESEARCH
/// Open Q2 locked:
///
/// - ARMED (tap): rides the `mods` array of the NEXT non-modifier tap only,
///   then auto-resets (D-10). No wire traffic on arm/disarm.
/// - LOCKED (long-press): a REAL server-side held key via the keymap.rs hold
///   codes (`ControlLeft`/`AltLeft`/`ShiftLeft`/`WinLeft`) — physical hold so
///   held-key combos autorepeat with the modifier applied (Pitfall 7), never
///   the mods array (double-apply avoidance).
/// - DISCONNECTED (D-12): everything resets client-side with ZERO effects —
///   the socket is gone; CONN-07 release_all already freed the real keys.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/modifier_fsm.dart';

void main() {
  late ModifierFsm fsm;

  setUp(() {
    fsm = ModifierFsm();
  });

  test('tap arms (no effects); next non-modifier tap auto-resets to rest', () {
    final effects = fsm.tap(Mod.ctrl);
    expect(effects, isEmpty, reason: 'arming is client-local — no wire sends');
    expect(fsm.stateOf(Mod.ctrl), ModifierState.armed);
    expect(fsm.modsForTap(), ['ctrl']);

    final resetEffects = fsm.onNonModifierTap();
    expect(resetEffects, isEmpty,
        reason: 'auto-reset sends nothing — armed mods rode the tap itself');
    expect(fsm.stateOf(Mod.ctrl), ModifierState.rest);
    expect(fsm.modsForTap(), isEmpty);
  });

  test('tap while armed disarms back to rest (no effects)', () {
    fsm.tap(Mod.shift);
    expect(fsm.stateOf(Mod.shift), ModifierState.armed);

    final effects = fsm.tap(Mod.shift);
    expect(effects, isEmpty);
    expect(fsm.stateOf(Mod.shift), ModifierState.rest);
    expect(fsm.modsForTap(), isEmpty);
  });

  test('chording: armed modifiers accumulate in tap order; one reset clears '
      'both', () {
    fsm.tap(Mod.ctrl);
    fsm.tap(Mod.alt);
    expect(fsm.modsForTap(), ['ctrl', 'alt'],
        reason: 'Ctrl+Alt+Del-style chord — mods listed in tap order');

    fsm.onNonModifierTap();
    expect(fsm.stateOf(Mod.ctrl), ModifierState.rest);
    expect(fsm.stateOf(Mod.alt), ModifierState.rest);
    expect(fsm.modsForTap(), isEmpty);
  });

  test('long-press locks = physical hold: down on lock, survives non-modifier '
      'taps, up on tap-off', () {
    final lockEffects = fsm.longPress(Mod.win);
    expect(lockEffects, hasLength(1));
    expect(lockEffects.single, isA<SendModifierDown>());
    expect((lockEffects.single as SendModifierDown).holdCode, 'WinLeft');
    expect(fsm.stateOf(Mod.win), ModifierState.locked);

    // A locked modifier is already physically held server-side — it must NOT
    // ride the mods array too (Pitfall 7 double-apply avoidance)...
    expect(fsm.modsForTap(), isNot(contains('win')));

    // ...and a non-modifier tap leaves it locked (only tap-off releases).
    fsm.onNonModifierTap();
    expect(fsm.stateOf(Mod.win), ModifierState.locked);

    final unlockEffects = fsm.tap(Mod.win);
    expect(unlockEffects, hasLength(1));
    expect(unlockEffects.single, isA<SendModifierUp>());
    expect((unlockEffects.single as SendModifierUp).holdCode, 'WinLeft');
    expect(fsm.stateOf(Mod.win), ModifierState.rest);
  });

  test('armed -> locked upgrade: long-press on an armed modifier locks it '
      '(one down, never double-arms)', () {
    fsm.tap(Mod.ctrl);
    expect(fsm.stateOf(Mod.ctrl), ModifierState.armed);

    final effects = fsm.longPress(Mod.ctrl);
    expect(effects, hasLength(1));
    expect(effects.single, isA<SendModifierDown>());
    expect((effects.single as SendModifierDown).holdCode, 'ControlLeft');
    expect(fsm.stateOf(Mod.ctrl), ModifierState.locked);
    // Upgraded out of the armed set — locked never rides the mods array.
    expect(fsm.modsForTap(), isEmpty);

    // Long-press while already locked is idempotent (no second down).
    expect(fsm.longPress(Mod.ctrl), isEmpty);
    expect(fsm.stateOf(Mod.ctrl), ModifierState.locked);
  });

  test('hold-code table mirrors keymap.rs CLIENT_KEY_CODES exactly', () {
    expect(kModifierHoldCodes[Mod.ctrl], 'ControlLeft');
    expect(kModifierHoldCodes[Mod.alt], 'AltLeft');
    expect(kModifierHoldCodes[Mod.shift], 'ShiftLeft');
    expect(kModifierHoldCodes[Mod.win], 'WinLeft');
    expect(kModifierHoldCodes, hasLength(Mod.values.length));
  });

  test('D-12 disconnected(): everything to rest with ZERO effects', () {
    fsm.tap(Mod.ctrl); // armed
    fsm.longPress(Mod.win); // locked (a real held key server-side)

    final effects = fsm.disconnected();
    expect(effects, isEmpty,
        reason: 'the socket is gone — CONN-07 release_all already freed the '
            'real keys; sending ups into a dead/new session would be wrong');
    for (final mod in Mod.values) {
      expect(fsm.stateOf(mod), ModifierState.rest);
    }
    expect(fsm.modsForTap(), isEmpty);
  });
}
