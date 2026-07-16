/// FloatingTrackpadWindow — the D8-03 expanded-state floating trackpad card.
///
/// A fixed ~78%w × ~38%h card ([kWindowWidthFraction]/[kWindowHeightFraction]
/// of the screen) with three stacked rows:
///
///   1. a header bar — a `⠿` drag handle (its OWN [GestureDetector], a SIBLING
///      of, never an ancestor of, the surface — RESEARCH Pitfall 2), an inline
///      drag-lock pill shown only while locked (driven by the [TrackpadCore]
///      drag-lock listenable), a `⤢` open-full button, and a `✕` collapse
///      button (the last two fire injected callbacks);
///   2. the shared [TrackpadCore] gesture surface — the SAME hot-path engine
///      the full Trackpad screen mounts, so cursor input in the window is
///      behavior-identical to the full screen by construction (SC2, D8-04);
///   3. a reused [MouseButtonsBar], gated muted when not authed.
///
/// The window is draggable by its HEADER ONLY: a pan on the `⠿` handle moves the
/// card and clamps it FULLY on-screen (the offset is bounded to
/// `[0, screen − card]` on both axes), and `onPanEnd` commits `(x, y)` fractions
/// to [windowPositionProvider] (08-01). Because the clamp keeps the whole card
/// visible and the committed fractions are in [0,1], a tampered/out-of-range
/// stored value can never place the window off-screen (T-08-06 / SC3). Touches
/// on the gesture surface are ALWAYS mouse input and never move the window — the
/// header detector and the core's [Listener] are spatially-disjoint siblings.
///
/// LEAF + callback-injection: the parent scaffold (08-05) supplies [authed],
/// [onExpandFull], [onCollapse], and [onMouseButton], so the widget test needs
/// no Navigator. On first-ever open the window store is the unset sentinel
/// (08-01) → the card anchors from [initialTopLeft] (the bubble spot) if given,
/// else centered; after any move it stores real fractions.
///
/// This card owns NO keyboard/tune affordances (Deferred) and acquires NO
/// keep-awake hold — [TrackpadCore] is the SOLE owner of that hold (Pitfall 4).
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/window_position.dart';
import '../theme/tokens.dart';
import '../widgets/keep_awake.dart';
import 'dot_grid.dart';
import 'mouse_buttons.dart';
import 'trackpad_core.dart';

/// The card width as a fraction of the screen (D8-03 "~78% width").
const double kWindowWidthFraction = 0.78;

/// The card height as a fraction of the screen (D8-03 "~38% height").
const double kWindowHeightFraction = 0.38;

/// The fixed header-bar height in logical pixels (holds the ~48px icon buttons).
const double _kHeaderHeight = 48;

/// Key on the inline header drag-lock pill (visible only while locked).
const Key kWindowDragLockPillKey = Key('window-drag-lock-pill');

/// Key on the card container (the widget the header-drag Positioned wraps).
const Key kWindowCardKey = Key('floating-trackpad-card');

/// The expanded-state floating trackpad card. See the library doc for the
/// contract. Renders as a single [Positioned] inside the scaffold's [Stack].
class FloatingTrackpadWindow extends ConsumerStatefulWidget {
  /// Whether the session is authed — forwarded to [TrackpadCore] (surface hint)
  /// and to [MouseButtonsBar] (muted-not-red gate).
  final bool authed;

  /// Fired when the `⤢` header button is tapped — the caller pushes the full
  /// Trackpad screen.
  final VoidCallback onExpandFull;

  /// Fired when the `✕` header button is tapped — the caller collapses back to
  /// the bubble.
  final VoidCallback onCollapse;

  /// Fired by the reused [MouseButtonsBar] with 'left' | 'middle' | 'right'.
  final void Function(String button) onMouseButton;

  /// The first-open anchor (top-left, logical px) when the window store is the
  /// unset sentinel — typically the bubble spot. Null → the card centers.
  final Offset? initialTopLeft;

  /// Test seam: inject the drag-lock notifier so a test can drive the inline
  /// pill without a live gesture. When null the window owns (and disposes) its
  /// own notifier and passes it to [TrackpadCore].
  @visibleForTesting
  final ValueNotifier<bool>? dragLock;

  /// Test seam: forwarded to [TrackpadCore] so tests inject a spy instead of
  /// the wakelock platform singleton.
  @visibleForTesting
  final KeepAwake? keepAwake;

  /// Creates the floating trackpad window.
  const FloatingTrackpadWindow({
    super.key,
    required this.authed,
    required this.onExpandFull,
    required this.onCollapse,
    required this.onMouseButton,
    this.initialTopLeft,
    this.dragLock,
    this.keepAwake,
  });

  @override
  ConsumerState<FloatingTrackpadWindow> createState() =>
      _FloatingTrackpadWindowState();
}

class _FloatingTrackpadWindowState
    extends ConsumerState<FloatingTrackpadWindow> {
  /// The shared drag-lock handle: [TrackpadCore] drives it via
  /// `onDragLockChanged`; the header pill reads it. Owned here unless injected.
  late final ValueNotifier<bool> _dragLock;
  bool _ownsDragLock = false;

  /// The live top-left while (or after) a header drag; null at rest, when the
  /// position comes from [windowPositionProvider] / [initialTopLeft] instead.
  Offset? _offset;

  /// The drag range `screen − card` on each axis, recomputed every build (never
  /// negative). The pan handlers clamp against it so the card stays on-screen.
  double _rangeX = 0;
  double _rangeY = 0;

  @override
  void initState() {
    super.initState();
    if (widget.dragLock != null) {
      _dragLock = widget.dragLock!;
    } else {
      _dragLock = ValueNotifier<bool>(false);
      _ownsDragLock = true;
    }
  }

  @override
  void dispose() {
    if (_ownsDragLock) _dragLock.dispose();
    super.dispose();
  }

  /// The at-rest top-left for [pos]: the stored fractions when set, else the
  /// first-open anchor ([initialTopLeft] clamped) or the screen center.
  Offset _resolve(WindowPosition pos) {
    if (pos.isSet) {
      return Offset(pos.xFraction * _rangeX, pos.yFraction * _rangeY);
    }
    if (widget.initialTopLeft != null) return _clamp(widget.initialTopLeft!);
    return Offset(_rangeX / 2, _rangeY / 2);
  }

  Offset _clamp(Offset o) =>
      Offset(o.dx.clamp(0.0, _rangeX), o.dy.clamp(0.0, _rangeY));

  void _onPanStart(DragStartDetails _) {
    setState(() => _offset ??= _resolve(ref.read(windowPositionProvider)));
  }

  void _onPanUpdate(DragUpdateDetails d) {
    setState(() => _offset = _clamp((_offset ?? Offset.zero) + d.delta));
  }

  void _onPanEnd(DragEndDetails _) {
    final o = _offset ?? Offset.zero;
    final fx = _rangeX <= 0 ? 0.0 : (o.dx / _rangeX).clamp(0.0, 1.0);
    final fy = _rangeY <= 0 ? 0.0 : (o.dy / _rangeY).clamp(0.0, 1.0);
    ref.read(windowPositionProvider.notifier).set(WindowPosition.at(fx, fy));
  }

  @override
  Widget build(BuildContext context) {
    final screen = MediaQuery.sizeOf(context);
    final cardW = screen.width * kWindowWidthFraction;
    final cardH = screen.height * kWindowHeightFraction;
    _rangeX = math.max(0.0, screen.width - cardW);
    _rangeY = math.max(0.0, screen.height - cardH);

    final pos = ref.watch(windowPositionProvider);
    final offset = _offset ?? _resolve(pos);

    return Positioned(
      left: offset.dx,
      top: offset.dy,
      width: cardW,
      height: cardH,
      child: _card(cardW, cardH),
    );
  }

  Widget _card(double w, double h) {
    return Container(
      key: kWindowCardKey,
      decoration: BoxDecoration(
        color: kSurface,
        border: Border.all(color: kHairline),
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(
            color: Color(0x66000000),
            blurRadius: 16,
            offset: Offset(0, 8),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _header(),
            // The SAME hot-path engine the full screen mounts → cursor parity
            // by construction (SC2). HitTestBehavior.opaque (from 08-02) keeps
            // surface touches from bubbling to the header.
            Expanded(
              child: TrackpadCore(
                authed: widget.authed,
                dragLock: _dragLock,
                keepAwake: widget.keepAwake,
                // 22px window-surface dot grid (Prototype line 405).
                dotTile: kTrackpadDotTileWindow,
              ),
            ),
            // L/M/R buttons (PAD-02), muted when not authed ("muted, not red").
            // 56px window bar (Prototype line 412) vs the 64px full-screen bar.
            MouseButtonsBar(
              onPress: widget.onMouseButton,
              enabled: widget.authed,
              height: 56,
            ),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return SizedBox(
      height: _kHeaderHeight,
      child: Row(
        children: [
          // The ⠿ drag handle — its OWN GestureDetector (a SIBLING of the core
          // Listener below, never an ancestor). A pan here moves + clamps the
          // window; a touch on the surface never reaches this detector.
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Icon(Icons.drag_indicator, size: 20, color: kMuted),
            ),
          ),
          // The inline drag-lock pill — visible ONLY while the core reports a
          // drag-lock (localized rebuild; the surface never rebuilds off it).
          Expanded(
            child: Center(
              child: ValueListenableBuilder<bool>(
                valueListenable: _dragLock,
                builder: (context, locked, _) => locked
                    ? const FittedBox(
                        fit: BoxFit.scaleDown,
                        child: _WindowDragLockPill(key: kWindowDragLockPillKey),
                      )
                    : const SizedBox.shrink(),
              ),
            ),
          ),
          IconButton(
            icon: const Icon(Icons.open_in_full, size: 18, color: kText),
            tooltip: 'Open full screen',
            onPressed: widget.onExpandFull,
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 18, color: kText),
            tooltip: 'Collapse',
            onPressed: widget.onCollapse,
          ),
        ],
      ),
    );
  }
}

/// The inline header drag-lock indicator (compact variant of the full screen's
/// pill): `kSurface` fill, `kAccent` 1px border, accent lock glyph + label.
class _WindowDragLockPill extends StatelessWidget {
  const _WindowDragLockPill({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: kSurface,
        border: Border.all(color: kAccent),
        borderRadius: BorderRadius.circular(999),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock, size: 12, color: kAccent),
          SizedBox(width: 4),
          Text(
            'Drag locked',
            style: TextStyle(
              color: kText,
              fontSize: 12,
              fontWeight: FontWeight.w400,
            ),
          ),
        ],
      ),
    );
  }
}
