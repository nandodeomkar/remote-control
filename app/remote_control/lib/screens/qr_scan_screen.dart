/// Full-screen QR pairing scanner (260716-kba, CONN-02).
///
/// Pushed as a `MaterialPageRoute<PairQrData>` from the pairing sheet's
/// "Scan QR" affordance; pops with a [PairQrData] when a valid `rc://pair`
/// code is read (or null when the user backs out). Dark-minimal per
/// tokens.dart; QR-only barcode formats.
///
/// Malformed codes (anything [parsePairQr] rejects, T-QR-01) render
/// [kQrMalformedCopy] on a RESERVED fixed-height line — scanning continues,
/// the sheet never jumps (house no-jump pattern from pairing_dialog.dart).
/// A DateTime-based ~2s cooldown stops a bad code held in frame from
/// re-triggering setState continuously.
///
/// Camera failures surface through [MobileScanner.errorBuilder], rendered by
/// the public, camera-free [QrScanErrorPanel] (widget-testable without the
/// platform view): permission denied gets [kCameraDeniedCopy], anything else
/// [kCameraErrorCopy]. mobile_scanner requests the runtime permission itself
/// on start — a denial lands here, never a crash or blank preview.
///
/// Secrets discipline (T-QR-02 / T-03-23): the raw QR contents and the pin
/// are NEVER logged or interpolated into copy.
library;

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:mobile_scanner/mobile_scanner.dart';

import '../net/pair_qr.dart';
import '../theme/tokens.dart';
import 'connection_copy.dart';

/// How long a malformed read keeps the error line before a fresh malformed
/// read may refresh it (throttles per-frame re-detection setState churn).
const Duration _kMalformedCooldown = Duration(seconds: 2);

/// The scanner route. Pops with a [PairQrData] on the first valid code.
class QrScanScreen extends StatefulWidget {
  /// Creates the scanner screen.
  const QrScanScreen({super.key});

  @override
  State<QrScanScreen> createState() => _QrScanScreenState();
}

class _QrScanScreenState extends State<QrScanScreen> {
  final MobileScannerController _controller = MobileScannerController(
    formats: const [BarcodeFormat.qrCode],
  );

  /// Set when a valid code popped the route — onDetect fires repeatedly per
  /// frame, the route must pop exactly once.
  bool _done = false;

  /// The malformed error line's copy, or null when clear.
  String? _errorCopy;

  /// When the malformed line was last (re)shown — the setState cooldown.
  DateTime? _malformedAt;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_done || !mounted) return;
    String? raw;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue;
      if (value != null) {
        raw = value;
        break;
      }
    }
    if (raw == null) return;

    final data = parsePairQr(raw);
    if (data != null) {
      _done = true;
      Navigator.of(context).pop(data);
      return;
    }

    // Malformed: show the explicit copy, keep scanning. The cooldown stops
    // one bad code held in frame from re-triggering setState every frame.
    final now = DateTime.now();
    final shownAt = _malformedAt;
    if (_errorCopy != null &&
        shownAt != null &&
        now.difference(shownAt) < _kMalformedCooldown) {
      return;
    }
    setState(() {
      _errorCopy = kQrMalformedCopy;
      _malformedAt = now;
    });
  }

  @override
  Widget build(BuildContext context) {
    final errorCopy = _errorCopy;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          kScanQrTitle,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: MobileScanner(
                controller: _controller,
                onDetect: _onDetect,
                errorBuilder: (context, error) =>
                    QrScanErrorPanel(errorCode: error.errorCode),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
              child: Column(
                children: [
                  const Text(
                    kScanQrHint,
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w400,
                      color: kMuted,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Reserved error line: fixed height so nothing jumps.
                  SizedBox(
                    height: 24,
                    child: errorCopy == null
                        ? const SizedBox.shrink()
                        : Text(
                            errorCopy,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: const TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w400,
                              color: kError,
                            ),
                          ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The camera-failure state, extracted camera-free so widget tests pump it
/// directly (the MobileScanner platform view has no test binding).
///
/// [MobileScannerErrorCode.permissionDenied] renders the explicit
/// allow-Camera copy; every other code renders the generic camera-error copy.
class QrScanErrorPanel extends StatelessWidget {
  /// The failed start's error code.
  final MobileScannerErrorCode errorCode;

  /// Creates the panel for [errorCode].
  const QrScanErrorPanel({super.key, required this.errorCode});

  @override
  Widget build(BuildContext context) {
    final denied = errorCode == MobileScannerErrorCode.permissionDenied;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              denied
                  ? Symbols.no_photography_rounded
                  : Symbols.videocam_off_rounded,
              size: 48,
              color: kMuted,
            ),
            const SizedBox(height: 16),
            Text(
              denied ? kCameraDeniedCopy : kCameraErrorCopy,
              textAlign: TextAlign.center,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w400,
                color: kMuted,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
