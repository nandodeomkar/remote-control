/// The trackpad surface — a pure [ConnectionService] consumer (03-07, D-08).
///
/// The Phase-2 spike scaffolding (connect/PIN UI, local channel + driver +
/// probe plumbing, the debug latency overlay) is gone: connectivity is the
/// service's job now. What remains:
///
/// - the full-bleed `#0E0F12` Listener surface — a raw pointer route with
///   zero gesture arena and ZERO rebuild on the hot path: `onPointerMove`
///   delegates straight to [ConnectionService.sendMove] (the service owns
///   the volatile gate — pre-auth frames are dropped, never sent);
/// - a `wakelock_plus` lock held while mounted so the screen never dims
///   mid-drag;
/// - the connection header chip (top-right, the old HUD position) and the
///   reconnecting banner — both on their own throttled reads (the chip's
///   500ms poll; the banner via the transition-only status provider). This
///   screen holds NO stream subscription and NO per-move setState.
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../screens/connection_copy.dart';
import '../widgets/connection_header.dart';

/// The trackpad screen: hot-path surface + header chip + drop banner.
class TrackpadScreen extends ConsumerStatefulWidget {
  /// Creates the trackpad screen.
  const TrackpadScreen({super.key});

  @override
  ConsumerState<TrackpadScreen> createState() => _TrackpadScreenState();
}

class _TrackpadScreenState extends ConsumerState<TrackpadScreen> {
  /// Cached once — the provider is an app-lifetime singleton, and the hot
  /// path must not pay a provider lookup per pointer event.
  late final ConnectionService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    // Keep the screen awake so it never dims mid-drag.
    WakelockPlus.enable();
  }

  @override
  void dispose() {
    WakelockPlus.disable();
    super.dispose();
  }

  // Hot path: raw 1:1 pointer delta -> service.sendMove (D-03, no
  // sensitivity multiplier). The service owns gating (volatile drop unless
  // authed) and the probe cadence — NO setState, NO allocation here.
  void _onPointerMove(PointerMoveEvent event) {
    _service.sendMove(event.delta.dx, event.delta.dy);
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot (value-equal): rebuilds on lifecycle changes,
    // NEVER on the move path (Phase-2 invariant, RESEARCH Pitfall 9).
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    return Scaffold(
      backgroundColor: const Color(0xFF0E0F12),
      body: SafeArea(
        child: Stack(
          children: [
            // The full-bleed trackpad surface: Listener is a raw pointer
            // route with zero gesture arena / rebuild on the hot path.
            Positioned.fill(
              child: Listener(
                onPointerMove: _onPointerMove,
                behavior: HitTestBehavior.opaque,
                child: Container(
                  color: const Color(0xFF0E0F12),
                  alignment: Alignment.center,
                  child: Text(
                    authed ? kTrackpadHintAuthed : kTrackpadHintNotConnected,
                    style: const TextStyle(color: Color(0xFF6B7280)),
                  ),
                ),
              ),
            ),

            // Banner (full-width, under the safe-area top) + header chip
            // (top-right — the old HUD slot). The chip ignores pointers so
            // the trackpad surface stays uninterrupted beneath it.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ReconnectingBannerSlot(
                    visible: status.chip == ChipStatus.reconnecting,
                    onRetry: _service.retryNow,
                  ),
                  Align(
                    alignment: Alignment.topRight,
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: IgnorePointer(
                        child: ConnectionHeaderChip.forService(_service),
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
