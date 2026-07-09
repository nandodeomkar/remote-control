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
    expect(find.byIcon(Icons.arrow_forward), findsOneWidget);
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
    expect(find.byIcon(Icons.lock), findsOneWidget);

    await tester.tap(find.text('Win'));
    await tester.pumpAndSettle();

    expect(sentKeys(), hasLength(2));
    expect(sentKeys().last.code, 'WinLeft');
    expect(sentKeys().last.action, 'up');
    expect(find.byIcon(Icons.lock), findsNothing);
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
    expect(find.byIcon(Icons.lock), findsOneWidget);
    final sendsBeforeDrop = sent.length;

    // The service drops: chip status flips to disconnected + a changes ping.
    disconnected = true;
    changes.add(null);
    await tester.pumpAndSettle();

    // Visual reset... but NO KeyMsg up — the socket is gone and CONN-07
    // release_all already freed the real key server-side.
    expect(find.byIcon(Icons.lock), findsNothing);
    expect(sent.length, sendsBeforeDrop);
  });

  testWidgets('gated panel renders chips and caps muted and inert',
      (tester) async {
    await tester.pumpWidget(host(expanded: true, enabled: false));
    await tester.pumpAndSettle();

    await tester.longPress(find.text('Win'));
    await tester.tap(find.text('Esc'));
    await tester.pumpAndSettle();

    expect(sent, isEmpty);
    expect(find.byIcon(Icons.lock), findsNothing);
  });
}
