// Task 1 (07-13) — the dashboard's final identity: 8 tiles in the exact
// D-09 order rendered as a UNIFORM 2×4 grid (07-UI-SPEC §1, Pitfall 9 —
// the legacy full-width Trackpad primary row is gone).
//
// House widget-test style: pump the grid with a recording onOpen callback —
// navigation stays out of the widget test.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/hub/hub_screen.dart';

/// The LOCKED D-09 reading order (top-left → reading order).
const List<String> kExpectedOrder = [
  'Trackpad',
  'Keyboard',
  'Media',
  'Apps',
  'Clipboard',
  'Power',
  'Presenter',
  'Browser',
];

Widget _host({
  required void Function(HubTileSpec spec) onOpen,
  bool enabled = true,
}) {
  return MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: HubTileGrid(tiles: kHubTiles, onOpen: onOpen, enabled: enabled),
      ),
    ),
  );
}

void main() {
  test('kHubTiles is EXACTLY the 8-tile D-09 order, Keyboard at index 1', () {
    expect(
      kHubTiles.map((s) => s.label).toList(),
      kExpectedOrder,
      reason: 'D-09 locks the reading order: Trackpad, Keyboard, Media, '
          'Apps, Clipboard, Power, Presenter, Browser',
    );
    expect(kHubTiles[1].label, 'Keyboard');
    expect(kHubTiles[1].icon, Symbols.keyboard_rounded);
  });

  testWidgets('grid renders all 8 tiles uniformly in 2×4 reading order',
      (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(_host(onOpen: (_) {}));

    for (final label in kExpectedOrder) {
      expect(find.text(label), findsOneWidget, reason: 'missing "$label"');
    }

    // UNIFORM: every tile rides the same AspectRatio cell — 8 of them, no
    // full-width special case (Pitfall 9: the SizedBox(height: 96) primary
    // row is gone).
    expect(find.byType(AspectRatio), findsNWidgets(8));

    // Every cell holds the UI-SPEC ~1.4:1 aspect ratio (§1 tile spec).
    for (final ar in t.widgetList<AspectRatio>(find.byType(AspectRatio))) {
      expect(ar.aspectRatio, 1.4, reason: 'tile cell must be 1.4:1 (UI-SPEC)');
    }

    Finder cellOf(String label) => find.ancestor(
          of: find.text(label),
          matching: find.byType(AspectRatio),
        );

    // All 8 cells are the SAME size (Trackpad is NOT a hero tile anymore).
    final firstSize = t.getSize(cellOf('Trackpad'));
    for (final label in kExpectedOrder) {
      expect(
        t.getSize(cellOf(label)),
        firstSize,
        reason: '"$label" must share the uniform cell size',
      );
    }

    // 2×4 reading order: row pairs share a top edge, rows descend, and the
    // left column sits left of the right column.
    final tops = [for (final l in kExpectedOrder) t.getTopLeft(cellOf(l))];
    for (var row = 0; row < 4; row++) {
      final left = tops[row * 2];
      final right = tops[row * 2 + 1];
      expect(left.dy, right.dy,
          reason: 'row ${row + 1} tiles must share a top edge');
      expect(left.dx, lessThan(right.dx),
          reason: 'row ${row + 1} must read left-to-right');
      if (row > 0) {
        expect(left.dy, greaterThan(tops[(row - 1) * 2].dy),
            reason: 'row ${row + 1} must render below row $row');
      }
    }
  });

  testWidgets('tapping a tile fires its entry through onOpen', (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final opened = <String>[];
    await t.pumpWidget(_host(onOpen: (spec) => opened.add(spec.label)));

    await t.tap(find.text('Keyboard'));
    await t.pump();
    await t.tap(find.text('Browser'));
    await t.pump();

    expect(opened, ['Keyboard', 'Browser']);
  });

  testWidgets('disabled grid renders every tile non-tappable (onTap null)',
      (t) async {
    t.view.physicalSize = const Size(800, 1400);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(_host(onOpen: (_) {}, enabled: false));

    // D-08 offline: same 8 tiles, but each InkWell has a null onTap — visible
    // and layout-stable, yet non-tappable (no ripple, no navigation).
    final inkWells = t.widgetList<InkWell>(find.byType(InkWell)).toList();
    expect(inkWells, hasLength(8));
    for (final ink in inkWells) {
      expect(ink.onTap, isNull, reason: 'offline tiles must be non-tappable');
    }
  });
}
