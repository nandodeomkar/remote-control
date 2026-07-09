/// Connection header chip + reconnecting banner (CONN-06, D-04, D-08).
///
/// [ConnectionHeaderChip] replaces the Phase-2 debug HUD overlay: a compact
/// status dot + word + p50 readout for the app-bar/actions area of any
/// connected-capable screen. It reads its suppliers on a
/// [Timer.periodic]([kHudReadThrottle]) `setState` poll — the throttled-read
/// pattern inherited from that HUD — so the hot move path NEVER rebuilds it
/// (RESEARCH Pitfall 9; the chip is never subscribed to per-frame events).
///
/// [ReconnectingBanner] is the D-04 drop UX: a non-blocking strip under the
/// app bar with the locked copy and a 'Retry now' action. Never a dialog —
/// input surfaces stay visible (gated) behind it. [ReconnectingBannerSlot]
/// owns visibility (shown only while reconnecting) with a 150ms slide-in.
///
/// Both widgets take their inputs via constructor (status/p50 suppliers,
/// retry callback) so tests inject states without Riverpod; the
/// providers-wired default is [ConnectionHeaderChip.forService].
library;

import 'dart:async';

import 'package:flutter/material.dart';

import '../hud/latency_probe.dart';
import '../net/connection_service.dart';
import '../screens/connection_copy.dart';

// UI-SPEC locked palette (Color table + "Header chip" states table).
const Color _connectedColor = Color(0xFF4C8DFF);
const Color _reconnectingColor = Color(0xFFE8A33D);
const Color _disconnectedColor = Color(0xFF6B7280);
const Color _chipFill = Color(0xCC0E0F12);
const Color _hairline = Color(0xFF2A2D34);
const Color _surface = Color(0xFF16181D);
const Color _text = Color(0xFFE6E8EB);

/// Chip color-transition budget (UI-SPEC: 200ms ease, color only).
const Duration _kChipColorEase = Duration(milliseconds: 200);

/// Banner slide-in budget (UI-SPEC motion budget: 150ms).
const Duration _kBannerSlideIn = Duration(milliseconds: 150);

/// The CONN-06 header chip: 8px status dot + status word + '· {p50} ms'.
///
/// Latency renders ONLY while connected ('--' until the probe has samples).
/// State colors per the locked table: connected #4C8DFF, reconnecting
/// #E8A33D, disconnected #6B7280. Reads happen on the [kHudReadThrottle]
/// poll — never on the hot move path.
class ConnectionHeaderChip extends StatefulWidget {
  /// Supplies the current chip status (read on the throttle tick).
  final ChipStatus Function() status;

  /// Supplies the probe's current p50 in millis, or null (no samples).
  final int? Function() p50;

  /// Creates a chip over injected suppliers (test seam — no Riverpod).
  const ConnectionHeaderChip({
    super.key,
    required this.status,
    required this.p50,
  });

  /// The providers-wired default: reads [ConnectionService.chipStatus] and
  /// the surviving probe engine's p50 (D-08).
  factory ConnectionHeaderChip.forService(
    ConnectionService service, {
    Key? key,
  }) {
    return ConnectionHeaderChip(
      key: key,
      status: () => service.chipStatus,
      p50: () => service.probe?.p50,
    );
  }

  @override
  State<ConnectionHeaderChip> createState() => _ConnectionHeaderChipState();
}

class _ConnectionHeaderChipState extends State<ConnectionHeaderChip> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Poll the suppliers on the throttle interval: the move path never
    // calls setState — the hot loop stays rebuild-free.
    _ticker = Timer.periodic(kHudReadThrottle, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  static Color _colorFor(ChipStatus status) {
    switch (status) {
      case ChipStatus.connected:
        return _connectedColor;
      case ChipStatus.reconnecting:
        return _reconnectingColor;
      case ChipStatus.disconnected:
        return _disconnectedColor;
    }
  }

  static String _wordFor(ChipStatus status) {
    switch (status) {
      case ChipStatus.connected:
        return 'Connected';
      case ChipStatus.reconnecting:
        return 'Reconnecting';
      case ChipStatus.disconnected:
        return 'Disconnected';
    }
  }

  /// Null-safe p50 formatting ('--' until the probe has samples).
  static String _fmt(int? p50) => '· ${p50 ?? '--'} ms';

  @override
  Widget build(BuildContext context) {
    final status = widget.status();
    final color = _colorFor(status);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: _chipFill,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: _hairline),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          // 8px status dot — color animates 200ms ease (the only motion).
          AnimatedContainer(
            duration: _kChipColorEase,
            curve: Curves.ease,
            width: 8,
            height: 8,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
          const SizedBox(width: 4),
          AnimatedDefaultTextStyle(
            duration: _kChipColorEase,
            curve: Curves.ease,
            style: TextStyle(
              color: color,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
            child: Text(_wordFor(status)),
          ),
          // Latency renders ONLY while connected (UI-SPEC states table).
          if (status == ChipStatus.connected) ...[
            const SizedBox(width: 4),
            Text(
              _fmt(widget.p50()),
              style: const TextStyle(
                color: _text,
                fontSize: 12,
                fontWeight: FontWeight.w400,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

/// The D-04 non-blocking drop strip: #16181D surface with #2A2D34 top+bottom
/// hairlines, amber wifi-off icon, 'Reconnecting…' text, and a trailing
/// 'Retry now' TextButton (accent text, ≥48px target). Never a dialog.
class ReconnectingBanner extends StatelessWidget {
  /// Invoked by 'Retry now' — wire to [ConnectionService.retryNow].
  final VoidCallback onRetry;

  /// Creates the banner strip.
  const ReconnectingBanner({super.key, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: _surface,
        border: Border(
          top: BorderSide(color: _hairline),
          bottom: BorderSide(color: _hairline),
        ),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        children: [
          const Icon(Icons.wifi_off, color: _reconnectingColor, size: 20),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              kReconnectingBannerCopy,
              style: TextStyle(
                color: _text,
                fontSize: 14,
                fontWeight: FontWeight.w400,
              ),
            ),
          ),
          TextButton(
            onPressed: onRetry,
            style: TextButton.styleFrom(
              minimumSize: const Size(48, 48),
              foregroundColor: _connectedColor,
            ),
            child: const Text(kRetryNowLabel),
          ),
        ],
      ),
    );
  }
}

/// Owns the banner's visibility: mounted under the app bar of any
/// connected-capable screen, it slides the strip in over 150ms while
/// [visible] (chipStatus == reconnecting) and collapses to nothing
/// otherwise. The screen behind stays visible and interactive (D-04).
class ReconnectingBannerSlot extends StatelessWidget {
  /// Whether the banner shows (chipStatus == reconnecting).
  final bool visible;

  /// Forwarded to [ReconnectingBanner.onRetry].
  final VoidCallback onRetry;

  /// Creates the slot.
  const ReconnectingBannerSlot({
    super.key,
    required this.visible,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: _kBannerSlideIn,
      transitionBuilder: (child, animation) => SizeTransition(
        sizeFactor: animation,
        alignment: const Alignment(-1, -1),
        child: SlideTransition(
          position: Tween<Offset>(
            begin: const Offset(0, -1),
            end: Offset.zero,
          ).animate(animation),
          child: child,
        ),
      ),
      child: visible
          ? ReconnectingBanner(onRetry: onRetry)
          : const SizedBox.shrink(),
    );
  }
}
