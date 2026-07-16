/// ModifierChip 3-state visual suite (09-03, KEY-03/D-10).
///
/// Pins the UI-SPEC "Modifier chip" state contract on the shipped widget:
/// - rest  → fill kSurface / border kHairline / label kText, no glyph;
/// - armed → fill kSurface / border kAccent  / label kAccent, no glyph;
/// - locked→ fill kAccent  / border kAccent  / label kBg + trailing lock glyph;
/// - disabled → muted label (gated, non-interactive), no glyph.
///
/// Plus the size/radius floor (48×48, radius 8) and the 200ms ease transition.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/modifier_chip.dart';
import 'package:remote_control/keyboard/modifier_fsm.dart';
import 'package:remote_control/theme/tokens.dart';

void main() {
  Widget host({
    required ModifierState state,
    bool enabled = true,
  }) =>
      MaterialApp(
        home: Scaffold(
          body: Center(
            child: ModifierChip(
              label: 'Ctrl',
              state: state,
              enabled: enabled,
              onTap: () {},
              onLongPress: () {},
            ),
          ),
        ),
      );

  BoxDecoration decorationOf(WidgetTester tester) {
    final container = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    return container.decoration! as BoxDecoration;
  }

  Color labelColorOf(WidgetTester tester) =>
      tester.widget<Text>(find.text('Ctrl')).style!.color!;

  testWidgets('rest → kSurface fill, kHairline border, kText label, no glyph',
      (tester) async {
    await tester.pumpWidget(host(state: ModifierState.rest));
    await tester.pumpAndSettle();

    final deco = decorationOf(tester);
    expect(deco.color, kSurface);
    expect(deco.border!.top.color, kHairline);
    expect(labelColorOf(tester), kText);
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });

  testWidgets('armed → kSurface fill, kAccent border + label, no glyph',
      (tester) async {
    await tester.pumpWidget(host(state: ModifierState.armed));
    await tester.pumpAndSettle();

    final deco = decorationOf(tester);
    expect(deco.color, kSurface);
    expect(deco.border!.top.color, kAccent);
    expect(labelColorOf(tester), kAccent);
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });

  testWidgets('locked → kAccent fill + border, kBg label, trailing lock glyph',
      (tester) async {
    await tester.pumpWidget(host(state: ModifierState.locked));
    await tester.pumpAndSettle();

    final deco = decorationOf(tester);
    expect(deco.color, kAccent);
    expect(deco.border!.top.color, kAccent);
    expect(labelColorOf(tester), kBg);

    // The lock glyph renders in kBg (contrast on the accent fill), size 16.
    final lock = find.byIcon(Symbols.lock_rounded);
    expect(lock, findsOneWidget);
    final icon = tester.widget<Icon>(lock);
    expect(icon.color, kBg);
    expect(icon.size, 16);
  });

  testWidgets('disabled → muted label, no accent, no glyph (gated state)',
      (tester) async {
    // Even in a state that would be locked, disabled wins: muted, no glyph.
    await tester.pumpWidget(
      host(state: ModifierState.locked, enabled: false),
    );
    await tester.pumpAndSettle();

    final deco = decorationOf(tester);
    expect(deco.color, kSurface, reason: 'disabled never fills accent');
    expect(deco.border!.top.color, kHairline);
    expect(labelColorOf(tester), kMuted);
    expect(find.byIcon(Symbols.lock_rounded), findsNothing);
  });

  testWidgets('chip meets 48×48 floor, radius 8, and animates 200ms ease',
      (tester) async {
    await tester.pumpWidget(host(state: ModifierState.rest));
    await tester.pumpAndSettle();

    final size = tester.getSize(find.byType(AnimatedContainer));
    expect(size.width, greaterThanOrEqualTo(48));
    expect(size.height, greaterThanOrEqualTo(48));

    final deco = decorationOf(tester);
    expect(deco.borderRadius, BorderRadius.circular(8));

    final animated = tester.widget<AnimatedContainer>(
      find.byType(AnimatedContainer),
    );
    expect(animated.duration, const Duration(milliseconds: 200));
    expect(animated.curve, Curves.ease);
  });
}
