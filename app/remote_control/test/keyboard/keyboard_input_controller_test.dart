/// KeyboardInputController suite — the sacred invariants proven ONCE, on the
/// owner itself, with no widget in sight (260809-ipc Task 1, D-95).
///
/// Before this file every stuck-key contract could only be asserted through a
/// widget harness, twice — once per keyboard surface. That is the disease the
/// shared owner cures: the controller is a plain Dart object with four
/// injected seams (`send`, `changes`, `isDisconnected`, `onChanged`), so a
/// test can drive `keyDown` / `keyUp` / the disconnect transition / `dispose()`
/// directly and assert the exact KeyMsg sequence.
///
/// The contracts pinned here, by name:
///
/// - **D-11 hold** — press/release is a down/up pair; Windows autorepeats
///   between them.
/// - **CR-02 rollover + remove() guard** — concurrently held codes each get
///   their up, and an up for a code that was never downed sends NOTHING (the
///   same guard that makes IN-04's forwarded releases and the cap-level
///   dispose release idempotent).
/// - **D-10 sticky modifiers** — an armed chip is client-local and rides the
///   next tap's mods, then auto-resets; a locked chip is a REAL physical hold.
/// - **D-12 disconnect reset** — zero wire sends, held set emptied, IME reset
///   tick fired, every chip back to rest; only on the false->true edge.
/// - **The LIVE-only dispose flush** — owed cap ups then `releaseAll()`, in
///   that order, and NOTHING at all on a dead socket.
library;

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/keyboard/keyboard_input_controller.dart';
import 'package:remote_control/keyboard/modifier_fsm.dart';
import 'package:remote_control/settings/haptics.dart';

void main() {
  // hapticTick() rides a platform channel; the binding makes that a no-op
  // rather than a throw, and the cache gate is pinned off for determinism.
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<RemoteMessage> sent;
  late StreamController<void> changes;
  late bool disconnected;
  late int changedCount;
  late bool hapticsWas;

  setUp(() {
    sent = <RemoteMessage>[];
    changes = StreamController<void>.broadcast();
    disconnected = false;
    changedCount = 0;
    hapticsWas = debugHapticsCached;
    debugHapticsCached = false;
  });

  tearDown(() async {
    debugHapticsCached = hapticsWas;
    await changes.close();
  });

  KeyboardInputController build() => KeyboardInputController(
        send: sent.add,
        changes: changes.stream,
        isDisconnected: () => disconnected,
        onChanged: () => changedCount++,
      );

  List<String> wire() => sent
      .whereType<KeyMsg>()
      .map((k) => '${k.action}:${k.code}')
      .toList();

  /// Lets a `changes` ping reach the controller's listener (a broadcast
  /// controller delivers asynchronously).
  Future<void> ping() async {
    changes.add(null);
    await Future<void>.delayed(Duration.zero);
  }

  test('D-11: keyDown then keyUp sends exactly down:Right, up:Right', () {
    final c = build();
    c.keyDown('Right');
    c.keyUp('Right');
    expect(wire(), ['down:Right', 'up:Right']);
    c.dispose();
  });

  test(
      'CR-02: rollover — down Right, down Down, up Right, up Down sends every '
      'up (a single-slot held code would swallow up:Right)', () {
    final c = build();
    c.keyDown('Right');
    c.keyDown('Down');
    c.keyUp('Right');
    c.keyUp('Down');
    expect(wire(), ['down:Right', 'down:Down', 'up:Right', 'up:Down']);
    c.dispose();
  });

  test(
      'CR-02: keyUp for a code that was never downed sends NOTHING (the '
      'remove() guard — IN-04 forwarded releases and cap-dispose releases are '
      'idempotent through it)', () {
    final c = build();
    c.keyUp('Right');
    expect(sent, isEmpty);
    c.dispose();
  });

  test(
      'D-10 arm: chipTap sends nothing and notifies; the next keyTapWithMods '
      'rides its mods once, then the FSM auto-resets', () {
    final c = build();

    c.chipTap(Mod.ctrl);
    expect(sent, isEmpty, reason: 'arming is client-local');
    expect(changedCount, 1);
    expect(c.stateOf(Mod.ctrl), ModifierState.armed);
    expect(c.hasArmedMods(), isTrue);

    c.keyTapWithMods('Esc');
    expect(sent.whereType<KeyMsg>(), hasLength(1));
    expect(sent.whereType<KeyMsg>().single.action, 'tap');
    expect(sent.whereType<KeyMsg>().single.mods, ['ctrl']);
    expect(c.stateOf(Mod.ctrl), ModifierState.rest);

    c.keyTapWithMods('Esc');
    expect(sent.whereType<KeyMsg>().last.mods, isEmpty,
        reason: 'the arm rode exactly one tap (D-10 auto-reset)');
    c.dispose();
  });

  test('D-10 lock: chipLongPress sends down:WinLeft; chipTap sends up:WinLeft',
      () {
    final c = build();

    c.chipLongPress(Mod.win);
    expect(wire(), ['down:WinLeft']);
    expect(c.stateOf(Mod.win), ModifierState.locked);

    c.chipTap(Mod.win);
    expect(wire(), ['down:WinLeft', 'up:WinLeft']);
    expect(c.stateOf(Mod.win), ModifierState.rest);
    c.dispose();
  });

  test(
      'D-12: the disconnected transition sends ZERO frames, empties the held '
      'set, ticks the IME reset and returns every chip to rest', () async {
    final c = build();
    c.chipLongPress(Mod.win);
    c.keyDown('Right');
    expect(wire(), ['down:WinLeft', 'down:Right']);
    final before = sent.length;
    final tickBefore = c.imeResetTick.value;

    disconnected = true;
    await ping();

    expect(sent.length, before,
        reason: 'the socket is gone — CONN-07 release_all already freed the '
            'real keys, and a send into a NEW session would be wrong');
    expect(c.debugHeldCodes, isEmpty);
    expect(c.imeResetTick.value, tickBefore + 1);
    for (final mod in Mod.values) {
      expect(c.stateOf(mod), ModifierState.rest);
    }

    // The late release finds remove() false: still nothing on the wire.
    c.keyUp('Right');
    expect(sent.length, before);
    c.dispose();
  });

  test(
      'D-12 edge: only the false->true edge fires a reset — a repeat ping '
      'while already disconnected, and the reconnect edge, fire nothing',
      () async {
    final c = build();

    disconnected = true;
    await ping();
    final afterDrop = c.imeResetTick.value;

    await ping(); // still disconnected
    expect(c.imeResetTick.value, afterDrop);

    disconnected = false;
    await ping(); // the reconnect edge
    expect(c.imeResetTick.value, afterDrop,
        reason: 'disconnected->connected must NOT fire the reset');
    c.dispose();
  });

  test(
      'dispose on a LIVE socket flushes owed cap ups then releaseAll(), in '
      'that order', () {
    final c = build();
    c.keyDown('Esc');
    c.chipLongPress(Mod.win);
    expect(wire(), ['down:Esc', 'down:WinLeft']);

    c.dispose();

    expect(wire(), ['down:Esc', 'down:WinLeft', 'up:Esc', 'up:WinLeft'],
        reason: 'owed cap ups first, then the locked-modifier releaseAll');
  });

  test('dispose on a DISCONNECTED socket sends NOTHING', () {
    final c = build();
    c.keyDown('Esc');
    c.chipLongPress(Mod.win);
    final before = sent.length;

    disconnected = true;
    c.dispose();

    expect(sent.length, before,
        reason: 'never into a dead socket, never into a NEW session');
  });

  test('dispose cancels the changes subscription: a later ping is inert',
      () async {
    final c = build();
    c.dispose();

    disconnected = true;
    await ping();

    expect(sent, isEmpty);
  });
}
