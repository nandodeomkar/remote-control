/// KeyboardPanel widget tests (04-05 Task 3, D-07).
///
/// The contract under test: expanding requests focus on the provided
/// FocusNode (raising the system IME on device), collapsing unfocuses, and
/// the HiddenTextInput stays mounted — SAME State — across the toggle so the
/// Android input connection survives (Pitfall 6).
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/keyboard/diff_ops.dart';
import 'package:remote_control/keyboard/hidden_text_input.dart';
import 'package:remote_control/keyboard/keyboard_panel.dart';

void main() {
  late FocusNode focusNode;
  late ImeDiffProducer producer;
  late List<TextMsg> emitted;

  setUp(() {
    focusNode = FocusNode(debugLabel: 'test-ime');
    emitted = <TextMsg>[];
    producer = ImeDiffProducer(emit: emitted.add);
  });

  tearDown(() {
    focusNode.dispose();
  });

  Widget host({required bool expanded}) => MaterialApp(
        home: Scaffold(
          body: Column(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              KeyboardPanel(
                expanded: expanded,
                imeFocusNode: focusNode,
                producer: producer,
              ),
            ],
          ),
        ),
      );

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
}
