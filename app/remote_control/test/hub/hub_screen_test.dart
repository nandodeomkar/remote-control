// Task 1 (05-02) — RED: the hub tile registry + grid (D-01/D-02).
//
// The hub is the Phase-7 dashboard skeleton: an ORDERED tile-spec list
// rendered by a grid widget with Trackpad as the full-width primary tile
// FIRST. Later plans (05-04/05-06/05-07) insert tiles into the registry
// without structural change. House widget-test style: pump the grid with a
// recording onOpen callback — navigation stays out of the widget test.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/hub/hub_screen.dart';

Widget host({required void Function(HubTileSpec spec) onOpen}) {
  return MaterialApp(
    home: Scaffold(
      body: HubTileGrid(tiles: kHubTiles, onOpen: onOpen),
    ),
  );
}

void main() {
  test('tile registry: Trackpad is FIRST (primary), Browser present', () {
    expect(kHubTiles, isNotEmpty);
    expect(
      kHubTiles.first.label,
      'Trackpad',
      reason: 'D-02: the trackpad is the full-width primary tile — '
          'always first in the registry',
    );
    expect(kHubTiles.map((s) => s.label), contains('Browser'));
    for (final tile in kHubTiles) {
      expect(tile.label, isNotEmpty);
      expect(tile.icon, isNotNull);
    }
  });

  testWidgets('grid renders every tile label and tap fires its entry',
      (t) async {
    // The bare grid (no scroll host) must fit its tiles: production HubScreen
    // wraps it in a SingleChildScrollView, so give the test surface enough
    // height for the registry as it grows (05-06 added Power; 10-02 added
    // Shortcuts → 9 tiles = 5 half-tile rows past the 800x600 default).
    t.view.physicalSize = const Size(800, 1800);
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);

    final opened = <String>[];
    await t.pumpWidget(host(onOpen: (spec) => opened.add(spec.label)));

    for (final tile in kHubTiles) {
      expect(find.text(tile.label), findsOneWidget);
    }

    await t.tap(find.text('Trackpad'));
    await t.pump();
    await t.tap(find.text('Browser'));
    await t.pump();

    expect(opened, ['Trackpad', 'Browser']);
  });
}
