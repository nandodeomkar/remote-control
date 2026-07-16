// Phase 09 Plan 01 — dot-grid trackpad texture suite.
//
// Task 1 (unit): pins the DotGridPainter const contract (tile/radius/hint
// values lifted from the prototype lines 99 / 405 / 130) and the shouldRepaint
// equality on the single `tile` field.
//
// Task 3 (widget) extends this file with per-surface tile + non-interactivity
// proofs (mounted TrackpadCore).

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/trackpad/dot_grid.dart';

void main() {
  group('DotGridPainter — const contract (prototype-sourced values)', () {
    test('tile / radius / hint consts equal the prototype values', () {
      expect(kTrackpadDotTileFull, 24);
      expect(kTrackpadDotTileWindow, 22);
      expect(kTrackpadDotRadius, 1.2);
      expect(kTrackpadHintColor, const Color(0xFF4A505C));
    });

    test('shouldRepaint is true iff the tile changed', () {
      expect(
        DotGridPainter(tile: 24).shouldRepaint(DotGridPainter(tile: 22)),
        isTrue,
        reason: 'a different tile size must repaint',
      );
      expect(
        DotGridPainter(tile: 24).shouldRepaint(DotGridPainter(tile: 24)),
        isFalse,
        reason: 'an equal tile size must not repaint',
      );
    });
  });
}
