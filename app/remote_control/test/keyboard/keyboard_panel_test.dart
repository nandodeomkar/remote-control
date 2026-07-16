/// KeyboardPanel widget tests (04-05 Task 3 shell, D-07; 04-06 Task 3 rows,
/// KEY-03/D-10/D-12).
///
/// Shell contract (04-05): expanding requests focus on the provided
/// FocusNode (raising the system IME on device), collapsing unfocuses, and
/// the HiddenTextInput stays mounted — SAME State — across the toggle so the
/// Android input connection survives (Pitfall 6).
///
/// Rows contract (04-06): chips row + switcher + active KeyRows in UI-SPEC
/// order; all three KeyMsg emission paths (modifier hold down/up, key-cap
/// down/up, tap+mods with auto-reset) ride the injected send seam; and the
/// D-12 disconnected transition — driven here by a FAKE changes stream —
/// provably resets the FSM with zero wire sends.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/keyboard/diff_ops.dart';
import 'package:remote_control/keyboard/hidden_text_input.dart';
import 'package:remote_control/keyboard/key_rows.dart';
import 'package:remote_control/keyboard/keyboard_panel.dart';
import 'package:remote_control/store/device_store.dart';

/// In-memory [PrefsKv] so the row-group store never touches the platform.
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
  late FocusNode focusNode;
  late ImeDiffProducer producer;
  late List<TextMsg> emitted;
  late List<RemoteMessage> sent;
  late StreamController<void> changes;
  late bool disconnected;

  setUp(() {
    focusNode = FocusNode(debugLabel: 'test-ime');
    emitted = <TextMsg>[];
    producer = ImeDiffProducer(emit: emitted.add);
    sent = <RemoteMessage>[];
    changes = StreamController<void>.broadcast();
    disconnected = false;
  });

  tearDown(() {
    focusNode.dispose();
    changes.close();
  });

  Widget host({required bool expanded, bool enabled = true}) => ProviderScope(
        overrides: [
          keyRowGroupStoreProvider.overrideWithValue(
            KeyRowGroupStore(prefs: _FakePrefsKv()),
          ),
        ],
        child: MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: Column(
                children: [
                  KeyboardPanel(
                    expanded: expanded,
                    imeFocusNode: focusNode,
                    producer: producer,
                    enabled: enabled,
                    send: sent.add,
                    changes: changes.stream,
                    isDisconnected: () => disconnected,
                  ),
                ],
              ),
            ),
          ),
        ),
      );

  List<KeyMsg> sentKeys() => sent.whereType<KeyMsg>().toList();

  testWidgets('expanding focuses the IME node; collapsing unfocuses',
      (tester) async {
    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isFalse);

    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue);

    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isFalse);
  });

  testWidgets('HiddenTextInput stays mounted (same State) across the toggle',
      (tester) async {
    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    expect(find.byType(HiddenTextInput), findsOneWidget);
    final collapsedState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));

    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(find.byType(HiddenTextInput), findsOneWidget);
    final expandedState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));

    // Same State object — the input connection is never detached.
    expect(identical(collapsedState, expandedState), isTrue);

    await tester.pumpWidget(host(expanded: false));
    await tester.pumpAndSettle();
    final recollapsedState =
        tester.state<State<HiddenTextInput>>(find.byType(HiddenTextInput));
    expect(identical(collapsedState, recollapsedState), isTrue);
  });

  testWidgets('typing into the hidden field emits diffs on the wire seam',
      (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();
    expect(focusNode.hasFocus, isTrue);

    await tester.enterText(
      find.byType(TextField),
      '${kImeSentinel}hi',
    );
    await tester.pump();

    expect(emitted, hasLength(1));
    expect(emitted.single.bs, 0);
    expect(emitted.single.ins, 'hi');
  });

  testWidgets(
      'expanded panel renders chips row + switcher + Nav rows '
      '(UI-SPEC order)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    for (final label in ['Ctrl', 'Alt', 'Shift', 'Win']) {
      expect(find.text(label), findsOneWidget);
    }
    for (final segment in ['Nav', 'Fn', 'Num']) {
      expect(find.text(segment), findsOneWidget);
    }
    // Nav is the D-09 default group.
    expect(find.text('Esc'), findsOneWidget);
    expect(find.byIcon(Symbols.arrow_forward_rounded), findsOneWidget);
  });

  testWidgets(
      'modifier long-press locks: hold-code down sent + lock icon; tap-off '
      'sends up (D-10 physical hold)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(1));
    expect(sentKeys().single.code, 'WinLeft');
    expect(sentKeys().single.action, 'down');
    expect(find.byIcon(Symbols.lock_rounded), findsOneWidget);

    await tester.tap(find.text('Win'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(2));
    expect(sentKeys().last.code, 'WinLeft');
    expect(sentKeys().last.action, 'up');
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });

  testWidgets(
      'key cap press-and-release sends down then up (KEY-04 autorepeat '
      'path)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    // The arrow cluster sits below the 600px test viewport — bring it in.
    final rightCap = find.byKey(const ValueKey('cap-Right'));
    await tester.ensureVisible(rightCap);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(rightCap));
    await tester.pump();
    await gesture.up();
    await tester.pump();

    expect(sentKeys(), hasLength(2));
    expect(sentKeys()[0].code, 'Right');
    expect(sentKeys()[0].action, 'down');
    expect(sentKeys()[1].code, 'Right');
    expect(sentKeys()[1].action, 'up');
  });

  testWidgets(
      'armed chip + key cap = one tap with mods, then the chip auto-resets '
      '(D-10 combo path)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Ctrl'));
    await tester.pumpAndSettle();
    expect(sentKeys(), isEmpty, reason: 'arming is client-local');

    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(1));
    expect(sentKeys().single.code, 'Esc');
    expect(sentKeys().single.action, 'tap');
    expect(sentKeys().single.mods, ['ctrl']);

    // Auto-reset (D-10): a second cap tap now rides the down/up path.
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();
    expect(sentKeys(), hasLength(3));
    expect(sentKeys()[1].action, 'down');
    expect(sentKeys()[2].action, 'up');
  });

  testWidgets(
      'D-12: the disconnected transition resets locked chips with ZERO '
      'wire sends (fake changes stream)', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.pumpAndSettle();
    expect(find.byIcon(Symbols.lock_rounded), findsOneWidget);
    final sendsBeforeDrop = sent.length;

    // The service drops: chip status flips to disconnected + a changes ping.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();

    // Visual reset... but NO KeyMsg up — the socket is gone and CONN-07
    // release_all already freed the real key server-side.
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
    expect(sent.length, sendsBeforeDrop);
  });

  testWidgets(
      'CR-01: disconnect wipes producer and controller atomically — first '
      'post-reconnect keystroke emits only the new char', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    // Steady-state baseline: typed text diffs onto the wire.
    await tester.enterText(find.byType(TextField), '${kImeSentinel}secret');
    await tester.pump();
    expect(emitted.last.ins, 'secret');

    // The WiFi drop: chip flips to disconnected + a changes ping (D-12).
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();

    // The controller was wiped back to EXACTLY the sentinel — the atomic
    // reseed purged the pre-disconnect text from the buffer (T-04-03).
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      kImeSentinel,
    );
    final emissionsAfterWipe = emitted.length;

    // Reconnect: the true->false transition must NOT fire another reset,
    // and neither the wipe write-back nor the ping emits anything.
    disconnected = false;
    changes.add(null);
    await tester.pump();
    expect(emitted.length, emissionsAfterWipe,
        reason: 'the reset write-back itself must emit NO TextMsg');

    // First post-reconnect keystroke: ONLY the new char — never a replay
    // of the pre-disconnect text (KEY-01 across disconnects).
    await tester.enterText(find.byType(TextField), '${kImeSentinel}x');
    await tester.pump();
    expect(emitted.last.bs, 0);
    expect(emitted.last.ins, 'x');
    expect(emitted.last.ins.contains('secret'), isFalse,
        reason: 'pre-disconnect text must never replay after reconnect');
  });

  testWidgets('CR-01: post-reconnect backspace emits bs:1, never an insert',
      (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    await tester.enterText(find.byType(TextField), '${kImeSentinel}secret');
    await tester.pump();
    expect(emitted.last.ins, 'secret');

    // Drop, then reconnect.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();
    disconnected = false;
    changes.add(null);
    await tester.pump();

    // A backspace on the wiped field: one trailing sentinel ZWSP shrinks.
    await tester.enterText(
      find.byType(TextField),
      kImeSentinel.substring(0, kImeSentinel.length - 1),
    );
    await tester.pump();

    // With the old one-sided reset this emitted ins:'secre' — an insert.
    expect(emitted.last.bs, 1);
    expect(emitted.last.ins, isEmpty);

    // The boundary reseed then restored the FULL sentinel — the existing
    // needsReseed/reseed path still works after the wipe.
    expect(
      tester.widget<TextField>(find.byType(TextField)).controller!.text,
      kImeSentinel,
    );
  });

  testWidgets(
      'CR-02: rollover — press Right, press Down, release Right, release '
      'Down sends up for BOTH keys', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    // Both caps sit in the arrow cluster below the 600px test viewport.
    final rightCap = find.byKey(const ValueKey('cap-Right'));
    final downCap = find.byKey(const ValueKey('cap-Down'));
    await tester.ensureVisible(rightCap);
    await tester.pumpAndSettle();
    await tester.ensureVisible(downCap);
    await tester.pumpAndSettle();

    // Two concurrent pointers — each _KeyCap has its own GestureDetector so
    // both tap arenas win independently. Pump past the 100ms press deadline
    // after each press so onTapDown fires eagerly (the scrollable's drag
    // recognizer shares the arena and would otherwise defer it to release).
    final g1 = await tester.startGesture(tester.getCenter(rightCap));
    await tester.pump(const Duration(milliseconds: 150));
    final g2 = await tester.startGesture(tester.getCenter(downCap));
    await tester.pump(const Duration(milliseconds: 150));
    await g1.up();
    await tester.pump();
    await g2.up();
    await tester.pump();

    // Pre-fix, the single-slot _heldCode was overwritten by down:Down and
    // up:Right was swallowed — Right autorepeated on the PC indefinitely.
    expect(
      sentKeys().map((k) => '${k.action}:${k.code}').toList(),
      ['down:Right', 'down:Down', 'up:Right', 'up:Down'],
    );
  });

  testWidgets(
      'CR-02/D-12: disconnect mid-hold clears ALL held caps — a later '
      'release sends NO stale up', (tester) async {
    await tester.pumpWidget(host(expanded: true));
    await tester.pumpAndSettle();

    final rightCap = find.byKey(const ValueKey('cap-Right'));
    await tester.ensureVisible(rightCap);
    await tester.pumpAndSettle();

    final gesture = await tester.startGesture(tester.getCenter(rightCap));
    await tester.pump(const Duration(milliseconds: 150));
    expect(sentKeys(), hasLength(1));
    expect(sentKeys().single.action, 'down');

    // The service drops mid-hold: the D-12 transition wipes the held set.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();
    final before = sent.length;

    await gesture.up();
    await tester.pump();

    // The release found remove('Right') false — no stale up rides into the
    // next session (CONN-07 release_all already freed the real key).
    expect(sent.length, before);
    expect(sentKeys().last.action, 'down');
  });

  testWidgets('gated panel renders chips and caps muted and inert',
      (tester) async {
    await tester.pumpWidget(host(expanded: true, enabled: false));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });
}
