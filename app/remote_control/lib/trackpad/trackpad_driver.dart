/// TrackpadDriver: the intent EXECUTOR half of the D-04 split — the
/// [GestureClassifier] (pure FSM) decides WHAT happened; this driver makes it
/// REAL: accelGain-scaled `sendMove` (PAD-01/D-05), `ClickMsg`/`DragMsg` on
/// the reliable path (PAD-02/04), px→wheel-unit `sendScroll` conversion plus
/// the momentum decay loop with instant touch-stop (PAD-03), the long-press
/// one-shot (PAD-04), haptic ticks, and the drag-lock notification the pill
/// rides.
///
/// Every side effect is an injected seam — `onSendMove`/`onSendScroll`/
/// `onSendReliable` (the screen wires ConnectionService), `onHaptic`
/// (HapticFeedback stays OUT of this file so it remains widget-free pure
/// Dart), `onDragLockChanged` (the pill's ValueNotifier), `onLongPressElapsed`
/// (the screen feeds `classifier.onLongPressFire()` back into [handle]), the
/// `sensitivity` getter (D-05 — the screen caches the provider value; never a
/// provider lookup per event), and the `schedule` timer seam (ConnectionService
/// `_schedule` idiom) so every branch unit-tests deterministically.
///
/// The schedule seam has NO cancel handle, so both the momentum loop and the
/// long-press one-shot use generation counters (the `_backoffGen`/
/// `_livenessGen` idiom): bumping the generation makes any in-flight callback
/// a no-op. Scroll/move deltas are NEVER queued or batched (RESEARCH
/// Anti-Pattern — queued deltas teleport on reconnect); one intent, one send.
///
/// Every feel constant comes from tuning.dart (D-06) — no magic numbers here.
library;

// Ctor params keep public names while fields stay private (house idiom —
// see ConnectionService/GestureClassifier's per-line ignores).
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:math' as math;

import 'package:remote_protocol/remote_protocol.dart';

import 'accel.dart';
import 'gesture_classifier.dart';
import 'tuning.dart';

/// Executes [GestureIntent]s against injected seams. See the library doc.
class TrackpadDriver {
  final void Function(double dx, double dy) _onSendMove;
  final void Function(double dx, double dy) _onSendScroll;
  final void Function(RemoteMessage msg) _onSendReliable;
  final void Function() _onHaptic;
  final void Function(bool locked) _onDragLockChanged;
  final void Function() _onLongPressElapsed;
  final double Function() _sensitivity;
  final void Function(Duration, void Function()) _schedule;
  final void Function()? _onReset;

  bool _disposed = false;
  bool _dragLocked = false;

  /// Momentum generation: bumping it kills any in-flight tick chain (the
  /// schedule seam has no cancel — stale ticks no-op on a gen mismatch).
  int _momentumGen = 0;

  /// Long-press generation: same guard for the pending one-shot.
  int _longPressGen = 0;

  double _vx = 0;
  double _vy = 0;

  /// Creates the driver over injected seams.
  ///
  /// [schedule] defaults to one-shot [Timer]s (production); tests inject a
  /// recording fake. [onReset] is the classifier-reset hook: the screen wires
  /// `classifier.reset` so one [reset] call clears BOTH halves on disconnect.
  TrackpadDriver({
    required void Function(double dx, double dy) onSendMove,
    required void Function(double dx, double dy) onSendScroll,
    required void Function(RemoteMessage msg) onSendReliable,
    required void Function() onHaptic,
    required void Function(bool locked) onDragLockChanged,
    required void Function() onLongPressElapsed,
    required double Function() sensitivity,
    void Function(Duration, void Function())? schedule,
    void Function()? onReset,
  })  : _onSendMove = onSendMove,
        _onSendScroll = onSendScroll,
        _onSendReliable = onSendReliable,
        _onHaptic = onHaptic,
        _onDragLockChanged = onDragLockChanged,
        _onLongPressElapsed = onLongPressElapsed,
        _sensitivity = sensitivity,
        _schedule = schedule ?? _timerSchedule,
        _onReset = onReset;

  static void _timerSchedule(Duration delay, void Function() fn) {
    Timer(delay, fn);
  }

  /// Whether drag-lock is currently engaged (the pill's source of truth).
  bool get dragLocked => _dragLocked;

  /// Executes one event's intents in order. No-op after [dispose].
  void handle(List<GestureIntent> intents) {
    if (_disposed) return;
    for (final intent in intents) {
      switch (intent) {
        case MoveIntent(:final dx, :final dy):
          final g = accelGain(dx, dy, _sensitivity());
          _onSendMove(dx * g, dy * g);
        case ClickLeftIntent():
          _onSendReliable(const ClickMsg(button: 'left'));
          _onHaptic();
        case ClickRightIntent():
          _onSendReliable(const ClickMsg(button: 'right'));
          _onHaptic();
        case ScrollIntent(:final dx, :final dy):
          _onSendScroll(
            dx * kScrollUnitPerPx,
            dy * kScrollUnitPerPx * kScrollDirection,
          );
        case FlingIntent(:final vx, :final vy):
          _startMomentum(vx, vy);
        case StopFlingIntent():
          _momentumGen++; // instant touch-stop: pending ticks are stale now
        case ArmLongPressIntent(:final delayMs):
          _armLongPress(delayMs);
        case DisarmLongPressIntent():
          _longPressGen++; // stale one-shot no-ops on fire
        case DragStartIntent():
          _onSendReliable(const DragMsg(action: 'start', button: 'left'));
          _dragLocked = true;
          _onDragLockChanged(true);
          _onHaptic();
        case DragEndIntent():
          _onSendReliable(const DragMsg(action: 'end', button: 'left'));
          _dragLocked = false;
          _onDragLockChanged(false);
      }
    }
  }

  /// Disconnect hygiene (D-12-adjacent): cancels the momentum loop and any
  /// pending long-press, clears drag-lock (notifying the pill down), and
  /// resets the classifier via the [onReset] hook. Sends NOTHING — the
  /// server's held state is CONN-07 `release_all`'s job, and there is no
  /// live session to send on anyway.
  void reset() {
    _momentumGen++;
    _longPressGen++;
    if (_dragLocked) {
      _dragLocked = false;
      _onDragLockChanged(false);
    }
    _onReset?.call();
  }

  /// Permanently stops the driver: no callback fires after this.
  void dispose() {
    _disposed = true;
    _momentumGen++;
    _longPressGen++;
  }

  /// Momentum loop (RESEARCH Pattern 2): a self-rescheduling
  /// [kMomentumTickMs] tick chain. Each tick decays velocity by
  /// [kMomentumDecay], stops itself below [kMomentumStopVelocity], and
  /// otherwise emits one px→wheel-unit scroll send (same conversion as live
  /// ScrollIntents — the fling is just fingers that already left).
  void _startMomentum(double vx, double vy) {
    final gen = ++_momentumGen;
    _vx = vx;
    _vy = vy;

    void tick() {
      if (_disposed || gen != _momentumGen) return; // superseded / stopped
      _vx *= kMomentumDecay;
      _vy *= kMomentumDecay;
      if (math.sqrt(_vx * _vx + _vy * _vy) < kMomentumStopVelocity) return;
      _onSendScroll(
        _vx * kMomentumTickMs * kScrollUnitPerPx,
        _vy * kMomentumTickMs * kScrollUnitPerPx * kScrollDirection,
      );
      _schedule(const Duration(milliseconds: kMomentumTickMs), tick);
    }

    _schedule(const Duration(milliseconds: kMomentumTickMs), tick);
  }

  /// One-shot long-press timer: fires [_onLongPressElapsed] unless disarmed
  /// (or re-armed, or disposed) before the delay elapses.
  void _armLongPress(int delayMs) {
    final gen = ++_longPressGen;
    _schedule(Duration(milliseconds: delayMs), () {
      if (_disposed || gen != _longPressGen) return; // stale — disarmed
      _onLongPressElapsed();
    });
  }
}
