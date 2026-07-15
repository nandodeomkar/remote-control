// Task 1 (08-03) — TrackpadBubble: the minimized draggable bubble that
// replaces the reserved-slot quick-bar affordance (D8-02). Widget-only and
// service-agnostic (callback-injected `onTap` + `authed` flag), so this test
// needs no live service or Navigator — mirroring the MouseButtonsBar house
// shape (test/trackpad/mouse_buttons_test.dart).
//
// Proves:
//   1. tap fires the injected onTap callback (haptic tick is a HapticFeedback
//      platform call — we assert the callback flag, not the platform channel);
//   2. muted gate — !authed renders kSurface fill + a muted (kMuted) icon and
//      is STILL tappable; authed renders kAccent fill + Icons.touch_app kText;
//   3. drag-snap — a release on the LEFT half commits Edge.left, on the RIGHT
//      half Edge.right, and the committed yFraction equals the release Y over
//      the surface height, clamped to [0,1] — observed on bubblePositionProvider
//      after the 200ms snap animation settles.
//
// The bubble commits through bubblePositionProvider.notifier.set(); an in-memory
// SharedPreferencesAsync platform double (mirrors bubble_position_test.dart)
// lets the store's real default adapter work with no plugin channel, so the
// commit is observable without real prefs. RED until Task 2 creates the widget.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'package:remote_control/settings/bubble_position.dart';
import 'package:remote_control/theme/tokens.dart';
import 'package:remote_control/widgets/trackpad_bubble.dart';

const Size _surface = Size(400, 800);

Widget _host({required VoidCallback onTap, required bool authed}) {
  return ProviderScope(
    child: MaterialApp(
      home: Scaffold(
        body: TrackpadBubble(onTap: onTap, authed: authed),
      ),
    ),
  );
}

ProviderContainer _containerOf(WidgetTester t) =>
    ProviderScope.containerOf(t.element(find.byType(TrackpadBubble)));

Finder get _circle => find.byType(TrackpadBubble);

BoxDecoration _bubbleDecoration(WidgetTester t) {
  final container = t.widget<Container>(
    find.descendant(of: _circle, matching: find.byType(Container)).first,
  );
  return container.decoration! as BoxDecoration;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
  });

  // Deterministic 400x800 logical surface for the drag-snap math.
  Future<void> sizedPump(WidgetTester t, Widget w) async {
    t.view.physicalSize = _surface;
    t.view.devicePixelRatio = 1.0;
    addTearDown(t.view.resetPhysicalSize);
    addTearDown(t.view.resetDevicePixelRatio);
    await t.pumpWidget(w);
    await t.pump();
  }

  group('tap', () {
    testWidgets('tapping the bubble fires the injected onTap (authed)',
        (t) async {
      var tapped = false;
      await sizedPump(t, _host(onTap: () => tapped = true, authed: true));

      await t.tap(find.byIcon(Icons.touch_app));
      await t.pump();

      expect(tapped, isTrue);
    });

    testWidgets('bubble is STILL tappable when not authed (muted, not dead)',
        (t) async {
      var tapped = false;
      await sizedPump(t, _host(onTap: () => tapped = true, authed: false));

      await t.tap(find.byIcon(Icons.touch_app));
      await t.pump();

      expect(tapped, isTrue);
    });
  });

  group('muted gate', () {
    testWidgets('authed renders kAccent fill + Icons.touch_app', (t) async {
      await sizedPump(t, _host(onTap: () {}, authed: true));

      expect(find.byIcon(Icons.touch_app), findsOneWidget);
      expect(_bubbleDecoration(t).color, kAccent);
      final icon = t.widget<Icon>(find.byIcon(Icons.touch_app));
      expect(icon.color, kText);
    });

    testWidgets('!authed renders kSurface fill + muted (kMuted) icon',
        (t) async {
      await sizedPump(t, _host(onTap: () {}, authed: false));

      expect(find.byIcon(Icons.touch_app), findsOneWidget);
      expect(_bubbleDecoration(t).color, kSurface);
      final icon = t.widget<Icon>(find.byIcon(Icons.touch_app));
      expect(icon.color, kMuted);
    });
  });

  group('drag-snap', () {
    testWidgets('release on the LEFT half commits Edge.left + clamped yFraction',
        (t) async {
      await sizedPump(t, _host(onTap: () {}, authed: true));

      // Drag from the bubble's rest center (right edge) to a left-half release
      // center at (60, 588) → top-left (32, 560) → yFraction 560/800 = 0.70.
      final start = t.getCenter(find.byIcon(Icons.touch_app));
      final g = await t.startGesture(start);
      await g.moveBy(const Offset(0, 20)); // cross touch-slop
      await g.moveTo(const Offset(60, 588));
      await g.up();
      await t.pumpAndSettle();

      final pos = _containerOf(t).read(bubblePositionProvider);
      expect(pos.edge, Edge.left);
      expect(pos.yFraction, closeTo(0.70, 0.05));
      expect(pos.yFraction, inInclusiveRange(0.0, 1.0));
    });

    testWidgets(
        'release on the RIGHT half commits Edge.right + clamped yFraction',
        (t) async {
      await sizedPump(t, _host(onTap: () {}, authed: true));

      // Release center at (340, 668) → top-left (312, 640) → yFraction 0.80,
      // center x 340 > 200 → right edge.
      final start = t.getCenter(find.byIcon(Icons.touch_app));
      final g = await t.startGesture(start);
      await g.moveBy(const Offset(0, 20)); // cross touch-slop
      await g.moveTo(const Offset(340, 668));
      await g.up();
      await t.pumpAndSettle();

      final pos = _containerOf(t).read(bubblePositionProvider);
      expect(pos.edge, Edge.right);
      expect(pos.yFraction, closeTo(0.80, 0.05));
      expect(pos.yFraction, inInclusiveRange(0.0, 1.0));
    });
  });
}
