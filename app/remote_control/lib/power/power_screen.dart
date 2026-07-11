/// The Power screen (PWR-01..03, D-05/D-06) — four slide-to-confirm tracks
/// plus the app's ONE modal, the red countdown dialog.
///
/// D-05/D-06 layout: a slim "Power" app bar (header chip, D-02) over a
/// reconnecting-banner slot and a `#0E0F12` body. The body stacks four
/// [ConfirmTrackFsm]-driven slide tracks in reading order — Lock, Sleep,
/// Restart, Shut down — md-gapped within each pair and lg-gapped between the
/// SAFE pair (Lock/Sleep, accent `#4C8DFF`) and the DESTRUCTIVE pair
/// (Restart/Shut down, `#FF6B6B`).
///
/// # The no-single-action-path contract (T-05-12, roadmap SC3)
///
/// Every power send originates from a completed slide's FSM effect — there is
/// NO plain button anywhere that maps to a [PowerMsg]. The FSM proves the
/// gesture gate (≥0.9); this screen only executes the effects it returns:
///   - [SendPower]    → `_service.sendReliable(PowerMsg(action))`
///   - [SendConfirm]  → `_service.sendReliable(ConfirmMsg(action))` — the
///     lock/sleep same-tick second message (FIFO order guaranteed by the
///     reliable queue, D-05).
///   - [OpenCountdown]→ the red dialog; its confirm button is the ONLY other
///     `ConfirmMsg` sender (restart/shutdown, D-06). Reaching 0s auto-dismisses
///     and sends NOTHING; Cancel/barrier-dismiss send nothing either.
///
/// [kPowerConfirmWindowSeconds] mirrors the server CONFIRM_WINDOW
/// (server-core dispatch/router.rs) — the dialog counts down from it.
///
/// # Quiet after a confirmed action (RESEARCH Pattern 5)
///
/// A confirmed sleep/restart/shutdown drops the socket BY DESIGN (the PC is
/// suspending/rebooting). This screen never stacks an error dialog on that —
/// the inherited reconnecting banner owns recovery. A late `confirm` earning
/// `err{noPendingAction}` is silently ignored (the auto-dismiss at 0s IS the
/// timeout surface); no error plumbing here by design.
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart' show ChipStatus, ConnectionService;
import '../widgets/connection_header.dart';
import 'confirm_track_fsm.dart';

// UI-SPEC locked palette.
const Color _bg = Color(0xFF0E0F12);
const Color _surface = Color(0xFF16181D);
const Color _hairline = Color(0xFF2A2D34);
const Color _text = Color(0xFFE6E8EB);
const Color _accent = Color(0xFF4C8DFF);
const Color _destructive = Color(0xFFFF6B6B);
const Color _muted = Color(0xFF6B7280);

/// The server-side `power`→`confirm` window (server-core dispatch/router.rs
/// CONFIRM_WINDOW). The countdown dialog counts down from this many seconds so
/// the client's dialog and the server's single-shot gate expire together.
const int kPowerConfirmWindowSeconds = 10;

/// One power action's presentation (label + icon + which pair it belongs to).
class _PowerAction {
  final String action;
  final String label;
  final IconData icon;
  final bool destructive;

  const _PowerAction({
    required this.action,
    required this.label,
    required this.icon,
    required this.destructive,
  });

  Color get color => destructive ? _destructive : _accent;
}

// Reading order: safe pair (Lock, Sleep) then destructive pair (Restart,
// Shut down) — D-05/D-06 grouping. Labels per the 05-UI-SPEC copywriting table.
const List<_PowerAction> _kSafePair = [
  _PowerAction(
    action: 'lock',
    label: 'Slide to lock',
    icon: Icons.lock_outline,
    destructive: false,
  ),
  _PowerAction(
    action: 'sleep',
    label: 'Slide to sleep',
    icon: Icons.bedtime_outlined,
    destructive: false,
  ),
];

const List<_PowerAction> _kDestructivePair = [
  _PowerAction(
    action: 'restart',
    label: 'Slide to restart',
    icon: Icons.restart_alt,
    destructive: true,
  ),
  _PowerAction(
    action: 'shutdown',
    label: 'Slide to shut down',
    icon: Icons.power_settings_new,
    destructive: true,
  ),
];

/// The power remote (D-05/D-06): four slide-to-confirm tracks + countdown
/// dialog. No single-tap path to any action exists on this screen.
class PowerScreen extends ConsumerStatefulWidget {
  /// Creates the power screen.
  const PowerScreen({super.key});

  @override
  ConsumerState<PowerScreen> createState() => _PowerScreenState();
}

class _PowerScreenState extends ConsumerState<PowerScreen> {
  /// Cached once — app-lifetime singleton (house pattern).
  late final ConnectionService _service;

  @override
  void initState() {
    super.initState();
    _service = ref.read(connectionServiceProvider);
  }

  // Execute the FSM's completion effects. This is the SOLE place PowerMsg is
  // sent, and one of exactly two places ConfirmMsg is sent (the other is the
  // countdown dialog's confirm button). SpringBack is a visual-only effect the
  // track already handled — nothing to send.
  void _runEffects(List<ConfirmTrackEffect> effects) {
    for (final e in effects) {
      switch (e) {
        case SendPower(:final action):
          _service.sendReliable(PowerMsg(action: action));
        case SendConfirm(:final action):
          // D-05: same-tick after SendPower — FIFO order held by the queue.
          _service.sendReliable(ConfirmMsg(action: action));
        case OpenCountdown(:final action):
          _openCountdown(action);
        case SpringBack():
          break;
      }
    }
  }

  // D-06: the red countdown dialog. Its confirm button is the ONLY confirm
  // sender for restart/shutdown; auto-dismiss at 0s sends nothing.
  void _openCountdown(String action) {
    final label = action == 'restart' ? 'Restart' : 'Shut down';
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: true, // barrier-dismiss = Cancel (sends nothing)
        builder: (_) => _CountdownDialog(
          verb: label,
          windowSeconds: kPowerConfirmWindowSeconds,
          onConfirm: () {
            // The second of exactly two ConfirmMsg send sites (D-06).
            _service.sendReliable(ConfirmMsg(action: action));
            unawaited(HapticFeedback.mediumImpact());
          },
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Transition-only snapshot — rebuilds on lifecycle changes only.
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;

    return Scaffold(
      backgroundColor: _bg,
      appBar: AppBar(
        backgroundColor: _bg,
        title: const Text(
          'Power',
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.w600,
            color: _text,
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
            // D-02: the non-blocking drop strip under the app bar.
            ReconnectingBannerSlot(
              visible: status.chip == ChipStatus.reconnecting,
              onRetry: _service.retryNow,
            ),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(16, 32, 16, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Safe pair (Lock, Sleep) — md gap between them.
                    for (var i = 0; i < _kSafePair.length; i++) ...[
                      if (i > 0) const SizedBox(height: 16),
                      _SlideTrack(
                        key: ValueKey(_kSafePair[i].action),
                        spec: _kSafePair[i],
                        enabled: authed,
                        onEffects: _runEffects,
                      ),
                    ],
                    // lg gap separates the safe pair from the destructive pair.
                    const SizedBox(height: 24),
                    for (var i = 0; i < _kDestructivePair.length; i++) ...[
                      if (i > 0) const SizedBox(height: 16),
                      _SlideTrack(
                        key: ValueKey(_kDestructivePair[i].action),
                        spec: _kDestructivePair[i],
                        enabled: authed,
                        onEffects: _runEffects,
                      ),
                    ],
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

/// One slide-to-confirm track (05-UI-SPEC state table). Owns its
/// [ConfirmTrackFsm]: horizontal drags feed dragStart/dragUpdate/dragEnd; the
/// completion effects surface through [onEffects]. Renders the thumb following
/// the finger, a 20%-opacity action-color fill, a fading label, a 200ms
/// spring-back on cancel, and a full-fill flash + haptic on completion. Inert
/// and muted (`#6B7280`) when [enabled] is false — never red.
class _SlideTrack extends StatefulWidget {
  final _PowerAction spec;
  final bool enabled;
  final void Function(List<ConfirmTrackEffect> effects) onEffects;

  const _SlideTrack({
    super.key,
    required this.spec,
    required this.enabled,
    required this.onEffects,
  });

  @override
  State<_SlideTrack> createState() => _SlideTrackState();
}

class _SlideTrackState extends State<_SlideTrack> {
  static const double _trackHeight = 64;
  static const double _thumbSize = 56;
  static const double _inset = 4;

  late final ConfirmTrackFsm _fsm = ConfirmTrackFsm(action: widget.spec.action);

  /// Thumb progress the widget renders (0..1). Diverges from the FSM only
  /// during the spring-back / completion-reset animation.
  double _display = 0.0;

  /// Drives the AnimatedPositioned/AnimatedContainer duration: zero while the
  /// finger is down (thumb tracks instantly), 200ms on release (spring-back).
  bool _animate = false;

  void _onStart(DragStartDetails _) {
    if (!widget.enabled) return;
    _fsm.dragStart();
    setState(() {
      _animate = false;
      _display = 0.0;
    });
  }

  void _onUpdate(DragUpdateDetails details, double width) {
    if (!widget.enabled) return;
    final p = (details.localPosition.dx / width).clamp(0.0, 1.0);
    _fsm.dragUpdate(p);
    setState(() => _display = _fsm.progress);
  }

  void _onEnd(DragEndDetails _) {
    if (!widget.enabled) return;
    final effects = _fsm.dragEnd();
    if (_fsm.state == ConfirmTrackState.completed) {
      // Full-fill flash + haptic tick on completion (press-style feedback).
      unawaited(HapticFeedback.mediumImpact());
      setState(() {
        _animate = false;
        _display = 1.0;
      });
      widget.onEffects(effects);
      // Ease the thumb back after the flash so the track is ready again (e.g.
      // if the countdown dialog is cancelled). The FSM auto-resets on the next
      // dragStart (completed → fresh drag).
      Future.delayed(const Duration(milliseconds: 300), () {
        if (!mounted) return;
        setState(() {
          _animate = true;
          _display = 0.0;
        });
      });
    } else {
      // Below threshold: spring the thumb back over 200ms, send nothing.
      widget.onEffects(effects); // SpringBack — visual only.
      setState(() {
        _animate = true;
        _display = 0.0;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final enabled = widget.enabled;
    final actionColor = enabled ? widget.spec.color : _muted;
    final animDuration =
        _animate ? const Duration(milliseconds: 200) : Duration.zero;

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final travel = w - _thumbSize - 2 * _inset;
        final thumbLeft = _inset + _display * travel;
        final fillWidth = thumbLeft + _thumbSize;

        return GestureDetector(
          onHorizontalDragStart: _onStart,
          onHorizontalDragUpdate: (d) => _onUpdate(d, w),
          onHorizontalDragEnd: _onEnd,
          behavior: HitTestBehavior.opaque,
          child: Container(
            height: _trackHeight,
            decoration: BoxDecoration(
              color: _surface,
              border: Border.all(color: _hairline),
              borderRadius: BorderRadius.circular(16),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              children: [
                // 20%-opacity action-color progress fill behind the thumb.
                AnimatedContainer(
                  duration: animDuration,
                  width: fillWidth,
                  height: _trackHeight,
                  color: actionColor.withValues(alpha: 0.2),
                ),
                // Centered label, fading out as the slide progresses.
                Positioned.fill(
                  child: Center(
                    child: Opacity(
                      opacity: (1.0 - _display).clamp(0.0, 1.0),
                      child: Text(
                        widget.spec.label,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w400,
                          color: _muted,
                        ),
                      ),
                    ),
                  ),
                ),
                // The draggable thumb — action icon + chevron on the action
                // color; icon in bg color for contrast.
                AnimatedPositioned(
                  duration: animDuration,
                  left: thumbLeft,
                  top: _inset,
                  child: Container(
                    width: _thumbSize,
                    height: _thumbSize,
                    decoration: BoxDecoration(
                      color: actionColor,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Icon(widget.spec.icon, size: 20, color: _bg),
                        const Icon(Icons.chevron_right, size: 16, color: _bg),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// The red countdown dialog (D-06) — the app's ONE modal. Ticks from
/// [windowSeconds] to 0 via a dialog-local 1s timer (cancelled on dispose).
/// The destructive [FilledButton] is the sole confirm sender; reaching 0
/// auto-pops WITHOUT confirming; Cancel/barrier-dismiss pop without confirming.
class _CountdownDialog extends StatefulWidget {
  final String verb; // "Restart" | "Shut down"
  final int windowSeconds;
  final VoidCallback onConfirm;

  const _CountdownDialog({
    required this.verb,
    required this.windowSeconds,
    required this.onConfirm,
  });

  @override
  State<_CountdownDialog> createState() => _CountdownDialogState();
}

class _CountdownDialogState extends State<_CountdownDialog> {
  late int _remaining = widget.windowSeconds;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() => _remaining -= 1);
      if (_remaining <= 0) {
        // Auto-dismiss at the SPEC window — send NOTHING (D-06).
        _ticker?.cancel();
        Navigator.of(context).pop();
      }
    });
  }

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  void _confirm() {
    _ticker?.cancel();
    widget.onConfirm();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: _surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      title: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, color: _destructive),
          const SizedBox(width: 8),
          Text(
            '${widget.verb} PC?',
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w600,
              color: _text,
            ),
          ),
        ],
      ),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'This will close everything open on your PC.',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w400,
                color: _text),
          ),
          const SizedBox(height: 8),
          Text(
            'Confirm within ${_remaining.clamp(0, widget.windowSeconds)}s',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w400,
              color: _muted,
              fontFeatures: [FontFeature.tabularFigures()],
            ),
          ),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(), // Cancel — sends nothing
          child: const Text('Cancel', style: TextStyle(color: _muted)),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: _destructive,
            foregroundColor: _bg,
            minimumSize: const Size(0, 48),
          ),
          onPressed: _confirm,
          child: Text(
            widget.verb,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
          ),
        ),
      ],
    );
  }
}
