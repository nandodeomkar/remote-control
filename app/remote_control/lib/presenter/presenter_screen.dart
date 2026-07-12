/// The Presenter screen (PRES-01/02, D-07/08/09) — full-screen split tap
/// zones + a bottom bar with the manual elapsed timer.
///
/// D-07 layout: a slim "Presenter" app bar (header chip, D-02) over a
/// reconnecting-banner slot and a full-bleed `#0E0F12` body. The body is two
/// tap zones split by a 1px `#2A2D34` hairline — Prev on the left third,
/// Next on the right two-thirds. A press-down on either zone sends
/// `present {prev|next}` on the reliable path, fires a haptic tick
/// (press-down, not release — the Phase-4 rule), and flashes the zone's
/// chevron accent (`#4C8DFF`) for 100ms. The 64px bottom bar (top hairline)
/// carries "Start show" / "End show" / the "Blank" toggle and the
/// right-aligned mm:ss timer.
///
/// D-08 timer: [PresenterTimer] is the client-local FSM (never a wire
/// message). "Start show" sends `present {start}` AND calls
/// `timer.startShow()`; "End show" sends `present {end}` and leaves the timer
/// untouched (manual control only). The timer text taps to pause/resume and
/// long-presses to reset. A single widget-local 1s `Timer.periodic` — created
/// lazily on the first Start show and CANCELLED in dispose (Pitfall 13) —
/// drives the mm:ss re-render; the FSM itself owns no timer.
///
/// D-09 keep-awake: the wakelock is enabled in initState and disabled in
/// dispose — it must never leak past this screen.
///
/// Every send is gated: when the header chip is not connected the zones and
/// bar controls render muted (`#6B7280`) and inert — never red. The Blank
/// toggle is optimistic local state (the wire has no blank readback): tapping
/// either state sends `present {blank}` and flips locally.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../settings/haptics.dart';
import '../theme/tokens.dart';
import '../widgets/connection_header.dart';
import '../widgets/keep_awake.dart';
import 'presenter_timer.dart';

/// The presenter remote (D-07): split tap zones, bottom bar, manual timer.
class PresenterScreen extends ConsumerStatefulWidget {
  /// Creates the presenter screen.
  const PresenterScreen({super.key});

  @override
  ConsumerState<PresenterScreen> createState() => _PresenterScreenState();
}

class _PresenterScreenState extends ConsumerState<PresenterScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  /// Client-local elapsed timer FSM (D-08). System clock in production.
  late final PresenterTimer _timer;

  /// Widget-local 1s re-render ticker — created lazily on the first Start
  /// show, cancelled in dispose (Pitfall 13). The FSM holds no timer.
  Timer? _ticker;

  /// Optimistic blank state (no wire readback — D-07/UI-SPEC).
  bool _blanked = false;

  /// 100ms chevron accent flash flags (per zone).
  bool _prevFlash = false;
  bool _nextFlash = false;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
    _timer = PresenterTimer(
      nowMillis: () => DateTime.now().millisecondsSinceEpoch,
    );
    // D-09/D-14: keep the phone awake while presenting, ref-counted so a
    // Trackpad quick-bar excursion never drops it out from under this screen.
    keepAwake.acquire();
  }

  @override
  void dispose() {
    _ticker?.cancel();
    // D-09/D-14: release this screen's hold — the shared ref-count only
    // disables the wakelock once every holder has released.
    keepAwake.release();
    super.dispose();
  }

  // The 1s ticker only needs to exist while a show has been started; the
  // display is otherwise static. Created once, then reused.
  void _ensureTicker() {
    _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  // Prev/Next zone taps: each sends its own present macro (a distinct
  // advance per the PRES-01 vocabulary) with a haptic tick per advance.
  void _onPrev() => _onZone(const PresentMsg(action: 'prev'), true);

  void _onNext() => _onZone(const PresentMsg(action: 'next'), false);

  // Zone tap (press-down): reliable present + haptic tick + 100ms accent
  // flash of the tapped chevron.
  void _onZone(PresentMsg msg, bool isPrev) {
    _service.sendReliable(msg);
    hapticTick();
    setState(() {
      if (isPrev) {
        _prevFlash = true;
      } else {
        _nextFlash = true;
      }
    });
    Future.delayed(const Duration(milliseconds: 100), () {
      if (!mounted) return;
      setState(() {
        if (isPrev) {
          _prevFlash = false;
        } else {
          _nextFlash = false;
        }
      });
    });
  }

  // "Start show": present {start} AND start the local timer (D-08).
  void _onStartShow() {
    _service.sendReliable(const PresentMsg(action: 'start'));
    hapticTick();
    _timer.startShow();
    _ensureTicker();
    setState(() {});
  }

  // "End show": present {end} only — the timer is manual, left untouched
  // (D-08).
  void _onEndShow() {
    _service.sendReliable(const PresentMsg(action: 'end'));
    hapticTick();
  }

  // "Blank" toggle: present {blank} + optimistic local flip (no readback).
  void _onBlank() {
    _service.sendReliable(const PresentMsg(action: 'blank'));
    hapticTick();
    setState(() => _blanked = !_blanked);
  }

  // Timer text tap = pause/resume; long-press = reset (client-local, D-08).
  void _onTimerTap() {
    _timer.tap();
    setState(() {});
  }

  void _onTimerReset() {
    _timer.reset();
    hapticTick();
    setState(() {});
  }

  String _fmtElapsed(int ms) {
    final totalSec = ms ~/ 1000;
    final m = (totalSec ~/ 60).toString().padLeft(2, '0');
    final s = (totalSec % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  Color _timerColor() {
    switch (_timer.state) {
      case PresenterTimerState.running:
        return kAccent;
      case PresenterTimerState.paused:
        return kText;
      case PresenterTimerState.stopped:
        return kMuted;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — rebuilds on lifecycle changes, never a hot
    // path here (all sends are discrete taps).
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    return Scaffold(
      backgroundColor: kBg,
      appBar: AppBar(
        backgroundColor: kBg,
        title: const Text(
          'Presenter',
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
            // Split tap zones — Prev (left third) | hairline | Next (right
            // two-thirds).
            Expanded(
              child: Row(
                children: [
                  Expanded(
                    flex: 1,
                    child: _TapZone(
                      icon: Icons.chevron_left,
                      caption: 'Previous',
                      flashing: _prevFlash,
                      enabled: authed,
                      onTapDown: _onPrev,
                    ),
                  ),
                  const SizedBox(
                    width: 1,
                    height: double.infinity,
                    child: ColoredBox(color: kHairline),
                  ),
                  Expanded(
                    flex: 2,
                    child: _TapZone(
                      icon: Icons.chevron_right,
                      caption: 'Next',
                      flashing: _nextFlash,
                      enabled: authed,
                      onTapDown: _onNext,
                    ),
                  ),
                ],
              ),
            ),
            _buildBottomBar(authed),
          ],
        ),
      ),
    );
  }

  Widget _buildBottomBar(bool authed) {
    return Container(
      height: 64,
      decoration: const BoxDecoration(
        color: kBg,
        border: Border(top: BorderSide(color: kHairline)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        children: [
          _BarButton(
            label: 'Start show',
            enabled: authed,
            onPressed: _onStartShow,
          ),
          const SizedBox(width: 8),
          _BarButton(
            label: 'End show',
            enabled: authed,
            onPressed: _onEndShow,
          ),
          const SizedBox(width: 8),
          _BlankToggle(
            active: _blanked,
            enabled: authed,
            onPressed: _onBlank,
          ),
          const Spacer(),
          // Manual elapsed timer (client-local — always interactive).
          Tooltip(
            message: 'Tap to pause, hold to reset',
            child: GestureDetector(
              onTap: _onTimerTap,
              onLongPress: _onTimerReset,
              behavior: HitTestBehavior.opaque,
              child: Container(
                constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                alignment: Alignment.centerRight,
                child: Text(
                  _fmtElapsed(_timer.elapsedMs()),
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w600,
                    color: _timerColor(),
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// One split tap zone: a big chevron + caption. Press-down fires [onTapDown]
/// (the send/haptic/flash live in the parent). The chevron flashes accent
/// while [flashing]; it renders muted when [enabled] is false (gated, never
/// red).
class _TapZone extends StatelessWidget {
  final IconData icon;
  final String caption;
  final bool flashing;
  final bool enabled;
  final VoidCallback onTapDown;

  const _TapZone({
    required this.icon,
    required this.caption,
    required this.flashing,
    required this.enabled,
    required this.onTapDown,
  });

  @override
  Widget build(BuildContext context) {
    final color = !enabled
        ? kMuted
        : flashing
            ? kAccent
            : kMuted;
    return GestureDetector(
      onTapDown: enabled ? (_) => onTapDown() : null,
      behavior: HitTestBehavior.opaque,
      child: Container(
        color: kBg,
        alignment: Alignment.center,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 48, color: color),
            const SizedBox(height: 4),
            Text(
              caption,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w400,
                color: color,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A bottom-bar text button ("Start show" / "End show"): key-cap chrome,
/// gated muted (never red) when disabled.
class _BarButton extends StatelessWidget {
  final String label;
  final bool enabled;
  final VoidCallback onPressed;

  const _BarButton({
    required this.label,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: const BorderSide(color: kHairline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: enabled ? kText : kMuted,
            ),
          ),
        ),
      ),
    );
  }
}

/// The "Blank" toggle: armed-chip outline pattern when [active] (`#4C8DFF`
/// border + accent label); gated muted when disabled.
class _BlankToggle extends StatelessWidget {
  final bool active;
  final bool enabled;
  final VoidCallback onPressed;

  const _BlankToggle({
    required this.active,
    required this.enabled,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    final Color borderColor;
    final Color fgColor;
    if (!enabled) {
      borderColor = kHairline;
      fgColor = kMuted;
    } else if (active) {
      borderColor = kAccent;
      fgColor = kAccent;
    } else {
      borderColor = kHairline;
      fgColor = kText;
    }
    return Material(
      color: kSurface,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: borderColor),
        borderRadius: BorderRadius.circular(8),
      ),
      child: InkWell(
        onTap: enabled ? onPressed : null,
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.crop_din, size: 18, color: fgColor),
              const SizedBox(width: 6),
              Text(
                'Blank',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: fgColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
