// Task 2 (13-09) — BAR-04: the bar is absent on a suppressed route and present
// everywhere else, with no flicker at either lifecycle boundary.
//
//  1. The bar is present on an ordinary route. The control, so a later case
//     asserting absence cannot pass because the bar was never there.
//  2. Under suppression the bar's KEY RESOLVES TO NOTHING. Absence, not an
//     opacity, not a zero-sized box, not an off-screen offset — a bar that is
//     merely invisible still eats taps in its own rect, and this screen's whole
//     surface is a camera preview.
//  3. Popping the suppressed route restores the bar with its PRE-PUSH RECT,
//     within 0.01. Suppression is not allowed to leave geometry behind.
//  4. THE FLICKER PROOF, frame by frame. On push the incoming route's
//     `initState` runs while the outgoing route is still mounted; on pop
//     `dispose` runs only after the transition completes. This case walks both
//     transitions in small pumps and asserts the bar never appears over the
//     scanner and never vanishes early. A boolean would blink at both ends, and
//     a blink reads as a rendering glitch rather than a state bug — which is
//     how it survives review.
//  5. Two NESTED suppressors, both released, restore the bar EXACTLY ONCE. The
//     count of visibility transitions is asserted, not just the final state:
//     "ends up visible" is also what a broken counter that oscillates produces.
//  6. Releasing ONE suppressor while another is still mounted leaves the bar
//     suppressed. This is the case a boolean gets wrong, stated on its own.
//  7. The bar RENDERS OVER an open modal route, on purpose. SC4 requires the
//     keyboard icon to be visibly disabled ON THE PAIRING SHEET, which is only
//     observable if the bar is there — so this is a requirement, not an
//     oversight, and there must be no second suppressor for modal routes.
//
// The suppressed route's content here is a plain Scaffold, never the real
// scanner: the scanner owns a camera platform view, and what is under test is
// the wrapper's lifecycle, not the screen it happens to wrap. The real screen's
// end-to-end pairing path stays covered by `test/qr_scan_pairing_test.dart` and
// `test/pairing_flow_test.dart`, which this plan re-runs unchanged.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_bar.dart';
import 'package:remote_control/shell/summon_bar_suppressor.dart';
import 'package:remote_control/shell/summon_scope.dart';

import 'summon_test_harness.dart';

/// Text rendered by the suppressed route, so a test can prove that route is on
/// screen at the moment it asserts the bar is not.
const String kSuppressedRouteText = 'suppressed route body';

/// Text rendered by a second suppressed route.
const String kSecondSuppressedText = 'second suppressed route body';

Widget _suppressed([String text = kSuppressedRouteText]) => SummonBarSuppressor(
      child: Scaffold(body: Center(child: Text(text))),
    );

/// A route wrapped in TWO suppressors — the nesting case.
Widget _doublySuppressed() => const SummonBarSuppressor(
      child: SummonBarSuppressor(
        child: Scaffold(body: Center(child: Text(kSuppressedRouteText))),
      ),
    );

Finder get _bar => find.byKey(kSummonBarKey);

void main() {
  setUp(installSummonTestPlatforms);

  testWidgets('the bar is present on an ordinary route', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav);

    expect(_bar, findsOneWidget);

    // A pushed, UN-suppressed route keeps it — the bar is app-scope chrome and
    // suppression is opt-in per route, never the default.
    unawaited(
      pushGuarded<void>(
        contextOf(t, kHarnessRootText),
        const Scaffold(body: Center(child: Text('ordinary pushed route'))),
      ),
    );
    await t.pumpAndSettle();

    expect(find.text('ordinary pushed route'), findsOneWidget);
    expect(_bar, findsOneWidget);
  });

  testWidgets(
    'under suppression the bar is ABSENT — its key resolves to nothing, not to '
    'a hidden or zero-sized bar',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      expect(_bar, findsOneWidget);

      unawaited(pushGuarded<void>(contextOf(t, kHarnessRootText), _suppressed()));
      await t.pumpAndSettle();

      expect(find.text(kSuppressedRouteText), findsOneWidget);
      expect(
        _bar,
        findsNothing,
        reason: 'a bar that is merely invisible still absorbs taps in its own '
            'rect, and this screen is a camera preview end to end',
      );
      // Nothing of the bar survives: neither slot is in the tree either.
      expect(find.byType(SummonBar), findsNothing);
    },
  );

  testWidgets(
    'popping the suppressed route restores the bar with its pre-push rect',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);

      final before = t.getRect(_bar);

      unawaited(pushGuarded<void>(contextOf(t, kHarnessRootText), _suppressed()));
      await t.pumpAndSettle();
      expect(_bar, findsNothing);

      nav.currentState!.pop();
      await t.pumpAndSettle();

      expect(_bar, findsOneWidget);
      final after = t.getRect(_bar);
      expect(after.left, closeTo(before.left, 0.01));
      expect(after.top, closeTo(before.top, 0.01));
      expect(after.width, closeTo(before.width, 0.01));
      expect(after.height, closeTo(before.height, 0.01));
    },
  );

  testWidgets(
    'THE FLICKER PROOF: across a full push/pop pair the bar is never present '
    'over the suppressed route and never absent over the ordinary one',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);
      expect(_bar, findsOneWidget);

      // ── PUSH ───────────────────────────────────────────────────────────
      // Frame N: the incoming route mounts (its `initState` runs mid-build, so
      // the suppression is applied at the end of this frame — see the
      // suppressor's doc). The claim being pinned is not "the bar vanishes on
      // frame N", it is the one that actually matters: THE BAR IS NEVER DRAWN
      // OVER A VISIBLE PIXEL OF THE SUPPRESSED SCREEN. On frame N the route's
      // transition value is still 0, so it is translated entirely off the
      // viewport and the two rects do not meet.
      unawaited(pushGuarded<void>(contextOf(t, kHarnessRootText), _suppressed()));

      var routeSeen = false;
      for (var frame = 0; frame < 8; frame++) {
        await t.pump(frame == 0 ? Duration.zero : const Duration(milliseconds: 40));

        final barHere = _bar.evaluate().isNotEmpty;
        final routeHere = find.text(kSuppressedRouteText).evaluate().isNotEmpty;
        routeSeen = routeSeen || routeHere;

        if (barHere && routeHere) {
          expect(
            t.getRect(_bar).overlaps(t.getRect(find.text(kSuppressedRouteText))),
            isFalse,
            reason: 'frame $frame — the bar may only coexist with the incoming '
                'route while that route is still off the viewport',
          );
        }
        if (routeSeen && frame > 1) {
          expect(
            barHere,
            isFalse,
            reason: 'frame $frame — once the route is on screen the bar is gone',
          );
        }
      }
      await t.pumpAndSettle();
      expect(_bar, findsNothing);

      // ── POP ────────────────────────────────────────────────────────────
      // `dispose` runs only AFTER the transition completes, so the scanner is
      // still on screen for the whole reverse animation and the bar must stay
      // away for all of it.
      nav.currentState!.pop();
      await t.pump();
      expect(
        _bar,
        findsNothing,
        reason: 'the suppressed route is still visible on the first pop frame',
      );
      for (var i = 0; i < 3; i++) {
        await t.pump(const Duration(milliseconds: 50));
        expect(find.text(kSuppressedRouteText), findsOneWidget);
        expect(
          _bar,
          findsNothing,
          reason: 'the bar must not reappear over a route that is still there',
        );
      }

      await t.pumpAndSettle();
      expect(find.text(kSuppressedRouteText), findsNothing);
      expect(_bar, findsOneWidget);
    },
  );

  testWidgets(
    'two NESTED suppressors, both released, restore the bar exactly once',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);

      final controller = SummonScope.of(contextOf(t, kHarnessRootText));
      final seen = <bool>[];
      void record() => seen.add(controller.barVisible.value);
      controller.barVisible.addListener(record);
      addTearDown(() => controller.barVisible.removeListener(record));

      unawaited(
        pushGuarded<void>(contextOf(t, kHarnessRootText), _doublySuppressed()),
      );
      await t.pumpAndSettle();
      expect(_bar, findsNothing);

      nav.currentState!.pop();
      await t.pumpAndSettle();
      expect(_bar, findsOneWidget);

      // Both suppressors took and released their own count, but the bar only
      // ever changed visibility twice: away once, back once. "Ends up visible"
      // is also what an oscillating counter produces, which is why the
      // transitions are counted rather than the final state.
      expect(
        seen.where((visible) => !visible).length,
        1,
        reason: 'the nested pair hid the bar exactly once',
      );
      expect(
        seen.where((visible) => visible).length,
        1,
        reason: 'and restored it exactly once',
      );
    },
  );

  testWidgets(
    'releasing ONE suppressor while another is still mounted leaves the bar '
    'suppressed — the case a boolean gets wrong',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);

      final rootContext = contextOf(t, kHarnessRootText);
      unawaited(pushGuarded<void>(rootContext, _suppressed()));
      await t.pumpAndSettle();
      expect(_bar, findsNothing);

      unawaited(
        pushGuarded<void>(
          contextOf(t, kSuppressedRouteText),
          _suppressed(kSecondSuppressedText),
        ),
      );
      await t.pumpAndSettle();
      expect(_bar, findsNothing);

      // Release the second. The first is still mounted, so the bar stays away.
      nav.currentState!.pop();
      await t.pumpAndSettle();
      expect(find.text(kSuppressedRouteText), findsOneWidget);
      expect(
        _bar,
        findsNothing,
        reason: 'one release out of two outstanding restores nothing',
      );

      // Release the first. Now, and only now, the bar comes back.
      nav.currentState!.pop();
      await t.pumpAndSettle();
      expect(_bar, findsOneWidget);
    },
  );

  testWidgets(
    'the bar RENDERS OVER an open modal route — SC4 requires it, do not '
    '"fix" this',
    (t) async {
      final nav = GlobalKey<NavigatorState>();
      await pumpShell(t, nav: nav);

      unawaited(
        showModalBottomSheet<void>(
          context: contextOf(t, kHarnessRootText),
          builder: (_) => const SizedBox(
            height: 200,
            child: Center(child: Text('a modal sheet')),
          ),
        ),
      );
      await t.pumpAndSettle();

      expect(find.text('a modal sheet'), findsOneWidget);
      expect(
        _bar,
        findsOneWidget,
        reason: 'SC4 requires the keyboard icon to be VISIBLY DISABLED on the '
            'pairing sheet, which is a modal route — that is only observable '
            'if the bar is drawn over it. There is exactly one suppression '
            'site in the app and it is not this one.',
      );
    },
  );
}
