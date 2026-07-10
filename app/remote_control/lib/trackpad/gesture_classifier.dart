/// Pure gesture-classification FSM for the trackpad (D-04) — no IO, no
/// Flutter imports, no timers (reconnect_fsm/handshake_fsm house style).
///
/// Raw pointer events go in; `List<GestureIntent>` comes out per event. The
/// DRIVER (the trackpad screen, plan 04-04) owns every side effect: it maps
/// `MoveIntent` → `accelGain` → `sendMove`, `ScrollIntent` → `sendScroll`,
/// clicks/drags → `sendReliable`, runs the long-press timer for
/// `ArmLongPressIntent`/`DisarmLongPressIntent` (calling [onLongPressFire]
/// when it elapses), and runs the momentum loop seeded by `FlingIntent` and
/// cancelled by `StopFlingIntent`. The classifier itself never sends, never
/// schedules, and never rebuilds UI — the hot path stays a pure function
/// call (Phase-2/3 invariant).
///
/// Vocabulary (D-04): single-finger move, tap = left click, two-finger tap =
/// right click (Pitfall 4 disambiguated by [kTwoFingerTapWindowMs] +
/// [kTapSlopPx]), two-finger scroll with fling seed + instant touch-stop
/// (PAD-03), and long-press drag with drag-lock (PAD-04 — the lock survives
/// the lift for screen-edge drags; the next tap "drops"). More than two
/// concurrent pointers: extras are ignored.
///
/// Every threshold is a `k*` constant from tuning.dart (D-06) — this file
/// contains no magic numbers. The clock is the injected [nowMillis] seam
/// (same idiom as ConnectionService) so every branch unit-tests
/// deterministically without a device.
library;

import 'dart:math' as math;

import 'tuning.dart';

// ---------------------------------------------------------------------------
// Intents
// ---------------------------------------------------------------------------

/// One driver instruction produced by the classifier. Sealed so the driver's
/// switch is exhaustiveness-checked.
sealed class GestureIntent {
  const GestureIntent();
}

/// Move the cursor by a raw pointer delta (driver applies accel + sends).
final class MoveIntent extends GestureIntent {
  /// Raw x delta in logical px.
  final double dx;

  /// Raw y delta in logical px.
  final double dy;

  /// Creates a move intent carrying raw deltas.
  const MoveIntent(this.dx, this.dy);

  @override
  bool operator ==(Object other) =>
      other is MoveIntent && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(MoveIntent, dx, dy);

  @override
  String toString() => 'MoveIntent($dx, $dy)';
}

/// Tap fired: send a left click (PAD-02).
final class ClickLeftIntent extends GestureIntent {
  /// Const left-click intent.
  const ClickLeftIntent();

  @override
  bool operator ==(Object other) => other is ClickLeftIntent;

  @override
  int get hashCode => (ClickLeftIntent).hashCode;

  @override
  String toString() => 'ClickLeftIntent()';
}

/// Two-finger tap fired: send a right click (PAD-02).
final class ClickRightIntent extends GestureIntent {
  /// Const right-click intent.
  const ClickRightIntent();

  @override
  bool operator ==(Object other) => other is ClickRightIntent;

  @override
  int get hashCode => (ClickRightIntent).hashCode;

  @override
  String toString() => 'ClickRightIntent()';
}

/// Scroll by the per-event average across the live tracked pointers
/// (PAD-03). The driver converts px → wheel units ([kScrollUnitPerPx],
/// [kScrollDirection]).
final class ScrollIntent extends GestureIntent {
  /// Averaged x delta in logical px.
  final double dx;

  /// Averaged y delta in logical px.
  final double dy;

  /// Creates a scroll intent carrying averaged deltas.
  const ScrollIntent(this.dx, this.dy);

  @override
  bool operator ==(Object other) =>
      other is ScrollIntent && other.dx == dx && other.dy == dy;

  @override
  int get hashCode => Object.hash(ScrollIntent, dx, dy);

  @override
  String toString() => 'ScrollIntent($dx, $dy)';
}

/// Two-finger lift with velocity: seed the driver's momentum loop (PAD-03).
final class FlingIntent extends GestureIntent {
  /// Seed x velocity in px/ms.
  final double vx;

  /// Seed y velocity in px/ms.
  final double vy;

  /// Creates a fling seed intent.
  const FlingIntent(this.vx, this.vy);

  @override
  bool operator ==(Object other) =>
      other is FlingIntent && other.vx == vx && other.vy == vy;

  @override
  int get hashCode => Object.hash(FlingIntent, vx, vy);

  @override
  String toString() => 'FlingIntent($vx, $vy)';
}

/// Cancel any running momentum loop NOW (instant touch-stop, PAD-03).
/// Always the FIRST intent of every pointer-down.
final class StopFlingIntent extends GestureIntent {
  /// Const touch-stop intent.
  const StopFlingIntent();

  @override
  bool operator ==(Object other) => other is StopFlingIntent;

  @override
  int get hashCode => (StopFlingIntent).hashCode;

  @override
  String toString() => 'StopFlingIntent()';
}

/// Start a one-shot long-press timer of [delayMs]; call
/// [GestureClassifier.onLongPressFire] when it elapses (PAD-04).
final class ArmLongPressIntent extends GestureIntent {
  /// Timer delay in ms ([kLongPressMs]).
  final int delayMs;

  /// Creates an arm intent carrying the timer delay.
  const ArmLongPressIntent(this.delayMs);

  @override
  bool operator ==(Object other) =>
      other is ArmLongPressIntent && other.delayMs == delayMs;

  @override
  int get hashCode => Object.hash(ArmLongPressIntent, delayMs);

  @override
  String toString() => 'ArmLongPressIntent($delayMs)';
}

/// Cancel the pending long-press timer (finger moved, lifted, or a second
/// finger landed).
final class DisarmLongPressIntent extends GestureIntent {
  /// Const disarm intent.
  const DisarmLongPressIntent();

  @override
  bool operator ==(Object other) => other is DisarmLongPressIntent;

  @override
  int get hashCode => (DisarmLongPressIntent).hashCode;

  @override
  String toString() => 'DisarmLongPressIntent()';
}

/// Long-press fired: press-and-hold the LEFT button (drag begins, PAD-04).
final class DragStartIntent extends GestureIntent {
  /// Const drag-start intent.
  const DragStartIntent();

  @override
  bool operator ==(Object other) => other is DragStartIntent;

  @override
  int get hashCode => (DragStartIntent).hashCode;

  @override
  String toString() => 'DragStartIntent()';
}

/// Drag-lock dropped (the post-drag tap): release the LEFT button (PAD-04).
final class DragEndIntent extends GestureIntent {
  /// Const drag-end intent.
  const DragEndIntent();

  @override
  bool operator ==(Object other) => other is DragEndIntent;

  @override
  int get hashCode => (DragEndIntent).hashCode;

  @override
  String toString() => 'DragEndIntent()';
}

// ---------------------------------------------------------------------------
// Classifier
// ---------------------------------------------------------------------------

/// FSM phase for the current touch episode (first down → last up).
enum _Phase {
  /// No tracked pointers down.
  idle,

  /// One pointer down, under slop — tap / long-press candidate.
  tapPending1,

  /// One pointer down, slop exceeded — streaming [MoveIntent]s.
  moving,

  /// Long-press fired — streaming [MoveIntent]s with the button held.
  dragging,

  /// Two pointers down, under slop — two-finger-tap candidate.
  tapPending2,

  /// Two-finger travel exceeded slop — streaming [ScrollIntent]s.
  scrolling,
}

class _Pointer {
  double x;
  double y;
  _Pointer(this.x, this.y);
}

class _Sample {
  final int ts;
  final double dx;
  final double dy;
  const _Sample(this.ts, this.dx, this.dy);
}

/// The pure gesture FSM. See the library doc for the contract.
class GestureClassifier {
  final int Function() _nowMillis;

  final Map<int, _Pointer> _pointers = <int, _Pointer>{};
  final Set<int> _ignored = <int>{};
  final List<_Sample> _samples = <_Sample>[];

  _Phase _phase = _Phase.idle;
  bool _armed = false;
  bool _dragLocked = false;
  bool _cancelled = false;
  int _firstDownAt = 0;
  double _combinedTravel = 0;

  /// Creates a classifier reading time through the injected [nowMillis] seam
  /// (same idiom as ConnectionService — deterministic in tests).
  GestureClassifier({required int Function() nowMillis})
      : _nowMillis = nowMillis; // ignore: prefer_initializing_formals

  /// A pointer landed. Always emits [StopFlingIntent] FIRST (instant
  /// touch-stop); a first finger also arms the long-press, a second finger
  /// disarms it and opens the two-finger-tap window. Extra pointers beyond
  /// two are ignored for the rest of their contact.
  List<GestureIntent> onPointerDown(int pointer, double x, double y) {
    final intents = <GestureIntent>[const StopFlingIntent()];
    if (_pointers.containsKey(pointer)) return intents; // defensive re-down
    if (_pointers.length >= 2 || _phase == _Phase.dragging) {
      // Extras never arm or reclassify; a second finger during a drag is
      // also ignored (the drag keeps the surface).
      if (_pointers.isNotEmpty) {
        _ignored.add(pointer);
        return intents;
      }
    }
    if (_pointers.isEmpty) {
      _pointers[pointer] = _Pointer(x, y);
      _firstDownAt = _nowMillis();
      _combinedTravel = 0;
      _cancelled = false;
      _samples.clear();
      _phase = _Phase.tapPending1;
      _armed = true;
      intents.add(const ArmLongPressIntent(kLongPressMs));
      return intents;
    }
    // Second finger.
    _pointers[pointer] = _Pointer(x, y);
    if (_armed) {
      _armed = false;
      intents.add(const DisarmLongPressIntent());
    }
    if (_phase == _Phase.tapPending1) {
      _phase = _Phase.tapPending2;
    } else if (_phase == _Phase.moving) {
      // Already past slop with one finger: this is a scroll, never a tap.
      _phase = _Phase.scrolling;
    }
    return intents;
  }

  /// A tracked pointer moved. Under slop nothing is emitted (the episode is
  /// still a tap candidate); crossing slop switches to move/scroll streaming.
  List<GestureIntent> onPointerMove(int pointer, double x, double y) {
    final p = _pointers[pointer];
    if (p == null) return const [];
    final dx = x - p.x;
    final dy = y - p.y;
    p.x = x;
    p.y = y;
    _combinedTravel += math.sqrt(dx * dx + dy * dy);
    if (_cancelled) return const [];
    switch (_phase) {
      case _Phase.idle:
        return const [];
      case _Phase.tapPending1:
        if (_combinedTravel <= kTapSlopPx) return const [];
        final intents = <GestureIntent>[];
        if (_armed) {
          _armed = false;
          intents.add(const DisarmLongPressIntent());
        }
        _phase = _Phase.moving;
        intents.add(MoveIntent(dx, dy));
        return intents;
      case _Phase.moving:
      case _Phase.dragging:
        return [MoveIntent(dx, dy)];
      case _Phase.tapPending2:
        if (_combinedTravel <= kTapSlopPx) return const [];
        _phase = _Phase.scrolling;
        return [_emitScroll(dx, dy)];
      case _Phase.scrolling:
        return [_emitScroll(dx, dy)];
    }
  }

  /// A pointer lifted. Resolves taps (left click / right click / drag drop)
  /// and, when the last scroll finger lifts with recent velocity, seeds the
  /// fling. A lift during a drag emits NOTHING — drag-lock persists.
  List<GestureIntent> onPointerUp(int pointer) {
    if (_ignored.remove(pointer)) return const [];
    final p = _pointers.remove(pointer);
    if (p == null) return const [];
    final now = _nowMillis();
    switch (_phase) {
      case _Phase.idle:
        return const [];
      case _Phase.tapPending1:
        final intents = <GestureIntent>[];
        if (_armed) {
          _armed = false;
          intents.add(const DisarmLongPressIntent());
        }
        final isTap = !_cancelled && (now - _firstDownAt) <= kTapMaxMs;
        if (isTap) {
          if (_dragLocked) {
            // "Tap to drop": the lock ends here instead of a click (PAD-04).
            _dragLocked = false;
            intents.add(const DragEndIntent());
          } else {
            intents.add(const ClickLeftIntent());
          }
        }
        _phase = _Phase.idle;
        return intents;
      case _Phase.moving:
        _phase = _Phase.idle;
        return const [];
      case _Phase.dragging:
        // Drag-lock persists across the lift (screen-edge drags).
        if (_pointers.isEmpty) _phase = _Phase.idle;
        return const [];
      case _Phase.tapPending2:
        if (_pointers.isNotEmpty) return const [];
        final isTwoTap =
            !_cancelled && (now - _firstDownAt) <= kTwoFingerTapWindowMs;
        _phase = _Phase.idle;
        return isTwoTap ? const [ClickRightIntent()] : const [];
      case _Phase.scrolling:
        if (_pointers.isNotEmpty) return const [];
        _phase = _Phase.idle;
        final fling = _cancelled ? null : _flingFrom(now);
        _samples.clear();
        return fling == null ? const [] : [fling];
    }
  }

  /// The system cancelled a pointer: behaves like a lift that can never
  /// resolve into a click or fling for this episode. Drag-lock is untouched
  /// (only [reset] or a tap-to-drop clears it).
  List<GestureIntent> onPointerCancel(int pointer) {
    if (_ignored.remove(pointer)) return const [];
    final p = _pointers.remove(pointer);
    if (p == null) return const [];
    _cancelled = true;
    final intents = <GestureIntent>[];
    if (_armed) {
      _armed = false;
      intents.add(const DisarmLongPressIntent());
    }
    if (_pointers.isEmpty) {
      _phase = _Phase.idle;
      _samples.clear();
    }
    return intents;
  }

  /// The driver's long-press timer elapsed. Only acts when the arm is still
  /// live (a single finger, held under slop): starts the drag and engages
  /// drag-lock. Stale fires (after any disarm) are no-ops.
  List<GestureIntent> onLongPressFire() {
    if (!_armed) return const [];
    _armed = false;
    if (_phase != _Phase.tapPending1 || _pointers.length != 1) {
      return const [];
    }
    if (_dragLocked) return const []; // already locked — nothing new to press
    _phase = _Phase.dragging;
    _dragLocked = true;
    return const [DragStartIntent()];
  }

  /// Clears ALL state including drag-lock (the driver calls this on
  /// disconnect, D-12-adjacent — pairs with the server's release-all).
  void reset() {
    _pointers.clear();
    _ignored.clear();
    _samples.clear();
    _phase = _Phase.idle;
    _armed = false;
    _dragLocked = false;
    _cancelled = false;
    _combinedTravel = 0;
  }

  /// Records a velocity sample and returns the scroll intent scaled to the
  /// per-event average across the LIVE tracked pointers: n == 2 while both
  /// fingers are down (only one pointer moves per event, the other
  /// contributes zero), n == 1 after one finger lifts so the remaining
  /// finger scrolls at full rate (WR-04). n >= 1 is structurally guaranteed:
  /// `_emitScroll` is only reached from [onPointerMove] after the
  /// `_pointers[pointer]` null-check.
  ScrollIntent _emitScroll(double dx, double dy) {
    final n = _pointers.length;
    final sdx = dx / n;
    final sdy = dy / n;
    final now = _nowMillis();
    _samples.add(_Sample(now, sdx, sdy));
    while (_samples.isNotEmpty &&
        now - _samples.first.ts > kVelocityWindowMs) {
      _samples.removeAt(0);
    }
    return ScrollIntent(sdx, sdy);
  }

  /// Fling seed from samples inside [kVelocityWindowMs] of [now]:
  /// velocity = sum(deltas) / (now − oldest-sample-ts). A pause before the
  /// lift naturally decays the seed below [kFlingMinVelocityPxMs].
  FlingIntent? _flingFrom(int now) {
    double sx = 0;
    double sy = 0;
    int? firstTs;
    for (final s in _samples) {
      if (now - s.ts > kVelocityWindowMs) continue;
      firstTs ??= s.ts;
      sx += s.dx;
      sy += s.dy;
    }
    if (firstTs == null) return null;
    final span = now - firstTs;
    if (span <= 0) return null;
    final vx = sx / span;
    final vy = sy / span;
    if (math.sqrt(vx * vx + vy * vy) < kFlingMinVelocityPxMs) return null;
    return FlingIntent(vx, vy);
  }
}
