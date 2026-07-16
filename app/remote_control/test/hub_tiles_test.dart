// Task 1 (07-13; Shortcuts added 10-02) — the dashboard's identity: 9 tiles in
// the exact reading order rendered as a UNIFORM 2-column grid (07-UI-SPEC §1,
// Pitfall 9 — the legacy full-width Trackpad primary row is gone). The 9th
// tile is an odd tail: a half-width cell beside an empty slot.
//
// House widget-test style: pump the grid with a recording onOpen callback —
// navigation stays out of the widget test.

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/hub/hub_screen.dart';

/// The LOCKED reading order (top-left → reading order); Shortcuts at index 2.
const List<String> kExpectedOrder = [
  'Trackpad',
  'Keyboard',
  'Shortcuts',
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
  test('kHubTiles is EXACTLY the 9-tile order, Keyboard at 1, Shortcuts at 2',
      () {
    expect(
      kHubTiles.map((s) => s.label).toList(),
      kExpectedOrder,
      reason: 'reading order: Trackpad, Keyboard, Shortcuts, Media, Apps, '
          'Clipboard, Power, Presenter, Browser',
    );
    expect(kHubTiles[1].label, 'Keyboard');
    expect(kHubTiles[1].icon, Symbols.keyboard_rounded);
    expect(kHubTiles[2].label, 'Shortcuts');
    expect(kHubTiles[2].icon, Symbols.bolt_rounded);
  });

  testWidgets('grid renders all 9 tiles uniformly with a half-width tail',
      (t) async {
    t.view.physicalSize = const Size(800, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    await t.pumpWidget(_host(onOpen: (_) {}));

    for (final label in kExpectedOrder) {
      expect(find.text(label), findsOneWidget, reason: 'missing "$label"');
    }

    // UNIFORM: every tile rides the same AspectRatio cell — 9 of them, no
    // full-width special case (Pitfall 9: the SizedBox(height: 96) primary
    // row is gone). The 9th is the odd tail (half-width beside an empty slot).
    expect(find.byType(AspectRatio), findsNWidgets(9));

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

    // Reading order: 4 full pair-rows (indices 0..7) share a top edge, rows
    // descend, left column sits left of right; the 9th tile (index 8) is a
    // half-width tail in the left column of a final row below row 4.
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

    // The tail tile (index 8) reads in the LEFT column, below row 4, with no
    // right-column pair (the odd-tail half-width-beside-empty pattern).
    final tail = tops[8];
    expect(tail.dx, tops[6].dx,
        reason: 'the tail tile shares the left-column x with row 4 left');
    expect(tail.dy, greaterThan(tops[6].dy),
        reason: 'the tail tile renders below row 4');
    expect(find.text(kExpectedOrder[8]), findsOneWidget,
        reason: 'the tail tile ("${kExpectedOrder[8]}") must render');
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

    // D-08 offline: same 9 tiles, but each InkWell has a null onTap — visible
    // and layout-stable, yet non-tappable (no ripple, no navigation).
    final inkWells = t.widgetList<InkWell>(find.byType(InkWell)).toList();
    expect(inkWells, hasLength(9));
    for (final ink in inkWells) {
      expect(ink.onTap, isNull, reason: 'offline tiles must be non-tappable');
    }
  });
}
