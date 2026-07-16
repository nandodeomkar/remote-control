/// BubbleScaffold (08-05, D8-05) — the per-screen overlay scaffold that
/// replaces the deleted quick-bar scaffold (07-13, D-10; removed 08-06,
/// D8-06).
///
/// Composes the tool `body` + the verbatim UIPI-banner slot + an expand-gated
/// bubble/window subtree in one `Stack` — Approach A per the design spec
/// (Stack children, NOT `OverlayEntry`, which would fight `PopScope` + the
/// per-screen-ephemeral lifecycle). The `body` is a `Positioned.fill` that
/// NEVER rebuilds off expand (Pitfall 3/6): it is supplied as the cached
/// `child` of the outer `ValueListenableBuilder` that only exists so the
/// `PopScope`'s `canPop` stays reactive to the expand state — the body Widget
/// instance itself is built exactly once per `BubbleScaffold` build.
///
/// A single `ValueNotifier<bool> _expanded` gates an INNER
/// `ValueListenableBuilder<bool>` that renders EITHER [TrackpadBubble]
/// (collapsed) OR [FloatingTrackpadWindow] (expanded) — never both (D8-01).
/// Expand/collapse rides a 200ms `AnimationController` (scale for the window,
/// fade for the bubble).
///
/// Back handling (D8-08): `PopScope(canPop: !expanded, onPopInvokedWithResult:)`
/// collapses the window on the first back and only lets a second back pop the
/// route. The `⤢` header button (D8-08) collapses then pushes the full
/// [TrackpadScreen] wrapped `showBubble: false` — the Trackpad-screen wrap
/// that suppresses the bubble/window while the UIPI banner still rides
/// (D8-05).
///
/// A1 CONFIRMED: `onPopInvokedWithResult` (not the deprecated `onPopInvoked`)
/// is the non-deprecated API on the pinned Flutter 3.44.5.
///
/// This scaffold does NOT acquire the keep-awake hold — [TrackpadCore] (08-02)
/// is the SOLE owner of that hold (Pitfall 4).
library;

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:remote_protocol/remote_protocol.dart';

import '../net/connection_providers.dart';
import '../net/connection_service.dart';
import '../settings/bubble_position.dart';
import '../theme/tokens.dart';
import '../trackpad/floating_trackpad_window.dart';
import '../trackpad/trackpad_screen.dart';
import 'trackpad_bubble.dart';
import 'uipi_banner.dart';

/// The expand/collapse animation duration (D8-01: "scale 200ms").
const Duration kBubbleExpandDuration = Duration(milliseconds: 200);

/// Wraps a tool screen with the expand-gated bubble/floating-window (D8-01,
/// D8-02, D8-03) and the contextual UIPI banner (D8-05, cloned verbatim from
/// the deleted quick-bar scaffold). See the library doc for the full contract.
class BubbleScaffold extends ConsumerStatefulWidget {
  /// The tool screen this scaffold hosts.
  final Widget body;

  /// False (the Trackpad screen, pushed via the `⤢` idiom) renders only
  /// [body] + the banner — no bubble/window on the screen you are already on.
  final bool showBubble;

  /// Creates the scaffold.
  const BubbleScaffold({
    super.key,
    required this.body,
    this.showBubble = true,
  });

  @override
  ConsumerState<BubbleScaffold> createState() => _BubbleScaffoldState();
}

class _BubbleScaffoldState extends ConsumerState<BubbleScaffold>
    with SingleTickerProviderStateMixin {
  /// Gates the bubble/window subtree: false = collapsed (bubble), true =
  /// expanded (window). The single source of truth for D8-01's "never both
  /// visible" invariant and the `PopScope.canPop` back-intercept (D8-08).
  final ValueNotifier<bool> _expanded = ValueNotifier<bool>(false);

  /// Drives the 200ms scale (window) / fade (bubble) expand<->collapse
  /// transition. 0 = collapsed, 1 = expanded.
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: kBubbleExpandDuration,
    );
  }

  @override
  void dispose() {
    _expanded.dispose();
    _controller.dispose();
    super.dispose();
  }

  void _expand() {
    _expanded.value = true;
    unawaited(_controller.forward());
  }

  void _collapse() {
    _expanded.value = false;
    unawaited(_controller.reverse());
  }

  /// D8-08: collapse, then push the full [TrackpadScreen] wrapped
  /// `showBubble: false` (the existing `_openTrackpad` push idiom, renamed
  /// from the deleted quick-bar scaffold's equivalent param).
  void _openFullTrackpad(BuildContext context) {
    _collapse();
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => const BubbleScaffold(
            showBubble: false,
            body: TrackpadScreen(),
          ),
        ),
      ),
    );
  }

  /// The first-open window anchor derived from the bubble's rest spot (mirrors
  /// `TrackpadBubble._restTopLeft`) — only consulted by
  /// [FloatingTrackpadWindow] when its own store is the unset sentinel.
  Offset _bubbleAnchor(BuildContext context, BubblePosition pos) {
    final size = MediaQuery.sizeOf(context);
    final padding = MediaQuery.paddingOf(context);
    final x = pos.edge == Edge.left
        ? kBubbleEdgeInset
        : size.width - kBubbleSize - kBubbleEdgeInset;
    final maxTop = size.height - kBubbleSize - padding.bottom;
    final y = (pos.yFraction * size.height).clamp(padding.top, maxTop);
    return Offset(x, y.toDouble());
  }

  @override
  Widget build(BuildContext context) {
    // App-lifetime singleton — watching a plain Provider never rebuilds.
    final service = ref.watch(connectionServiceProvider);
    // Transition-only snapshot (value-equal): rebuilds on lifecycle changes,
    // never on the trackpad move path (Phase-2 invariant).
    final status = ref.watch(connectionStatusProvider);
    final authed = status.chip == ChipStatus.connected;
    final bubblePos = ref.watch(bubblePositionProvider);

    // The outer ValueListenableBuilder exists ONLY so PopScope.canPop stays
    // reactive to _expanded; its `child` (body + banner + the inner
    // bubble/window builder) is built exactly ONCE per BubbleScaffold build
    // and never rebuilt by this notifier (Pitfall 3/6 — the body never
    // rebuilds off expand).
    return ValueListenableBuilder<bool>(
      valueListenable: _expanded,
      builder: (context, expanded, child) => PopScope(
        canPop: !expanded,
        onPopInvokedWithResult: (didPop, result) {
          if (!didPop) _collapse();
        },
        child: child!,
      ),
      child: Material(
        color: kBg,
        child: Stack(
          children: [
            // NEVER rebuilds off _expanded (Pitfall 3/6).
            Positioned.fill(child: widget.body),
            // The verbatim-preserved UIPI contract (from the deleted
            // quick-bar scaffold): top-anchored, IgnorePointer inside
            // UipiBanner, never steals a body touch.
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: SafeArea(
                bottom: false,
                child: UipiBanner.forService(service),
              ),
            ),
            // The ONLY subtree that rebuilds on expand — renders EITHER the
            // bubble OR the window, never both (D8-01).
            if (widget.showBubble)
              ValueListenableBuilder<bool>(
                valueListenable: _expanded,
                builder: (context, isExpanded, _) {
                  if (isExpanded) {
                    // FloatingTrackpadWindow returns a single Positioned
                    // (08-04) that must be a DIRECT descendant of this Stack
                    // with no intervening RenderObjectWidget (Transform /
                    // Opacity would break the Positioned<->Stack contract) —
                    // so it is rendered unwrapped; the 200ms controller still
                    // drives the bubble's fade below.
                    return FloatingTrackpadWindow(
                      authed: authed,
                      onCollapse: _collapse,
                      onExpandFull: () => _openFullTrackpad(context),
                      onMouseButton: (button) =>
                          service.sendReliable(ClickMsg(button: button)),
                      initialTopLeft: _bubbleAnchor(context, bubblePos),
                    );
                  }
                  return FadeTransition(
                    opacity: Tween<double>(begin: 1, end: 0).animate(
                      CurvedAnimation(parent: _controller, curve: Curves.easeIn),
                    ),
                    child: TrackpadBubble(onTap: _expand, authed: authed),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
