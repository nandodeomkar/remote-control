/// The PIN pairing modal bottom sheet (CONN-02) with the full UI-SPEC
/// error-copy contract: every `authFail` reason renders its locked string
/// via [pairingErrorCopy] — raw enum values never reach the user (T-03-24).
///
/// [PairingSheet] takes its dependencies (status, failure, callbacks) as
/// constructor parameters so widget tests inject states directly;
/// [showPairingSheet] wires the real providers and rebuilds the sheet on
/// every ConnectionService `changes` ping (handshake sub-status transitions
/// like needPin don't alter the coarse [ConnectionStatus] snapshot, so a
/// plain provider watch would miss them).
///
/// Retry model (verified against session.rs in 03-05): the client
/// `HandshakeFsm` is terminal on failure, so every PIN attempt after an
/// `authFail` is a FRESH dial — submitting with a failure present triggers
/// `onRetryConnect` and the collected PIN is auto-fed once the new
/// handshake reaches needPin. Server-side attempt/lockout enforcement is
/// untouched Phase-1 code.
///
/// Secrets discipline (T-03-23): the PIN goes ONLY to `onSubmitPin` (the
/// service's `feedPin` -> wire); it is never logged, never interpolated
/// into copy, and the field's controller is disposed with the sheet.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../net/connection_providers.dart';
import '../net/handshake.dart';
import '../net/handshake_fsm.dart';
import '../net/pair_qr.dart';
import '../net/reconnect_fsm.dart';
import '../store/device_store.dart';
import '../theme/tokens.dart';
import 'connection_copy.dart';
import 'qr_scan_screen.dart';

/// The pairing sheet body. Pure widget: state comes in via constructor
/// parameters, actions go out via callbacks — no Riverpod inside.
class PairingSheet extends StatefulWidget {
  /// The device name shown in the heading ("Pair with {device name}").
  final String deviceName;

  /// The in-flight handshake's status (null when no channel is up).
  final HandshakeStatus? status;

  /// The last definitive auth failure, or null.
  final FailedEffect? failure;

  /// The revoked-token explanation shown when the sheet opens after a
  /// revocation (D-05), rendered on the reserved error line when no
  /// [failure] is present.
  final String? explanation;

  /// Feeds the entered PIN to the in-flight handshake (needPin).
  final void Function(String pin) onSubmitPin;

  /// Starts a FRESH dial to the target (the post-authFail retry path).
  final VoidCallback onRetryConnect;

  /// The current target's host — a scanned QR naming this host+port feeds
  /// the pin through the exact manual-entry path (260716-kba).
  final String targetHost;

  /// The current target's port (see [targetHost]).
  final int targetPort;

  /// Starts a fresh dial at a DIFFERENT scanned host/port (the user scanned
  /// another PC's pair window — the QR is authoritative for where that PIN
  /// lives). The sheet parks the pin and auto-feeds it at needPin.
  final void Function(String host, int port) onConnectScanned;

  /// The injected scan seam (house pattern): production pushes the real
  /// [QrScanScreen] route, tests return a canned [PairQrData] or null.
  final Future<PairQrData?> Function() scanQr;

  /// Creates the sheet.
  const PairingSheet({
    super.key,
    required this.deviceName,
    required this.status,
    required this.failure,
    this.explanation,
    required this.onSubmitPin,
    required this.onRetryConnect,
    required this.targetHost,
    required this.targetPort,
    required this.onConnectScanned,
    required this.scanQr,
  });

  @override
  State<PairingSheet> createState() => _PairingSheetState();
}

class _PairingSheetState extends State<PairingSheet> {
  final TextEditingController _pinCtrl = TextEditingController();

  /// Lockout seconds remaining (0 = not locked out). Driven by a 1s ticker
  /// derived from the failure's retryAfterSecs.
  int _remaining = 0;
  Timer? _ticker;

  /// A PIN collected while failed, waiting for the fresh dial's needPin.
  String? _pendingPin;

  @override
  void initState() {
    super.initState();
    // Button enablement tracks the field length.
    _pinCtrl.addListener(() => setState(() {}));
    _syncLockout(widget.failure);
  }

  @override
  void didUpdateWidget(PairingSheet old) {
    super.didUpdateWidget(old);
    if (old.failure != widget.failure) {
      _syncLockout(widget.failure);
    }
    // The fresh dial reached needPin: feed the PIN collected at retry time.
    final pending = _pendingPin;
    if (pending != null &&
        widget.status == HandshakeStatus.needPin &&
        old.status != HandshakeStatus.needPin) {
      _pendingPin = null;
      widget.onSubmitPin(pending);
    }
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // T-03-23: the PIN never outlives the sheet.
    _pinCtrl.dispose();
    super.dispose();
  }

  /// (Re)starts or stops the lockout countdown for [failure].
  void _syncLockout(FailedEffect? failure) {
    _ticker?.cancel();
    _ticker = null;
    final secs =
        failure?.reason == 'lockedOut' ? failure?.retryAfterSecs : null;
    _remaining = secs ?? 0;
    if (_remaining <= 0) return;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _remaining -= 1;
        if (_remaining <= 0) {
          _remaining = 0;
          _ticker?.cancel();
          _ticker = null; // countdown over — input re-enables
        }
      });
    });
  }

  bool get _lockedOut => _remaining > 0;

  bool get _canSubmit => _pinCtrl.text.trim().length == 6 && !_lockedOut;

  /// The reserved error line's copy, or null when clear.
  String? get _errorCopy {
    final failure = widget.failure;
    if (failure != null) {
      return pairingErrorCopy(
        failure.reason,
        attemptsRemaining: failure.attemptsRemaining,
        // The live countdown replaces the static retryAfterSecs.
        retryAfterSecs:
            failure.reason == 'lockedOut' ? _remaining : failure.retryAfterSecs,
      );
    }
    return widget.explanation;
  }

  void _submit() {
    if (!_canSubmit) return;
    final pin = _pinCtrl.text.trim();
    if (widget.failure != null) {
      // Post-authFail: the handshake is terminal — fresh dial, then the
      // pending PIN is fed when the new handshake reaches needPin.
      _pendingPin = pin;
      widget.onRetryConnect();
      return;
    }
    widget.onSubmitPin(pin);
  }

  /// Routes a scan result into the EXISTING pairing path (260716-kba).
  ///
  /// Matching target: fill the field and run [_submit] — byte-identical to
  /// typing (including the failure-retry branch and the lockout no-op:
  /// during lockout the field fills, the countdown explains, the user taps
  /// Pair when it ends). Different target: park the pin as [_pendingPin]
  /// (the existing post-authFail retry mechanism) and fire a fresh dial —
  /// the didUpdateWidget needPin-transition hook auto-feeds it.
  Future<void> _scan() async {
    final result = await widget.scanQr();
    if (!mounted || result == null) return;
    if (result.host == widget.targetHost && result.port == widget.targetPort) {
      _pinCtrl.text = result.pin;
      _submit();
      return;
    }
    _pendingPin = result.pin;
    widget.onConnectScanned(result.host, result.port);
  }

  @override
  Widget build(BuildContext context) {
    final errorCopy = _errorCopy;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            pairingSheetHeading(widget.deviceName),
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: kText,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            kPinSheetBody,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: kMuted,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 16),
          TextField(
            controller: _pinCtrl,
            enabled: !_lockedOut,
            autofocus: true,
            keyboardType: TextInputType.number,
            maxLength: 6,
            textAlign: TextAlign.center,
            // Display type: PIN digits only (UI-SPEC typography).
            style: const TextStyle(
              fontSize: 28,
              fontWeight: FontWeight.w600,
              letterSpacing: 8,
              color: kText,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
            decoration: const InputDecoration(counterText: ''),
            onSubmitted: (_) => _submit(),
          ),
          const SizedBox(height: 8),
          // Reserved error line: fixed height so the sheet never jumps.
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
                      // Countdown seconds must not jitter.
                      fontFeatures: [FontFeature.tabularFigures()],
                    ),
                  ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _canSubmit ? _submit : null,
              child: const Text(kPairCta),
            ),
          ),
          const SizedBox(height: 8),
          // D-03 secondary affordance: always a TextButton — accent stays
          // reserved for the primary CTA. Manual PIN entry is unchanged.
          TextButton.icon(
            onPressed: _scan,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: kText,
            ),
            icon: const Icon(Symbols.qr_code_scanner_rounded, size: 20),
            label: const Text(
              kScanQrLabel,
              style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400),
            ),
          ),
        ],
      ),
    );
  }
}

/// Opens the pairing sheet for [target], wired to the real providers.
///
/// Rebuilds the sheet body on every service `changes` ping (needPin /
/// failure transitions don't alter the coarse status snapshot) and closes
/// automatically when the session reaches authed.
Future<void> showPairingSheet(BuildContext context, DeviceTarget target) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: kSurface,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheetContext) => Consumer(
      builder: (consumerContext, ref, _) {
        final service = ref.watch(connectionServiceProvider);
        // Auto-close on success (authed IS a coarse-status transition).
        ref.listen(connectionStatusProvider, (previous, next) {
          if (next.fsmState == ReconnectState.authed) {
            Navigator.of(sheetContext).pop();
          }
        });
        return StreamBuilder<void>(
          stream: service.changes,
          builder: (streamContext, _) => Padding(
            // Ride above the numeric keyboard.
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(streamContext).viewInsets.bottom,
            ),
            child: PairingSheet(
              deviceName: target.name,
              status: service.handshakeStatus,
              failure: service.lastAuthFailure,
              explanation: service.pairingExplanation,
              onSubmitPin: service.feedPin,
              onRetryConnect: () => unawaited(service.connectTo(target)),
              targetHost: target.host,
              targetPort: target.port,
              // A scan naming ANOTHER PC dials it with the same manual-key
              // connect shape as Connect-by-IP; the scanned host still
              // crosses the RFC1918 dial guard inside connectTo (T-QR-01).
              onConnectScanned: (host, port) => unawaited(
                service.connectTo(
                  DeviceTarget(
                    key: manualDeviceKey(host, port),
                    name: host,
                    host: host,
                    port: port,
                  ),
                ),
              ),
              scanQr: () => Navigator.of(sheetContext).push<PairQrData>(
                MaterialPageRoute(builder: (_) => const QrScanScreen()),
              ),
            ),
          ),
        );
      },
    ),
  );
}
