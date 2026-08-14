// Task 3 (13-02, Wave 2) — the first end-to-end raise, driven through the REAL
// shell at `MaterialApp.builder`. Pins the BAR-01 / BAR-02 / SUM-01 / SUM-02 /
// SUM-03 must_haves:
//
//  1. BAR-01 presence — the 56dp bar renders on the root route and on a pushed
//     tool route, and its Rect is identical on both. Geometry, not "a widget of
//     that type exists somewhere".
//  2. BAR-02 / invariant I2 — the bar's bottom edge sits exactly
//     `max(Pbot, Ibot)` above the window bottom, so the glyphs never land in
//     the Android gesture zone. Computed from the driven metrics.
//  3. SUM-01 / SUM-03 — tapping a bar icon raises an empty surface in place;
//     tapping the same icon lowers it. A toggle, not a stack.
//  4. BAR-02 / invariant I1 — `surfaceRect.bottom == barRect.top` at rest,
//     within the house 0.01 tolerance, so the surface RESTS ON the bar and the
//     bar is never occluded. Invariants I3 and I4 ride along.
//  5. SUM-01 — raising navigates NOWHERE: a NavigatorObserver sees zero pushes,
//     pops, replacements and removals across a full raise and lower.
//  6. D-13-08 — the raised surface's only descendants are the 48dp handle band
//     and an empty expanded region. No Text, no placeholder, no readout. THE
//     EMPTINESS IS THE DELIVERABLE.
//  7. BAR-02 — the bar wins taps inside its own rect on EVERY frame of a raise,
//     including while the surface geometrically covers it mid-animation. That
//     is what makes the bar "visible and tappable the whole time" executable.
//  8. SUM-02 — a tappable widget in the body outside the surface still receives
//     its tap while a surface is raised. Nothing beneath the surface is
//     re-laid-out, and the bar's full-screen overlay layer passes hit tests
//     through everywhere except the bar's own rect.
//
// LOCATION BY KEY, NEVER BY GLYPH. `Symbols.keyboard_rounded` collides with
// `KeyboardTabBar`'s Type tab the moment Phase 15 mounts the tab bar inside the
// raised surface, so every finder here uses the declared Keys.
//
// NO `pumpAndSettle` IN THIS FILE. It advances until no frames are scheduled,
// so a 200ms summon and a 900ms summon are indistinguishable — the ban is on
// using it anywhere near a geometry or timing assertion, and this suite is
// nothing but geometry assertions. Every advance below is an explicit
// `pump(Duration)`, including the route transitions.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_bar.dart';
import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_handle.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_surface.dart';

import 'summon_test_harness.dart';

/// The reference device: 411x891, gesture nav 48, status 24, IME down.
const Size kRefSize = Size(411, 891);
const double kRefTop = 24;
const double kRefBottom = 48;

/// Longer than any Material page transition, so a push lands without
/// `pumpAndSettle`.
const Duration kRouteSettle = Duration(milliseconds: 400);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installSummonTestPlatforms);

  /// One frame past the budget.
  ///
  /// `_InterpolationSimulation.isDone` is a STRICT `>`, so at exactly the
  /// budget the controller's value has arrived but its status has not yet
  /// flipped. Every "land it" below therefore advances the exact budget and
  /// then one more frame — which is also what discriminates the budget: a
  /// 300ms summon would still be mid-flight at 201ms.
  const tick = Duration(milliseconds: 1);

  /// Raises [icon]'s surface and lands the 200ms animation exactly.
  Future<void> raiseAndLand(WidgetTester t, Key icon) async {
    await t.tap(find.byKey(icon));
    await t.pump();
    await t.pump(kSummonRaiseDuration);
    await t.pump(tick);
  }

  /// Lowers whatever is up and lands the 150ms animation exactly.
  Future<void> lowerAndLand(WidgetTester t, Key icon) async {
    await t.tap(find.byKey(icon));
    await t.pump();
    await t.pump(kSummonLowerDuration);
    await t.pump(tick);
  }

  /// Pushes a guarded tool route with explicit pumps.
  Future<void> pushTool(WidgetTester t, GlobalKey<NavigatorState> nav) async {
    unawaited(
      nav.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const SummonBackGuard(
            child: Scaffold(body: Center(child: Text('tool body'))),
          ),
        ),
      ),
    );
    await t.pump();
    await t.pump(kRouteSettle);
  }

  testWidgets(
      'BAR-01: the bar renders on the root route and on a pushed tool route, '
      'with a byte-identical Rect on both', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    expect(find.byKey(kSummonBarKey), findsOneWidget);
    expect(find.byKey(kSummonTrackpadIconKey), findsOneWidget);
    expect(find.byKey(kSummonKeyboardIconKey), findsOneWidget);
    final onRoot = t.getRect(find.byKey(kSummonBarKey));

    await pushTool(t, nav);
    expect(find.text('tool body'), findsOneWidget);
    expect(
      find.byKey(kSummonBarKey),
      findsOneWidget,
      reason: 'ONE bar, app-scope — a per-route shell would mount a second',
    );

    final onTool = t.getRect(find.byKey(kSummonBarKey));
    expect(onTool.left, closeTo(onRoot.left, 0.01));
    expect(onTool.top, closeTo(onRoot.top, 0.01));
    expect(onTool.right, closeTo(onRoot.right, 0.01));
    expect(onTool.bottom, closeTo(onRoot.bottom, 0.01));
  });

  testWidgets(
      'BAR-02/I2: the bar is a 56dp full-width band sitting exactly the '
      'gesture-nav inset above the window bottom', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    final bar = t.getRect(find.byKey(kSummonBarKey));
    final offset = barBottomOffsetOf(bottom: kRefBottom);

    expect(bar.height, closeTo(kSummonBarHeight, 0.01));
    expect(bar.left, closeTo(0, 0.01));
    expect(bar.width, closeTo(kRefSize.width, 0.01));
    expect(
      bar.bottom,
      closeTo(kRefSize.height - offset, 0.01),
      reason: 'the nav inset is padded BELOW the 56dp band, so the trackpad '
          'glyph never competes with swipe-up-to-home (D-13-13, T-13-06)',
    );

    // The two 56x56 slots, 32dp apart, centred as a pair — every number
    // derived from the bar rect rather than quoted.
    final trackpad = t.getRect(find.byKey(kSummonTrackpadIconKey));
    final keyboard = t.getRect(find.byKey(kSummonKeyboardIconKey));
    expect(trackpad.height, closeTo(bar.height, 0.01));
    expect(trackpad.width, closeTo(kSummonIconSlot, 0.01));
    expect(keyboard.width, closeTo(kSummonIconSlot, 0.01));
    expect(keyboard.left - trackpad.right, closeTo(kSummonIconGap, 0.01));
    expect(
      keyboard.right - trackpad.left,
      closeTo(kSummonIconPairWidth, 0.01),
    );
    expect(
      trackpad.center.dx + keyboard.center.dx,
      closeTo(bar.center.dx * 2, 0.01),
      reason: 'the pair is centred, not distributed: the dead width either '
          'side is equal and deliberately empty (D-13-12)',
    );
  });

  testWidgets(
      'SUM-01/SUM-03: tapping the trackpad icon raises a surface in place and '
      'tapping it again lowers it', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    expect(find.byKey(kSummonSurfaceKey), findsNothing);

    await raiseAndLand(t, kSummonTrackpadIconKey);
    expect(find.byKey(kSummonSurfaceKey), findsOneWidget);

    await lowerAndLand(t, kSummonTrackpadIconKey);
    expect(
      find.byKey(kSummonSurfaceKey),
      findsNothing,
      reason: 'the same icon toggles — a second tap is a dismiss, not a '
          'second surface (SUM-03)',
    );
  });

  testWidgets(
      'BAR-02/I1: the surface rests ON the bar — surfaceRect.bottom equals '
      'barRect.top, and its height comes from the one shared derivation',
      (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);
    await raiseAndLand(t, kSummonTrackpadIconKey);

    final bar = t.getRect(find.byKey(kSummonBarKey));
    final surface = t.getRect(find.byKey(kSummonSurfaceKey));
    final available =
        availableOf(size: kRefSize, top: kRefTop, bottom: kRefBottom);

    expect(
      surface.bottom,
      closeTo(bar.top, 0.01),
      reason: 'I1 — "the surface sits on top of the bar" is VERTICAL '
          'stacking, not z-order; the bar is never occluded',
    );
    expect(
      surface.height,
      closeTo(
        summonSurfaceHeightFor(SummonSurfaceKind.trackpad, available),
        0.01,
      ),
      reason: 'I4 — computed from the driven metrics, never quoted',
    );
    expect(
      surface.top,
      greaterThanOrEqualTo(kRefTop - 0.01),
      reason: 'I3 — the surface never reaches under the status bar',
    );
    expect(surface.left, closeTo(0, 0.01));
    expect(surface.width, closeTo(kRefSize.width, 0.01));

    // The keyboard surface is taller and rides the same derivation and the
    // same invariant — one function, both surfaces (D-13-06).
    await raiseAndLand(t, kSummonKeyboardIconKey);
    final keyboardSurface = t.getRect(find.byKey(kSummonSurfaceKey));
    expect(
      keyboardSurface.height,
      closeTo(
        summonSurfaceHeightFor(SummonSurfaceKind.keyboard, available),
        0.01,
      ),
    );
    expect(keyboardSurface.bottom, closeTo(bar.top, 0.01));
    expect(keyboardSurface.height, greaterThan(surface.height));
  });

  testWidgets('SUM-01: raising navigates NOWHERE — no push, pop, replace or '
      'remove crosses a raise or a lower', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    final observer = RecordingNavigatorObserver();
    await pumpShell(t, nav: nav, observers: <NavigatorObserver>[observer]);

    final before = observer.mutations;
    await raiseAndLand(t, kSummonTrackpadIconKey);
    expect(find.byKey(kSummonSurfaceKey), findsOneWidget);
    await lowerAndLand(t, kSummonTrackpadIconKey);

    expect(
      observer.mutations,
      before,
      reason: 'the summon path calls SummonShellController.toggle and nothing '
          'else; a raise that pushed a route would break back handling, the '
          'hero transitions and every screen beneath it',
    );
  });

  testWidgets(
      'D-13-08: the raised surface is EMPTY — its only descendants are the '
      '48dp handle band and an empty expanded region', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);
    await raiseAndLand(t, kSummonTrackpadIconKey);

    final surface = find.byKey(kSummonSurfaceKey);
    expect(
      find.descendant(of: surface, matching: find.byType(Text)),
      findsNothing,
      reason: 'no empty-state heading, body, hint or debug height readout — '
          'a placeholder is exactly the throwaway artefact that can confuse a '
          'failure during this phase\'s geometry UAT',
    );
    expect(
      find.descendant(of: surface, matching: find.byKey(kSummonHandleKey)),
      findsOneWidget,
    );
    expect(
      find.descendant(of: surface, matching: find.byType(Expanded)),
      findsOneWidget,
    );

    final band = t.getRect(find.byKey(kSummonHandleKey));
    final surfaceRect = t.getRect(surface);
    expect(band.height, closeTo(kSummonHandleBandHeight, 0.01));
    expect(band.width, closeTo(surfaceRect.width, 0.01));
    expect(
      band.top,
      closeTo(surfaceRect.top + kSummonHairline, 0.01),
      reason: 'the band sits immediately under the 1px top rule, which is what '
          'makes the inherited content box height - 1 - 48',
    );

    // The 48x48 tap target Phase 14 attaches to must be a REAL box, not an
    // icon-sized hit region, so an accessibility service has something to
    // drive (SUM-05).
    final target = t.getRect(
      find
          .descendant(
            of: find.byKey(kSummonHandleKey),
            matching: find.byType(Semantics),
          )
          .first,
    );
    expect(target.height, closeTo(kSummonHandleBandHeight, 0.01));
    expect(target.width, closeTo(kSummonHandleBandHeight, 0.01));

    // The content box Phases 14 and 15 inherit, measured on the rendered tree
    // rather than trusted from the arithmetic — this is the join between
    // `summonSurfaceContentHeight` and what is actually laid out.
    final content = t.getRect(
      find.descendant(of: surface, matching: find.byType(Expanded)),
    );
    expect(
      content.height,
      closeTo(
        summonSurfaceHeightFor(
              SummonSurfaceKind.trackpad,
              availableOf(size: kRefSize, top: kRefTop, bottom: kRefBottom),
            ) -
            kSummonHairline -
            kSummonHandleBandHeight,
        0.01,
      ),
      reason: 'the rendered empty region IS height - 1 - 48; if the hairline '
          'stops costing its 1dp of layout, Phases 14 and 15 inherit a box a '
          'pixel taller than the number they were handed',
    );
  });

  testWidgets(
      'BAR-02: the bar wins taps in its own rect MID-ANIMATION, while the '
      'sliding surface geometrically covers it', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);
    final controller = SummonScope.of(contextOf(t, kHarnessRootText));

    await t.tap(find.byKey(kSummonTrackpadIconKey));
    await t.pump();
    await t.pump(const Duration(milliseconds: 100)); // half way up

    final bar = t.getRect(find.byKey(kSummonBarKey));
    final surface = t.getRect(find.byKey(kSummonSurfaceKey));
    expect(
      surface.bottom,
      greaterThan(bar.top),
      reason: 'mid-raise the surface is translated DOWN over the bar band — '
          'without that overlap this case would prove nothing',
    );

    // The bar is the last Stack child, and Stack hit-tests in reverse paint
    // order, so this tap must reach the bar rather than the surface covering
    // it. `tap` warns if the hit test does not land on the finder's widget.
    await t.tap(find.byKey(kSummonKeyboardIconKey));
    await t.pump();
    await t.pump(kSummonRaiseDuration);
    await t.pump(tick);

    expect(
      controller.raised.value?.surface,
      SummonSurfaceKind.keyboard,
      reason: 'the tap reached the bar mid-animation; BAR-02 is "visible AND '
          'tappable the whole time"',
    );
  });

  testWidgets(
      'SUM-02: a tappable widget in the body outside the surface still '
      'receives its tap while a surface is raised', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    var bodyTaps = 0;
    await pumpShell(
      t,
      nav: nav,
      body: Scaffold(
        body: Center(
          child: GestureDetector(
            onTap: () => bodyTaps++,
            child: const Text(kHarnessRootText),
          ),
        ),
      ),
    );

    await raiseAndLand(t, kSummonTrackpadIconKey);
    final target = t.getRect(find.text(kHarnessRootText));
    final surface = t.getRect(find.byKey(kSummonSurfaceKey));
    expect(
      target.bottom,
      lessThan(surface.top),
      reason: 'the target must be OUTSIDE the surface for this to mean '
          'anything',
    );

    await t.tap(find.text(kHarnessRootText));
    await t.pump();

    expect(
      bodyTaps,
      1,
      reason: 'the Navigator is a Positioned.fill SIBLING of the chrome, never '
          'a descendant of it, and the bar\'s overlay layer passes hit tests '
          'through everywhere except the bar\'s own rect',
    );
  });
}
