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

import '../net/connection_providers.dart';
import '../net/handshake.dart';
import '../net/handshake_fsm.dart';
import '../net/reconnect_fsm.dart';
import 'connection_copy.dart';

// Theme tokens (03-UI-SPEC Color table).
const Color _surface = Color(0xFF16181D);
const Color _text = Color(0xFFE6E8EB);
const Color _muted = Color(0xFF6B7280);
const Color _error = Color(0xFFFF6B6B);

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

  /// Creates the sheet.
  const PairingSheet({
    super.key,
    required this.deviceName,
    required this.status,
    required this.failure,
    this.explanation,
    required this.onSubmitPin,
    required this.onRetryConnect,
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
              color: _text,
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            kPinSheetBody,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w400,
              color: _muted,
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
              color: _text,
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
                      color: _error,
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
    backgroundColor: _surface,
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
            ),
          ),
        );
      },
    ),
  );
}
