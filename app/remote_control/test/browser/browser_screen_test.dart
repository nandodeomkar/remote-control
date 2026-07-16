// Task 1 (05-02) — RED: the browser macro vocabulary + grid (BROW-01).
//
// House widget-test style (mouse_buttons_test.dart): pump the callback-taking
// grid widget with a recording onAction — no service fake needed. The action
// strings must byte-match the server router's browser_macro table
// (server-core/src/dispatch/router.rs): back, forward, newtab, closetab,
// refresh, zoomin, zoomout — unknown actions are silently dropped server-side,
// so any drift here is an invisible no-op in production.

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_control/browser/browser_screen.dart';
import 'package:remote_control/theme/tokens.dart';

/// The exact router vocabulary (router.rs `browser_macro`).
const Set<String> kRouterBrowserVocabulary = {
  'back',
  'forward',
  'newtab',
  'closetab',
  'refresh',
  'zoomin',
  'zoomout',
};

Widget host({
  required void Function(String action) onAction,
  required bool enabled,
}) {
  return MaterialApp(
    home: Scaffold(
      body: BrowserMacroGrid(onAction: onAction, enabled: enabled),
    ),
  );
}

void main() {
  test('kBrowserActions is exactly the 7-action router vocabulary', () {
    expect(kBrowserActions, hasLength(7));
    expect(
      kBrowserActions.map((s) => s.action).toSet(),
      kRouterBrowserVocabulary,
      reason: 'action strings must byte-match router.rs browser_macro — '
          'anything else is silently dropped by the server',
    );
    // No duplicates: 7 specs, 7 distinct actions.
    expect(kBrowserActions.map((s) => s.action).toSet(), hasLength(7));
    for (final spec in kBrowserActions) {
      expect(spec.label, isNotEmpty);
      expect(spec.icon, isNotNull);
    }
  });

  testWidgets('tapping each of the 7 buttons records its action string',
      (t) async {
    final actions = <String>[];
    await t.pumpWidget(host(onAction: actions.add, enabled: true));

    // UI-SPEC labels, tapped in grid reading order.
    const labelToAction = <String, String>{
      'Back': 'back',
      'Forward': 'forward',
      'New tab': 'newtab',
      'Close tab': 'closetab',
      'Refresh': 'refresh',
      'Zoom out': 'zoomout',
      'Zoom in': 'zoomin',
    };
    for (final label in labelToAction.keys) {
      await t.tap(find.text(label));
      await t.pump();
    }

    expect(actions, labelToAction.values.toList());
  });

  testWidgets('Refresh renders full-width on its own row (unpaired)',
      (t) async {
    await t.pumpWidget(host(onAction: (_) {}, enabled: true));

    Size keyBox(String label) {
      final box = find
          .ancestor(of: find.text(label), matching: find.byType(Container))
          .first;
      return t.getSize(box);
    }

    // A paired key (Back) sits in a 2-column Row with an Expanded sibling, so
    // it is roughly half the grid width; Refresh spans its own stretched row.
    final refreshWidth = keyBox('Refresh').width;
    final backWidth = keyBox('Back').width;
    expect(
      refreshWidth,
      greaterThan(backWidth * 1.5),
      reason: 'Refresh must be full-width (its own row), not paired',
    );
  });

  testWidgets('a pressed key flashes accent border + label', (t) async {
    await t.pumpWidget(host(onAction: (_) {}, enabled: true));

    Color labelColor(String label) =>
        t.widget<Text>(find.text(label)).style!.color!;
    Color borderColor(String label) {
      final container = t.widget<Container>(
        find
            .ancestor(of: find.text(label), matching: find.byType(Container))
            .first,
      );
      final decoration = container.decoration! as BoxDecoration;
      return decoration.border!.top.color;
    }

    // At rest: text is kText, border is kHairline.
    expect(labelColor('Refresh'), kText);
    expect(borderColor('Refresh'), kHairline);

    // Press-down (hold): the key flashes accent border + accent label.
    final gesture = await t.startGesture(t.getCenter(find.text('Refresh')));
    await t.pump();

    expect(labelColor('Refresh'), kAccent);
    expect(borderColor('Refresh'), kAccent);

    await gesture.up();
    await t.pump();
    // Released: back to the rest palette.
    expect(labelColor('Refresh'), kText);
    expect(borderColor('Refresh'), kHairline);
  });

  testWidgets('disabled grid records nothing', (t) async {
    final actions = <String>[];
    await t.pumpWidget(host(onAction: actions.add, enabled: false));

    for (final label in [
      'Back',
      'Forward',
      'New tab',
      'Close tab',
      'Refresh',
      'Zoom out',
      'Zoom in',
    ]) {
      await t.tap(find.text(label), warnIfMissed: false);
      await t.pump();
    }

    expect(actions, isEmpty);
  });
}
