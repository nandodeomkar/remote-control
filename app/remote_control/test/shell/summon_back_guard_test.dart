// Task 1 (13-05, Wave 3) — the whole dismiss vocabulary, driven through the
// REAL SummonShell, the REAL SummonBackGuard and the REAL controller. Pins
// SUM-04 and the two decisions the ownership model was designed to make free:
//
//  1. OWNERSHIP (D-13-02). Raise on the hub, push a tool route, and three
//     consecutive system backs resolve exactly one thing each, in order:
//     the pushed route pops with the surface STILL RAISED (the lower guard is
//     not even consulted — only the topmost present route participates,
//     navigator.dart:5547), then the hub's guard owns the raise so the surface
//     lowers with the route stack UNCHANGED, then the app exits.
//
//     `canPop` is the single most dangerous expression in this phase. Written
//     as `!raised` — "anything is raised" — it inverts D-13-02: the FIRST back
//     would dismiss the surface and the user could not leave the tool screen
//     without dismissing first (13-RESEARCH Pitfall B). Written as a constant
//     `false` it stops back exiting the app from the hub (T-13-05) and kills
//     Android's back-to-home animation. Both failures are silent. Case 1 turns
//     the first into a red test and case 1's third back turns the second.
//
//  2. THE ORPHAN (D-13-03). Raise from a tool route, then pop that route the
//     way its AppBar arrow does — programmatically, not with a back gesture.
//     The surface stays raised and un-owned: back from the hub exits the app
//     with the surface still up, and only an icon tap lowers it. This is the
//     trade the owner stated explicitly; ownership transfer was offered and
//     DECLINED, so the absence of a matching live guard id is the whole
//     mechanism and there is no transfer machinery to test.
//
//  3. NO RETAINED ROUTE (D-13-19). Ownership is an ABSENT ID, never a dangling
//     `Route` reference: after the owner is popped, no LIVE guard id owns the
//     raise, the raise still records the dead id (nothing was "cleared"), and
//     the guard stack is maintained by VALUE — an out-of-order removal retires
//     the right id. A source scan proves neither shell file names a `Route`
//     type in code at all.
//
//  4. MODAL ROUTES STAY UN-GUARDED. A dialog is the topmost route, so back
//     closes the dialog first and the raised surface is untouched. That is
//     INTENDED behaviour — nobody should wire guards into the six modal sites.
//
// Settle-until-idle pumping appears below for NAVIGATION transitions only
// (the plan's `planner-discipline-allow`). It never precedes a geometry or a
// motion assertion; every summon advance is an explicit `pump(Duration)`.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:remote_control/shell/summon_back_guard.dart';
import 'package:remote_control/shell/summon_geometry.dart';
import 'package:remote_control/shell/summon_icon_button.dart';
import 'package:remote_control/shell/summon_scope.dart';
import 'package:remote_control/shell/summon_surface.dart';

import 'summon_test_harness.dart';

/// The root route's body text — this suite's stand-in for the hub.
const String kHubText = 'hub body';

/// A pushed page route's body text — the stand-in for a tool screen.
const String kToolText = 'tool body';

/// The first of two pushed routes in the out-of-order disposal case.
const String kFirstText = 'first pushed body';

/// The second of two pushed routes in the out-of-order disposal case.
const String kSecondText = 'second pushed body';

/// A dialog's body text.
const String kDialogText = 'dialog body';

/// Slack past a motion budget, so an assertion after it reads the settled
/// state rather than the last animating frame.
const Duration kSettleSlack = Duration(milliseconds: 40);

/// The default guarded root body.
Widget get _hubBody =>
    const Scaffold(body: Center(child: Text(kHubText)));

/// A guarded page route — the production shape every push site uses.
MaterialPageRoute<void> guardedRoute(String text) => MaterialPageRoute<void>(
      builder: (_) => SummonBackGuard(
        child: Scaffold(body: Center(child: Text(text))),
      ),
    );

/// The guard id minted by the [SummonBackGuard] enclosing [text].
///
/// Read through `SummonGuardScope`, which is exactly how a descendant asks the
/// question in production — the test never reaches into private state.
int guardIdOf(WidgetTester t, String text) {
  final scope =
      contextOf(t, text).getInheritedWidgetOfExactType<SummonGuardScope>();
  expect(scope, isNotNull, reason: 'every page route is wrapped in a guard');
  return scope!.guardId;
}

/// Advances past a full raise, so the surface is at rest before the case's
/// back gestures start.
Future<void> landRaise(WidgetTester t) async {
  await t.pump();
  await t.pump(kSummonRaiseDuration + kSettleSlack);
}

/// Advances past a full lower, so the slab has unmounted.
Future<void> landLower(WidgetTester t) async {
  await t.pump();
  await t.pump(kSummonLowerDuration + kSettleSlack);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(installSummonTestPlatforms);

  testWidgets(
      '1 — OWNERSHIP (D-13-02): three consecutive backs pop the pushed route '
      'with the surface still up, then lower, then exit', (t) async {
    final nav = GlobalKey<NavigatorState>();
    final observer = RecordingNavigatorObserver();
    await pumpShell(t, nav: nav, body: _hubBody, observers: [observer]);

    // Raise ON THE HUB — the hub's guard is the top of the stack, so the hub
    // owns the raise.
    final controller = SummonScope.of(contextOf(t, kHubText));
    final hubId = guardIdOf(t, kHubText);
    controller.raise(SummonSurfaceKind.trackpad);
    await landRaise(t);
    expect(controller.raised.value?.ownerGuardId, hubId);

    // Push a tool route AFTER the raise. Its guard mints a different id.
    unawaited(nav.currentState!.push(guardedRoute(kToolText)));
    await t.pumpAndSettle(); // navigation only
    expect(find.text(kToolText), findsOneWidget);
    expect(
      find.byKey(kSummonSurfaceKey),
      findsOneWidget,
      reason: 'the surface rides along onto the pushed route — raising and '
          'pushing are independent (SUM-02)',
    );
    expect(
      SummonScope.ownsRaisedSurface(contextOf(t, kToolText)),
      isFalse,
      reason: 'the pushed route did not raise it, so it must not intercept',
    );

    final popsBefore = observer.pops;

    // ── BACK 1 — the pushed route pops, the surface stays up ───────────────
    final first = await t.binding.handlePopRoute();
    await t.pumpAndSettle(); // navigation only

    expect(first, isTrue, reason: 'the framework handled the back by popping');
    expect(
      find.text(kToolText),
      findsNothing,
      reason: 'back on a route pushed AFTER the raise pops that route '
          'normally — its guard canPop is true and the hub guard below is '
          'never consulted (navigator.dart:5547)',
    );
    expect(
      controller.raised.value,
      isNotNull,
      reason: 'THE INVERSION TEST. A canPop keyed on "anything is raised" '
          'would have dismissed the surface here instead of popping, leaving '
          'the user unable to leave the tool screen without dismissing first '
          '(13-RESEARCH Pitfall B, D-13-02 inverted)',
    );
    expect(observer.pops, popsBefore + 1);
    expect(find.text(kHubText), findsOneWidget);

    // ── BACK 2 — the owner lowers, the route stack is untouched ────────────
    final popsAfterFirst = observer.pops;
    final second = await t.binding.handlePopRoute();
    await t.pump();

    expect(second, isTrue,
        reason: 'the guard blocked the pop and consumed the gesture');
    expect(
      controller.raised.value,
      isNull,
      reason: 'the hub owns the raise, so ITS back lowers the surface (SUM-04)',
    );
    expect(
      observer.pops,
      popsAfterFirst,
      reason: 'the route stack is unchanged — one gesture resolved exactly one '
          'thing, and that thing was the surface',
    );
    expect(find.text(kHubText), findsOneWidget);
    await landLower(t);

    // ── BACK 3 — nothing raised, so the app exits ──────────────────────────
    final third = await t.binding.handlePopRoute();
    await t.pump();

    expect(
      third,
      isFalse,
      reason: 'with nothing raised every guard canPop is true, the framework '
          'declines the back and Android exits the app. A static canPop of '
          'false here would freeze the phone on the dashboard (T-13-05)',
    );
    expect(find.text(kHubText), findsOneWidget);
    expect(observer.pops, popsAfterFirst);
  });

  testWidgets(
      '2 — THE ORPHAN (D-13-03): popping the owner by other means leaves the '
      'surface raised, un-owned, and dismissible only by the icon', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav, body: _hubBody);
    final controller = SummonScope.of(contextOf(t, kHubText));

    unawaited(nav.currentState!.push(guardedRoute(kToolText)));
    await t.pumpAndSettle(); // navigation only

    // Raise FROM THE PUSHED ROUTE — that route owns it.
    final toolId = guardIdOf(t, kToolText);
    controller.raise(SummonSurfaceKind.trackpad);
    await landRaise(t);
    expect(
      SummonScope.ownsRaisedSurface(contextOf(t, kToolText)),
      isTrue,
      reason: 'the pushed route raised it, so the pushed route owns it',
    );

    // The AppBar-arrow path: the owning route is popped WITHOUT a back
    // gesture, so the guard never runs and the surface is never lowered.
    nav.currentState!.pop();
    await t.pumpAndSettle(); // navigation only

    expect(find.text(kHubText), findsOneWidget);
    expect(
      controller.raised.value,
      isNotNull,
      reason: 'an orphaned surface stays raised — ownership transfer was '
          'offered and DECLINED (D-13-03), so nothing dismisses it on the way '
          'out',
    );
    expect(find.byKey(kSummonSurfaceKey), findsOneWidget);
    expect(
      controller.raised.value?.ownerGuardId,
      toolId,
      reason: 'the raise still records the DEAD id. Ownership evaporated '
          'because no LIVE guard carries that id, not because anything was '
          'cleared — that absence IS the whole mechanism (D-13-19)',
    );
    expect(
      SummonScope.ownsRaisedSurface(contextOf(t, kHubText)),
      isFalse,
      reason: 'the hub did not raise it and cannot inherit it',
    );

    // Back from the hub now exits the app WITH the surface still up.
    final handled = await t.binding.handlePopRoute();
    await t.pumpAndSettle(); // navigation only

    expect(
      handled,
      isFalse,
      reason: 'canPop is true on every live guard, so back exits the app with '
          'the surface still raised. That is the accepted trade stated '
          'explicitly by the owner in D-13-03, not a defect',
    );
    expect(controller.raised.value, isNotNull);
    expect(find.byKey(kSummonSurfaceKey), findsOneWidget);

    // The icon tap is the ONE affordance that still dismisses it.
    await t.tap(find.byKey(kSummonTrackpadIconKey));
    await t.pump();
    expect(
      controller.raised.value,
      isNull,
      reason: 'the bar is app-scope, so its icon never depended on the route '
          'that raised the surface',
    );
    await landLower(t);
    expect(find.byKey(kSummonSurfaceKey), findsNothing);
  });

  testWidgets(
      '3a — NO RETAINED ROUTE (D-13-19): after the owner dies no LIVE guard id '
      'owns the raise', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav, body: _hubBody);
    final controller = SummonScope.of(contextOf(t, kHubText));
    // Captured BEFORE the push: the hub's Text goes offstage under an opaque
    // route, so it is unreachable by a default Finder while the tool is up.
    final hubId = guardIdOf(t, kHubText);

    unawaited(nav.currentState!.push(guardedRoute(kToolText)));
    await t.pumpAndSettle(); // navigation only
    final toolId = guardIdOf(t, kToolText);
    controller.raise(SummonSurfaceKind.trackpad);
    await landRaise(t);
    expect(controller.ownsRaisedSurface(toolId), isTrue);

    nav.currentState!.pop();
    await t.pumpAndSettle(); // navigation only

    // EVERY live guard id — the hub's is the only one left.
    expect(
      controller.ownsRaisedSurface(hubId),
      isFalse,
      reason: 'no live route owns an orphaned surface',
    );
    expect(SummonScope.ownsRaisedSurface(contextOf(t, kHubText)), isFalse);
    expect(
      controller.raised.value?.ownerGuardId,
      toolId,
      reason: 'the record still names the dead id — "un-owned" is an ABSENT '
          'id, never a dangling reference',
    );

    // A fresh raise re-points ownership at the live top of the stack, which
    // proves the dead id left the stack rather than lingering at its top.
    controller.lower();
    await landLower(t);
    controller.raise(SummonSurfaceKind.keyboard);
    await landRaise(t);
    expect(
      controller.raised.value?.ownerGuardId,
      hubId,
      reason: 'stack.last is the hub once the tool guard has disposed',
    );
  });

  testWidgets(
      '3b — the guard stack is maintained BY VALUE: out-of-order disposal '
      'leaves exactly the surviving id', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav, body: _hubBody);
    final controller = SummonScope.of(contextOf(t, kHubText));
    final hubId = guardIdOf(t, kHubText);

    final first = guardedRoute(kFirstText);
    unawaited(nav.currentState!.push(first));
    await t.pumpAndSettle(); // navigation only
    final firstId = guardIdOf(t, kFirstText);

    unawaited(nav.currentState!.push(guardedRoute(kSecondText)));
    await t.pumpAndSettle(); // navigation only
    final secondId = guardIdOf(t, kSecondText);

    // Remove the FIRST pushed route out of order — it sits BELOW the second.
    // The stack was [hub, first, second]; by value it becomes [hub, second].
    nav.currentState!.removeRoute(first);
    await t.pumpAndSettle(); // navigation only
    expect(find.text(kSecondText), findsOneWidget);

    controller.raise(SummonSurfaceKind.trackpad);
    await landRaise(t);

    expect(
      controller.raised.value?.ownerGuardId,
      secondId,
      reason: 'stack.last must be the SURVIVING pushed route. An index-based '
          'removal would have retired the wrong entry and left [hub, first], '
          'silently handing ownership to a route that no longer exists',
    );
    expect(controller.ownsRaisedSurface(firstId), isFalse);
    expect(controller.ownsRaisedSurface(hubId), isFalse);

    // And the stack really is exactly [hub, second]: pop the survivor and the
    // next raise lands on the hub.
    controller.lower();
    await landLower(t);
    nav.currentState!.pop();
    await t.pumpAndSettle(); // navigation only
    controller.raise(SummonSurfaceKind.trackpad);
    await landRaise(t);
    expect(
      controller.raised.value?.ownerGuardId,
      hubId,
      reason: 'nothing but the hub id is left in the stack',
    );
  });

  test(
      '3c — neither shell file names a Route type in code: ownership retains '
      'no route object graph (D-13-19)', () {
    // The mechanism is an int stack, so a `Route` / `ModalRoute` /
    // `NavigatorState` field anywhere in these two files is the retention this
    // decision exists to exclude. Doc comments discuss `Route` at length and
    // are exempt — they explain the choice, they do not make it.
    const banned = <String>['ModalRoute', 'NavigatorState'];
    final routeWord = RegExp(r'\bRoute\b');
    final offenders = <String>[];

    for (final path in const [
      'lib/shell/summon_scope.dart',
      'lib/shell/summon_back_guard.dart',
    ]) {
      final lines = File(path).readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        final trimmed = lines[i].trim();
        if (trimmed.startsWith('//')) continue;
        for (final token in banned) {
          if (lines[i].contains(token)) {
            offenders.add('$path:${i + 1} names $token');
          }
        }
        if (routeWord.hasMatch(lines[i])) {
          offenders.add('$path:${i + 1} names a bare Route type');
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason: 'ownership is a monotonic int guard-id stack (D-13-19). Holding '
          'a Route would retain a popped MaterialPageRoute — its animation '
          'controllers, settings and overlay entries — for as long as a '
          'surface stays orphaned, and would make "un-owned" a dangling '
          'pointer instead of an absent id',
    );
  });

  testWidgets(
      '4 — MODAL ROUTES STAY UN-GUARDED: a dialog is closed by the first back '
      'and the raised surface is untouched', (t) async {
    final nav = GlobalKey<NavigatorState>();
    await pumpShell(t, nav: nav, body: _hubBody);
    final hubContext = contextOf(t, kHubText);
    final controller = SummonScope.of(hubContext);

    controller.raise(SummonSurfaceKind.trackpad);
    await landRaise(t);
    expect(SummonScope.ownsRaisedSurface(hubContext), isTrue);

    unawaited(
      showDialog<void>(
        context: hubContext,
        builder: (_) => const AlertDialog(content: Text(kDialogText)),
      ),
    );
    await t.pumpAndSettle(); // navigation only
    expect(find.text(kDialogText), findsOneWidget);

    final handled = await t.binding.handlePopRoute();
    await t.pumpAndSettle(); // navigation only

    expect(handled, isTrue);
    expect(
      find.text(kDialogText),
      findsNothing,
      reason: 'the dialog is the topmost present route, so it is the only one '
          'consulted — the hub guard below never participates',
    );
    expect(
      controller.raised.value,
      isNotNull,
      reason: 'INTENDED behaviour, not a gap: the six modal sites are '
          'deliberately un-guarded and nobody should wire guards into them. '
          'The surface is dismissed by the NEXT back, on the route that owns '
          'it',
    );
    expect(find.byKey(kSummonSurfaceKey), findsOneWidget);

    // The very next back is the owner's, and it lowers.
    final next = await t.binding.handlePopRoute();
    await t.pump();
    expect(next, isTrue);
    expect(controller.raised.value, isNull);
    await landLower(t);
  });
}
