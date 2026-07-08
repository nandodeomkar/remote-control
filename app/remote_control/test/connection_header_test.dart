/// ConnectionHeaderChip + ReconnectingBanner behavior suite (03-07 Task 1).
///
/// Four behavior groups per the plan:
///  1. Connected state: dot+word in #4C8DFF, '· {p50} ms' tabular, '--' when
///     the probe has no samples yet.
///  2. Reconnecting (#E8A33D) and Disconnected (#6B7280) states hide latency.
///  3. Throttle proof: the chip polls on [kHudReadThrottle] — a probe value
///     change is invisible before the tick and visible after it.
///  4. ReconnectingBanner renders the locked copy with a 'Retry now'
///     TextButton invoking the injected callback.
///
/// States are injected via constructor suppliers — no Riverpod, no service.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/hud/latency_probe.dart';
import 'package:remote_control/net/connection_service.dart' show ChipStatus;
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/widgets/connection_header.dart';

// UI-SPEC locked state colors.
const Color _connectedColor = Color(0xFF4C8DFF);
const Color _reconnectingColor = Color(0xFFE8A33D);
const Color _disconnectedColor = Color(0xFF6B7280);

Widget _host(Widget child) {
  return MaterialApp(
    home: Scaffold(body: Center(child: child)),
  );
}

/// The chip's status-word target color (AnimatedDefaultTextStyle animates
/// TOWARD this — reading the target avoids animation-timing flakiness).
/// Scoped to the chip: Material mounts its own AnimatedDefaultTextStyles.
Color? _statusWordColor(WidgetTester tester) {
  final animated = tester.widget<AnimatedDefaultTextStyle>(
    find.descendant(
      of: find.byType(ConnectionHeaderChip),
      matching: find.byType(AnimatedDefaultTextStyle),
    ),
  );
  return animated.style.color;
}

void main() {
  group('ConnectionHeaderChip — connected state', () {
    testWidgets('renders dot + word in #4C8DFF with tabular p50', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ConnectionHeaderChip(
            status: () => ChipStatus.connected,
            p50: () => 12,
          ),
        ),
      );

      expect(find.text('Connected'), findsOneWidget);
      expect(_statusWordColor(tester), _connectedColor);

      // Latency readout: '· {p50} ms' in tabular figures.
      expect(find.text('· 12 ms'), findsOneWidget);
      final latency = tester.widget<Text>(find.text('· 12 ms'));
      expect(
        latency.style?.fontFeatures,
        contains(const FontFeature.tabularFigures()),
      );

      // The 8px status dot animates toward the connected color.
      final dot = tester.widget<AnimatedContainer>(
        find.descendant(
          of: find.byType(ConnectionHeaderChip),
          matching: find.byType(AnimatedContainer),
        ),
      );
      final decoration = dot.decoration! as BoxDecoration;
      expect(decoration.color, _connectedColor);
    });

    testWidgets('null p50 renders --', (tester) async {
      await tester.pumpWidget(
        _host(
          ConnectionHeaderChip(
            status: () => ChipStatus.connected,
            p50: () => null,
          ),
        ),
      );

      expect(find.text('Connected'), findsOneWidget);
      expect(find.textContaining('--'), findsOneWidget);
    });
  });

  group('ConnectionHeaderChip — reconnecting / disconnected states', () {
    testWidgets('reconnecting renders amber word, latency hidden', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ConnectionHeaderChip(
            status: () => ChipStatus.reconnecting,
            p50: () => 12, // present but must NOT render
          ),
        ),
      );

      expect(find.text('Reconnecting'), findsOneWidget);
      expect(_statusWordColor(tester), _reconnectingColor);
      expect(find.textContaining('ms'), findsNothing);
      expect(find.textContaining('--'), findsNothing);
    });

    testWidgets('disconnected renders muted word, latency hidden', (
      tester,
    ) async {
      await tester.pumpWidget(
        _host(
          ConnectionHeaderChip(
            status: () => ChipStatus.disconnected,
            p50: () => 12,
          ),
        ),
      );

      expect(find.text('Disconnected'), findsOneWidget);
      expect(_statusWordColor(tester), _disconnectedColor);
      expect(find.textContaining('ms'), findsNothing);
    });
  });

  group('ConnectionHeaderChip — throttled reads', () {
    testWidgets('probe change invisible before kHudReadThrottle, visible '
        'after', (tester) async {
      int? p50 = 5;
      await tester.pumpWidget(
        _host(
          ConnectionHeaderChip(
            status: () => ChipStatus.connected,
            p50: () => p50,
          ),
        ),
      );
      expect(find.text('· 5 ms'), findsOneWidget);

      // Mutate the supplied value — nothing may change until the poll tick.
      p50 = 9;
      await tester.pump(kHudReadThrottle - const Duration(milliseconds: 100));
      expect(find.text('· 5 ms'), findsOneWidget);
      expect(find.text('· 9 ms'), findsNothing);

      // Pump past the throttle: the periodic poll picks the new value up.
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.text('· 9 ms'), findsOneWidget);
      expect(find.text('· 5 ms'), findsNothing);
    });
  });

  group('ReconnectingBanner', () {
    testWidgets('shows locked copy and Retry now invokes the callback', (
      tester,
    ) async {
      var retries = 0;
      await tester.pumpWidget(
        _host(ReconnectingBanner(onRetry: () => retries++)),
      );

      expect(find.text(kReconnectingBannerCopy), findsOneWidget);

      final retry = find.widgetWithText(TextButton, kRetryNowLabel);
      expect(retry, findsOneWidget);

      await tester.tap(retry);
      await tester.pump();
      expect(retries, 1);
    });
  });
}
