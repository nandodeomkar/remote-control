/// UipiBanner behavior suite (07-11 Task 2, SRV-05/D-07).
///
/// Three behavior groups per the plan:
///  1. A new `input.blocked` snapshot renders the exact UI-SPEC copy and
///     auto-dismisses ~4s later (a Timer); a newer snapshot restarts it.
///  2. The banner never paints the destructive/accent colors — advisory
///     styling only (surface + muted + info icon).
///  3. The banner does not intercept touches to the content beneath it.
///
/// States are injected via constructor suppliers (snapshot getter + a
/// changes stream) — no Riverpod, no service — mirroring
/// `connection_header_test.dart`.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/theme/tokens.dart';
import 'package:remote_control/widgets/uipi_banner.dart';

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Stack(children: [child])),
  );
}

void main() {
  group('UipiBanner — appear + auto-dismiss', () {
    testWidgets(
      'renders the UI-SPEC copy on a new snapshot and auto-dismisses '
      '~4s later',
      (tester) async {
        InputBlockedSnapshot? current;
        final controller = StreamController<void>.broadcast();
        addTearDown(controller.close);

        await tester.pumpWidget(
          _host(UipiBanner(snapshot: () => current, changes: controller.stream)),
        );

        expect(find.text(kUipiBannerCopy), findsNothing);

        current = InputBlockedSnapshot(reason: 'elevated', at: DateTime.now());
        controller.add(null);
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 200)); // settle slide-in

        expect(find.text(kUipiBannerCopy), findsOneWidget);

        // Still visible just short of the dismiss delay.
        await tester.pump(kUipiBannerDismissDelay - const Duration(seconds: 1));
        expect(find.text(kUipiBannerCopy), findsOneWidget);

        // Past the dismiss delay: gone.
        await tester.pump(const Duration(seconds: 2));
        expect(find.text(kUipiBannerCopy), findsNothing);
      },
    );

    testWidgets('a newer snapshot restarts the dismiss timer', (tester) async {
      InputBlockedSnapshot? current;
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _host(UipiBanner(snapshot: () => current, changes: controller.stream)),
      );

      current = InputBlockedSnapshot(reason: 'elevated', at: DateTime.now());
      controller.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kUipiBannerCopy), findsOneWidget);

      // Advance most of the way to dismissal, then push a NEWER snapshot.
      await tester.pump(kUipiBannerDismissDelay - const Duration(seconds: 1));
      current = InputBlockedSnapshot(reason: 'elevated', at: DateTime.now());
      controller.add(null);
      await tester.pump();

      // The original timer would have fired by now — but the newer
      // snapshot must have restarted it, so the banner is still visible.
      await tester.pump(const Duration(seconds: 2));
      expect(find.text(kUipiBannerCopy), findsOneWidget);

      // Now let the RESTARTED timer run out.
      await tester.pump(kUipiBannerDismissDelay);
      expect(find.text(kUipiBannerCopy), findsNothing);
    });
  });

  group('UipiBanner — advisory styling only', () {
    testWidgets('never paints the destructive or accent color', (tester) async {
      InputBlockedSnapshot? current =
          InputBlockedSnapshot(reason: 'elevated', at: DateTime.now());
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);

      await tester.pumpWidget(
        _host(UipiBanner(snapshot: () => current, changes: controller.stream)),
      );
      controller.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));

      expect(find.text(kUipiBannerCopy), findsOneWidget);

      final icon = tester.widget<Icon>(find.byIcon(Icons.info_outline));
      expect(icon.color, isNot(kError));
      expect(icon.color, isNot(kAccent));
      expect(icon.color, kMuted);

      final text = tester.widget<Text>(find.text(kUipiBannerCopy));
      expect(text.style?.color, isNot(kError));
      expect(text.style?.color, isNot(kAccent));
      expect(text.style?.color, kText);
    });
  });

  group('UipiBanner — touch passthrough', () {
    testWidgets('does not intercept touches to the content beneath it', (
      tester,
    ) async {
      InputBlockedSnapshot? current =
          InputBlockedSnapshot(reason: 'elevated', at: DateTime.now());
      final controller = StreamController<void>.broadcast();
      addTearDown(controller.close);
      var tapped = false;

      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Stack(
              children: [
                Positioned.fill(
                  child: GestureDetector(
                    onTap: () => tapped = true,
                    child: Container(color: Colors.blue),
                  ),
                ),
                UipiBanner(snapshot: () => current, changes: controller.stream),
              ],
            ),
          ),
        ),
      );
      controller.add(null);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text(kUipiBannerCopy), findsOneWidget);

      await tester.tap(find.byType(GestureDetector));
      expect(tapped, isTrue);
    });
  });
}
