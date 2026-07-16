/// Dot-grid trackpad texture (Phase 09 headline delta).
///
/// The approved prototype textures BOTH trackpad surfaces with a repeating
/// radial-gradient dot grid over the `#0E0F12` base:
///
/// - full Trackpad surface — `background-size:24px 24px` (Prototype.dc.html
///   line 99);
/// - floating-window surface — `background-size:22px 22px` (line 405);
///
/// with the dot itself `radial-gradient(circle at center,
/// rgba(255,255,255,0.045) 1.2px, transparent 1.2px)` — a 1.2px-radius dot at
/// white @ 4.5% opacity. The trackpad hint text takes `#4a505c` (lines 107 /
/// 130), a NON-token hue that mirrors `connection_header.dart`'s local-const
/// pattern.
///
/// [DotGridPainter] is a LEAF [CustomPainter]: it paints the base fill + the
/// dots and has no child and no `hitTest`, so mounted UNDER the raw `Listener`
/// it is purely decorative and never intercepts a pointer event (the drag/tap
/// still reach the cursor engine — proven in `dot_grid_test.dart`).
///
/// ZERO locked-token change: the dot literal `Color.fromRGBO(255,255,255,0.045)`
/// and the hint `Color(0xFF4A505C)` are neither of the seven `tokens.dart`
/// consts, so the D-12 theme-token guard is not tripped. The base fill consumes
/// the imported [kBg] symbol — never a raw `0xFF0E0F12` literal.
library;

import 'package:flutter/material.dart';

import '../theme/tokens.dart';

/// Dot-grid tile size on the full Trackpad surface (Prototype line 99).
const double kTrackpadDotTileFull = 24;

/// Dot-grid tile size in the floating-window surface (Prototype line 405).
const double kTrackpadDotTileWindow = 22;

/// Dot radius in logical px (Prototype `1.2px`).
const double kTrackpadDotRadius = 1.2;

/// Trackpad surface hint text color (Prototype lines 107 / 130, `#4a505c`).
/// A non-token hue — deliberately NOT one of the seven locked palette consts.
const Color kTrackpadHintColor = Color(0xFF4A505C);

/// The dot color: white @ 4.5% opacity (Prototype `rgba(255,255,255,0.045)`).
const Color _kDotColor = Color.fromRGBO(255, 255, 255, 0.045);

/// A decorative repeating dot-grid painter: fills [kBg], then draws one
/// [kTrackpadDotRadius] dot centered in every [tile]×[tile] cell. Leaf painter —
/// no child, no hit-testing — so it never intercepts pointer events.
class DotGridPainter extends CustomPainter {
  /// The square tile edge in logical px ([kTrackpadDotTileFull] /
  /// [kTrackpadDotTileWindow]).
  final double tile;

  /// Creates the painter over a required tile size.
  const DotGridPainter({required this.tile});

  @override
  void paint(Canvas canvas, Size size) {
    // Base fill first (the `#0E0F12` surface) via the imported token symbol.
    final basePaint = Paint()..color = kBg;
    canvas.drawRect(Offset.zero & size, basePaint);

    // One dot centered in each tile cell (offset tile/2 from the cell origin).
    final dotPaint = Paint()..color = _kDotColor;
    final half = tile / 2;
    for (var y = half; y < size.height; y += tile) {
      for (var x = half; x < size.width; x += tile) {
        canvas.drawCircle(Offset(x, y), kTrackpadDotRadius, dotPaint);
      }
    }
  }

  @override
  bool shouldRepaint(DotGridPainter oldDelegate) => oldDelegate.tile != tile;
}
