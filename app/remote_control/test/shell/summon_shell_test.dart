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
//  9. SUM-02 — nothing beneath a raised surface RESIZES: a body widget's Rect
//     is identical before a raise and with the surface fully raised. This is
//     NOT an IME-style resize contract, and the reason is written on the case.
// 10. BAR-05 / SC1 — the three surfaces the success criterion names by hand
//     reach their last item at 360x640 with the bar present: the browser tab
//     list, the browser bookmarks section and the already-scrolling hub grid.
//
// ── THIS SUITE IS THE SUCCESSOR OF `test/bubble_scaffold_test.dart` ─────────
//
// TEST-MIGRATION.md's rule is "do not delete a file until its successor
// exists", so the bubble scaffold suite's header contracts land here BEFORE
// Phase 16 deletes the original. Which of its five go where (13-08):
//
//  * C1 presence — the `TrackpadBubble` half DIES with the bubble. Its
//    surviving half is the `UipiBanner` host, which the shell rehomes
//    (SAFE-03); asserted at case 1 below, so the SRV-05 advisory cannot be
//    silently deleted along with `BubbleScaffold`.
//  * C2 absence — DIES. `showBubble` ceases to exist; there is one app-scope
//    shell and no per-screen opt-out.
//  * C3 expand toggle (never both visible) — MUTATED into "tapping a bar icon
//    raises the surface, tapping the same icon lowers it" (case 3), plus
//    `summon_motion_test.dart`'s swap accounting for the two-surfaces half.
//  * C4 body-hit-testable — SURVIVES IN SPIRIT, and it is the single most
//    valuable contract in the milestone: it is what proves overlay-not-screen.
//    Case 8 is a real `tap` with a counter, never a `findsOneWidget`, and it
//    now carries the complementary negative (a target INSIDE the surface's
//    rect must NOT receive the tap) with a nothing-raised control tap so a
//    silently-untappable target cannot masquerade as a pass.
//  * C5 back-intercept — MUTATED into `test/shell/summon_back_guard_test.dart`
//    (SUM-04, D-13-02, D-13-03) with the ownership predicate added. It does
//    NOT live here.
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
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:remote_protocol/remote_protocol.dart';

import 'package:remote_control/browser/browser_screen.dart';
import 'package:remote_control/hub/hub_screen.dart';
import 'package:remote_control/net/connection_providers.dart';
import 'package:remote_control/net/connection_service.dart';
import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_bar.dart';
import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_handle.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_shell.dart';
import 'package:remote_control/shell/summon_surface.dart';
import 'package:remote_control/widgets/uipi_banner.dart';

import 'summon_test_harness.dart';

/// The reference device: 411x891, gesture nav 48, status 24, IME down.
const Size kRefSize = Size(411, 891);
const double kRefTop = 24;
const double kRefBottom = 48;

/// The short device SC1 names for the three reach cases: 360x640 with the same
/// gesture-nav inset. This is the viewport where 56dp of new chrome is most
/// likely to strand a list's last row, which is why it is the one driven by
/// hand rather than the reference device.
const Size kShortSize = Size(360, 640);

/// Longer than any Material page transition, so a push lands without
/// `pumpAndSettle`.
const Duration kRouteSettle = Duration(milliseconds: 400);

/// Longer than the browser rows' 100ms accent press flash, so the reach cases
/// leave no timer pending at teardown without reaching for a settle.
const Duration kRowFlash = Duration(milliseconds: 150);

/// Records the live route STACK, so a test can assert its length rather than
/// only that a mutation counter did not move. A push immediately followed by a
/// pop leaves the counter changed and the stack identical; SUM-01 is a claim
/// about the stack.
class _StackObserver extends NavigatorObserver {
  /// The routes currently on the stack, oldest first.
  final List<Route<dynamic>> stack = <Route<dynamic>>[];

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.add(route);

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) =>
      stack.remove(route);

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    final index = stack.indexOf(oldRoute!);
    if (index >= 0) stack[index] = newRoute!;
  }
}

/// A [RecordingService] that also parks the two browser snapshots and records
/// every reliable send, so the three SC1 reach cases can drive the REAL
/// screens and assert that the last row's tap reached its handler.
///
/// It starts AUTHED: the hub disables every tile when the chip is
/// disconnected (D-08), and a disabled tile would make "the last tile is
/// hit-testable" pass for the wrong reason.
class _ScreenService extends RecordingService {
  /// Creates the double, already connected.
  _ScreenService() {
    authed = true;
  }

  /// Every message the screen sent reliably, in order.
  final List<RemoteMessage> reliable = [];

  /// The parked tab snapshot the tabs store reads on build.
  TabsSnapshot? tabs;

  /// The parked bookmark snapshot the bookmarks store reads on build.
  BookmarksSnapshot? bookmarks;

  @override
  TabsSnapshot? get tabsSnapshot => tabs;

  @override
  BookmarksSnapshot? get bookmarksSnapshot => bookmarks;

  @override
  void sendReliable(RemoteMessage msg) => reliable.add(msg);
}

/// Twelve tabs — far more than a 360x640 viewport shows, so the tab list is
/// genuinely scrolled to its end rather than fitting by accident.
final TabsSnapshot _manyTabs = TabsSnapshot(
  connected: true,
  tabs: [
    for (var i = 0; i < 12; i++)
      TabInfo(id: i, title: 'Tab $i', active: i == 0),
  ],
  groups: const [],
);

/// Three Chrome roots, the first holding one subfolder plus twenty links —
/// the same shape `browser_screen_test.dart` uses, kept so the bookmarks
/// section is unambiguously taller than its viewport.
final BookmarksSnapshot _bmTree = BookmarksSnapshot(
  connected: true,
  truncated: false,
  nodes: [
    const BmNode(
      id: '1',
      parentId: '0',
      title: 'Bookmarks bar',
      folder: true,
      count: 21,
      locked: true,
    ),
    const BmNode(
      id: '2',
      parentId: '0',
      title: 'Other bookmarks',
      folder: true,
      count: 0,
      locked: true,
    ),
    const BmNode(id: '10', parentId: '1', title: 'Work', folder: true, count: 1),
    for (var i = 0; i < 20; i++)
      BmNode(id: 'b$i', parentId: '1', title: 'Link $i'),
    const BmNode(id: '20', parentId: '10', title: 'Jira'),
  ],
);

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
    expect(
      find.byType(UipiBanner),
      findsOneWidget,
      reason: 'C1\'s surviving half (SAFE-03): the banner host is rehomed into '
          'the shell, so deleting BubbleScaffold in Phase 16 cannot silently '
          'delete the SRV-05 advisory from the product',
    );
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
    final stack = _StackObserver();
    await pumpShell(
      t,
      nav: nav,
      observers: <NavigatorObserver>[observer, stack],
    );

    final before = observer.mutations;
    final depthBefore = stack.stack.length;
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
    expect(
      stack.stack.length,
      depthBefore,
      reason: 'the ROUTE STACK, not merely the mutation counter: a raise that '
          'pushed and a lower that popped would leave the counter changed and '
          'this length identical, and a raise that pushed WITHOUT a matching '
          'pop would leave this length changed — the two assertions together '
          'are what make "raising navigates nowhere" executable (SUM-01)',
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

  // ── C4's complementary negative ────────────────────────────────────────
  //
  // The positive case above proves the overlay does not swallow the screen.
  // On its own it is also satisfied by an overlay that swallows NOTHING, which
  // would be a different defect wearing the same green: the user sees an
  // opaque slab, taps it, and the hub tile underneath opens. The pair is the
  // contract; neither half is it alone.
  testWidgets(
      'SUM-02: a tappable widget INSIDE the raised surface\'s rect does not '
      'receive the tap — the slab is above it', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    var buriedTaps = 0;
    await pumpShell(
      t,
      nav: nav,
      body: Scaffold(
        // SafeArea consumes the shell's injected +56, so bottom-aligned lands
        // the target exactly in the band a raised surface covers.
        body: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: GestureDetector(
              onTap: () => buriedTaps++,
              child: const Text(kHarnessRootText),
            ),
          ),
        ),
      ),
    );

    // CONTROL, with nothing raised. Without it a target that was never
    // tappable at all — mis-placed, zero-sized, behind the bar — would pass
    // the negative below for entirely the wrong reason.
    final control = t.getRect(find.text(kHarnessRootText));
    await t.tapAt(control.center);
    await t.pump();
    expect(
      buriedTaps,
      1,
      reason: 'the control must land, or the negative proves nothing',
    );
    buriedTaps = 0;

    await raiseAndLand(t, kSummonTrackpadIconKey);
    final target = t.getRect(find.text(kHarnessRootText));
    final surface = t.getRect(find.byKey(kSummonSurfaceKey));
    final bar = t.getRect(find.byKey(kSummonBarKey));
    expect(
      surface.contains(target.center),
      isTrue,
      reason: 'the target must be INSIDE the surface for this to mean anything',
    );
    expect(
      bar.contains(target.center),
      isFalse,
      reason: 'and it must NOT be inside the bar, or this would be case 7 '
          '(the bar winning its own rect) wearing a different name',
    );

    // `tapAt`, never `tap`: `tap` fails a hit-test miss, and a miss is exactly
    // what this case asserts.
    await t.tapAt(target.center);
    await t.pump();

    expect(
      buriedTaps,
      0,
      reason: 'the slab\'s own BoxDecoration hit-tests true inside its rect '
          '(RenderDecoratedBox.hitTestSelf), and a Stack hit-tests in reverse '
          'paint order, so the surface consumes the tap before the Navigator '
          'sees it. An empty surface that passed taps through to the screen '
          'beneath would be invisible in the positive case above',
    );
  });

  testWidgets(
      'SUM-02: nothing beneath the surface RESIZES — a body widget\'s Rect is '
      'identical before and after a raise', (t) async {
    driveView(t, size: kRefSize, top: kRefTop, bottom: kRefBottom);
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(
      t,
      nav: nav,
      body: const Scaffold(
        body: SafeArea(
          child: Align(
            alignment: Alignment.bottomCenter,
            child: Text(kHarnessRootText),
          ),
        ),
      ),
    );

    // Bottom-aligned deliberately: a resize contract would move THIS widget
    // and leave a centred or top-aligned one alone.
    final before = t.getRect(find.text(kHarnessRootText));
    await raiseAndLand(t, kSummonTrackpadIconKey);
    final after = t.getRect(find.text(kHarnessRootText));

    expect(after.left, closeTo(before.left, 0.01));
    expect(after.top, closeTo(before.top, 0.01));
    expect(after.right, closeTo(before.right, 0.01));
    expect(
      after.bottom,
      closeTo(before.bottom, 0.01),
      reason: 'this is NOT an IME-style resize contract. Nothing on the phone '
          'is the input target, so there is no field to keep visible, and '
          'converting "raise in place" into a resize would make every tool '
          'screen scrollable for a problem this app does not have. The '
          'surface is a Positioned SIBLING of the Navigator and never an '
          'ancestor of it, which is what makes this free',
    );
  });

  // ── BAR-05 / SC1: the three named 640dp reach cases ────────────────────
  //
  // "Nothing clipped or stranded on all fourteen screens" is a RENDERING
  // claim that no single assertion covers. It is closed by the BACKSTOP — the
  // full-suite run recorded immediately before and immediately after the
  // reservation landed in plan 13-01 — PLUS these three cases, which the
  // success criterion names by hand. That is the owner-directed shape of this
  // evidence: it is deliberately neither fourteen hand-written assertions nor
  // a single aggregate one, and it must not be silently upgraded or
  // downgraded later.
  //
  // The failure each case catches is a final row stranded under 56dp of new
  // chrome, which reads to the user as the list ending one item early. No
  // aggregate assertion detects that.
  //
  // NO SCREEN IS EDITED to make any of these pass. BAR-05 is reserved through
  // ONE injection with zero per-screen edits, and a per-screen fix here would
  // destroy the property being tested — which is why this plan's verify
  // asserts `git diff --name-only -- lib/` is empty.

  /// Pumps a REAL screen under the production shell shape.
  ///
  /// `pumpShell` is deliberately not reused: it ends in a settle-until-idle
  /// pump, and every one of these screens carries the connection header chip,
  /// whose periodic poll never goes idle.
  Future<void> pumpScreenUnderShell(
    WidgetTester t, {
    required Widget screen,
    required ConnectionService service,
    List<NavigatorObserver> observers = const <NavigatorObserver>[],
  }) async {
    await t.pumpWidget(
      ProviderScope(
        overrides: [
          connectionServiceProvider.overrideWith((ref) => service),
        ],
        child: MaterialApp(
          navigatorObservers: observers,
          builder: (context, child) => SummonShell(child: child!),
          home: SummonBackGuard(child: screen),
        ),
      ),
    );
    // Two frames: the build, then the post-frame primes and async store loads.
    await t.pump();
    await t.pump();
  }

  /// Jumps the screen's one scroll region to its TRUE end and returns the
  /// position, so the caller can also assert that it genuinely scrolls.
  ///
  /// A jump rather than a drag: a drag that under-shoots would leave the last
  /// row above the fold and the reach assertion would pass without ever
  /// testing reach.
  Future<ScrollPosition> scrollToEnd(WidgetTester t) async {
    final scrollable = t.state<ScrollableState>(
      find
          .descendant(
            of: find.byType(SingleChildScrollView),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    scrollable.position.jumpTo(scrollable.position.maxScrollExtent);
    await t.pump();
    return scrollable.position;
  }

  /// Drains the browser macro grid's PRE-EXISTING horizontal overflow.
  ///
  /// At 360dp width, under the widget-test font, one macro key's `Row`
  /// overflows by 12 pixels on the RIGHT. It is not the reservation and it is
  /// not this phase: it reproduces identically against a bare
  /// `MaterialApp(home: BrowserScreen())` with no shell mounted at all, at the
  /// same viewport (verified by hand while writing these cases, and recorded in
  /// this phase's `deferred-items.md`). The overflow is also very probably a
  /// test-font artefact — the same one 13-UI-SPEC flags for the chip row —
  /// since every glyph is a full em under the test face.
  ///
  /// It is drained rather than fixed for the reason this whole block exists:
  /// BAR-05 is reserved through ONE injection with ZERO per-screen edits, and
  /// editing `browser_screen.dart` here would destroy the property under test.
  ///
  /// **The drain asserts what it swallows.** `on the right` is a HORIZONTAL
  /// overflow, and this phase's injection is vertical only, changing no
  /// horizontal constraint. A vertical overflow — precisely the failure these
  /// three cases exist to catch — does not match and fails the test.
  void drainPreExistingHorizontalOverflow(WidgetTester t) {
    final error = t.takeException();
    if (error == null) return;
    expect(
      error.toString(),
      contains('on the right'),
      reason: 'the ONLY exception these cases tolerate is the pre-existing '
          'horizontal macro-grid overflow. Anything else — and any VERTICAL '
          'overflow — is signal from the 56dp reservation and must fail',
    );
  }

  /// The browser's PINNED macro-grid footer must also clear the bar.
  ///
  /// This assertion is here because of what a hand-falsification showed. With
  /// the shell's `MediaQuery` reservation deleted, the hub-grid case below goes
  /// red (its last tile lands 40px under the bar) — but the two browser cases
  /// stayed GREEN, because the browser's scroll region is bounded by this
  /// pinned footer rather than by the safe area, so its last row cannot be
  /// stranded no matter what the reservation does. On this screen the footer is
  /// what a lost reservation actually buries, and the 7-action macro grid going
  /// under the bar is the same user-visible failure as a stranded row.
  ///
  /// Without this line the two named browser cases would be a green that
  /// measures nothing against the failure they exist to catch.
  void expectFooterAboveBar(WidgetTester t, Rect bar) {
    expect(
      t.getRect(find.byType(BrowserMacroGrid)).bottom,
      lessThanOrEqualTo(bar.top + 0.01),
      reason: 'the pinned macro grid — the browser\'s bottom-most content — '
          'clears the bar too. Buried, the user loses back/forward/refresh '
          'entirely, which is worse than a list ending one item early',
    );
  }

  /// The row a label sits in: its nearest `Material` ancestor, which is the
  /// row/tile chrome on every one of the three surfaces. The ROW's bottom edge
  /// is what may be stranded, not the text's.
  Rect rowRectOf(WidgetTester t, Finder label) => t.getRect(
        find.ancestor(of: label, matching: find.byType(Material)).first,
      );

  testWidgets(
      'BAR-05/SC1: the browser TAB LIST reaches its last row at 360x640 with '
      'the bar present, and that row is hit-testable', (t) async {
    driveView(t, size: kShortSize, top: kRefTop, bottom: kRefBottom);
    final service = _ScreenService()..tabs = _manyTabs;
    await pumpScreenUnderShell(
      t,
      screen: const BrowserScreen(),
      service: service,
    );
    drainPreExistingHorizontalOverflow(t);

    final position = await scrollToEnd(t);
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'the fixture must actually overflow this viewport, or "reaches '
          'its last row" is a claim about a list that never scrolled',
    );

    final bar = t.getRect(find.byKey(kSummonBarKey));
    final row = rowRectOf(t, find.text('Tab 11'));
    expect(
      row.bottom,
      lessThanOrEqualTo(bar.top + 0.01),
      reason: 'the last tab row is fully above the bar. A row stranded under '
          'the bar reads to the user as the tab list ending one item early',
    );
    expectFooterAboveBar(t, bar);

    await t.tap(find.text('Tab 11'));
    await t.pump();
    // The row's own 100ms press flash. Drained explicitly so no timer is left
    // pending at teardown — and AFTER the geometry assertions, never before.
    await t.pump(kRowFlash);
    expect(
      service.reliable.whereType<TabsActivateMsg>().map((m) => m.id),
      [11],
      reason: 'visible is not enough — the last row must still reach its '
          'handler with 56dp of new chrome below it',
    );
  });

  testWidgets(
      'BAR-05/SC1: the browser BOOKMARKS section reaches its last row at '
      '360x640 with the bar present, and that row is hit-testable', (t) async {
    driveView(t, size: kShortSize, top: kRefTop, bottom: kRefBottom);
    final service = _ScreenService()..bookmarks = _bmTree;
    await pumpScreenUnderShell(
      t,
      screen: const BrowserScreen(),
      service: service,
    );
    drainPreExistingHorizontalOverflow(t);

    // Settle-until-idle is banned in this file, so the segment switch and the
    // folder drill are explicit pumps. Neither precedes a geometry assertion.
    await t.tap(find.text('Bookmarks'));
    await t.pump();
    await t.pump();
    await t.tap(find.text('Bookmarks bar'));
    await t.pump();
    await t.pump();

    final position = await scrollToEnd(t);
    expect(position.maxScrollExtent, greaterThan(0));

    final bar = t.getRect(find.byKey(kSummonBarKey));
    final row = rowRectOf(t, find.text('Link 19'));
    expect(
      row.bottom,
      lessThanOrEqualTo(bar.top + 0.01),
      reason: 'the last bookmark row is fully above the bar',
    );
    expectFooterAboveBar(t, bar);

    await t.tap(find.text('Link 19'));
    await t.pump();
    await t.pump(kRowFlash);
    expect(
      service.reliable.whereType<BmOpenMsg>().map((m) => m.nodeId),
      ['b19'],
      reason: 'the last bookmark still opens with the bar present',
    );
  });

  testWidgets(
      'BAR-05/SC1: the already-scrolling HUB GRID reaches its last tile at '
      '360x640 with the bar present, and that tile is hit-testable', (t) async {
    driveView(t, size: kShortSize, top: kRefTop, bottom: kRefBottom);
    final service = _ScreenService();
    final stack = _StackObserver();
    await pumpScreenUnderShell(
      t,
      screen: const HubScreen(),
      service: service,
      observers: <NavigatorObserver>[stack],
    );

    final last = kHubTiles.last.label;
    final position = await scrollToEnd(t);
    expect(
      position.maxScrollExtent,
      greaterThan(0),
      reason: 'SC1 calls this grid "already scrolling" — if it fits, the case '
          'is measuring the wrong viewport',
    );

    final bar = t.getRect(find.byKey(kSummonBarKey));
    final tile = rowRectOf(t, find.text(last));
    expect(
      tile.bottom,
      lessThanOrEqualTo(bar.top + 0.01),
      reason: 'the last hub tile is fully above the bar. Stranded, it reads as '
          'the dashboard having one tool fewer than it has',
    );

    final depthBefore = stack.stack.length;
    await t.tap(find.text(last));
    await t.pump();
    expect(
      stack.stack.length,
      depthBefore + 1,
      reason: 'the tile is not merely visible: its tap reached _open and '
          'pushed the guarded route',
    );
  });
}
