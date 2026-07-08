/// Live latency + connection-status overlay (D-05/D-06/D-07), dark-minimal.
///
/// Reads the [LatencyProbe]'s p50/p95 and a connection-status line
/// (Connecting / Pairing / Authed / `Failed:reason` / Disconnected). Reads are
/// THROTTLED to [kHudReadThrottle] via an internal timer — the hot move path
/// NEVER rebuilds this widget (the probe is mutated in place; the HUD samples
/// it periodically), satisfying the "no rebuild on the move path" constraint.
library;

import 'dart:async';

import 'package:flutter/material.dart';

import 'latency_probe.dart';

/// A small p50/p95 + status overlay in the dark-minimal theme (#0E0F12).
class LatencyHud extends StatefulWidget {
  /// The probe to sample p50/p95 from.
  final LatencyProbe probe;

  /// The current connection-status line (already formatted by the screen).
  final String status;

  /// Creates the HUD overlay.
  const LatencyHud({super.key, required this.probe, required this.status});

  @override
  State<LatencyHud> createState() => _LatencyHudState();
}

class _LatencyHudState extends State<LatencyHud> {
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    // Poll the probe on the throttle interval — the move path never calls
    // setState, so the hot loop stays rebuild-free.
    _ticker = Timer.periodic(kHudReadThrottle, (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  String _fmt(int? v) => v == null ? '--' : '${v}ms';

  @override
  Widget build(BuildContext context) {
    final p50 = _fmt(widget.probe.p50);
    final p95 = _fmt(widget.probe.p95);
    return IgnorePointer(
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xCC0E0F12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: const Color(0xFF2A2D34)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.status,
              style: const TextStyle(
                color: Color(0xFF4C8DFF),
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'p50 $p50   p95 $p95',
              style: const TextStyle(
                color: Color(0xFFE6E8EB),
                fontSize: 12,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
