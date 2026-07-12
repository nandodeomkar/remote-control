/// The Media screen (MED-01/02, D-04) — system transport controls plus the
/// absolute volume slider and server-authoritative mute.
///
/// Layout (UI-SPEC), top→bottom with xl top padding:
///   - App bar "Media" + inherited header chip + reconnecting banner (D-02).
///   - Transport row: three circular buttons centered with sm gaps — Prev
///     (48px), Play/Pause (64px, the visually primary control), Next (48px).
///     Rest `#16181D` + `#2A2D34` border, icon `#E6E8EB`; press-down flashes
///     the accent border + icon and fires a haptic tick; each sends
///     `media {prev|playpause|next}` on the reliable path (MED-01 — the exact
///     router vocabulary). The play/pause button renders a neutral
///     `Icons.play_arrow` (the wire has no playback-state readback) but always
///     sends `playpause`.
///   - lg gap, then the volume block: a mute icon-button + a Material slider +
///     a fixed-width tabular % readout.
///
/// Volume behavior is the D-04 finger-wins contract owned by
/// [volumeStateProvider]: the slider value + mute render from the pushed
/// `vol.changed` snapshot (server-authoritative, no optimistic mute flip);
/// dragging delegates to the store (leading-edge throttled `setvol`, pushes
/// ignored while the finger is down). Pre-snapshot (connected, no push yet) or
/// disconnected: the slider + mute render inert at `#6B7280` and the readout is
/// "--" — the 05-03 after-auth snapshot resolves this in <1s.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import 'volume_store.dart';

/// The media remote: transport row + volume block (MED-01/02).
class MediaScreen extends ConsumerStatefulWidget {
  /// Creates the media screen.
  const MediaScreen({super.key});

  @override
  ConsumerState<MediaScreen> createState() => _MediaScreenState();
}

class _MediaScreenState extends ConsumerState<MediaScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
  }

  // Transport taps (MED-01): reliable media macro + haptic tick (press-down).
  // The button widget owns the accent flash; the send stays here.
  void _onPrev() => _service.sendReliable(const MediaMsg(action: 'prev'));

  void _onPlayPause() =>
      _service.sendReliable(const MediaMsg(action: 'playpause'));

  void _onNext() => _service.sendReliable(const MediaMsg(action: 'next'));

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — rebuilds on lifecycle changes, never a hot
    // path here (every send is a discrete tap).
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    // Volume view state (value-equal; the notifier suppresses no-op rebuilds).
    final vol = ref.watch(volumeStateProvider);
    final volume = ref.read(volumeStateProvider.notifier);

    // The slider + mute are live only once connected AND a push has landed
    // (D-03 after-auth snapshot); otherwise inert at #6B7280 with a "--"
    // readout.
    final volumeLive = authed && vol.hasSnapshot;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          'Media',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: kText,
          ),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 16),
            child: Center(child: ConnectionHeaderChip.forService(_service)),
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            // D-02: non-blocking drop strip under the app bar.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: SingleChildScrollView(
                // md edge padding, xl top padding (UI-SPEC).
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Transport row — Prev 48 / Play-Pause 64 / Next 48, sm
                    // gaps, centered.
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _TransportButton(
                          icon: Icons.skip_previous,
                          size: 48,
                          tooltip: 'Previous',
                          enabled: authed,
                          onPress: _onPrev,
                        ),
                        const SizedBox(width: 8),
                        _TransportButton(
                          // Neutral toggle glyph — the wire has no playback
                          // readback, so this always sends `playpause`.
                          icon: Icons.play_arrow,
                          size: 64,
                          tooltip: 'Play or pause',
                          enabled: authed,
                          onPress: _onPlayPause,
                        ),
                        const SizedBox(width: 8),
                        _TransportButton(
                          icon: Icons.skip_next,
                          size: 48,
                          tooltip: 'Next',
                          enabled: authed,
                          onPress: _onNext,
                        ),
                      ],
                    ),
                    // lg gap between the transport row and the volume block.
                    const SizedBox(height: 24),
                    // Volume block — mute + slider + tabular % readout.
                    Row(
                      children: [
                        _MuteButton(
                          enabled: volumeLive,
                          muted: vol.muted,
                          onPressed: volume.toggleMute,
                        ),
                        const SizedBox(width: 4),
                        Expanded(
                          child: SliderTheme(
                            data: SliderTheme.of(context).copyWith(
                              activeTrackColor: kAccent,
                              inactiveTrackColor: kHairline,
                              thumbColor: kAccent,
                              disabledActiveTrackColor: kMuted,
                              disabledInactiveTrackColor: kHairline,
                              disabledThumbColor: kMuted,
                            ),
                            child: Slider(
                              value: vol.value.clamp(0, 100).toDouble(),
                              min: 0,
                              max: 100,
                              onChangeStart: volumeLive
                                  ? (_) => volume.dragStart()
                                  : null,
                              onChanged: volumeLive
                                  ? (v) => volume.dragUpdate(v.round())
                                  : null,
                              onChangeEnd:
                                  volumeLive ? (_) => volume.dragEnd() : null,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        // Fixed-width tabular readout so it never reflows.
                        SizedBox(
                          width: 44,
                          child: Text(
                            vol.hasSnapshot ? '${vol.value}%' : '--',
                            textAlign: TextAlign.right,
                            style: const TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w400,
                              color: kText,
                              fontFeatures: [FontFeature.tabularFigures()],
                            ),
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// One circular transport button (carried Phase-4 key-cap pressed pattern):
/// `#16181D` fill + `#2A2D34` border at rest; press-down flashes the accent
/// border + icon (`#4C8DFF`) and fires a haptic tick, then relaxes after
/// 100ms. Gated muted (`#6B7280`, never red) when disabled.
class _TransportButton extends StatefulWidget {
  final IconData icon;
  final double size;
  final String tooltip;
  final bool enabled;
  final VoidCallback onPress;

  const _TransportButton({
    required this.icon,
    required this.size,
    required this.tooltip,
    required this.enabled,
    required this.onPress,
  });

  @override
  State<_TransportButton> createState() => _TransportButtonState();
}

class _TransportButtonState extends State<_TransportButton> {
  bool _pressed = false;

  // Press-down (Phase-4 rule): send + haptic + accent flash immediately.
  void _fire() {
    widget.onPress();
    unawaited(HapticFeedback.lightImpact());
    setState(() => _pressed = true);
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      setState(() => _pressed = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final borderColor = _pressed ? kAccent : kHairline;
    final iconColor = !widget.enabled
        ? kMuted
        : _pressed
            ? kAccent
            : kText;
    return Tooltip(
      message: widget.tooltip,
      child: Material(
        color: kSurface,
        shape: CircleBorder(side: BorderSide(color: borderColor)),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.enabled ? () {} : null,
          onTapDown: widget.enabled ? (_) => _fire() : null,
          child: SizedBox(
            width: widget.size,
            height: widget.size,
            child: Icon(widget.icon, size: widget.size * 0.5, color: iconColor),
          ),
        ),
      ),
    );
  }
}

/// The mute icon-button (MED-02). Server-authoritative: engaged renders the
/// Phase-4 locked-chip solid pattern (solid `#4C8DFF` fill + `#0E0F12`
/// `Icons.volume_off`), rest renders `#16181D` + border + `Icons.volume_up`.
/// Gated muted (`#6B7280`, inert) when not live. Tapping sends `media {mute}`;
/// the rendered state follows the next push — NO optimistic flip.
class _MuteButton extends StatelessWidget {
  final bool enabled;
  final bool muted;
  final VoidCallback onPressed;

  const _MuteButton({
    required this.enabled,
    required this.muted,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final Color fill;
    final Color iconColor;
    final BorderSide side;
    final IconData icon;
    if (!enabled) {
      fill = kSurface;
      iconColor = kMuted;
      side = const BorderSide(color: kHairline);
      icon = Icons.volume_up;
    } else if (muted) {
      fill = kAccent;
      iconColor = kBg;
      side = BorderSide.none;
      icon = Icons.volume_off;
    } else {
      fill = kSurface;
      iconColor = kText;
      side = const BorderSide(color: kHairline);
      icon = Icons.volume_up;
    }
    return Tooltip(
      message: muted ? 'Unmute' : 'Mute',
      child: Material(
        color: fill,
        shape: CircleBorder(side: side),
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: enabled ? onPressed : null,
          child: SizedBox(
            width: 48,
            height: 48,
            child: Icon(icon, size: 24, color: iconColor),
          ),
        ),
      ),
    );
  }
}
