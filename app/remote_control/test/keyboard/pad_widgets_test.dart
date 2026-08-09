/// Pad widget tests (10-04, KEY-02/KEY-04) — the four full-screen keyboard
/// pads and the bottom tab bar.
///
/// The contract under test:
/// (a) each pad renders EXACTLY the caps `capsForPad` declares for it, and
///     every one is a [KeyCap] — the shared emission model, never a clone;
/// (b) the emission model passes through unchanged: press+release with no
///     armed mods is a down/up pair (KEY-04 hold), with armed mods it is one
///     tap+mods (D-10 combo), and a gated pad is inert;
/// (c) the caps are finger-sized — they fill the pad by flex, "dramatically
///     larger than the old ~200px strip" (the user-locked acceptance bar);
/// (d) the tab bar shows the selected pad in accent with a 2px top underline
///     and is ALWAYS interactive (navigation, never gated).
///
/// Pads take injected callbacks, so none of this needs a service fake.
library;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/keyboard/key_pads.dart';
import 'package:remote_control/keyboard/key_rows.dart';
import 'package:remote_control/theme/tokens.dart';

void main() {
  late List<String> events;
  late bool armed;

  setUp(() {
    events = <String>[];
    armed = false;
  });

  /// Builds [pad]'s widget with the recording callbacks bound.
  Widget padFor(KeyboardPad pad, {bool enabled = true}) {
    void onKeyDown(String code) => events.add('down:$code');
    void onKeyUp(String code) => events.add('up:$code');
    void onKeyTapWithMods(String code) => events.add('tapMods:$code');
    bool hasArmedMods() => armed;
    void onPressHaptic() => events.add('haptic');

    return switch (pad) {
      KeyboardPad.type => TypePad(
          enabled: enabled,
          onKeyDown: onKeyDown,
          onKeyUp: onKeyUp,
          onKeyTapWithMods: onKeyTapWithMods,
          hasArmedMods: hasArmedMods,
          onPressHaptic: onPressHaptic,
        ),
      KeyboardPad.arrows => ArrowsPad(
          enabled: enabled,
          onKeyDown: onKeyDown,
          onKeyUp: onKeyUp,
          onKeyTapWithMods: onKeyTapWithMods,
          hasArmedMods: hasArmedMods,
          onPressHaptic: onPressHaptic,
        ),
      KeyboardPad.numpad => NumpadPad(
          enabled: enabled,
          onKeyDown: onKeyDown,
          onKeyUp: onKeyUp,
          onKeyTapWithMods: onKeyTapWithMods,
          hasArmedMods: hasArmedMods,
          onPressHaptic: onPressHaptic,
        ),
      KeyboardPad.fn => FnPad(
          enabled: enabled,
          onKeyDown: onKeyDown,
          onKeyUp: onKeyUp,
          onKeyTapWithMods: onKeyTapWithMods,
          hasArmedMods: hasArmedMods,
          onPressHaptic: onPressHaptic,
        ),
    };
  }

  Widget host(KeyboardPad pad, {bool enabled = true}) => MaterialApp(
        home: Scaffold(body: padFor(pad, enabled: enabled)),
      );

  /// The cap's identity-bearing GestureDetector (set by [KeyCap] itself).
  Finder capOf(String code) => find.byKey(ValueKey('cap-$code'));

  /// Presses and releases [code], pumping between.
  Future<void> pressRelease(WidgetTester tester, String code) async {
    final gesture = await tester.startGesture(tester.getCenter(capOf(code)));
    await tester.pump();
    await gesture.up();
    await tester.pump();
  }

  group('pad cap coverage', () {
    testWidgets('each pad renders exactly the caps capsForPad declares, and '
        'every one is a KeyCap', (tester) async {
      for (final pad in KeyboardPad.values) {
        await tester.pumpWidget(host(pad));

        final defs = capsForPad(pad);
        expect(
          find.byType(KeyCap),
          findsNWidgets(defs.length),
          reason: '${pad.name} must render its full cap set through the '
              'SHARED KeyCap — a cap that is not a KeyCap has forked the '
              'sacred emission model',
        );
        for (final def in defs) {
          expect(
            capOf(def.code),
            findsOneWidget,
            reason: '${pad.name} cap ${def.code} must render',
          );
        }
      }
    });

    testWidgets('TypePad renders the hint and a 7-cap extras row',
        (tester) async {
      await tester.pumpWidget(host(KeyboardPad.type));

      expect(find.text(kKeyboardHint), findsOneWidget);
      expect(find.byType(KeyCap), findsNWidgets(7));

      // All 7 sit on one row: same vertical center, left-to-right in the
      // user-locked order Esc | Tab | ← | ↑ | ↓ | → | Del.
      final codes = [for (final d in kTypeExtrasCaps) d.code];
      final centers = [for (final c in codes) tester.getCenter(capOf(c))];
      for (final center in centers) {
        expect(center.dy, moreOrLessEquals(centers.first.dy));
      }
      for (var i = 1; i < centers.length; i++) {
        expect(centers[i].dx, greaterThan(centers[i - 1].dx));
      }
    });

    testWidgets('TypePad(showHint: false) renders the 7-cap extras row and NO '
        'hint — the docked-panel strip (260809-ipc)', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: TypePad(
            enabled: true,
            showHint: false,
            onKeyDown: (code) => events.add('down:$code'),
            onKeyUp: (code) => events.add('up:$code'),
            onKeyTapWithMods: (code) => events.add('tapMods:$code'),
            hasArmedMods: () => armed,
          ),
        ),
      ));

      expect(find.text(kKeyboardHint), findsNothing);
      expect(find.byType(KeyCap), findsNWidgets(7));
      for (final def in kTypeExtrasCaps) {
        expect(capOf(def.code), findsOneWidget);
      }
    });

    testWidgets('FnPad renders Esc plus all twelve F-keys', (tester) async {
      await tester.pumpWidget(host(KeyboardPad.fn));

      expect(capOf('Esc'), findsOneWidget);
      for (var i = 1; i <= 12; i++) {
        expect(find.text('F$i'), findsOneWidget);
      }
      // Esc sits above the grid.
      expect(
        tester.getCenter(capOf('Esc')).dy,
        lessThan(tester.getCenter(capOf('F1')).dy),
      );
    });

    testWidgets('NumpadPad renders the calculator grid; Enter spans the full '
        'right-block height', (tester) async {
      await tester.pumpWidget(host(KeyboardPad.numpad));

      for (final label in ['7', '0', 'Enter', '.']) {
        expect(find.text(label), findsOneWidget);
      }

      final enter = tester.getRect(capOf('NumEnter'));
      final seven = tester.getRect(capOf('Num7'));
      final zero = tester.getRect(capOf('Num0'));

      // The big Enter (user-locked): as tall as the whole 4-row left block.
      expect(enter.top, moreOrLessEquals(seven.top));
      expect(enter.bottom, moreOrLessEquals(zero.bottom));
      expect(enter.height, greaterThan(seven.height * 3));
      // ...and it lives to the right of the digits.
      expect(enter.left, greaterThan(seven.right));

      // `0` spans two columns: wider than a single digit cap, and `.` takes
      // the third.
      expect(zero.width, greaterThan(seven.width * 1.5));
      expect(tester.getRect(capOf('NumDot')).left, greaterThan(zero.right));
    });

    testWidgets('ArrowsPad renders the nav row above the inverted-T',
        (tester) async {
      await tester.pumpWidget(host(KeyboardPad.arrows));

      for (final label in ['Home', 'End', 'PgUp', 'PgDn']) {
        expect(find.text(label), findsOneWidget);
      }

      final home = tester.getRect(capOf('Home'));
      final up = tester.getRect(capOf('Up'));
      final left = tester.getRect(capOf('Left'));
      final down = tester.getRect(capOf('Down'));
      final right = tester.getRect(capOf('Right'));

      // Nav row on top, then the cluster.
      expect(home.bottom, lessThan(up.top));
      // Inverted-T: Up above Down, column-aligned; Left/Down/Right in a row.
      expect(up.bottom, lessThanOrEqualTo(down.top));
      expect(up.center.dx, moreOrLessEquals(down.center.dx));
      expect(left.center.dy, moreOrLessEquals(down.center.dy));
      expect(left.right, lessThan(down.left));
      expect(down.right, lessThan(right.left));
      // Finger-shaped: ≥64px square-ish, width capped so they never stretch
      // into bars (UI-SPEC §Pad layouts — Arrows pad).
      for (final r in [up, left, down, right]) {
        expect(r.height, greaterThanOrEqualTo(64));
        expect(r.width, lessThanOrEqualTo(96));
      }
    });

    testWidgets('the large pads fill the height — caps are dramatically '
        'larger than the old ~200px strip', (tester) async {
      // The acceptance bar is user-locked: caps size by flex, so on a real
      // phone-height pad they dwarf the docked panel's 48px rows.
      for (final pad in [KeyboardPad.arrows, KeyboardPad.numpad, KeyboardPad.fn]) {
        await tester.pumpWidget(host(pad));
        final caps = tester.widgetList<KeyCap>(find.byType(KeyCap));
        for (final cap in caps) {
          final size = tester.getSize(capOf(cap.def.code));
          expect(
            size.height,
            greaterThanOrEqualTo(56),
            reason: '${pad.name} cap ${cap.def.code} must be finger-sized',
          );
        }
      }
    });
  });

  group('emission passthrough (the sacred model, shared not cloned)', () {
    testWidgets('press+release with no armed mods: down then up in order '
        '(KEY-04 hold path)', (tester) async {
      const cases = {
        KeyboardPad.type: 'Esc',
        KeyboardPad.arrows: 'Home',
        KeyboardPad.numpad: 'Num7',
        KeyboardPad.fn: 'F5',
      };

      for (final entry in cases.entries) {
        events.clear();
        await tester.pumpWidget(host(entry.key));
        await pressRelease(tester, entry.value);

        expect(
          events,
          ['haptic', 'down:${entry.value}', 'up:${entry.value}'],
          reason: '${entry.key.name} must pass the down/up pair through '
              'unchanged — Windows autorepeats between them',
        );
      }
    });

    testWidgets('with armed mods at press-down: release fires exactly one '
        'tap+mods and zero down/up (D-10 combo path)', (tester) async {
      armed = true;
      await tester.pumpWidget(host(KeyboardPad.numpad));
      await pressRelease(tester, 'Num7');

      expect(events, ['haptic', 'tapMods:Num7']);
    });

    testWidgets('gated pads are inert (press entry null)', (tester) async {
      for (final pad in KeyboardPad.values) {
        events.clear();
        await tester.pumpWidget(host(pad, enabled: false));
        await pressRelease(tester, capsForPad(pad).first.code);

        expect(events, isEmpty, reason: '${pad.name} must be inert when gated');
      }
    });

    testWidgets('IN-04: enabled flips false mid-press — the release still '
        'fires the up', (tester) async {
      await tester.pumpWidget(host(KeyboardPad.numpad));

      final gesture = await tester.startGesture(tester.getCenter(capOf('Num7')));
      await tester.pump(const Duration(milliseconds: 150));

      // A mid-press gate flip must not swallow the up — that is the
      // stuck-key door IN-04 closed at the KeyCap level.
      await tester.pumpWidget(host(KeyboardPad.numpad, enabled: false));
      await tester.pump();

      await gesture.up();
      await tester.pump();

      expect(events, ['haptic', 'down:Num7', 'up:Num7']);
    });

    testWidgets('CR-01: a pad disposed mid-hold releases its held key',
        (tester) async {
      await tester.pumpWidget(host(KeyboardPad.numpad));

      await tester.startGesture(tester.getCenter(capOf('Num7')));
      await tester.pump();
      expect(events, ['haptic', 'down:Num7']);

      // Leaving the pad (the PageView disposes the outgoing page's caps —
      // which is exactly why no keep-alive may ever be added here).
      await tester.pumpWidget(const MaterialApp(home: Scaffold()));
      await tester.pump();

      expect(events, ['haptic', 'down:Num7', 'up:Num7']);
    });
  });

  group('KeyboardTabBar', () {
    Widget tabHost(KeyboardPad current, {void Function(KeyboardPad)? onSelect}) =>
        MaterialApp(
          home: Scaffold(
            body: KeyboardTabBar(
              current: current,
              onSelect: onSelect ?? (_) {},
            ),
          ),
        );

    testWidgets('renders 4 tabs with their labels and icons', (tester) async {
      await tester.pumpWidget(tabHost(KeyboardPad.type));

      for (final pad in KeyboardPad.values) {
        expect(find.text(kKeyboardTabLabels[pad]!), findsOneWidget);
        expect(find.byIcon(kKeyboardTabIcons[pad]!), findsOneWidget);
      }
    });

    testWidgets('selected tab is accent with a 2px accent TOP underline; '
        'unselected are muted over the hairline', (tester) async {
      await tester.pumpWidget(tabHost(KeyboardPad.numpad));

      Text labelOf(KeyboardPad pad) =>
          tester.widget<Text>(find.text(kKeyboardTabLabels[pad]!));
      Icon iconOf(KeyboardPad pad) =>
          tester.widget<Icon>(find.byIcon(kKeyboardTabIcons[pad]!));
      BorderSide topOf(KeyboardPad pad) {
        final container = tester.widget<Container>(
          find
              .ancestor(
                of: find.text(kKeyboardTabLabels[pad]!),
                matching: find.byType(Container),
              )
              .first,
        );
        return (container.decoration! as BoxDecoration).border!.top;
      }

      // Selected.
      expect(labelOf(KeyboardPad.numpad).style!.color, kAccent);
      expect(iconOf(KeyboardPad.numpad).color, kAccent);
      expect(topOf(KeyboardPad.numpad).color, kAccent);
      expect(topOf(KeyboardPad.numpad).width, 2);

      // Unselected: muted faces; the 2px accent segment gives way to the
      // bar's 1px hairline top border.
      for (final pad in [KeyboardPad.type, KeyboardPad.arrows, KeyboardPad.fn]) {
        expect(labelOf(pad).style!.color, kMuted);
        expect(iconOf(pad).color, kMuted);
        expect(topOf(pad).color, kHairline);
        expect(topOf(pad).width, 1);
      }
    });

    testWidgets('tapping a tab fires onSelect with the matching pad',
        (tester) async {
      final selected = <KeyboardPad>[];
      await tester.pumpWidget(
        tabHost(KeyboardPad.type, onSelect: selected.add),
      );

      for (final pad in KeyboardPad.values) {
        await tester.tap(find.text(kKeyboardTabLabels[pad]!));
        await tester.pump();
      }

      expect(selected, KeyboardPad.values);
    });

    testWidgets('tabs are ALWAYS interactive — even the selected one, and '
        'there is no gated variant', (tester) async {
      final selected = <KeyboardPad>[];
      await tester.pumpWidget(
        tabHost(KeyboardPad.numpad, onSelect: selected.add),
      );

      // Re-tapping the current tab still fires: the bar is navigation, and
      // navigation never depends on the connection (caps and chips carry the
      // gating). The screen owner decides what a same-page select means.
      await tester.tap(find.text(kKeyboardTabLabels[KeyboardPad.numpad]!));
      await tester.pump();

      expect(selected, [KeyboardPad.numpad]);
      for (final tab in tester.widgetList<InkWell>(find.byType(InkWell))) {
        expect(tab.onTap, isNotNull);
      }
    });

    testWidgets('bar is >=56 tall; icons 24, labels 12/400', (tester) async {
      await tester.pumpWidget(tabHost(KeyboardPad.type));

      expect(
        tester.getSize(find.byType(KeyboardTabBar)).height,
        greaterThanOrEqualTo(56),
      );
      for (final pad in KeyboardPad.values) {
        expect(
          tester.widget<Icon>(find.byIcon(kKeyboardTabIcons[pad]!)).size,
          24,
        );
        final style =
            tester.widget<Text>(find.text(kKeyboardTabLabels[pad]!)).style!;
        expect(style.fontSize, 12);
        expect(style.fontWeight, FontWeight.w400);
      }
    });
  });
}
