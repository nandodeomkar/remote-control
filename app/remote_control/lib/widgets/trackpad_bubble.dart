/// The D8-02 minimized floating bubble that replaces the reserved-slot
/// quick-bar affordance (UI-01 quick-bar → bubble replacement).
///
/// A 56dp circle carrying [Icons.touch_app]: `kAccent` fill + `kText` icon when
/// authed, `kSurface` fill + `kMuted` icon when not — STILL tappable in both
/// states ("muted, not red", mirroring `mouse_buttons.dart` L119-121). Tapping
/// fires a haptic tick + the injected [TrackpadBubble.onTap] (expand). Dragging
/// anywhere then releasing animates (200ms `Curves.easeOut`) to the nearest
/// left/right edge with an 8px inset and persists `(edge, yFraction)` to the
/// [bubblePositionProvider] from 08-01.
///
/// LEAF + callback-injection (service-agnostic, like [MouseButtonsBar]): the
/// parent scaffold supplies `authed` and the expand `onTap`, so the widget test
/// needs no live service or Navigator. Off the hot path, so the drag + edge-snap
/// use a `GestureDetector` + `AnimationController` (NOT `Draggable`/`DragTarget`
/// — wrong semantics).
library;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../settings/bubble_position.dart';
import '../settings/haptics.dart';
import '../theme/tokens.dart';

/// The bubble diameter in logical pixels (D8-02 "56dp circle").
const double kBubbleSize = 56;

/// The inset from the snapped screen edge in logical pixels (D8-02 "8px inset").
const double kBubbleEdgeInset = 8;

/// The minimized draggable bubble. See the library doc for the contract.
class TrackpadBubble extends ConsumerStatefulWidget {
  /// Fired (after a haptic tick) when the bubble is tapped — the caller expands
  /// to the floating trackpad window.
  final VoidCallback onTap;

  /// True renders the accent (connected) look; false the muted (not-connected)
  /// look. The bubble stays tappable either way ("muted, not red").
  final bool authed;

  /// Creates the bubble.
  const TrackpadBubble({
    super.key,
    required this.onTap,
    required this.authed,
  });

  @override
  ConsumerState<TrackpadBubble> createState() => _TrackpadBubbleState();
}

class _TrackpadBubbleState extends ConsumerState<TrackpadBubble>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  /// The live bubble top-left while dragging or snap-animating; `null` when at
  /// rest (position then comes from [bubblePositionProvider]).
  Offset? _dragOffset;

  /// The active snap tween (top-left begin→edge), or `null` when not animating.
  Animation<Offset>? _snapAnim;

  /// The position to commit once the snap animation completes.
  BubblePosition? _pendingCommit;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    )
      ..addListener(_onTick)
      ..addStatusListener(_onStatus);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTick)
      ..removeStatusListener(_onStatus)
      ..dispose();
    super.dispose();
  }

  void _onTick() {
    final anim = _snapAnim;
    if (anim != null) setState(() => _dragOffset = anim.value);
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed && _pendingCommit != null) {
      // Persist the snapped dock; survives screen switches + restarts via 08-01.
      ref.read(bubblePositionProvider.notifier).set(_pendingCommit!);
      setState(() {
        _pendingCommit = null;
        _snapAnim = null;
        _dragOffset = null; // fall back to the (now committed) rest position
      });
    }
  }

  /// The rest top-left for [pos] within [size]: docked to its edge (± 8px inset)
  /// at `yFraction` down the surface, kept fully on-screen.
  Offset _restTopLeft(Size size, EdgeInsets padding, BubblePosition pos) {
    final x = pos.edge == Edge.left
        ? kBubbleEdgeInset
        : size.width - kBubbleSize - kBubbleEdgeInset;
    final maxTop = size.height - kBubbleSize - padding.bottom;
    final y = (pos.yFraction * size.height).clamp(padding.top, maxTop);
    return Offset(x, y.toDouble());
  }

  Offset _currentTopLeft(Size size, EdgeInsets padding) =>
      _dragOffset ??
      _restTopLeft(size, padding, ref.read(bubblePositionProvider));

  void _handleTap() {
    hapticTick();
    widget.onTap();
  }

  void _onPanStart(DragStartDetails _) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    _controller.stop();
    setState(() {
      _snapAnim = null;
      _pendingCommit = null;
      _dragOffset = _restTopLeft(size, padding, ref.read(bubblePositionProvider));
    });
  }

  void _onPanUpdate(DragUpdateDetails d) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final next = _currentTopLeft(size, padding) + d.delta;
    // Clamp the live offset to on-screen bounds (respecting safe-area top/bottom)
    // so the bubble can never be dragged off-screen (T-08-05).
    final maxX = size.width - kBubbleSize;
    final maxY = size.height - kBubbleSize - padding.bottom;
    setState(() {
      _dragOffset = Offset(
        next.dx.clamp(0.0, maxX),
        next.dy.clamp(padding.top, maxY),
      );
    });
  }

  void _onPanEnd(DragEndDetails _) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final topLeft = _currentTopLeft(size, padding);
    final center = topLeft + const Offset(kBubbleSize / 2, kBubbleSize / 2);
    // Nearest edge from the release center; yFraction = release Y / surface
    // height, clamped to [0,1] (SC3/SC4, T-08-05).
    final edge = center.dx > size.width / 2 ? Edge.right : Edge.left;
    final yFraction = (topLeft.dy / size.height).clamp(0.0, 1.0);
    final commit = BubblePosition(edge: edge, yFraction: yFraction.toDouble());

    _pendingCommit = commit;
    _snapAnim = Tween<Offset>(
      begin: topLeft,
      end: _restTopLeft(size, padding, commit),
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOut));
    _controller.forward(from: 0);
  }

  @override
  Widget build(BuildContext context) {
    final pos = ref.watch(bubblePositionProvider);
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final topLeft = _dragOffset ?? _restTopLeft(size, padding, pos);

    final fill = widget.authed ? kAccent : kSurface;
    final iconColor = widget.authed ? kText : kMuted;

    return Stack(
      children: [
        Positioned(
          left: topLeft.dx,
          top: topLeft.dy,
          child: GestureDetector(
            onTap: _handleTap,
            onPanStart: _onPanStart,
            onPanUpdate: _onPanUpdate,
            onPanEnd: _onPanEnd,
            child: Container(
              width: kBubbleSize,
              height: kBubbleSize,
              decoration: BoxDecoration(
                color: fill,
                shape: BoxShape.circle,
                border: Border.all(color: kHairline),
                boxShadow: const [
                  BoxShadow(
                    color: Color(0x66000000),
                    blurRadius: 8,
                    offset: Offset(0, 2),
                  ),
                ],
              ),
              child: Icon(Icons.touch_app, size: 24, color: iconColor),
            ),
          ),
        ),
      ],
    );
  }
}
