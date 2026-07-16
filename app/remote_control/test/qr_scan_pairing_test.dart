// 260716-kba Task 3 — scan-result routing through the EXISTING pairing
// path, plus the camera-free error panel.
//
// House harness (pairing_flow_test.dart): constructor-injected PairingSheet
// inside MaterialApp/Scaffold — no Riverpod, no sockets, no navigation. The
// fake scanQr is a closure returning a canned Future, so no camera platform
// view is ever pumped. QrScanErrorPanel is the camera-free surface under
// test; mobile_scanner is imported ONLY for the MobileScannerErrorCode enum
// (a plain Dart enum, no platform channel).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart' show MobileScannerErrorCode;
import 'package:remote_control/net/handshake.dart';
import 'package:remote_control/net/handshake_fsm.dart';
import 'package:remote_control/net/pair_qr.dart';
import 'package:remote_control/screens/connection_copy.dart';
import 'package:remote_control/screens/pairing_dialog.dart';
import 'package:remote_control/screens/qr_scan_screen.dart';

Widget _wrap(Widget child) => MaterialApp(home: Scaffold(body: child));

PairingSheet _sheet({
  HandshakeStatus? status = HandshakeStatus.needPin,
  FailedEffect? failure,
  void Function(String pin)? onSubmitPin,
  VoidCallback? onRetryConnect,
  void Function(String host, int port)? onConnectScanned,
  Future<PairQrData?> Function()? scanQr,
}) =>
    PairingSheet(
      deviceName: 'OMKAR-LAPTOP',
      status: status,
      failure: failure,
      onSubmitPin: onSubmitPin ?? (_) {},
      onRetryConnect: onRetryConnect ?? () {},
      targetHost: '192.168.1.50',
      targetPort: 17777,
      onConnectScanned: onConnectScanned ?? (_, _) {},
      scanQr: scanQr ?? () async => null,
    );

/// All Text data currently rendered (for negative raw-enum assertions).
Iterable<String> _renderedTexts(WidgetTester tester) => tester
    .widgetList<Text>(find.byType(Text))
    .map((t) => t.data ?? '')
    .where((s) => s.isNotEmpty);

/// The scanned payload matching the harness target.
const PairQrData _matched =
    PairQrData(host: '192.168.1.50', port: 17777, pin: '123456');

/// A payload naming a DIFFERENT PC's pair window.
const PairQrData _otherPc =
    PairQrData(host: '10.0.0.9', port: 17777, pin: '123456');

void main() {
  group('PairingSheet — Scan QR affordance (260716-kba)', () {
    testWidgets('renders the Scan QR TextButton beside intact manual entry',
        (tester) async {
      await tester.pumpWidget(_wrap(_sheet()));

      // The secondary affordance: a TextButton, never a FilledButton.
      expect(find.widgetWithText(TextButton, kScanQrLabel), findsOneWidget);
      expect(find.byIcon(Symbols.qr_code_scanner_rounded), findsOneWidget);

      // Manual PIN entry stays and is unchanged.
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(FilledButton, kPairCta), findsOneWidget);
    });

    testWidgets('matched scan fills the field and submits through the '
        'manual-entry path', (tester) async {
      final submitted = <String>[];
      await tester.pumpWidget(_wrap(_sheet(
        onSubmitPin: submitted.add,
        scanQr: () async => _matched,
      )));

      await tester.tap(find.widgetWithText(TextButton, kScanQrLabel));
      await tester.pump();

      expect(submitted, ['123456'],
          reason: 'a matched scan submits via the SAME _submit path as '
              'typing');
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '123456',
        reason: 'the field fills so the user sees what was scanned',
      );
    });

    testWidgets('mismatched scan fires onConnectScanned, then the needPin '
        'transition auto-feeds the parked pin', (tester) async {
      final submitted = <String>[];
      final connects = <(String, int)>[];

      Widget sheetAt(HandshakeStatus? status) => _wrap(_sheet(
            status: status,
            onSubmitPin: submitted.add,
            onConnectScanned: (host, port) => connects.add((host, port)),
            scanQr: () async => _otherPc,
          ));

      await tester.pumpWidget(sheetAt(null));
      await tester.tap(find.widgetWithText(TextButton, kScanQrLabel));
      await tester.pump();

      expect(connects, [('10.0.0.9', 17777)],
          reason: 'the QR is authoritative for where that PIN lives — a '
              'different host means a fresh dial at the scanned target');
      expect(submitted, isEmpty,
          reason: 'the pin waits for the new handshake to reach needPin');

      // The fresh dial's handshake reaches needPin: the existing
      // _pendingPin didUpdateWidget hook auto-feeds the parked pin.
      await tester.pumpWidget(sheetAt(HandshakeStatus.needPin));
      await tester.pump();
      expect(submitted, ['123456']);
    });

    testWidgets('cancelled scan (null) fires nothing, field unchanged',
        (tester) async {
      final submitted = <String>[];
      final connects = <(String, int)>[];
      var retries = 0;

      await tester.pumpWidget(_wrap(_sheet(
        onSubmitPin: submitted.add,
        onRetryConnect: () => retries++,
        onConnectScanned: (host, port) => connects.add((host, port)),
        scanQr: () async => null,
      )));

      await tester.tap(find.widgetWithText(TextButton, kScanQrLabel));
      await tester.pump();

      expect(submitted, isEmpty);
      expect(connects, isEmpty);
      expect(retries, 0);
      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty,
      );
    });

    testWidgets('matched scan while lockedOut fills the field but the '
        '_canSubmit gate holds', (tester) async {
      final submitted = <String>[];
      var retries = 0;

      await tester.pumpWidget(_wrap(_sheet(
        status: HandshakeStatus.failed,
        failure: const FailedEffect('lockedOut', retryAfterSecs: 30),
        onSubmitPin: submitted.add,
        onRetryConnect: () => retries++,
        scanQr: () async => _matched,
      )));

      await tester.tap(find.widgetWithText(TextButton, kScanQrLabel));
      await tester.pump();

      expect(
        tester.widget<TextField>(find.byType(TextField)).controller!.text,
        '123456',
        reason: 'the field fills; the countdown line explains; the user '
            'taps Pair when the lockout ends — identical to typing',
      );
      expect(submitted, isEmpty);
      expect(retries, 0);

      // Dispose the sheet so the lockout ticker cancels (no pending timers).
      await tester.pumpWidget(const SizedBox());
    });

    testWidgets('expired-PIN round trip renders the exact expiry copy via '
        'the untouched authFail path, never the raw enum', (tester) async {
      final submitted = <String>[];

      Widget sheetWith({FailedEffect? failure, HandshakeStatus? status}) =>
          _wrap(_sheet(
            status: status,
            failure: failure,
            onSubmitPin: submitted.add,
            scanQr: () async => _matched,
          ));

      // A matched scan feeds the (stale) pin through the manual path.
      await tester.pumpWidget(sheetWith(status: HandshakeStatus.needPin));
      await tester.tap(find.widgetWithText(TextButton, kScanQrLabel));
      await tester.pump();
      expect(submitted, ['123456']);

      // The server rejects it: authFail{pinExpired} — existing copy path.
      await tester.pumpWidget(sheetWith(
        status: HandshakeStatus.failed,
        failure: const FailedEffect('pinExpired'),
      ));
      await tester.pump();

      expect(
        find.text('That PIN expired — check your PC for a new one'),
        findsOneWidget,
      );
      for (final text in _renderedTexts(tester)) {
        expect(text, isNot(contains('pinExpired')),
            reason: 'raw enum values never render (T-03-24)');
      }
    });
  });

  group('QrScanErrorPanel — camera failure states (260716-kba)', () {
    testWidgets('permissionDenied renders the explicit allow-Camera copy',
        (tester) async {
      await tester.pumpWidget(_wrap(const QrScanErrorPanel(
        errorCode: MobileScannerErrorCode.permissionDenied,
      )));

      expect(find.text(kCameraDeniedCopy), findsOneWidget);
      expect(find.byIcon(Symbols.no_photography_rounded), findsOneWidget);
    });

    testWidgets('any other code renders the generic camera-error copy',
        (tester) async {
      await tester.pumpWidget(_wrap(const QrScanErrorPanel(
        errorCode: MobileScannerErrorCode.genericError,
      )));

      expect(find.text(kCameraErrorCopy), findsOneWidget);
      expect(find.byIcon(Symbols.videocam_off_rounded), findsOneWidget);
    });
  });
}
