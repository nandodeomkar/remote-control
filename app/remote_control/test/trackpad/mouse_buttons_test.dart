// Task 2 (04-04) — MouseButtonsBar: the L/M/R bar is widget-only and
// callback-injected (no service fake needed). Proves tap routing to the
// ClickMsg button vocabulary and the gated (disabled) inertness.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/trackpad/mouse_buttons.dart';

Widget host({required void Function(String) onPress, required bool enabled}) {
  return MaterialApp(
    home: Scaffold(
      body: MouseButtonsBar(onPress: onPress, enabled: enabled),
    ),
  );
}

void main() {
  testWidgets('tapping L / M / R records left / middle / right', (t) async {
    final pressed = <String>[];
    await t.pumpWidget(host(onPress: pressed.add, enabled: true));

    await t.tap(find.text('L'));
    await t.pump();
    await t.tap(find.text('M'));
    await t.pump();
    await t.tap(find.text('R'));
    await t.pump();

    expect(pressed, ['left', 'middle', 'right']);
  });

  testWidgets('press fires on tap-DOWN (mouse buttons act on press)',
      (t) async {
    final pressed = <String>[];
    await t.pumpWidget(host(onPress: pressed.add, enabled: true));

    final gesture = await t.startGesture(t.getCenter(find.text('L')));
    // Pump past the tap recognizer's press deadline so onTapDown fires while
    // the finger is still down.
    await t.pump(const Duration(milliseconds: 200));
    expect(pressed, ['left'], reason: 'recorded before the finger lifts');
    await gesture.up();
    await t.pump();
    expect(pressed, ['left']);
  });

  testWidgets('disabled bar records nothing', (t) async {
    final pressed = <String>[];
    await t.pumpWidget(host(onPress: pressed.add, enabled: false));

    await t.tap(find.text('L'), warnIfMissed: false);
    await t.tap(find.text('M'), warnIfMissed: false);
    await t.tap(find.text('R'), warnIfMissed: false);
    await t.pump();

    expect(pressed, isEmpty);
  });

  testWidgets('all three buttons render with tooltips', (t) async {
    await t.pumpWidget(host(onPress: (_) {}, enabled: true));

    expect(find.text('L'), findsOneWidget);
    expect(find.text('M'), findsOneWidget);
    expect(find.text('R'), findsOneWidget);
    expect(find.byTooltip('Left click'), findsOneWidget);
    expect(find.byTooltip('Middle click'), findsOneWidget);
    expect(find.byTooltip('Right click'), findsOneWidget);
  });
}
