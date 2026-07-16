// Task 3 (TDD) — pairing UX (CONN-02): the pairingErrorCopy unit table
// (every authFail reason -> its exact UI-SPEC string) and PairingSheet
// widget behavior (PIN field contract, error rendering, lockout countdown,
// reserved error space, no raw enums ever rendered).
//
// PairingSheet takes its dependencies (status, failure, callbacks) as
// constructor parameters, so these tests inject states directly — no
// Riverpod overrides, no sockets.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/net/handshake.dart';
import 'package:remote_control/net/handshake_fsm.dart';
import 'package:remote_control/net/reconnect_fsm.dart';
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/screens/pairing_dialog.dart';

const Color _errorColor = Color(0xFFFF6B6B);

Widget _wrap(Widget sheet) => MaterialApp(home: Scaffold(body: sheet));

PairingSheet _sheet({
  HandshakeStatus? status = HandshakeStatus.needPin,
  FailedEffect? failure,
  String? explanation,
  void Function(String pin)? onSubmitPin,
  VoidCallback? onRetryConnect,
}) =>
    PairingSheet(
      deviceName: 'OMKAR-LAPTOP',
      status: status,
      failure: failure,
      explanation: explanation,
      onSubmitPin: onSubmitPin ?? (_) {},
      onRetryConnect: onRetryConnect ?? () {},
      // Neutral 260716-kba scan-seam defaults: this suite exercises manual
      // PIN entry only; scan-routing behavior lives in qr_scan_pairing_test.
      targetHost: '192.168.1.50',
      targetPort: 17777,
      onConnectScanned: (_, _) {},
      scanQr: () async => null,
    );

/// All Text data currently rendered (for negative raw-enum assertions).
Iterable<String> _renderedTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty);

void main() {
  group('pairingErrorCopy — the UI-SPEC reason table (CONN-02)', () {
    test('pinInvalid interpolates attemptsRemaining (plural)', () {
      expect(
        pairingErrorCopy('pinInvalid', attemptsRemaining: 4),
        'Wrong PIN — 4 attempts left',
      );
    });

    test('pinInvalid uses the singular form for 1 attempt', () {
      expect(
        pairingErrorCopy('pinInvalid', attemptsRemaining: 1),
        'Wrong PIN — 1 attempt left',
      );
    });

    test('pinExpired maps to the exact expiry line', () {
      expect(
        pairingErrorCopy('pinExpired'),
        'That PIN expired — check your PC for a new one',
      );
    });

    test('lockedOut interpolates the countdown seconds', () {
      expect(
        pairingErrorCopy('lockedOut', retryAfterSecs: 42),
        'Too many attempts — try again in 42s',
      );
    });

    test('noPairing and badMac both map to the D-05 revoked explanation '
        '(single definition from reconnect_fsm.dart)', () {
      expect(pairingErrorCopy('noPairing'), kRevokedExplanation);
      expect(pairingErrorCopy('badMac'), kRevokedExplanation);
      expect(
        kRevokedExplanation,
        'This PC no longer recognizes this phone — pair again',
      );
    });

    test('versionMismatch maps to the update-both line', () {
      expect(
        pairingErrorCopy('versionMismatch'),
        'This phone and the PC server need matching versions — update both, '
        'then try again',
      );
    });

    test('an unknown reason renders a generic retry line, never the enum',
        () {
      final copy = pairingErrorCopy('someFutureReason');
      expect(copy, isNot(contains('someFutureReason')));
      expect(copy, isNotEmpty);
    });
  });

  group('PairingSheet — PIN entry contract (UI-SPEC dialog row)', () {
    testWidgets('renders heading, body, Display-type field, disabled Pair',
        (tester) async {
      await tester.pumpWidget(_wrap(_sheet()));

      expect(find.text('Pair with OMKAR-LAPTOP'), findsOneWidget);
      expect(find.text(kPinSheetBody), findsOneWidget);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.style?.fontSize, 28);
      expect(field.style?.fontWeight, FontWeight.w600);
      expect(field.style?.letterSpacing, 8);
      expect(field.maxLength, 6);

      final button = tester.widget<FilledButton>(find.byType(FilledButton));
      expect(button.onPressed, isNull,
          reason: 'Pair must be disabled until 6 digits are entered');
    });

    testWidgets('Pair stays disabled at 5 digits, enables at 6',
        (tester) async {
      await tester.pumpWidget(_wrap(_sheet()));

      await tester.enterText(find.byType(TextField), '12345');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });

    testWidgets('submitting 6 digits calls onSubmitPin with the pin',
        (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(
        _wrap(_sheet(onSubmitPin: submitted.add)),
      );

      await tester.enterText(find.byType(TextField), '042042');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));

      expect(submitted, ['042042'],
          reason: 'leading zeros are significant — the pin travels verbatim');
    });
  });

  group('PairingSheet — failure rendering', () {
    testWidgets('pinInvalid(4) shows the exact copy in error red, field '
        're-enabled for retry', (tester) async {
      await tester.pumpWidget(_wrap(_sheet(
        status: HandshakeStatus.failed,
        failure: const FailedEffect('pinInvalid', attemptsRemaining: 4),
      )));

      final errorText = tester.widget<Text>(
        find.text('Wrong PIN — 4 attempts left'),
      );
      expect(errorText.style?.color, _errorColor);

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.enabled, isNot(isFalse),
          reason: 'a wrong PIN is retryable — the field stays usable');
    });

    testWidgets('raw reason enums never reach a rendered widget',
        (tester) async {
      for (final reason in ['badMac', 'noPairing']) {
        await tester.pumpWidget(_wrap(_sheet(
          status: HandshakeStatus.failed,
          failure: FailedEffect(reason),
        )));

        for (final text in _renderedTexts(tester)) {
          expect(text, isNot(contains(reason)),
              reason: 'raw enum "$reason" must never render (T-03-24)');
        }
        expect(find.text(kRevokedExplanation), findsOneWidget);
      }
    });

    testWidgets('the error line space is reserved — sheet height identical '
        'with and without an error', (tester) async {
      await tester.pumpWidget(_wrap(_sheet()));
      final without = tester.getSize(find.byType(PairingSheet)).height;

      await tester.pumpWidget(_wrap(_sheet(
        status: HandshakeStatus.failed,
        failure: const FailedEffect('pinInvalid', attemptsRemaining: 2),
      )));
      final withError = tester.getSize(find.byType(PairingSheet)).height;

      expect(withError, without,
          reason: 'the sheet must not jump when an error appears');
    });
  });

  group('PairingSheet — lockout countdown (CONN-02)', () {
    testWidgets('lockedOut shows the live countdown; field AND button '
        'disabled; replaced state re-enables', (tester) async {
      await tester.pumpWidget(_wrap(_sheet(
        status: HandshakeStatus.failed,
        failure: const FailedEffect('lockedOut', retryAfterSecs: 30),
      )));

      expect(find.text('Too many attempts — try again in 30s'), findsOneWidget);
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isFalse,
      );
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );

      // The 1s ticker counts down live (tabular figures — no jitter).
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Too many attempts — try again in 29s'), findsOneWidget);

      // Countdown state replaced (fresh dial cleared the failure): re-enable.
      await tester.pumpWidget(_wrap(_sheet()));
      await tester.pump();
      expect(
        tester.widget<TextField>(find.byType(TextField)).enabled,
        isNot(isFalse),
      );
      await tester.enterText(find.byType(TextField), '123456');
      await tester.pump();
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNotNull,
      );
    });
  });

  group('PairingSheet — retry model (fresh dial after authFail)', () {
    testWidgets('submitting after a failure triggers onRetryConnect, then '
        'needPin auto-feeds the collected pin', (tester) async {
      final submitted = <String>[];
      var retries = 0;

      await tester.pumpWidget(_wrap(_sheet(
        status: HandshakeStatus.failed,
        failure: const FailedEffect('pinInvalid', attemptsRemaining: 3),
        onSubmitPin: submitted.add,
        onRetryConnect: () => retries++,
      )));

      await tester.enterText(find.byType(TextField), '654321');
      await tester.pump();
      await tester.tap(find.byType(FilledButton));

      expect(retries, 1,
          reason: 'after authFail the client FSM is terminal — every PIN '
              'attempt is a FRESH dial (03-05 retry model)');
      expect(submitted, isEmpty,
          reason: 'the pin waits for the new handshake to reach needPin');

      // The fresh handshake reached needPin: the pending pin is fed.
      await tester.pumpWidget(_wrap(_sheet(
        onSubmitPin: submitted.add,
        onRetryConnect: () => retries++,
      )));
      await tester.pump();
      expect(submitted, ['654321']);
    });
  });

  group('PairingSheet — revoked-token explanation (D-05)', () {
    testWidgets('opening with an explanation renders it on the reserved line',
        (tester) async {
      await tester.pumpWidget(_wrap(_sheet(
        status: null,
        explanation: kRevokedExplanation,
      )));

      expect(find.text(kRevokedExplanation), findsOneWidget);
    });
  });
}
